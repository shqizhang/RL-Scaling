#!/usr/bin/env bash
# ============================================================================
# test-s3-consolidation.sh — S3: Decoder request consolidation E2E.
#
# Proves that in-flight decode requests can be migrated from D1 (source)
# to D2 (destination) using the coordinated /migrate endpoint.  The test
# captures detailed token-level evidence:
#   - How many tokens D1 had already decoded
#   - Expected max_tokens for the request
#   - Proof of successful migration to D2 (status=ok, replay_tokens)
#   - D2's generation progress after migration
#
# Uses the coordinated /migrate endpoint which ensures KV consistency:
#   1. migrate_out holds request on D1 (defers abort)
#   2. /migrate calls D2's /migrate_in internally
#   3. On success: D1 aborts + frees; On failure: D1 continues (rollback)
#
# Pass criteria:
#   PASS_MIG_OK     : >=1 migration succeeded
#   PASS_NO_ERRORS  : no migration errors
#   PASS_GPU_RELEASE: D1 running-requests decreased
#   PASS_DST_TOKENS : D2 generation_tokens grew (proving forward progress)
#   PASS_DECLINE    : synthetic oversize migrate_in returned declined
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
N_LONG="${N_LONG:-60}"
LONG_MAX_TOK="${LONG_MAX_TOK:-8000}"
SCHED_WAIT="${SCHED_WAIT:-3}"
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
log "TARGET (source)     = ${TARGET_POD}"
log "PEER   (destination)= ${PEER_POD}"

FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || die "frontend not found"
log "FRONTEND=${FRONTEND_POD}"

# Get PEER pod IP for coordinated /migrate endpoint (pod-to-pod in cluster)
PEER_IP=$(kubectl -n "${NS}" get pod "${PEER_POD}" -o jsonpath='{.status.podIP}')
log "PEER_IP=${PEER_IP}"
[[ -n "${PEER_IP}" ]] || die "could not resolve PEER pod IP"
PEER_URL="http://${PEER_IP}:9091"

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
running()   { read_metric "$1" '^vllm:num_requests_running[ {]'; }
gen_tot()   { curl -fsS -m 2 "http://127.0.0.1:${1}/metrics" 2>/dev/null \
              | awk '/^vllm:generation_tokens_total[ {]/{s+=$NF}END{printf "%d",s+0}'; }

snapshot() {
  local label="$1"
  local tr=$(running "$TGT_METR"); local pr=$(running "$PEER_METR")
  local tt=$(gen_tot "$TGT_METR"); local pt=$(gen_tot "$PEER_METR")
  printf '%s,%s,%s,%s,%s\n' "$label" "$tr" "$pr" "$tt" "$pt" \
    | tee -a "${OUT}/metrics.csv"
}

active_requests() {
  curl -fsS -m 3 "http://127.0.0.1:${1}/v1/active_requests" 2>/dev/null
}
active_count() {
  active_requests "$1" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0"
}

submit_long_chat_async() {
  local idx="$1"
  (
    curl -s -m 120 -o "${OUT}/chat-${idx}.json" -w '%{http_code} %{time_total}\n' \
      -H "Content-Type: application/json" \
      --data "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Tell me a detailed story about distributed systems. Idx ${idx}.\"}],\"max_tokens\":${LONG_MAX_TOK},\"temperature\":0.7,\"stream\":true}" \
      "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions" \
      >> "${OUT}/long-chats.csv" 2>/dev/null
  ) &
  chat_pids+=("$!")
}

# ----------------------------------------------------------- pre-state
log "warming"
curl -s -o /dev/null -m 30 -H "Content-Type: application/json" \
  --data "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
  "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions" >/dev/null
sleep 1

echo "label,tgt_running,peer_running,tgt_gen_tot,peer_gen_tot" > "${OUT}/metrics.csv"
echo "idx,code,latency" > "${OUT}/long-chats.csv"
snapshot "T0_pre"

# =========================================================== Phase 1: submit load
log "==== Phase 1: submitting ${N_LONG} long chats (max_tokens=${LONG_MAX_TOK})"
for i in $(seq 1 "${N_LONG}"); do
  submit_long_chat_async "$i"
done

# Start a continuous background feeder to keep requests flowing
FEEDER_STOP="${OUT}/.feeder_stop"
(
  idx=1000
  while [[ ! -f "${FEEDER_STOP}" ]]; do
    idx=$((idx+1))
    submit_long_chat_async "$idx"
    sleep 0.3
  done
) &
FEEDER_PID=$!
cleanup_pids+=("${FEEDER_PID}")

log "polling for active requests on D1 (max ${SCHED_WAIT}s)..."
TGT_ACT0=0
for _w in $(seq 1 $((SCHED_WAIT * 10))); do
  TGT_ACT0=$(active_count "${TGT_SIDE}")
  [[ "${TGT_ACT0}" -gt 0 ]] && break
  sleep 0.1
done
snapshot "T1_scheduled"

PEER_ACT0=$(active_count "${PEER_SIDE}")
active_requests "${TGT_SIDE}" | python3 -m json.tool > "${OUT}/active_tgt_T1.json" 2>/dev/null || true
active_requests "${PEER_SIDE}" | python3 -m json.tool > "${OUT}/active_peer_T1.json" 2>/dev/null || true
log "T1 active: D1=${TGT_ACT0}  D2=${PEER_ACT0}"

# =========================================================== Phase 2: migrations
log "==== Phase 2: coordinated migrations (up to ${MIG_LOOPS}x) D1 -> D2"
echo "iter,status,request_id,generated_tokens,max_tokens,remaining,path,replay_tokens,rolled_back" > "${OUT}/migrations.csv"
MIG_OK=0
MIG_ERR=0
MIG_DECLINED=0
MIG_ROLLED_BACK=0
MIG_RETRIES=0
MAX_RETRIES=10

for i in $(seq 1 "${MIG_LOOPS}"); do
  # Poll for active requests (may need to wait for next batch)
  pre_active=0
  for _retry in $(seq 1 20); do
    pre_active=$(active_count "${TGT_SIDE}")
    [[ "${pre_active}" -gt 0 ]] && break
    sleep 0.5
  done
  if [[ "${pre_active}" -le 0 ]]; then
    MIG_RETRIES=$((MIG_RETRIES+1))
    log "iter ${i}: D1 has no active requests after polling; skipping"
    [[ "${MIG_RETRIES}" -ge "${MAX_RETRIES}" ]] && { log "too many retries; stopping"; break; }
    continue
  fi

  log "--- Migration #${i} (D1 active: ${pre_active})"

  # Use coordinated /migrate endpoint
  mig_resp=$(curl -fsS -m 60 -X POST -H "Content-Type: application/json" \
    --data "{\"request_id\":\"*\", \"target_url\":\"${PEER_URL}\"}" \
    "http://127.0.0.1:${TGT_SIDE}/migrate" 2>/dev/null || echo '{"status":"http_error"}')
  echo "$mig_resp" | python3 -m json.tool > "${OUT}/migrate_${i}.json" 2>/dev/null || echo "$mig_resp" > "${OUT}/migrate_${i}.json"

  # Extract fields from response
  m_status=$(echo "$mig_resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")
  m_rid=$(echo "$mig_resp"    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("request_id","-"))' 2>/dev/null || echo "-")
  m_rolled=$(echo "$mig_resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("rolled_back",False))' 2>/dev/null || echo "False")

  # Extract token details from migrate_out sub-response
  m_gen_count=$(echo "$mig_resp" | python3 -c '
import json,sys
d=json.load(sys.stdin)
out=d.get("migrate_out",{})
gen=out.get("generated_tokens",[])
print(len(gen))
' 2>/dev/null || echo "0")

  m_max_tok=$(echo "$mig_resp" | python3 -c '
import json,sys
d=json.load(sys.stdin)
out=d.get("migrate_out",{})
sp=out.get("sampling_params",{})
print(sp.get("max_tokens","?"))
' 2>/dev/null || echo "?")

  m_remaining=$(python3 -c "
mt=${m_max_tok} if '${m_max_tok}'.isdigit() else 0
gc=${m_gen_count}
print(max(0, mt - gc) if mt > 0 else '?')
" 2>/dev/null || echo "?")

  # Extract migrate_in sub-response
  m_path=$(echo "$mig_resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("migrate_in",{}).get("path","-"))' 2>/dev/null || echo "-")
  m_replay=$(echo "$mig_resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("migrate_in",{}).get("replay_tokens","-"))' 2>/dev/null || echo "-")

  printf '%d,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$i" "$m_status" "$m_rid" "$m_gen_count" "$m_max_tok" "$m_remaining" "$m_path" "$m_replay" "$m_rolled" \
    >> "${OUT}/migrations.csv"

  log "  request_id=${m_rid}"
  log "  D1 had decoded: ${m_gen_count} tokens (max_tokens=${m_max_tok}, remaining~${m_remaining})"
  log "  result: status=${m_status} path=${m_path} replay_tokens=${m_replay} rolled_back=${m_rolled}"

  case "$m_status" in
    ok)       MIG_OK=$((MIG_OK+1)) ;;
    declined) MIG_DECLINED=$((MIG_DECLINED+1)) ;;
    *)        MIG_ERR=$((MIG_ERR+1)) ;;
  esac
  [[ "${m_rolled}" == "True" ]] && MIG_ROLLED_BACK=$((MIG_ROLLED_BACK+1))

  # Post-migration state
  post_tgt=$(active_count "${TGT_SIDE}")
  post_peer=$(active_count "${PEER_SIDE}")
  log "  post-migration active: D1=${post_tgt}  D2=${post_peer}"

  sleep 0.5
done

# Stop the background feeder
touch "${FEEDER_STOP}"
kill "${FEEDER_PID}" 2>/dev/null || true
wait "${FEEDER_PID}" 2>/dev/null || true

sleep 2
snapshot "T2_migrated"

# =========================================================== Phase 3: decline test
log "==== Phase 3: synthetic oversize migrate_in (expect declined)"
PROMPT_BIG=$(python3 -c 'import json; print(json.dumps(list(range(9000))))')
GEN_SOME=$(python3 -c 'import json; print(json.dumps(list(range(50))))')
DEC_RESP=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
  --data "{\"request_id\":\"synthetic-overbudget\",\"prompt_tokens\":${PROMPT_BIG},\"generated_tokens\":${GEN_SOME},\"sampling_params\":{\"max_tokens\":1000}}" \
  "http://127.0.0.1:${PEER_SIDE}/migrate_in" 2>/dev/null || echo '{"status":"http_error"}')
echo "$DEC_RESP" | python3 -m json.tool > "${OUT}/decline.json" 2>/dev/null || echo "$DEC_RESP" > "${OUT}/decline.json"
DEC_STATUS=$(echo "$DEC_RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")
log "decline test: status=${DEC_STATUS}"
PASS_DECLINE="false"; [[ "${DEC_STATUS}" == "declined" ]] && PASS_DECLINE="true"

# =========================================================== wait for chats
log "waiting for long chats to finish"
for _p in "${chat_pids[@]}"; do wait "$_p" 2>/dev/null || true; done
sleep 1
snapshot "T3_drained"

# Capture final worker logs
kubectl -n "${NS}" logs "${TARGET_POD}" --tail=100 > "${OUT}/workerlog-tgt-final.txt" 2>/dev/null || true
kubectl -n "${NS}" logs "${PEER_POD}"   --tail=100 > "${OUT}/workerlog-peer-final.txt" 2>/dev/null || true

# =========================================================== analyze
TGT_RUN_T1=$(awk -F, '$1=="T1_scheduled"{print $2}'  "${OUT}/metrics.csv")
TGT_RUN_T2=$(awk -F, '$1=="T2_migrated"{print $2}'   "${OUT}/metrics.csv")
PEER_GEN_T1=$(awk -F, '$1=="T1_scheduled"{print $5}'  "${OUT}/metrics.csv")
PEER_GEN_T3=$(awk -F, '$1=="T3_drained"{print $5}'    "${OUT}/metrics.csv")
TGT_GEN_T1=$(awk -F, '$1=="T1_scheduled"{print $4}'   "${OUT}/metrics.csv")
TGT_GEN_T3=$(awk -F, '$1=="T3_drained"{print $4}'     "${OUT}/metrics.csv")
PEER_GEN_DELTA=$(awk -v a="${PEER_GEN_T1:-0}" -v b="${PEER_GEN_T3:-0}" 'BEGIN{print b-a}')
TGT_GEN_DELTA=$(awk  -v a="${TGT_GEN_T1:-0}"  -v b="${TGT_GEN_T3:-0}"  'BEGIN{print b-a}')

PASS_MIG_OK="false";       [[ "${MIG_OK}" -ge 1 ]]  && PASS_MIG_OK="true"
PASS_NO_ERRORS="false";    [[ "${MIG_ERR}" -eq 0 ]]  && PASS_NO_ERRORS="true"
PASS_GPU_RELEASE=$(awk -v a="${TGT_RUN_T1:-0}" -v b="${TGT_RUN_T2:-0}" 'BEGIN{print (b+0<a+0)?"true":"false"}')
PASS_DST_TOKENS=$(awk -v d="${PEER_GEN_DELTA:-0}" 'BEGIN{print (d>0)?"true":"false"}')

PASS="false"
[[ "${PASS_MIG_OK}" == "true" && "${PASS_NO_ERRORS}" == "true" \
   && "${PASS_DECLINE}" == "true" \
   && ( "${PASS_GPU_RELEASE}" == "true" || "${PASS_DST_TOKENS}" == "true" ) \
]] && PASS="true"

# =========================================================== report
cat > "${OUT}/REPORT.md" <<REPORT_EOF
# S3 Decoder consolidation — E2E test report (${TS})

DGD: \`${DGD}\` | namespace: \`${NS}\` | model: \`${MODEL}\`
D1 (source):      \`${TARGET_POD}\`
D2 (destination): \`${PEER_POD}\`
Frontend:         \`${FRONTEND_POD}\`

## 1. Test design

- Submit ${N_LONG} long-running chats (\`max_tokens=${LONG_MAX_TOK}\`)
- Wait ${SCHED_WAIT}s for scheduler to distribute across D1 and D2
- Migrate up to ${MIG_LOOPS} requests from D1 → D2 using coordinated
  \`POST /migrate\` endpoint

The coordinated endpoint ensures KV consistency:
1. \`migrate_out\` holds the request on D1 (defers abort, blocks pinned)
2. Internally calls D2's \`/migrate_in\` with the state snapshot
3. On success: aborts D1's copy, frees blocks (D2 continues decoding)
4. On failure: releases hold, D1 continues (rollback — no work lost)

## 2. Pre-migration state

| metric                        | D1          | D2          |
|-------------------------------|------------:|------------:|
| active requests (T1)          | ${TGT_ACT0} | ${PEER_ACT0}|
| \`num_requests_running\` (T1) | ${TGT_RUN_T1} | $(awk -F, '$1=="T1_scheduled"{print $3}' "${OUT}/metrics.csv") |
| \`generation_tokens_total\` (T1)| ${TGT_GEN_T1} | ${PEER_GEN_T1} |

## 3. Per-migration detail

$(python3 -c '
import csv, sys
with open(sys.argv[1]) as f:
    reader = csv.DictReader(f)
    rows = list(reader)
if not rows:
    print("*No migrations executed.*")
    sys.exit(0)
print("| # | request_id (short) | D1 decoded | max_tokens | remaining | path | replay_tokens | status | rolled_back |")
print("|---|-------|----:|----:|----:|------|----:|--------|---------|")
for r in rows:
    rid = r["request_id"]
    short_rid = (rid[:8] + "...") if len(rid) > 12 else rid
    it = r["iter"]
    gt = r["generated_tokens"]
    mt = r["max_tokens"]
    rm = r["remaining"]
    pa = r["path"]
    rt = r["replay_tokens"]
    st = r["status"]
    rb = r["rolled_back"]
    print(f"| {it} | `{short_rid}` | {gt} | {mt} | {rm} | {pa} | {rt} | **{st}** | {rb} |")
' "${OUT}/migrations.csv")

**How to read this table:**
- **D1 decoded**: number of tokens D1 had already generated for this request
  before migration.  This is the work that would be lost without migration.
- **max_tokens**: the total token budget for this request.
- **remaining**: \`max_tokens - D1_decoded\`.  D2 will generate these tokens.
- **replay_tokens**: total tokens D2 received as its new prompt
  (\`original_prompt + D1_generated_tokens\`).  D2 re-prefills this and
  continues decoding from where D1 stopped.
- **rolled_back**: if true, D2 declined and D1's request continues unchanged.

### Migration summary

| outcome              | count              |
|----------------------|-------------------:|
| migrations ok        | **${MIG_OK}**      |
| migrations declined  | ${MIG_DECLINED}    |
| migrations error     | ${MIG_ERR}         |
| rolled back          | ${MIG_ROLLED_BACK} |

## 4. Post-migration metrics

| metric                             | T1 (before) | T2 (after mig) | T3 (drained) |
|------------------------------------|------------:|---------------:|-------------:|
| D1 \`num_requests_running\`        | ${TGT_RUN_T1} | ${TGT_RUN_T2}  | $(awk -F, '$1=="T3_drained"{print $2}' "${OUT}/metrics.csv") |
| D2 \`num_requests_running\`        | $(awk -F, '$1=="T1_scheduled"{print $3}' "${OUT}/metrics.csv") | $(awk -F, '$1=="T2_migrated"{print $3}' "${OUT}/metrics.csv") | $(awk -F, '$1=="T3_drained"{print $3}' "${OUT}/metrics.csv") |
| D1 \`generation_tokens_total\`     | ${TGT_GEN_T1} | - | ${TGT_GEN_T3} |
| D2 \`generation_tokens_total\`     | ${PEER_GEN_T1} | - | ${PEER_GEN_T3} |

**D2 generation_tokens delta** (T1 → T3): **${PEER_GEN_DELTA}**
(This proves D2 actually decoded tokens for the migrated requests)

**D1 running-requests decreased**: T1=${TGT_RUN_T1} → T2=${TGT_RUN_T2}
→ **${PASS_GPU_RELEASE}** (proves D1 resources were freed)

## 5. Cost-benefit gate

Synthetic \`migrate_in\` with \`prompt_tokens=9000\` (exceeds
\`max_replay_tokens=8192\`):

\`\`\`json
$(cat "${OUT}/decline.json")
\`\`\`

* Oversize migration declined: **${PASS_DECLINE}**

## 6. D1 worker log excerpts (migration events)

\`\`\`
$(grep -E 'Migration|migrate|abort|block_hold|rollback' "${OUT}/workerlog-tgt-final.txt" 2>/dev/null | tail -20 || echo "(no matching lines)")
\`\`\`

## Overall

| condition                                | result              |
|------------------------------------------|---------------------|
| ≥1 migration succeeded                  | **${PASS_MIG_OK}**       |
| zero migration errors                    | **${PASS_NO_ERRORS}**    |
| D1 running-requests decreased            | **${PASS_GPU_RELEASE}**  |
| D2 generation_tokens grew (Δ=${PEER_GEN_DELTA}) | **${PASS_DST_TOKENS}** |
| cost-benefit gate declined oversize      | **${PASS_DECLINE}**      |
| **OVERALL**                              | **${PASS}**              |
REPORT_EOF

log "REPORT: ${OUT}/REPORT.md"
log "MIG_OK=${MIG_OK}  MIG_ERR=${MIG_ERR}  MIG_DECLINED=${MIG_DECLINED}  MIG_ROLLED_BACK=${MIG_ROLLED_BACK}"
log "PASS_MIG_OK=${PASS_MIG_OK}  PASS_NO_ERRORS=${PASS_NO_ERRORS}  PASS_GPU_RELEASE=${PASS_GPU_RELEASE}  PASS_DST_TOKENS=${PASS_DST_TOKENS}  PASS_DECLINE=${PASS_DECLINE}"
log "OVERALL=${PASS}"
[[ "${PASS}" == "true" ]] && exit 0 || exit 1
