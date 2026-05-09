#!/usr/bin/env bash
# E2E proof of true role-flip routing + timing capture.
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
trap 'for p in "${cleanup_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done' EXIT

log "discovering decode pods in ns=${NS} for DGD=${DGD}"
mapfile -t DECODE_PODS < <(
  kubectl -n "${NS}" get pod \
    -l "nvidia.com/dynamo-component=VllmDecodeWorker,nvidia.com/dynamo-graph-deployment-name=${DGD}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | sort
)
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 decode pods, found ${#DECODE_PODS[@]}: ${DECODE_PODS[*]}"
log "decode pods (${#DECODE_PODS[@]}): ${DECODE_PODS[*]}"
TARGET_POD="${TARGET_POD:-${DECODE_PODS[0]}}"
log "TARGET_POD = ${TARGET_POD}"

DUAL=$(kubectl -n "${NS}" exec "${TARGET_POD}" -- printenv DYNAMO_RL_DUAL_MODE 2>/dev/null || echo "")
[[ "${DUAL}" == "1" ]] || die "TARGET_POD ${TARGET_POD} missing DYNAMO_RL_DUAL_MODE=1 (got '${DUAL}')."
log "DYNAMO_RL_DUAL_MODE=1 confirmed"

kubectl -n "${NS}" get pod -L nvidia.com/dynamo-current-role > "${OUT}/pod_view_before.txt"

FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "${FRONTEND_POD}" ]] || die "could not find frontend pod"
log "FRONTEND_POD = ${FRONTEND_POD}"

start_pf() {
  local pod="$1" lport="$2" rport="$3" tag="$4"
  kubectl -n "${NS}" port-forward "pod/${pod}" "${lport}:${rport}" \
    > "${OUT}/pf-${tag}.log" 2>&1 &
  cleanup_pids+=("$!")
  for _ in $(seq 1 30); do
    if (echo > "/dev/tcp/127.0.0.1/${lport}") 2>/dev/null; then
      log "pf ready ${tag} ${pod}:${rport} -> :${lport}"; return 0
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

read_pod_metric() {
  local p="$1"; local port="${POD_METRIC_PORT[$p]}"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk '/^vllm:prompt_tokens_total[ {]/ {sum+=$NF} END{printf "%d", sum+0}'
}

submit_chat() {
  local nonce="$1"
  local body="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"S3 E2E probe ${nonce}.\"}],\"max_tokens\":4,\"temperature\":0,\"stream\":false}"
  curl -s -o /dev/null -w '%{http_code}' -m 30 \
    -H "Content-Type: application/json" --data "${body}" \
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

log "warming model"
submit_chat "warmup-1" >/dev/null || true
submit_chat "warmup-2" >/dev/null || true
sleep 1

log "pre-switch routing probes (${PRE_PROBES})"
PRE_CSV="${OUT}/chat_probes_pre.csv"
echo "ts,nonce,pod,delta" > "${PRE_CSV}"
declare -A pre_count
for p in "${DECODE_PODS[@]}"; do pre_count["$p"]=0; done
pre_count["?"]=0
for i in $(seq 1 "${PRE_PROBES}"); do
  res=$(identify_serving_pod "pre-${i}")
  pod="${res%%:*}"; delta="${res#*:}"
  printf '%s,pre-%d,%s,%s\n' "$(date +%s.%N)" "$i" "$pod" "$delta" >> "${PRE_CSV}"
  if [[ -n "${pre_count[$pod]+x}" ]]; then pre_count["$pod"]=$(( ${pre_count["$pod"]} + 1 )); fi
done
log "pre attribution:"; for p in "${DECODE_PODS[@]}"; do log "  ${p} = ${pre_count[$p]}"; done

log "==== Phase 1: switch_role decode->prefill on ${TARGET_POD}"
T0=$(date +%s.%N)
SWITCH_RESP=$(curl -fsS -m 60 -X POST -H "Content-Type: application/json" \
  --data '{"target_role":"prefill"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role") || die "POST /switch_role failed"
T1=$(date +%s.%N)
WALL_MS=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
echo "${SWITCH_RESP}" > "${OUT}/switch_decode_to_prefill.json"
echo "${SWITCH_RESP}"
SERVER_TOTAL=$(echo "${SWITCH_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("switch_time_ms","?"))' 2>/dev/null || echo "?")
log "wall-clock: ${WALL_MS} ms | server total: ${SERVER_TOTAL} ms"

sleep 1
log "post-switch probes (${N_POST_PROBES})"
POST_CSV="${OUT}/chat_probes_post_d2p.csv"
echo "ts,nonce,pod,delta" > "${POST_CSV}"
T_DETECT=""
for i in $(seq 1 "${N_POST_PROBES}"); do
  res=$(identify_serving_pod "post-d2p-${i}")
  pod="${res%%:*}"; delta="${res#*:}"
  ts=$(date +%s.%N)
  printf '%s,post-d2p-%d,%s,%s\n' "$ts" "$i" "$pod" "$delta" >> "${POST_CSV}"
  if [[ "$pod" != "?" && "$pod" != "${TARGET_POD}" && -z "$T_DETECT" ]]; then
    T_DETECT="$ts"
    log "[probe ${i}] first chat off-target landed on ${pod}"
  fi
  if [[ "$pod" == "${TARGET_POD}" ]]; then
    log "[probe ${i}] WARNING chat still on flipped pod ${TARGET_POD}"
  fi
done
T_REROUTE_MS=""
[[ -n "$T_DETECT" ]] && T_REROUTE_MS=$(awk -v a="$T0" -v b="$T_DETECT" 'BEGIN{printf "%.3f", (b-a)*1000.0}')

declare -A post_count
for p in "${DECODE_PODS[@]}"; do post_count["$p"]=0; done
post_count["?"]=0
while IFS=, read -r _ts _nonce _pod _delta; do
  [[ "$_ts" == "ts" ]] && continue
  if [[ -n "${post_count[$_pod]+x}" ]]; then post_count["$_pod"]=$(( ${post_count["$_pod"]} + 1 )); else post_count["$_pod"]=1; fi
done < "${POST_CSV}"
log "post-switch attribution:"
for p in "${DECODE_PODS[@]}"; do log "  ${p} = ${post_count[$p]}"; done
TARGET_HITS_AFTER="${post_count[$TARGET_POD]}"

kubectl -n "${NS}" get pod -L nvidia.com/dynamo-current-role > "${OUT}/pod_view_after_d2p.txt"

log "==== Phase 2: revert prefill->decode on ${TARGET_POD}"
T2=$(date +%s.%N)
REVERT_RESP=$(curl -fsS -m 60 -X POST -H "Content-Type: application/json" \
  --data '{"target_role":"decode"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role") || die "revert POST failed"
T3=$(date +%s.%N)
WALL_MS_2=$(awk -v a="$T2" -v b="$T3" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
echo "${REVERT_RESP}" > "${OUT}/switch_prefill_to_decode.json"
echo "${REVERT_RESP}"
SERVER_TOTAL_2=$(echo "${REVERT_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("switch_time_ms","?"))' 2>/dev/null || echo "?")
log "wall-clock: ${WALL_MS_2} ms | server total: ${SERVER_TOTAL_2} ms"

sleep 1
REVERT_CSV="${OUT}/chat_probes_post_p2d.csv"
echo "ts,nonce,pod,delta" > "${REVERT_CSV}"
declare -A revert_count
for p in "${DECODE_PODS[@]}"; do revert_count["$p"]=0; done
revert_count["?"]=0
T_REJOIN=""
for i in $(seq 1 "${N_POST_PROBES}"); do
  res=$(identify_serving_pod "post-p2d-${i}")
  pod="${res%%:*}"; delta="${res#*:}"
  ts=$(date +%s.%N)
  printf '%s,post-p2d-%d,%s,%s\n' "$ts" "$i" "$pod" "$delta" >> "${REVERT_CSV}"
  if [[ -n "${revert_count[$pod]+x}" ]]; then revert_count["$pod"]=$(( ${revert_count["$pod"]} + 1 )); else revert_count["$pod"]=1; fi
  if [[ "$pod" == "${TARGET_POD}" && -z "$T_REJOIN" ]]; then
    T_REJOIN="$ts"; log "[probe ${i}] target rejoined chat pool"
  fi
done
T_REJOIN_MS=""
[[ -n "$T_REJOIN" ]] && T_REJOIN_MS=$(awk -v a="$T2" -v b="$T_REJOIN" 'BEGIN{printf "%.3f", (b-a)*1000.0}')

log "post-revert attribution:"
for p in "${DECODE_PODS[@]}"; do log "  ${p} = ${revert_count[$p]}"; done

kubectl -n "${NS}" get pod -L nvidia.com/dynamo-current-role > "${OUT}/pod_view_after_revert.txt"

PASS_D2P=true; PASS_P2D=true
[[ "${TARGET_HITS_AFTER}" -eq 0 ]] || PASS_D2P=false
[[ "${revert_count[$TARGET_POD]}" -gt 0 ]] || PASS_P2D=false

cat > "${OUT}/REPORT.md" <<REPORT_EOF
# S3 E2E switch-routing report — ${TS}

DGD: \`${DGD}\` | ns: \`${NS}\` | target: \`${TARGET_POD}\`

## Summary

|                                    | decode -> prefill   | prefill -> decode (revert) |
|------------------------------------|---------------------|----------------------------|
| client wall-clock (ms)             | ${WALL_MS}          | ${WALL_MS_2}               |
| server total switch_time_ms        | ${SERVER_TOTAL}     | ${SERVER_TOTAL_2}          |
| t_first_off_target (ms)            | ${T_REROUTE_MS:-N/A}| -                          |
| t_target_rejoin (ms)               | -                   | ${T_REJOIN_MS:-N/A}        |
| target hits over ${N_POST_PROBES} probes | ${TARGET_HITS_AFTER} (expect 0) | ${revert_count[$TARGET_POD]} (expect >0) |
| PASS                               | **${PASS_D2P}**     | **${PASS_P2D}**            |

## /switch_role response (decode -> prefill)
\`\`\`json
$(cat "${OUT}/switch_decode_to_prefill.json")
\`\`\`

## /switch_role response (prefill -> decode)
\`\`\`json
$(cat "${OUT}/switch_prefill_to_decode.json")
\`\`\`

## Attribution

### pre-switch (${PRE_PROBES} probes)
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` -> ${pre_count[$p]}"; done)

### post-switch decode->prefill (${N_POST_PROBES} probes)
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` -> ${post_count[$p]}"; done)

### post-revert prefill->decode (${N_POST_PROBES} probes)
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` -> ${revert_count[$p]}"; done)
REPORT_EOF

log "REPORT: ${OUT}/REPORT.md"
log "decode->prefill PASS=${PASS_D2P}  hits=${TARGET_HITS_AFTER}"
log "prefill->decode PASS=${PASS_P2D}  rejoin_hits=${revert_count[$TARGET_POD]}"
if [[ "${PASS_D2P}" == "true" && "${PASS_P2D}" == "true" ]]; then
  log "OVERALL: PASS"; exit 0
fi
log "OVERALL: FAIL"; exit 1
