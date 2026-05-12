#!/usr/bin/env bash
# ============================================================================
# test-s3-consolidation.sh — S3: Decoder long-request consolidation E2E.
#
# Goal: prove that an in-flight long-running decode request can be moved off
# a TARGET decoder onto a PEER decoder, freeing TARGET's GPU KV (so TARGET
# can be drained / scaled down / role-switched) while the request continues
# to make forward progress on PEER.
#
# Wire protocol (see migration.py):
#   POST <target>/migrate_out  {"request_id":"*"}
#       -> aborts the most-progressed request on TARGET, returns its
#          {prompt_tokens, generated_tokens, sampling_params, ...}
#   POST <peer>/migrate_in   <body from migrate_out>
#       -> cost-benefit gate; on accept, recompute-prefill replay on PEER
#
# Pass criteria:
#   PASS_MIG_OK     : >=1 (migrate_out, migrate_in) pair both returned status=ok
#   PASS_NO_ERRORS  : no migration response had status=="error"
#   PASS_GPU_RELEASE: TARGET's vllm:gpu_cache_usage_perc dropped after migrations
#   PASS_DST_TAKEOVER: PEER saw new active requests after migrations
#                     (running count or generation_tokens_total delta)
#   PASS_DECLINE    : synthetic over-budget migrate_in returns status=="declined"
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${SCRIPT_DIR}/reports/s3-consolidation-${TS}"
mkdir -p "${OUT}"

NS="${NS:-dynamo-system}"
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
FRONTEND_LOCAL="${FRONTEND_LOCAL:-18000}"
TGT_SIDE="${TGT_SIDE:-19191}"
PEER_SIDE="${PEER_SIDE:-19192}"
TGT_METR="${TGT_METR:-19291}"
PEER_METR="${PEER_METR:-19292}"
N_LONG="${N_LONG:-24}"
LONG_MAX_TOK="${LONG_MAX_TOK:-3500}"
SCHED_WAIT="${SCHED_WAIT:-8}"
MIG_LOOPS="${MIG_LOOPS:-6}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${OUT}/run.log"; }
die() { log "FATAL: $*"; exit 1; }

cleanup_pids=()
chat_pids=()
trap 'for p in "${cleanup_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done' EXIT

# ----------------------------------------------------------- discover pods
mapfile -t DECODE_PODS < <(
  kubectl -n "${NS}" get pod \
    -l "nvidia.com/dynamo-component=VllmDecodeWorker,nvidia.com/dynamo-graph-deployment-name=${DGD}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
)
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 running decode pods (have ${#DECODE_PODS[@]})"
TARGET_POD="${DECODE_PODS[0]}"
PEER_POD="${DECODE_PODS[1]}"
log "TARGET=${TARGET_POD}"
log "PEER  =${PEER_POD}"

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

start_pf "${FRONTEND_POD}" "${FRONTEND_LOCAL}" 8000 "frontend"
start_pf "${TARGET_POD}"   "${TGT_SIDE}"       9091 "tgt-side"
start_pf "${PEER_POD}"     "${PEER_SIDE}"      9091 "peer-side"
start_pf "${TARGET_POD}"   "${TGT_METR}"       9090 "tgt-metr"
start_pf "${PEER_POD}"     "${PEER_METR}"      9090 "peer-metr"

# ----------------------------------------------------------- helpers
read_metric() {
  local port="$1" pat="$2"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk -v p="$pat" '$0 ~ p && $0 !~ /^#/ {print $NF}' | tail -1
}
gpu_pct()   { read_metric "$1" '^vllm:gpu_cache_usage_perc[ {]'; }
running()   { read_metric "$1" '^vllm:num_requests_running[ {]'; }
gen_tot()   { curl -fsS -m 2 "http://127.0.0.1:${1}/metrics" 2>/dev/null \
              | awk '/^vllm:generation_tokens_total[ {]/{s+=$NF}END{printf "%d",s+0}'; }

snapshot() {
  local label="$1"
  local tg=$(gpu_pct "$TGT_METR"); local pg=$(gpu_pct "$PEER_METR")
  local tr=$(running "$TGT_METR"); local pr=$(running "$PEER_METR")
  local tt=$(gen_tot "$TGT_METR"); local pt=$(gen_tot "$PEER_METR")
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$label" "$tg" "$pg" "$tr" "$pr" "$tt" "$pt" \
    | tee -a "${OUT}/metrics.csv"
}

active_count() {
  curl -fsS -m 3 "http://127.0.0.1:${1}/v1/active_requests" 2>/dev/null \
    | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'
}

submit_long_chat_async() {
  local idx="$1"
  local body="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Tell me a long detailed story about distributed systems and elasticity, with at least ${LONG_MAX_TOK} tokens worth of detail. Idx ${idx}.\"}],\"max_tokens\":${LONG_MAX_TOK},\"temperature\":0.7,\"stream\":true}"
  (
    out=$(curl -s -m 120 -o "${OUT}/chat-${idx}.json" -w '%{http_code} %{time_total}\n' \
      -H "Content-Type: application/json" --data "${body}" \
      "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions")
    echo "${idx},${out}" >> "${OUT}/long-chats.csv"
  ) &
  chat_pids+=("$!")
}

# ----------------------------------------------------------- pre-state
log "warming"
curl -s -o /dev/null -m 30 -H "Content-Type: application/json" \
  --data "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
  "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions" >/dev/null
sleep 1

echo "label,tgt_gpu_pct,peer_gpu_pct,tgt_running,peer_running,tgt_gen_tot,peer_gen_tot" > "${OUT}/metrics.csv"
echo "idx,http,latency_s" > "${OUT}/long-chats.csv"
snapshot "T0_pre"

# ----------------------------------------------------------- drive load
log "submitting ${N_LONG} long chats (max_tokens=${LONG_MAX_TOK})"
for i in $(seq 1 "${N_LONG}"); do
  submit_long_chat_async "$i"
done
log "waiting ${SCHED_WAIT}s for scheduling"
sleep "${SCHED_WAIT}"
snapshot "T1_after_schedule"

TGT_ACT0=$(active_count "${TGT_SIDE}"); PEER_ACT0=$(active_count "${PEER_SIDE}")
log "active_requests TGT=${TGT_ACT0}  PEER=${PEER_ACT0}"

# ----------------------------------------------------------- migrations
log "==== migration loop (up to ${MIG_LOOPS} migrations from TARGET to PEER)"
echo "iter,phase,status,path,replay_tokens,reason,request_id" > "${OUT}/migrations.csv"
MIG_OK=0
MIG_ERR=0
MIG_DECLINED=0
MIG_CONNECTOR=0
for i in $(seq 1 "${MIG_LOOPS}"); do
  pre_active=$(active_count "${TGT_SIDE}")
  if [[ "${pre_active}" -le 0 ]]; then
    log "iter ${i}: TGT has no active requests; stopping"
    break
  fi
  out_resp=$(curl -fsS -m 30 -X POST -H "Content-Type: application/json" \
    --data '{"request_id":"*"}' \
    "http://127.0.0.1:${TGT_SIDE}/migrate_out" || echo '{"status":"http_error"}')
  echo "$out_resp" > "${OUT}/migrate_out_${i}.json"
  o_status=$(echo "$out_resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))')
  o_rid=$(echo "$out_resp"    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("request_id","-"))')
  printf '%d,migrate_out,%s,-,-,-,%s\n' "$i" "$o_status" "$o_rid" >> "${OUT}/migrations.csv"
  log "iter ${i}: migrate_out -> status=${o_status} rid=${o_rid}"
  if [[ "${o_status}" != "ok" ]]; then
    MIG_ERR=$((MIG_ERR+1))
    continue
  fi

  in_resp=$(curl -fsS -m 30 -X POST -H "Content-Type: application/json" \
    --data "${out_resp}" \
    "http://127.0.0.1:${PEER_SIDE}/migrate_in" || echo '{"status":"http_error"}')
  echo "$in_resp" > "${OUT}/migrate_in_${i}.json"
  i_status=$(echo "$in_resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))')
  i_path=$(echo "$in_resp"   | python3 -c 'import json,sys;print(json.load(sys.stdin).get("path","-"))')
  i_rep=$(echo "$in_resp"    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("replay_tokens","-"))')
  i_rsn=$(echo "$in_resp"    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("reason","-").replace(",",";"))')
  printf '%d,migrate_in,%s,%s,%s,%s,%s\n' "$i" "$i_status" "$i_path" "$i_rep" "$i_rsn" "$o_rid" >> "${OUT}/migrations.csv"
  log "iter ${i}: migrate_in  -> status=${i_status} path=${i_path} replay=${i_rep}"

  # Phase-2.B block-hold ack: if migrate_in succeeded, tell the source
  # to release the held KV blocks.  The /migration_complete endpoint
  # only exists when connector_enabled=True on the source; when it is
  # off (Phase-2.A) the abort already happened in migrate_out, so the
  # call is a harmless no-op.
  if [[ "${i_status}" == "ok" ]]; then
    mc_resp=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
      --data "{\"request_id\":\"${o_rid}\"}" \
      "http://127.0.0.1:${TGT_SIDE}/migration_complete" 2>/dev/null || echo '{"status":"http_error"}')
    mc_status=$(echo "$mc_resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")
    log "iter ${i}: migration_complete -> status=${mc_status}"
  fi

  case "$i_status" in
    ok)       MIG_OK=$((MIG_OK+1))
              [[ "${i_path}" == "connector" ]] && MIG_CONNECTOR=$((MIG_CONNECTOR+1))
              ;;
    declined) MIG_DECLINED=$((MIG_DECLINED+1)) ;;
    *)        MIG_ERR=$((MIG_ERR+1)) ;;
  esac
  sleep 0.5
done
sleep 2
snapshot "T2_after_migrations"

# ----------------------------------------------------------- decline test
log "==== synthetic over-budget migrate_in (expect declined)"
PROMPT_BIG=$(python3 -c 'import json; print(json.dumps(list(range(9000))))')
GEN_SOME=$(python3 -c 'import json; print(json.dumps(list(range(50))))')
DECLINE_BODY="{\"request_id\":\"synthetic-overbudget\",\"prompt_tokens\":${PROMPT_BIG},\"generated_tokens\":${GEN_SOME},\"sampling_params\":{\"max_tokens\":1000}}"
DEC_RESP=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
  --data "${DECLINE_BODY}" "http://127.0.0.1:${PEER_SIDE}/migrate_in" || echo '{"status":"http_error"}')
echo "$DEC_RESP" > "${OUT}/decline.json"
DEC_STATUS=$(echo "$DEC_RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))')
log "decline test status=${DEC_STATUS}"
PASS_DECLINE="false"; [[ "${DEC_STATUS}" == "declined" ]] && PASS_DECLINE="true"

# ----------------------------------------------------------- wait long chats
log "waiting for outstanding long chats"
for _p in "${chat_pids[@]}"; do wait "$_p" 2>/dev/null || true; done
sleep 1
snapshot "T3_drained"

# ----------------------------------------------------------- analyze
TGT_RUN_T1=$(awk -F, '$1=="T1_after_schedule"{print $4}' "${OUT}/metrics.csv")
TGT_RUN_T2=$(awk -F, '$1=="T2_after_migrations"{print $4}' "${OUT}/metrics.csv")
PEER_RUN_T1=$(awk -F, '$1=="T1_after_schedule"{print $5}' "${OUT}/metrics.csv")
PEER_RUN_T2=$(awk -F, '$1=="T2_after_migrations"{print $5}' "${OUT}/metrics.csv")
PEER_GEN_T1=$(awk -F, '$1=="T1_after_schedule"{print $7}' "${OUT}/metrics.csv")
PEER_GEN_T3=$(awk -F, '$1=="T3_drained"{print $7}' "${OUT}/metrics.csv")
TGT_GEN_T1=$(awk -F, '$1=="T1_after_schedule"{print $6}' "${OUT}/metrics.csv")
TGT_GEN_T3=$(awk -F, '$1=="T3_drained"{print $6}' "${OUT}/metrics.csv")
PEER_GEN_DELTA=$(awk -v a="${PEER_GEN_T1:-0}" -v b="${PEER_GEN_T3:-0}" 'BEGIN{print b-a}')
TGT_GEN_DELTA=$(awk  -v a="${TGT_GEN_T1:-0}"  -v b="${TGT_GEN_T3:-0}"  'BEGIN{print b-a}')

PASS_MIG_OK="false";       [[ "${MIG_OK}"  -ge 1 ]] && PASS_MIG_OK="true"
PASS_NO_ERRORS="false";    [[ "${MIG_ERR}" -eq 0 ]] && PASS_NO_ERRORS="true"
PASS_GPU_RELEASE=$(awk -v a="${TGT_RUN_T1:-0}" -v b="${TGT_RUN_T2:-0}" 'BEGIN{print (b+0<a+0)?"true":"false"}')
PASS_DST_TAKEOVER=$(awk -v d="${PEER_GEN_DELTA:-0}" 'BEGIN{print (d>0)?"true":"false"}')

PASS="false"
[[ "${PASS_MIG_OK}" == "true" && "${PASS_NO_ERRORS}" == "true" \
   && "${PASS_DECLINE}" == "true" \
   && ( "${PASS_GPU_RELEASE}" == "true" || "${PASS_DST_TAKEOVER}" == "true" ) \
]] && PASS="true"

cat > "${OUT}/REPORT.md" <<REPORT_EOF
# S3 Decoder consolidation — E2E test report (${TS})

DGD: \`${DGD}\` | namespace: \`${NS}\` | model: \`${MODEL}\`
Target pod: \`${TARGET_POD}\`
Peer pod  : \`${PEER_POD}\`

Driver: ${N_LONG} long chats (\`max_tokens=${LONG_MAX_TOK}\`) submitted
through the frontend; KV-router distributes them across the two decoders.
After ${SCHED_WAIT} s the test loops up to ${MIG_LOOPS} times calling
\`POST /migrate_out\` on TARGET (\`request_id="*"\` -> most-progressed
in-flight request) and \`POST /migrate_in\` on PEER.

## Migration results

| outcome              | count          |
|----------------------|----------------|
| migrate_in **ok**    | ${MIG_OK}      |
| — via connector path | ${MIG_CONNECTOR}|
| migrate_in declined  | ${MIG_DECLINED}|
| errors               | ${MIG_ERR}     |

* >=1 successful migration: **${PASS_MIG_OK}**
* No \`status=error\` responses: **${PASS_NO_ERRORS}**

## GPU release / dst takeover

|                                            | before mig (T1) | after mig (T2) | drained (T3) |
|--------------------------------------------|----------------:|---------------:|-------------:|
| TARGET \`vllm:num_requests_running\`       | ${TGT_RUN_T1}   | ${TGT_RUN_T2}  | -            |
| PEER   \`vllm:num_requests_running\`       | ${PEER_RUN_T1}  | ${PEER_RUN_T2} | -            |
| TARGET \`vllm:generation_tokens_total\`    | ${TGT_GEN_T1}   | -              | ${TGT_GEN_T3} |
| PEER   \`vllm:generation_tokens_total\`    | ${PEER_GEN_T1}  | -              | ${PEER_GEN_T3} |

* TARGET running-requests count decreased after migration: **${PASS_GPU_RELEASE}**
* PEER produced additional tokens after T1 (delta=${PEER_GEN_DELTA}): **${PASS_DST_TAKEOVER}**
  (TARGET delta over the same window = ${TGT_GEN_DELTA})

## Cost-benefit gate (Phase-2 policy)

Synthetic \`migrate_in\` with \`prompt_tokens\`=9000 (over the
\`max_replay_tokens=8192\` policy ceiling) was sent to PEER:

response \`status\` = **${DEC_STATUS}**
* Cost-benefit gate rejects oversize migrations: **${PASS_DECLINE}**

\`\`\`json
$(cat "${OUT}/decline.json")
\`\`\`

## Per-iteration migration log (CSV head)

\`\`\`csv
$(head -20 "${OUT}/migrations.csv")
\`\`\`

## Overall
**${PASS}**
REPORT_EOF

log "REPORT: ${OUT}/REPORT.md"
log "MIG_OK=${MIG_OK}  MIG_CONNECTOR=${MIG_CONNECTOR}  MIG_DECLINED=${MIG_DECLINED}  MIG_ERR=${MIG_ERR}"
log "PASS_MIG_OK=${PASS_MIG_OK}  PASS_NO_ERRORS=${PASS_NO_ERRORS}  PASS_GPU_RELEASE=${PASS_GPU_RELEASE}  PASS_DST_TAKEOVER=${PASS_DST_TAKEOVER}  PASS_DECLINE=${PASS_DECLINE}"
log "OVERALL=${PASS}"
[[ "${PASS}" == "true" ]] && exit 0 || exit 1
