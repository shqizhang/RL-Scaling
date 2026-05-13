#!/usr/bin/env bash
# ============================================================================
# test-s2-elastic.sh — S2: Elastic PD role switch end-to-end test.
#
# Proves that a decode worker can switch to prefill (and back) while the
# cluster continues serving requests.  After each switch, heavy load is
# driven to demonstrate the target pod correctly serves the expected role.
#
# Pass criteria:
#   PASS_CR_D2P     : CR loses backend/generate model_card after switch
#   PASS_CR_P2D     : CR regains it after revert
#   PASS_PREFILL    : target's prompt_tokens_total grew (prefill serving)
#   PASS_DECODE     : target's generation_tokens_total grew after revert
#   PASS_LOAD       : sustained load during switch window, <=2 errors
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${SCRIPT_DIR}/reports/s2-elastic-${TS}"
mkdir -p "${OUT}"

NS="${NS:-dynamo-system}"
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
FRONTEND_LOCAL="${FRONTEND_LOCAL:-18000}"
SIDECAR_LOCAL="${SIDECAR_LOCAL:-19091}"
METRIC_BASE="${METRIC_BASE:-19200}"
N_PROBES="${N_PROBES:-30}"
LOAD_RPS="${LOAD_RPS:-2}"
LOAD_DUR="${LOAD_DUR:-30}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${OUT}/run.log"; }
die() { log "FATAL: $*"; exit 1; }

cleanup_pids=()
trap 'for p in "${cleanup_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done' EXIT

# ----------------------------------------------------------- discover pods (Ready only)
mapfile -t DECODE_PODS < <(
  kubectl -n "${NS}" get pod \
    -l "nvidia.com/dynamo-component=VllmDecodeWorker,nvidia.com/dynamo-graph-deployment-name=${DGD}" \
    --field-selector=status.phase=Running \
    -o json 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in item.get("status", {}).get("conditions", [])
    )
    if ready:
        print(item["metadata"]["name"])
' | sort
)
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 ready decode pods (have ${#DECODE_PODS[@]})"
TARGET_POD="${TARGET_POD:-${DECODE_PODS[0]}}"
PEER_POD=""
for p in "${DECODE_PODS[@]}"; do [[ "$p" != "$TARGET_POD" ]] && PEER_POD="$p" && break; done
log "TARGET=${TARGET_POD}"
log "PEER  =${PEER_POD}"

DUAL=$(kubectl -n "${NS}" exec "${TARGET_POD}" -- printenv DYNAMO_RL_DUAL_MODE 2>/dev/null || echo "")
[[ "${DUAL}" == "1" ]] || die "TARGET missing DYNAMO_RL_DUAL_MODE=1"

FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || die "frontend not found"
log "FRONTEND=${FRONTEND_POD}"

# ----------------------------------------------------------- port-forwards
start_pf() {
  local pod="$1" lport="$2" rport="$3" tag="$4"
  kubectl -n "${NS}" port-forward "pod/${pod}" "${lport}:${rport}" \
    > "${OUT}/pf-${tag}.log" 2>&1 &
  cleanup_pids+=("$!")
  for _ in $(seq 1 30); do
    (echo > "/dev/tcp/127.0.0.1/${lport}") 2>/dev/null && return 0
    sleep 0.3
  done
  log "warn: pf ${tag} not reachable"
}

start_pf "${FRONTEND_POD}" "${FRONTEND_LOCAL}" 8000  "frontend"
start_pf "${TARGET_POD}"   "${SIDECAR_LOCAL}"  9091  "sidecar"

declare -A POD_METRIC_PORT
for i in "${!DECODE_PODS[@]}"; do
  p="${DECODE_PODS[$i]}"
  lport=$(( METRIC_BASE + i ))
  POD_METRIC_PORT["$p"]="$lport"
  start_pf "$p" "$lport" 9090 "metrics-$i"
done

# ----------------------------------------------------------- helpers
read_metric() {
  local port="$1" pat="$2"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk -v p="$pat" '$0 ~ p && $0 !~ /^#/ {print $NF}' | tail -1
}

read_prompt_tokens() {
  local p="$1" port="${POD_METRIC_PORT[$p]}"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk '/^vllm:prompt_tokens_total[ {]/ {sum+=$NF} END{printf "%d", sum+0}'
}

read_gen_tokens() {
  local p="$1" port="${POD_METRIC_PORT[$p]}"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk '/^vllm:generation_tokens_total[ {]/ {sum+=$NF} END{printf "%d", sum+0}'
}

dump_target_cr() {
  local label="$1"
  kubectl -n "${NS}" get dynamoworkermetadata "${TARGET_POD}" -o json \
    > "${OUT}/cr-${label}.json" 2>/dev/null || true
}

count_decode_mdc_in_cr() {
  local label="$1"
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
mc = (data.get("spec") or {}).get("data", {}).get("model_cards", {}) or {}
eps = (data.get("spec") or {}).get("data", {}).get("endpoints", {}) or {}
n_mc = sum(1 for k in mc if "/backend/generate/" in k)
n_ep = sum(1 for k in eps if "/backend/generate/" in k)
print(f"{n_mc} {n_ep}")
' "${OUT}/cr-${label}.json"
}

submit_chat() {
  local nonce="$1" max_tokens="${2:-4}"
  curl -s -m 30 \
    -H "Content-Type: application/json" \
    --data "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"S2 probe ${nonce}.\"}],\"max_tokens\":${max_tokens},\"temperature\":0,\"stream\":false}" \
    "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions"
}

submit_chat_code() {
  local nonce="$1" max_tokens="${2:-4}"
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -m 30 \
    -H "Content-Type: application/json" \
    --data "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"S2 load ${nonce}.\"}],\"max_tokens\":${max_tokens},\"temperature\":0,\"stream\":false}" \
    "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions"
}

capture_worker_log() {
  local pod="$1" label="$2" lines="${3:-200}"
  kubectl -n "${NS}" logs "${pod}" --tail="${lines}" \
    > "${OUT}/workerlog-${label}.txt" 2>/dev/null || true
}

# ----------------------------------------------------------- pre-state
log "warming model"
submit_chat warmup-1 4 > /dev/null || true
sleep 1

dump_target_cr before
PRE_CR=$(count_decode_mdc_in_cr before)
PRE_MC=$(echo $PRE_CR | awk '{print $1}')
log "PRE CR: model_cards=${PRE_MC}  endpoints=$(echo $PRE_CR | awk '{print $2}')"
[[ "${PRE_MC}" == "1" ]] || die "expected 1 backend/generate model_card pre-switch"

TGT_PROMPT_PRE=$(read_prompt_tokens "${TARGET_POD}")
TGT_GEN_PRE=$(read_gen_tokens "${TARGET_POD}")
log "baseline: prompt_tokens=${TGT_PROMPT_PRE}  gen_tokens=${TGT_GEN_PRE}"

# ----------------------------------------------------------- sustained load (background)
log "starting sustained load (${LOAD_RPS} rps for ${LOAD_DUR}s)"
LOAD_CSV="${OUT}/load.csv"
echo "ts,nonce,code,latency_s" > "${LOAD_CSV}"
LOAD_END=$(( $(date +%s) + LOAD_DUR ))
(
  i=0
  while (( $(date +%s) < LOAD_END )); do
    i=$((i+1))
    ( out=$(submit_chat_code "load-${i}" 8)
      code=$(echo "$out" | awk '{print $1}')
      lat=$(echo "$out"  | awk '{print $2}')
      printf '%s,load-%d,%s,%s\n' "$(date +%s.%N)" "$i" "$code" "$lat" >> "${LOAD_CSV}"
    ) &
    sleep $(awk -v r="${LOAD_RPS}" 'BEGIN{printf "%.3f", 1.0/r}')
  done
  wait
) &
LOAD_PID=$!
cleanup_pids+=("${LOAD_PID}")
sleep 5

# ============================================================ Phase 1: switch to prefill
log "==== Phase 1: switch_role decode -> prefill"
T0=$(date +%s.%N)
SW1=$(curl -fsS -m 60 -X POST -H "Content-Type: application/json" \
  --data '{"target_role":"prefill"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role")
T1=$(date +%s.%N)
WALL_D2P=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f",(b-a)*1000.0}')
echo "${SW1}" | python3 -m json.tool > "${OUT}/switch_d2p.json" 2>/dev/null || echo "${SW1}" > "${OUT}/switch_d2p.json"
SERVER_D2P=$(echo "${SW1}" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("switch_time_ms","?"))' 2>/dev/null || echo "?")
log "d2p: wall=${WALL_D2P}ms server=${SERVER_D2P}ms"

sleep 2
dump_target_cr after_d2p
POST_D2P=$(count_decode_mdc_in_cr after_d2p)
POST_D2P_MC=$(echo $POST_D2P | awk '{print $1}')
PASS_CR_D2P="false"; [[ "${POST_D2P_MC}" == "0" ]] && PASS_CR_D2P="true"
log "CR after d2p: model_cards=${POST_D2P_MC} (expect 0) => ${PASS_CR_D2P}"

# ============================================================ Phase 2: verify prefill serving
log "==== Phase 2: ${N_PROBES} chat probes to verify prefill serving on target"
TGT_PROMPT_BEFORE=$(read_prompt_tokens "${TARGET_POD}")

echo "idx,status" > "${OUT}/probes_prefill.csv"
PROBE_OK=0
for i in $(seq 1 "${N_PROBES}"); do
  resp=$(submit_chat "pf-${i}" 8)
  ok=$(echo "$resp" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("ok" if d.get("choices") else "err")' 2>/dev/null || echo "err")
  echo "${i},${ok}" >> "${OUT}/probes_prefill.csv"
  [[ "$ok" == "ok" ]] && PROBE_OK=$((PROBE_OK+1))
  [[ "$i" -le 3 ]] && echo "$resp" | python3 -m json.tool > "${OUT}/probe_pf_${i}.json" 2>/dev/null || true
done

TGT_PROMPT_AFTER=$(read_prompt_tokens "${TARGET_POD}")
TGT_PROMPT_DELTA=$(( TGT_PROMPT_AFTER - TGT_PROMPT_BEFORE ))
log "prefill result: ${PROBE_OK}/${N_PROBES} ok, target prompt_tokens delta=${TGT_PROMPT_DELTA}"
PASS_PREFILL="false"; [[ "${TGT_PROMPT_DELTA}" -gt 0 ]] && PASS_PREFILL="true"

capture_worker_log "${TARGET_POD}" "after_prefill" 200

# ============================================================ Phase 3: revert to decode
log "==== Phase 3: revert prefill -> decode"
T2=$(date +%s.%N)
SW2=$(curl -fsS -m 60 -X POST -H "Content-Type: application/json" \
  --data '{"target_role":"decode"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role")
T3=$(date +%s.%N)
WALL_P2D=$(awk -v a="$T2" -v b="$T3" 'BEGIN{printf "%.3f",(b-a)*1000.0}')
echo "${SW2}" | python3 -m json.tool > "${OUT}/switch_p2d.json" 2>/dev/null || echo "${SW2}" > "${OUT}/switch_p2d.json"
SERVER_P2D=$(echo "${SW2}" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("switch_time_ms","?"))' 2>/dev/null || echo "?")
log "p2d: wall=${WALL_P2D}ms server=${SERVER_P2D}ms"

sleep 2
dump_target_cr after_p2d
POST_P2D=$(count_decode_mdc_in_cr after_p2d)
POST_P2D_MC=$(echo $POST_P2D | awk '{print $1}')
PASS_CR_P2D="false"; [[ "${POST_P2D_MC}" == "1" ]] && PASS_CR_P2D="true"
log "CR after p2d: model_cards=${POST_P2D_MC} (expect 1) => ${PASS_CR_P2D}"

# ============================================================ Phase 4: verify decode serving
log "==== Phase 4: ${N_PROBES} chat probes to verify decode serving on target"
TGT_GEN_BEFORE=$(read_gen_tokens "${TARGET_POD}")

echo "idx,status" > "${OUT}/probes_decode.csv"
DECODE_OK=0
for i in $(seq 1 "${N_PROBES}"); do
  resp=$(submit_chat "dc-${i}" 16)
  ok=$(echo "$resp" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("ok" if d.get("choices") else "err")' 2>/dev/null || echo "err")
  echo "${i},${ok}" >> "${OUT}/probes_decode.csv"
  [[ "$ok" == "ok" ]] && DECODE_OK=$((DECODE_OK+1))
  [[ "$i" -le 3 ]] && echo "$resp" | python3 -m json.tool > "${OUT}/probe_dc_${i}.json" 2>/dev/null || true
done

TGT_GEN_AFTER=$(read_gen_tokens "${TARGET_POD}")
TGT_GEN_DELTA=$(( TGT_GEN_AFTER - TGT_GEN_BEFORE ))
log "decode result: ${DECODE_OK}/${N_PROBES} ok, target gen_tokens delta=${TGT_GEN_DELTA}"
PASS_DECODE="false"; [[ "${TGT_GEN_DELTA}" -gt 0 ]] && PASS_DECODE="true"

capture_worker_log "${TARGET_POD}" "after_decode" 200

# ============================================================ finalize load
log "waiting for sustained load to finish"
wait "${LOAD_PID}" 2>/dev/null || true
sleep 1

TOT=$(awk -F, 'NR>1' "${LOAD_CSV}" | wc -l)
N200=$(awk -F, 'NR>1 && $3=="200"' "${LOAD_CSV}" | wc -l)
NERR=$(awk -F, 'NR>1 && $3!="200"' "${LOAD_CSV}" | wc -l)
P50=$(awk -F, 'NR>1 && $3=="200"{print $4}' "${LOAD_CSV}" | sort -n | awk 'BEGIN{c=0}{a[c++]=$1}END{if(c==0){print "n/a"}else{print a[int(c*0.5)]}}')
P99=$(awk -F, 'NR>1 && $3=="200"{print $4}' "${LOAD_CSV}" | sort -n | awk 'BEGIN{c=0}{a[c++]=$1}END{if(c==0){print "n/a"}else{print a[int(c*0.99)]}}')
PASS_LOAD="false"; [[ "${N200}" -gt 0 && "${NERR}" -le 2 ]] && PASS_LOAD="true"

# ============================================================ report
PASS="false"
[[ "${PASS_CR_D2P}" == "true" && "${PASS_CR_P2D}" == "true" \
   && "${PASS_PREFILL}" == "true" && "${PASS_DECODE}" == "true" \
   && "${PASS_LOAD}" == "true" ]] && PASS="true"

cat > "${OUT}/REPORT.md" <<REPORT_EOF
# S2 Elastic PD switch — E2E test report (${TS})

DGD: \`${DGD}\` | namespace: \`${NS}\` | model: \`${MODEL}\`
Target: \`${TARGET_POD}\`
Peer:   \`${PEER_POD}\`

## 1. Switch latency

| direction         | client wall (ms) | server total (ms) |
|-------------------|-----------------:|------------------:|
| decode → prefill  | ${WALL_D2P}      | ${SERVER_D2P}     |
| prefill → decode  | ${WALL_P2D}      | ${SERVER_P2D}     |

## 2. Router awareness (DynamoWorkerMetadata CR)

| state                    | model_cards w/ \`backend/generate\` | endpoints w/ \`backend/generate\` |
|--------------------------|------------------------------------:|----------------------------------:|
| pre-switch               | $(echo $PRE_CR   | awk '{print $1}') | $(echo $PRE_CR   | awk '{print $2}') |
| after switch → prefill   | $(echo $POST_D2P | awk '{print $1}') | $(echo $POST_D2P | awk '{print $2}') |
| after revert → decode    | $(echo $POST_P2D | awk '{print $1}') | $(echo $POST_P2D | awk '{print $2}') |

* CR loses decode card after switch: **${PASS_CR_D2P}**
* CR regains decode card after revert: **${PASS_CR_P2D}**

## 3. Prefill serving (after switch to prefill)

${N_PROBES} chat requests sent.  If the target is active as a prefill
worker, its \`vllm:prompt_tokens_total\` counter will grow.

| metric                      | value                    |
|-----------------------------|-------------------------:|
| prompt_tokens before probes | ${TGT_PROMPT_BEFORE}     |
| prompt_tokens after probes  | ${TGT_PROMPT_AFTER}      |
| **delta (must be > 0)**     | **${TGT_PROMPT_DELTA}**  |
| probes returned ok          | ${PROBE_OK}/${N_PROBES}  |

**Analysis**: delta > 0 proves the target executed prefill compute.
Combined with HTTP 200 OK, the target is end-to-end serving as prefill.

* Prefill serving verified: **${PASS_PREFILL}**

## 4. Decode serving (after revert to decode)

${N_PROBES} chat requests sent after reverting to decode role.

| metric                      | value                    |
|-----------------------------|-------------------------:|
| gen_tokens before probes    | ${TGT_GEN_BEFORE}        |
| gen_tokens after probes     | ${TGT_GEN_AFTER}         |
| **delta (must be > 0)**     | **${TGT_GEN_DELTA}**     |
| probes returned ok          | ${DECODE_OK}/${N_PROBES}  |

**Analysis**: delta > 0 proves the target generated decode tokens.
The full round-trip (decode → prefill → decode) is confirmed.

* Decode serving verified: **${PASS_DECODE}**

## 5. Sustained-load impact

| metric          | value  |
|-----------------|--------|
| total requests  | ${TOT} |
| HTTP 200        | ${N200}|
| HTTP non-200    | ${NERR}|
| p50 latency (s) | ${P50} |
| p99 latency (s) | ${P99} |

* Sustained-load passes (errors ≤ 2): **${PASS_LOAD}**

## 6. Switch responses

### decode → prefill
\`\`\`json
$(cat "${OUT}/switch_d2p.json")
\`\`\`
### prefill → decode
\`\`\`json
$(cat "${OUT}/switch_p2d.json")
\`\`\`

## 7. Worker log excerpts (target)

### After prefill serving phase
\`\`\`
$(grep -E 'DualMode|partner_prefill|switch_role|disaggregation_mode|sleep|wake' "${OUT}/workerlog-after_prefill.txt" 2>/dev/null | tail -20 || echo "(no matching lines)")
\`\`\`
### After decode serving phase
\`\`\`
$(grep -E 'DualMode|switch_role|disaggregation_mode|sleep|wake' "${OUT}/workerlog-after_decode.txt" 2>/dev/null | tail -20 || echo "(no matching lines)")
\`\`\`

## Overall

| condition                            | result          |
|--------------------------------------|-----------------|
| CR loses decode card after switch    | **${PASS_CR_D2P}** |
| CR regains decode card after revert  | **${PASS_CR_P2D}** |
| Target served prefill (delta > 0)    | **${PASS_PREFILL}** |
| Target served decode (delta > 0)     | **${PASS_DECODE}**  |
| Sustained load ≤ 2 errors           | **${PASS_LOAD}**    |
| **OVERALL**                          | **${PASS}**         |
REPORT_EOF

log "REPORT: ${OUT}/REPORT.md"
log "PASS_CR_D2P=${PASS_CR_D2P}  PASS_CR_P2D=${PASS_CR_P2D}  PASS_PREFILL=${PASS_PREFILL}  PASS_DECODE=${PASS_DECODE}  PASS_LOAD=${PASS_LOAD}"
log "OVERALL=${PASS}"
[[ "${PASS}" == "true" ]] && exit 0 || exit 1
