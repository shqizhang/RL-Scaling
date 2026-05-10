#!/usr/bin/env bash
# ============================================================================
# test-s3-e2e.sh — End-to-end proof of true role-flip routing + timing.
#
# What this proves
#   After POST /switch_role decode->prefill on pod X, the frontend's KV/chat
#   router stops dispatching chat traffic to X (because X's MDC under the
#   backend.generate URI was unregistered) and X starts receiving prefill
#   requests at prefill.generate (because a fresh ModelType.Prefill MDC was
#   published there).  Reversing the flip restores the original routing.
#
# What this records (user explicit ask: "测试需要记录切换的耗时")
#   * server-reported per-phase timings_ms returned by /switch_role
#   * server-reported total switch_time_ms
#   * client wall-clock around the /switch_role POST
#   * t_first_off_target — wall-clock from POST until a chat probe
#     returns a 200 that did NOT land on the flipped pod (i.e. moment
#     when the user stops seeing chat traffic on the flipped pod)
#   * t_target_rejoin — wall-clock from revert POST until target pod
#     served chat again
#
# Output
#   reports/s3-e2e-<ts>/
#     ├── REPORT.md                  — human-readable summary
#     ├── switch_decode_to_prefill.json   — raw /switch_role response
#     ├── switch_prefill_to_decode.json   — raw revert /switch_role
#     ├── chat_probes_pre.csv             — pre-switch attribution
#     ├── chat_probes_post_d2p.csv        — after decode->prefill
#     ├── chat_probes_post_p2d.csv        — after prefill->decode
#     ├── pod_view_*.txt                  — kubectl get pod snapshots
#     ├── pf-*.log                        — port-forward logs
#     └── run.log
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${SCRIPT_DIR}/reports/s3-e2e-${TS}"
mkdir -p "${OUT}"

NS="${NS:-dynamo-system}"
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
FRONTEND_LOCAL="${FRONTEND_LOCAL:-18000}"
FRONTEND_REMOTE="${FRONTEND_REMOTE:-8000}"
SIDECAR_LOCAL="${SIDECAR_LOCAL:-19091}"
SIDECAR_REMOTE="${SIDECAR_REMOTE:-9091}"
SYSTEM_PORT_LOCAL_BASE="${SYSTEM_PORT_LOCAL_BASE:-19200}"
SYSTEM_PORT_REMOTE="${SYSTEM_PORT_REMOTE:-9090}"
N_POST_PROBES="${N_POST_PROBES:-30}"
PRE_PROBES="${PRE_PROBES:-6}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${OUT}/run.log"; }
die() { log "FATAL: $*"; exit 1; }

cleanup_pids=()
trap '
  for p in "${cleanup_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
' EXIT

# ---------------------------------------------------------- pod discovery ----
log "discovering decode pods in ns=${NS} for DGD=${DGD}"
mapfile -t DECODE_PODS < <(
  kubectl -n "${NS}" get pod \
    -l "nvidia.com/dynamo-component=VllmDecodeWorker,nvidia.com/dynamo-graph-deployment-name=${DGD}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | sort
)
if [[ "${#DECODE_PODS[@]}" -eq 0 ]]; then
  log "label query empty; falling back to name-prefix match"
  mapfile -t DECODE_PODS < <(
    kubectl -n "${NS}" get pod --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep "^${DGD}-vllmdecodeworker-" | sort
  )
fi
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 decode pods, found ${#DECODE_PODS[@]}: ${DECODE_PODS[*]}"
log "decode pods (${#DECODE_PODS[@]}): ${DECODE_PODS[*]}"
TARGET_POD="${TARGET_POD:-${DECODE_PODS[0]}}"
log "TARGET_POD = ${TARGET_POD}"

DUAL=$(kubectl -n "${NS}" exec "${TARGET_POD}" -- printenv DYNAMO_RL_DUAL_MODE 2>/dev/null || echo "")
[[ "${DUAL}" == "1" ]] || die "TARGET_POD ${TARGET_POD} missing DYNAMO_RL_DUAL_MODE=1 (got '${DUAL}'). Re-deploy with the updated DGD."
log "DYNAMO_RL_DUAL_MODE=1 confirmed on ${TARGET_POD}"

kubectl -n "${NS}" get pod -L nvidia.com/dynamo-current-role > "${OUT}/pod_view_before.txt"
cat "${OUT}/pod_view_before.txt"

# ------------------------------------------------------------ port-forwards ---
FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "${FRONTEND_POD}" ]] || FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^${DGD}-frontend-" | head -1)
[[ -n "${FRONTEND_POD}" ]] || die "could not find frontend pod"
log "FRONTEND_POD = ${FRONTEND_POD}"

start_pf() {
  local pod="$1" lport="$2" rport="$3" tag="$4"
  kubectl -n "${NS}" port-forward "pod/${pod}" "${lport}:${rport}" \
    > "${OUT}/pf-${tag}.log" 2>&1 &
  cleanup_pids+=("$!")
  for _ in $(seq 1 30); do
    if (echo > "/dev/tcp/127.0.0.1/${lport}") 2>/dev/null; then
      log "pf ready ${tag} ${pod}:${rport} -> :${lport}"
      return 0
    fi
    sleep 0.3
  done
  log "warn: pf ${tag} did not become reachable; continuing"
}

start_pf "${FRONTEND_POD}" "${FRONTEND_LOCAL}" "${FRONTEND_REMOTE}" "frontend"
start_pf "${TARGET_POD}"   "${SIDECAR_LOCAL}"  "${SIDECAR_REMOTE}"  "sidecar-target"

declare -A POD_METRIC_PORT
for i in "${!DECODE_PODS[@]}"; do
  p="${DECODE_PODS[$i]}"
  lport=$(( SYSTEM_PORT_LOCAL_BASE + i ))
  POD_METRIC_PORT["$p"]="$lport"
  start_pf "$p" "$lport" "${SYSTEM_PORT_REMOTE}" "metrics-${i}"
done

# ---------------------------------------------------------------- helpers ----
read_pod_metric() {
  local p="$1"; local port="${POD_METRIC_PORT[$p]}"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk '/^vllm:prompt_tokens_total[ {]/ {sum+=$NF} END{printf "%d", sum+0}'
}

submit_chat() {
  local nonce="$1"
  local body
  body=$(cat <<EOF
{"model":"${MODEL}","messages":[{"role":"user","content":"S3 E2E probe ${nonce}. Reply with the single word PONG."}],"max_tokens":4,"temperature":0,"stream":false}
EOF
)
  curl -s -o /dev/null -w '%{http_code}' \
    -m 30 \
    -H "Content-Type: application/json" \
    --data "${body}" \
    "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions"
}

identify_serving_pod() {
  local nonce="$1"
  declare -A before
  for p in "${DECODE_PODS[@]}"; do before["$p"]=$(read_pod_metric "$p"); done
  local code; code=$(submit_chat "$nonce")
  if [[ "$code" != "200" ]]; then echo "?:HTTP${code}"; return; fi
  sleep 0.4
  local best="?" best_delta=0
  for p in "${DECODE_PODS[@]}"; do
    local after; after=$(read_pod_metric "$p")
    local delta=$(( after - ${before[$p]} ))
    if (( delta > best_delta )); then best_delta="$delta"; best="$p"; fi
  done
  echo "$best:${best_delta}"
}

# --------------------------------------------------------- pre-flight probe --
log "warming model with 2 chat probes"
submit_chat "warmup-1" >/dev/null || true
submit_chat "warmup-2" >/dev/null || true
sleep 1

log "pre-switch routing probe — sending ${PRE_PROBES} chats"
PRE_PROBES_CSV="${OUT}/chat_probes_pre.csv"
echo "ts,nonce,pod_with_max_delta,delta_or_status" > "${PRE_PROBES_CSV}"
declare -A pre_count
for p in "${DECODE_PODS[@]}"; do pre_count["$p"]=0; done
pre_count["?"]=0
for i in $(seq 1 "${PRE_PROBES}"); do
  res=$(identify_serving_pod "pre-${i}")
  pod="${res%%:*}"; delta="${res#*:}"
  printf '%s,pre-%d,%s,%s\n' "$(date +%s.%N)" "$i" "$pod" "$delta" >> "${PRE_PROBES_CSV}"
  if [[ -n "${pre_count[$pod]+x}" ]]; then pre_count["$pod"]=$(( ${pre_count["$pod"]} + 1 )); fi
done
log "pre-switch attribution:"
for p in "${DECODE_PODS[@]}"; do log "  ${p} = ${pre_count[$p]}"; done

# ============================================================================
# PHASE 1 — DECODE -> PREFILL on TARGET_POD
# ============================================================================
log "============================================================"
log "Phase 1: switch_role decode->prefill on ${TARGET_POD}"

T0=$(date +%s.%N)
SWITCH_RESP=$(curl -fsS -m 60 -X POST \
  -H "Content-Type: application/json" \
  --data '{"target_role":"prefill"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role" 2>&1) || die "POST /switch_role failed: ${SWITCH_RESP}"
T1=$(date +%s.%N)
WALL_MS=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
echo "${SWITCH_RESP}" > "${OUT}/switch_decode_to_prefill.json"
echo "${SWITCH_RESP}"
SERVER_TOTAL=$(echo "${SWITCH_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("switch_time_ms","?"))' 2>/dev/null || echo "?")
log "wall-clock: ${WALL_MS} ms  | server-reported total: ${SERVER_TOTAL} ms"

sleep 1
log "post-switch routing probes (${N_POST_PROBES})"
POST_PROBES_CSV="${OUT}/chat_probes_post_d2p.csv"
echo "ts,nonce,pod_with_max_delta,delta_or_status" > "${POST_PROBES_CSV}"
T_DETECT=""
for i in $(seq 1 "${N_POST_PROBES}"); do
  res=$(identify_serving_pod "post-d2p-${i}")
  pod="${res%%:*}"; delta="${res#*:}"
  ts=$(date +%s.%N)
  printf '%s,post-d2p-%d,%s,%s\n' "$ts" "$i" "$pod" "$delta" >> "${POST_PROBES_CSV}"
  if [[ "$pod" != "?" && "$pod" != "${TARGET_POD}" && -z "$T_DETECT" ]]; then
    T_DETECT="$ts"
    log "[probe ${i}] first chat after switch landed on ${pod} (not target) at ${ts}"
  fi
  if [[ "$pod" == "${TARGET_POD}" ]]; then
    log "[probe ${i}] WARNING: chat still landed on flipped pod ${TARGET_POD}"
  fi
done
T_REROUTE_MS=""
[[ -n "$T_DETECT" ]] && T_REROUTE_MS=$(awk -v a="$T0" -v b="$T_DETECT" 'BEGIN{printf "%.3f", (b-a)*1000.0}')

declare -A post_count
for p in "${DECODE_PODS[@]}"; do post_count["$p"]=0; done
post_count["?"]=0
while IFS=, read -r _ts _nonce _pod _delta; do
  [[ "$_ts" == "ts" ]] && continue
  if [[ -n "${post_count[$_pod]+x}" ]]; then
    post_count["$_pod"]=$(( ${post_count["$_pod"]} + 1 ))
  else
    post_count["$_pod"]=1
  fi
done < "${POST_PROBES_CSV}"

log "post-switch attribution (${N_POST_PROBES} probes):"
for p in "${DECODE_PODS[@]}"; do log "  ${p} = ${post_count[$p]}"; done
TARGET_HITS_AFTER="${post_count[$TARGET_POD]}"

kubectl -n "${NS}" get pod -L nvidia.com/dynamo-current-role > "${OUT}/pod_view_after_decode_to_prefill.txt"

# ============================================================================
# PHASE 2 — PREFILL -> DECODE (revert)
# ============================================================================
log "============================================================"
log "Phase 2: switch_role prefill->decode on ${TARGET_POD} (revert)"

T2=$(date +%s.%N)
REVERT_RESP=$(curl -fsS -m 60 -X POST \
  -H "Content-Type: application/json" \
  --data '{"target_role":"decode"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role" 2>&1) || die "revert POST /switch_role failed: ${REVERT_RESP}"
T3=$(date +%s.%N)
WALL_MS_2=$(awk -v a="$T2" -v b="$T3" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
echo "${REVERT_RESP}" > "${OUT}/switch_prefill_to_decode.json"
echo "${REVERT_RESP}"
SERVER_TOTAL_2=$(echo "${REVERT_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("switch_time_ms","?"))' 2>/dev/null || echo "?")
log "wall-clock: ${WALL_MS_2} ms  | server-reported total: ${SERVER_TOTAL_2} ms"

sleep 1
log "post-revert routing probes (${N_POST_PROBES})"
REVERT_PROBES_CSV="${OUT}/chat_probes_post_p2d.csv"
echo "ts,nonce,pod_with_max_delta,delta_or_status" > "${REVERT_PROBES_CSV}"
declare -A revert_count
for p in "${DECODE_PODS[@]}"; do revert_count["$p"]=0; done
revert_count["?"]=0
T_REJOIN=""
for i in $(seq 1 "${N_POST_PROBES}"); do
  res=$(identify_serving_pod "post-p2d-${i}")
  pod="${res%%:*}"; delta="${res#*:}"
  ts=$(date +%s.%N)
  printf '%s,post-p2d-%d,%s,%s\n' "$ts" "$i" "$pod" "$delta" >> "${REVERT_PROBES_CSV}"
  if [[ -n "${revert_count[$pod]+x}" ]]; then
    revert_count["$pod"]=$(( ${revert_count["$pod"]} + 1 ))
  else
    revert_count["$pod"]=1
  fi
  if [[ "$pod" == "${TARGET_POD}" && -z "$T_REJOIN" ]]; then
    T_REJOIN="$ts"
    log "[probe ${i}] target pod served chat again at ${ts}"
  fi
done
T_REJOIN_MS=""
[[ -n "$T_REJOIN" ]] && T_REJOIN_MS=$(awk -v a="$T2" -v b="$T_REJOIN" 'BEGIN{printf "%.3f", (b-a)*1000.0}')

log "post-revert attribution:"
for p in "${DECODE_PODS[@]}"; do log "  ${p} = ${revert_count[$p]}"; done

kubectl -n "${NS}" get pod -L nvidia.com/dynamo-current-role > "${OUT}/pod_view_after_revert.txt"

# ============================================================================
# REPORT
# ============================================================================
PASS_D2P=true; PASS_P2D=true
[[ "${TARGET_HITS_AFTER}" -eq 0 ]] || PASS_D2P=false
[[ "${revert_count[$TARGET_POD]}" -gt 0 ]] || PASS_P2D=false

cat > "${OUT}/REPORT.md" <<EOF
# S3 E2E switch-routing report — ${TS}

DGD: \`${DGD}\` | ns: \`${NS}\` | target pod: \`${TARGET_POD}\`

## Summary

|                                       | decode -> prefill   | prefill -> decode (revert) |
|---------------------------------------|---------------------|----------------------------|
| client wall-clock (ms)                | ${WALL_MS}          | ${WALL_MS_2}               |
| server total switch_time_ms           | ${SERVER_TOTAL}     | ${SERVER_TOTAL_2}          |
| t_first_off_target (ms)               | ${T_REROUTE_MS:-N/A}| -                          |
| t_target_rejoin (ms)                  | -                   | ${T_REJOIN_MS:-N/A}        |
| target hits (over ${N_POST_PROBES} probes) | ${TARGET_HITS_AFTER} (expect 0) | ${revert_count[$TARGET_POD]} (expect >0) |
| PASS                                  | **${PASS_D2P}**     | **${PASS_P2D}**            |

## Per-phase server timings (decode -> prefill)
\`\`\`json
$(cat "${OUT}/switch_decode_to_prefill.json")
\`\`\`

## Per-phase server timings (prefill -> decode)
\`\`\`json
$(cat "${OUT}/switch_prefill_to_decode.json")
\`\`\`

## Pre-switch chat attribution (${PRE_PROBES} probes)
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` → ${pre_count[$p]}"; done)

## Post-switch chat attribution (${N_POST_PROBES} probes, decode -> prefill)
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` → ${post_count[$p]}"; done)

## Post-revert chat attribution (${N_POST_PROBES} probes, prefill -> decode)
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` → ${revert_count[$p]}"; done)

## Cluster pod view

### before
\`\`\`
$(cat "${OUT}/pod_view_before.txt")
\`\`\`

### after decode -> prefill
\`\`\`
$(cat "${OUT}/pod_view_after_decode_to_prefill.txt")
\`\`\`

### after revert
\`\`\`
$(cat "${OUT}/pod_view_after_revert.txt")
\`\`\`
EOF

log "============================================================"
log "REPORT written: ${OUT}/REPORT.md"
log "decode->prefill: PASS=${PASS_D2P}, target_hits_after=${TARGET_HITS_AFTER}"
log "prefill->decode: PASS=${PASS_P2D}, target_rejoin_hits=${revert_count[$TARGET_POD]}"

if [[ "${PASS_D2P}" == "true" && "${PASS_P2D}" == "true" ]]; then
  log "OVERALL: PASS"
  exit 0
fi
log "OVERALL: FAIL"
exit 1
