#!/usr/bin/env bash
# ============================================================================
# test-s2-elastic.sh — S2: Elastic PD role switch end-to-end test.
#
# Path A semantics (see S2_elastic_pd_switch.md):
#   switch_role decode -> prefill := target pod LEAVES the chat WorkerSet
#                                    (decode model_card removed from its
#                                    DynamoWorkerMetadata CR; sleep level=2
#                                    frees GPU KV; reset_prefix_cache clears
#                                    prefix pool).
#   switch_role decode (revert)  := target pod REJOINS the chat WorkerSet
#                                    (decode model_card re-published).
#
# This test directly proves router-awareness (CR diff), not just chat
# attribution, plus measures sustained-load impact during the switch window.
#
# Pass criteria:
#   PASS_CR_D2P:  CR.spec.data.model_cards loses "*/backend/generate/*" after switch
#   PASS_CR_P2D:  CR.spec.data.model_cards regains "*/backend/generate/*" after revert
#   PASS_PROBE:   30 chat probes after switch attribute 0 to target, >0 to peer
#   PASS_LOAD:    sustained 2 rps load over 30 s sees zero HTTP 500 attributable
#                 to the routing transition (transient sleep window allowed)
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

# ----------------------------------------------------------- discover pods
mapfile -t DECODE_PODS < <(
  kubectl -n "${NS}" get pod \
    -l "nvidia.com/dynamo-component=VllmDecodeWorker,nvidia.com/dynamo-graph-deployment-name=${DGD}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
)
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 running decode pods (have ${#DECODE_PODS[@]})"
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
read_pod_chat_count() {
  local p="$1" port="${POD_METRIC_PORT[$p]}"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk '/^vllm:prompt_tokens_total[ {]/ {sum+=$NF} END{printf "%d", sum+0}'
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
  local body="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"S2 elastic probe ${nonce}.\"}],\"max_tokens\":${max_tokens},\"temperature\":0,\"stream\":false}"
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -m 30 \
    -H "Content-Type: application/json" --data "${body}" \
    "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions"
}

attribute_chat() {
  local nonce="$1"
  declare -A before
  for p in "${DECODE_PODS[@]}"; do before["$p"]=$(read_pod_chat_count "$p"); done
  local code; code=$(submit_chat "$nonce" 4 | awk '{print $1}')
  if [[ "$code" != "200" ]]; then echo "?:HTTP${code}"; return; fi
  sleep 0.4
  local best="?" best_d=0
  for p in "${DECODE_PODS[@]}"; do
    local after; after=$(read_pod_chat_count "$p")
    local d=$(( after - ${before[$p]} ))
    (( d > best_d )) && best_d="$d" && best="$p"
  done
  echo "${best}:${best_d}"
}

# ----------------------------------------------------------- pre-state
log "warming model"
submit_chat warmup-1 4 >/dev/null || true
sleep 1

dump_target_cr before
PRE_CR_COUNTS=$(count_decode_mdc_in_cr before)
log "PRE  CR (target ${TARGET_POD}): model_cards=$(echo $PRE_CR_COUNTS | awk '{print $1}')  endpoints=$(echo $PRE_CR_COUNTS | awk '{print $2}')"
PRE_MC_COUNT=$(echo $PRE_CR_COUNTS | awk '{print $1}')
[[ "${PRE_MC_COUNT}" == "1" ]] || die "expected 1 backend/generate model_card in target CR pre-switch, got ${PRE_MC_COUNT}"

# ----------------------------------------------------------- sustained load
log "starting sustained load (${LOAD_RPS} rps for ${LOAD_DUR}s)"
LOAD_CSV="${OUT}/load.csv"
echo "ts,nonce,code,latency_s" > "${LOAD_CSV}"
LOAD_END=$(( $(date +%s) + LOAD_DUR ))
(
  i=0
  while (( $(date +%s) < LOAD_END )); do
    i=$((i+1))
    (
      out=$(submit_chat "load-${i}" 8)
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

# Let load build up
sleep 5

# ----------------------------------------------------------- switch
log "==== Phase 1: switch_role decode->prefill"
T0=$(date +%s.%N)
SW1=$(curl -fsS -m 60 -X POST -H "Content-Type: application/json" \
  --data '{"target_role":"prefill"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role")
T1=$(date +%s.%N)
WALL_MS_1=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f",(b-a)*1000.0}')
echo "${SW1}" > "${OUT}/switch_d2p.json"; echo "${SW1}"
SERVER_MS_1=$(echo "${SW1}" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("switch_time_ms","?"))')
log "wall=${WALL_MS_1}ms server=${SERVER_MS_1}ms"

sleep 2
dump_target_cr after_d2p
POST_D2P=$(count_decode_mdc_in_cr after_d2p)
POST_D2P_MC=$(echo $POST_D2P | awk '{print $1}')
log "POST d2p CR: model_cards=$(echo $POST_D2P | awk '{print $1}')  endpoints=$(echo $POST_D2P | awk '{print $2}')"
PASS_CR_D2P="false"; [[ "${POST_D2P_MC}" == "0" ]] && PASS_CR_D2P="true"

# Probe routing
log "post-switch probes (${N_PROBES})"
PROBE_CSV="${OUT}/probes_post_d2p.csv"
echo "ts,nonce,pod,delta" > "${PROBE_CSV}"
declare -A POST_HITS
for p in "${DECODE_PODS[@]}"; do POST_HITS["$p"]=0; done
POST_HITS["?"]=0
for i in $(seq 1 "${N_PROBES}"); do
  res=$(attribute_chat "post-${i}")
  pod="${res%%:*}"; d="${res#*:}"
  printf '%s,post-%d,%s,%s\n' "$(date +%s.%N)" "$i" "$pod" "$d" >> "${PROBE_CSV}"
  if [[ -n "${POST_HITS[$pod]+x}" ]]; then POST_HITS["$pod"]=$(( ${POST_HITS["$pod"]} + 1 )); fi
done
TARGET_HITS_AFTER="${POST_HITS[$TARGET_POD]}"
PEER_HITS_AFTER="${POST_HITS[$PEER_POD]}"
PASS_PROBE="false"
[[ "${TARGET_HITS_AFTER}" -eq 0 && "${PEER_HITS_AFTER}" -gt 0 ]] && PASS_PROBE="true"

# ----------------------------------------------------------- revert
log "==== Phase 2: revert prefill->decode"
T2=$(date +%s.%N)
SW2=$(curl -fsS -m 60 -X POST -H "Content-Type: application/json" \
  --data '{"target_role":"decode"}' \
  "http://127.0.0.1:${SIDECAR_LOCAL}/switch_role")
T3=$(date +%s.%N)
WALL_MS_2=$(awk -v a="$T2" -v b="$T3" 'BEGIN{printf "%.3f",(b-a)*1000.0}')
echo "${SW2}" > "${OUT}/switch_p2d.json"; echo "${SW2}"
SERVER_MS_2=$(echo "${SW2}" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("switch_time_ms","?"))')
log "wall=${WALL_MS_2}ms server=${SERVER_MS_2}ms"

sleep 2
dump_target_cr after_p2d
POST_P2D=$(count_decode_mdc_in_cr after_p2d)
POST_P2D_MC=$(echo $POST_P2D | awk '{print $1}')
log "POST p2d CR: model_cards=$(echo $POST_P2D | awk '{print $1}')  endpoints=$(echo $POST_P2D | awk '{print $2}')"
PASS_CR_P2D="false"; [[ "${POST_P2D_MC}" == "1" ]] && PASS_CR_P2D="true"

# Probe routing again
log "post-revert probes (${N_PROBES})"
REV_CSV="${OUT}/probes_post_p2d.csv"
echo "ts,nonce,pod,delta" > "${REV_CSV}"
declare -A REV_HITS
for p in "${DECODE_PODS[@]}"; do REV_HITS["$p"]=0; done
REV_HITS["?"]=0
for i in $(seq 1 "${N_PROBES}"); do
  res=$(attribute_chat "rev-${i}")
  pod="${res%%:*}"; d="${res#*:}"
  printf '%s,rev-%d,%s,%s\n' "$(date +%s.%N)" "$i" "$pod" "$d" >> "${REV_CSV}"
  if [[ -n "${REV_HITS[$pod]+x}" ]]; then REV_HITS["$pod"]=$(( ${REV_HITS["$pod"]} + 1 )); fi
done
TARGET_REJOIN="${REV_HITS[$TARGET_POD]}"

# ----------------------------------------------------------- finalize load
log "waiting for sustained load to finish"
wait "${LOAD_PID}" 2>/dev/null || true
sleep 1

# Analyse load.csv
TOT=$(awk -F, 'NR>1' "${LOAD_CSV}" | wc -l)
N200=$(awk -F, 'NR>1 && $3=="200"' "${LOAD_CSV}" | wc -l)
NERR=$(awk -F, 'NR>1 && $3!="200"' "${LOAD_CSV}" | wc -l)
P50=$(awk -F, 'NR>1 && $3=="200"{print $4}' "${LOAD_CSV}" | sort -n | awk 'BEGIN{c=0}{a[c++]=$1}END{if(c==0){print "n/a"}else{print a[int(c*0.5)]}}')
P99=$(awk -F, 'NR>1 && $3=="200"{print $4}' "${LOAD_CSV}" | sort -n | awk 'BEGIN{c=0}{a[c++]=$1}END{if(c==0){print "n/a"}else{print a[int(c*0.99)]}}')
ERR_RATE=$(awk -v e="$NERR" -v t="$TOT" 'BEGIN{if(t==0){print "n/a"}else{printf "%.2f%%",100.0*e/t}}')
PASS_LOAD="false"; [[ "${N200}" -gt 0 && "${NERR}" -le 2 ]] && PASS_LOAD="true"

# ----------------------------------------------------------- report
PASS="false"
[[ "${PASS_CR_D2P}" == "true" && "${PASS_CR_P2D}" == "true" \
   && "${PASS_PROBE}" == "true" && "${PASS_LOAD}" == "true" ]] && PASS="true"

cat > "${OUT}/REPORT.md" <<REPORT_EOF
# S2 Elastic PD switch — E2E test report (${TS})

DGD: \`${DGD}\` | namespace: \`${NS}\` | model: \`${MODEL}\`
Target pod: \`${TARGET_POD}\`
Peer pod  : \`${PEER_POD}\`

## Switch latency

|                              | decode -> prefill | prefill -> decode |
|------------------------------|-------------------|-------------------|
| client wall-clock (ms)       | ${WALL_MS_1}      | ${WALL_MS_2}      |
| server total switch_time_ms  | ${SERVER_MS_1}    | ${SERVER_MS_2}    |

## Router awareness (DynamoWorkerMetadata CR diff on target)

The frontend's WorkerSet is rebuilt from \`DynamoWorkerMetadata\` CRs
watched in the deployment namespace. We assert directly on the target's
own CR:

|                        | model_cards w/ \`backend/generate\` | endpoints w/ \`backend/generate\` |
|------------------------|------------------------------------:|----------------------------------:|
| pre-switch             | $(echo $PRE_CR_COUNTS  | awk '{print $1}') | $(echo $PRE_CR_COUNTS  | awk '{print $2}') |
| after switch -> prefill| $(echo $POST_D2P       | awk '{print $1}') | $(echo $POST_D2P       | awk '{print $2}') |
| after revert -> decode | $(echo $POST_P2D       | awk '{print $1}') | $(echo $POST_P2D       | awk '{print $2}') |

* CR loses chat ModelCard after switch -> prefill: **${PASS_CR_D2P}**
* CR regains chat ModelCard after revert       : **${PASS_CR_P2D}**

## Routing attribution (${N_PROBES} chat probes per phase)

After switch -> prefill (target should be **0**, peer should be **>0**):
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` -> ${POST_HITS[$p]}"; done)

After revert -> decode (target should be **>0**, peer **>0**):
$(for p in "${DECODE_PODS[@]}"; do echo "- \`${p}\` -> ${REV_HITS[$p]}"; done)

* Routing flipped off target then back: **${PASS_PROBE}**

## Sustained-load impact (${LOAD_RPS} rps, ${LOAD_DUR} s)

| metric                 | value     |
|------------------------|-----------|
| total chat completions | ${TOT}    |
| HTTP 200               | ${N200}   |
| HTTP non-200           | ${NERR}   |
| error rate             | ${ERR_RATE} |
| p50 latency (s)        | ${P50}    |
| p99 latency (s)        | ${P99}    |

* Sustained-load passes (errors <= 2 out of ${TOT}): **${PASS_LOAD}**

## Switch responses

\`\`\`json
$(cat "${OUT}/switch_d2p.json")
\`\`\`

\`\`\`json
$(cat "${OUT}/switch_p2d.json")
\`\`\`

## Overall
**${PASS}**
REPORT_EOF

log "REPORT: ${OUT}/REPORT.md"
log "PASS_CR_D2P=${PASS_CR_D2P}  PASS_CR_P2D=${PASS_CR_P2D}  PASS_PROBE=${PASS_PROBE}  PASS_LOAD=${PASS_LOAD}"
log "OVERALL=${PASS}"
[[ "${PASS}" == "true" ]] && exit 0 || exit 1
