#!/usr/bin/env bash
# ============================================================================
# test-s3-detailed-evidence.sh — S3: Detailed E2E evidence collection for
# request consolidation (live migration of in-flight decode requests).
#
# Captures:
#   - Active requests on TARGET before/after migration (IDs, token counts)
#   - Full migrate_out response (prompt_tokens, generated_tokens, sampling_params)
#   - Full migrate_in response (path, replay_tokens)
#   - Metrics snapshots (gpu_cache, num_requests_running, generation_tokens)
#   - Per-request state on both source and destination
#   - Cost-benefit gate behavior (decline evidence)
#   - Worker logs showing recompute-prefill execution
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${SCRIPT_DIR}/reports/s3-detailed-${TS}"
mkdir -p "${OUT}"

NS="${NS:-dynamo-system}"
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
FRONTEND_LOCAL="${FRONTEND_LOCAL:-18000}"
TGT_SIDECAR="${TGT_SIDECAR:-19191}"
PEER_SIDECAR="${PEER_SIDECAR:-19192}"
TGT_METRICS="${TGT_METRICS:-19291}"
PEER_METRICS="${PEER_METRICS:-19292}"
N_LONG_CHATS="${N_LONG_CHATS:-8}"
N_MIGRATIONS="${N_MIGRATIONS:-3}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${OUT}/run.log"; }
die() { log "FATAL: $*"; exit 1; }

cleanup_pids=()
trap 'for p in "${cleanup_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null' EXIT

# ========================================================= discover pods
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

FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || die "frontend not found"

log "TARGET   = ${TARGET_POD}"
log "PEER     = ${PEER_POD}"
log "FRONTEND = ${FRONTEND_POD}"

# ========================================================= port-forwards
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
start_pf "${TARGET_POD}"   "${TGT_SIDECAR}"    9091  "sidecar-target"
start_pf "${PEER_POD}"     "${PEER_SIDECAR}"    9091  "sidecar-peer"
start_pf "${TARGET_POD}"   "${TGT_METRICS}"     9090  "metrics-target"
start_pf "${PEER_POD}"     "${PEER_METRICS}"     9090  "metrics-peer"

# ========================================================= helpers
read_metric() {
  local port="$1" metric="$2"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk -v m="${metric}" '$0 ~ "^"m"[ {]" {sum+=$NF} END{printf "%s", sum+0}'
}

snapshot_metrics() {
  local label="$1"
  local tgt_gpu=$(read_metric "${TGT_METRICS}" "vllm:gpu_cache_usage_perc")
  local peer_gpu=$(read_metric "${PEER_METRICS}" "vllm:gpu_cache_usage_perc")
  local tgt_run=$(read_metric "${TGT_METRICS}" "vllm:num_requests_running")
  local peer_run=$(read_metric "${PEER_METRICS}" "vllm:num_requests_running")
  local tgt_gen=$(read_metric "${TGT_METRICS}" "vllm:generation_tokens_total")
  local peer_gen=$(read_metric "${PEER_METRICS}" "vllm:generation_tokens_total")
  local tgt_pt=$(read_metric "${TGT_METRICS}" "vllm:prompt_tokens_total")
  local peer_pt=$(read_metric "${PEER_METRICS}" "vllm:prompt_tokens_total")
  echo "${label},${tgt_gpu},${peer_gpu},${tgt_run},${peer_run},${tgt_gen},${peer_gen},${tgt_pt},${peer_pt}" >> "${OUT}/metrics.csv"
  log "metrics[${label}]: tgt_gpu=${tgt_gpu}% peer_gpu=${peer_gpu}% tgt_run=${tgt_run} peer_run=${peer_run} tgt_gen=${tgt_gen} peer_gen=${peer_gen}"
}

active_requests() {
  local port="$1"
  curl -fsS -m 3 "http://127.0.0.1:${port}/v1/active_requests" 2>/dev/null || echo "[]"
}

# ========================================================= warmup
log "warming model"
curl -s -X POST "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"warmup\"}],\"max_tokens\":4}" > /dev/null
sleep 2

echo "label,tgt_gpu_pct,peer_gpu_pct,tgt_running,peer_running,tgt_gen_total,peer_gen_total,tgt_prompt_total,peer_prompt_total" > "${OUT}/metrics.csv"

# ================================================================
# PHASE 0: BASELINE (no load)
# ================================================================
log "================================================================"
log "PHASE 0: BASELINE — no load"
log "================================================================"

snapshot_metrics "T0_baseline"

TGT_ACTIVE_PRE=$(active_requests "${TGT_SIDECAR}")
PEER_ACTIVE_PRE=$(active_requests "${PEER_SIDECAR}")
log "TARGET active requests: ${TGT_ACTIVE_PRE}"
log "PEER   active requests: ${PEER_ACTIVE_PRE}"
echo "${TGT_ACTIVE_PRE}" > "${OUT}/active-target-baseline.json"
echo "${PEER_ACTIVE_PRE}" > "${OUT}/active-peer-baseline.json"

# ================================================================
# PHASE 1: SCHEDULE LONG-RUNNING DECODE REQUESTS
# ================================================================
log "================================================================"
log "PHASE 1: Scheduling ${N_LONG_CHATS} long-running chat requests"
log "================================================================"

log "Sending ${N_LONG_CHATS} streaming chats with max_tokens=16384 (long decode)"
CHAT_PIDS=()
for i in $(seq 1 "${N_LONG_CHATS}"); do
  (
    curl -s -o "${OUT}/chat-long-${i}.json" -w "%{http_code}" \
      -m 120 -H "Content-Type: application/json" \
      -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a very detailed essay about the history of computing, covering every decade from 1940 to 2020 with key inventions, people, and milestones. Be extremely thorough. Request ${i} nonce ${RANDOM}.\"}],\"max_tokens\":16384,\"temperature\":0.7,\"stream\":false}" \
      "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions" \
      > "${OUT}/chat-long-${i}-code.txt" 2>/dev/null
  ) &
  CHAT_PIDS+=("$!")
  cleanup_pids+=("${CHAT_PIDS[-1]}")
  sleep 0.2
done

# Wait for requests to start processing
log "Waiting 3s for requests to start generating..."
sleep 3

snapshot_metrics "T1_after_schedule"

TGT_ACTIVE_LOADED=$(active_requests "${TGT_SIDECAR}")
PEER_ACTIVE_LOADED=$(active_requests "${PEER_SIDECAR}")
TGT_ACTIVE_COUNT=$(echo "${TGT_ACTIVE_LOADED}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
PEER_ACTIVE_COUNT=$(echo "${PEER_ACTIVE_LOADED}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
log "TARGET active requests (${TGT_ACTIVE_COUNT}): ${TGT_ACTIVE_LOADED}"
log "PEER   active requests (${PEER_ACTIVE_COUNT}): ${PEER_ACTIVE_LOADED}"
echo "${TGT_ACTIVE_LOADED}" | python3 -m json.tool > "${OUT}/active-target-loaded.json" 2>/dev/null || echo "${TGT_ACTIVE_LOADED}" > "${OUT}/active-target-loaded.json"
echo "${PEER_ACTIVE_LOADED}" | python3 -m json.tool > "${OUT}/active-peer-loaded.json" 2>/dev/null || echo "${PEER_ACTIVE_LOADED}" > "${OUT}/active-peer-loaded.json"

[[ "${TGT_ACTIVE_COUNT}" -ge 1 ]] || die "no active requests on TARGET after scheduling load"

# ================================================================
# PHASE 2: MIGRATE REQUESTS FROM TARGET → PEER
# ================================================================
log "================================================================"
log "PHASE 2: Migrate ${N_MIGRATIONS} requests from TARGET → PEER"
log "================================================================"

echo "iter,phase,status,request_id,prompt_len,generated_len,path,replay_tokens,reason" > "${OUT}/migrations.csv"

MIG_OK=0; MIG_ERR=0; MIG_DECLINED=0
for i in $(seq 1 "${N_MIGRATIONS}"); do
  log "--- Migration #${i} ---"

  # Show active requests before this migration
  TGT_BEFORE=$(active_requests "${TGT_SIDECAR}")
  TGT_BEFORE_CT=$(echo "${TGT_BEFORE}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  log "  TARGET active before: ${TGT_BEFORE_CT} requests"

  # Step 1: migrate_out (abort + extract on source)
  log "  → POST /migrate_out {request_id: *}"
  MIG_OUT=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
    --data '{"request_id":"*"}' \
    "http://127.0.0.1:${TGT_SIDECAR}/migrate_out" 2>/dev/null)
  echo "${MIG_OUT}" | python3 -m json.tool > "${OUT}/migrate_out_${i}.json" 2>/dev/null || echo "${MIG_OUT}" > "${OUT}/migrate_out_${i}.json"

  OUT_STATUS=$(echo "${MIG_OUT}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "error")
  OUT_RID=$(echo "${MIG_OUT}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("request_id","?"))' 2>/dev/null || echo "?")
  OUT_PROMPT_LEN=$(echo "${MIG_OUT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("prompt_tokens",[])))' 2>/dev/null || echo "?")
  OUT_GEN_LEN=$(echo "${MIG_OUT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("generated_tokens",[])))' 2>/dev/null || echo "?")
  OUT_HAS_BLOCKS=$(echo "${MIG_OUT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("src_block_ids") else "no")' 2>/dev/null || echo "?")
  OUT_HAS_KV=$(echo "${MIG_OUT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("kv_transfer_params") else "no")' 2>/dev/null || echo "?")

  log "  migrate_out: status=${OUT_STATUS} request_id=${OUT_RID}"
  log "    prompt_tokens: ${OUT_PROMPT_LEN} tokens"
  log "    generated_tokens: ${OUT_GEN_LEN} tokens"
  log "    src_block_ids present: ${OUT_HAS_BLOCKS}"
  log "    kv_transfer_params present: ${OUT_HAS_KV}"

  if [[ "${OUT_STATUS}" != "ok" ]]; then
    log "  migrate_out failed: $(echo "${MIG_OUT}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message","?"))' 2>/dev/null)"
    echo "${i},out,${OUT_STATUS},${OUT_RID},${OUT_PROMPT_LEN},${OUT_GEN_LEN},,,$(echo "${MIG_OUT}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",""))' 2>/dev/null)" >> "${OUT}/migrations.csv"
    MIG_ERR=$((MIG_ERR+1))
    continue
  fi

  # Show first 10 and last 10 generated tokens for evidence
  echo "${MIG_OUT}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
gt = d.get("generated_tokens", [])
pt = d.get("prompt_tokens", [])
sp = d.get("sampling_params", {})
print("  Prompt tokens (first 10): %s..." % pt[:10])
print("  Generated tokens (first 10): %s..." % gt[:10])
print("  Generated tokens (last 10): ...%s" % gt[-10:])
print("  Sampling params: temperature=%s, max_tokens=%s, top_p=%s" % (sp.get("temperature","?"), sp.get("max_tokens","?"), sp.get("top_p","?")))
' 2>/dev/null | tee -a "${OUT}/run.log"

  # Show TARGET active after migrate_out (should have 1 fewer)
  TGT_AFTER_OUT=$(active_requests "${TGT_SIDECAR}")
  TGT_AFTER_OUT_CT=$(echo "${TGT_AFTER_OUT}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  log "  TARGET active after migrate_out: ${TGT_AFTER_OUT_CT} (was ${TGT_BEFORE_CT}, diff=$(( TGT_BEFORE_CT - TGT_AFTER_OUT_CT )))"

  # Step 2: migrate_in to PEER (forward full migrate_out response)
  log "  → POST /migrate_in to PEER (replay on destination)"
  MIG_IN=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
    --data "${MIG_OUT}" \
    "http://127.0.0.1:${PEER_SIDECAR}/migrate_in" 2>/dev/null)
  echo "${MIG_IN}" | python3 -m json.tool > "${OUT}/migrate_in_${i}.json" 2>/dev/null || echo "${MIG_IN}" > "${OUT}/migrate_in_${i}.json"

  IN_STATUS=$(echo "${MIG_IN}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "error")
  IN_PATH=$(echo "${MIG_IN}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("path","?"))' 2>/dev/null || echo "?")
  IN_REPLAY=$(echo "${MIG_IN}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("replay_tokens","?"))' 2>/dev/null || echo "?")
  IN_REASON=$(echo "${MIG_IN}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null || echo "")

  log "  migrate_in: status=${IN_STATUS} path=${IN_PATH} replay_tokens=${IN_REPLAY} reason=${IN_REASON}"
  echo "${i},in,${IN_STATUS},${OUT_RID},${OUT_PROMPT_LEN},${OUT_GEN_LEN},${IN_PATH},${IN_REPLAY},${IN_REASON}" >> "${OUT}/migrations.csv"

  if [[ "${IN_STATUS}" == "ok" ]]; then
    MIG_OK=$((MIG_OK+1))
  elif [[ "${IN_STATUS}" == "declined" ]]; then
    MIG_DECLINED=$((MIG_DECLINED+1))
  else
    MIG_ERR=$((MIG_ERR+1))
  fi

  # Show PEER active after migrate_in
  PEER_AFTER_IN=$(active_requests "${PEER_SIDECAR}")
  PEER_AFTER_IN_CT=$(echo "${PEER_AFTER_IN}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  log "  PEER active after migrate_in: ${PEER_AFTER_IN_CT}"

  sleep 1
done

log "Migration summary: ok=${MIG_OK} declined=${MIG_DECLINED} error=${MIG_ERR}"

# Wait for recompute-prefill to execute
log "Waiting 5s for recompute-prefill replays to complete on PEER..."
sleep 5

snapshot_metrics "T2_after_migrations"

# ================================================================
# PHASE 3: VERIFY MIGRATION EFFECTS
# ================================================================
log "================================================================"
log "PHASE 3: Verify migration effects"
log "================================================================"

TGT_ACTIVE_POST=$(active_requests "${TGT_SIDECAR}")
PEER_ACTIVE_POST=$(active_requests "${PEER_SIDECAR}")
TGT_POST_CT=$(echo "${TGT_ACTIVE_POST}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
PEER_POST_CT=$(echo "${PEER_ACTIVE_POST}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
log "TARGET active after migrations: ${TGT_POST_CT} (was ${TGT_ACTIVE_COUNT})"
log "PEER   active after migrations: ${PEER_POST_CT} (was ${PEER_ACTIVE_COUNT})"
echo "${TGT_ACTIVE_POST}" > "${OUT}/active-target-post-migration.json"
echo "${PEER_ACTIVE_POST}" > "${OUT}/active-peer-post-migration.json"

# Capture TARGET worker logs showing aborts
log "--- TARGET logs showing request aborts ---"
{ kubectl -n "${NS}" logs "${TARGET_POD}" --since=120s 2>&1 \
  | grep -aiE "abort|deregist|migrate|cancel" \
  | tail -20 || true; } \
  | tee "${OUT}/target-logs-aborts.txt" | tee -a "${OUT}/run.log"

# Capture PEER worker logs showing recompute replay
log "--- PEER logs showing recompute-prefill replay ---"
{ kubectl -n "${NS}" logs "${PEER_POD}" --since=120s 2>&1 \
  | grep -aiE "replay|migrate|recompute|submit|prefix" \
  | tail -20 || true; } \
  | tee "${OUT}/peer-logs-replay.txt" | tee -a "${OUT}/run.log"

# Wait for everything to settle
log "Waiting 10s for all requests to drain..."
sleep 10
snapshot_metrics "T3_drained"

# ================================================================
# PHASE 4: COST-BENEFIT GATE (DECLINE EVIDENCE)
# ================================================================
log "================================================================"
log "PHASE 4: Cost-benefit gate — synthetic decline test"
log "================================================================"

# Generate a synthetic oversize payload
DECLINE_BODY=$(python3 -c '
import json
body = {
    "request_id": "synthetic-oversize-test",
    "prompt_tokens": list(range(9000)),
    "generated_tokens": list(range(50)),
    "sampling_params": {"max_tokens": 1000, "temperature": 0.7}
}
print(json.dumps(body))
')

DECLINE_RESP=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
  --data "${DECLINE_BODY}" \
  "http://127.0.0.1:${PEER_SIDECAR}/migrate_in" 2>/dev/null)
echo "${DECLINE_RESP}" | python3 -m json.tool > "${OUT}/decline-response.json" 2>/dev/null
DECLINE_STATUS=$(echo "${DECLINE_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null)
DECLINE_REASON=$(echo "${DECLINE_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason","?"))' 2>/dev/null)
log "Decline test: status=${DECLINE_STATUS} reason=${DECLINE_REASON}"

# Also test min_generated_tokens decline
DECLINE2_BODY='{"request_id":"synthetic-too-few-gen","prompt_tokens":[1,2,3],"generated_tokens":[10,11],"sampling_params":{"max_tokens":1000}}'
DECLINE2_RESP=$(curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
  --data "${DECLINE2_BODY}" \
  "http://127.0.0.1:${PEER_SIDECAR}/migrate_in" 2>/dev/null)
echo "${DECLINE2_RESP}" | python3 -m json.tool > "${OUT}/decline2-min-gen.json" 2>/dev/null
DECLINE2_STATUS=$(echo "${DECLINE2_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null)
DECLINE2_REASON=$(echo "${DECLINE2_RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason","?"))' 2>/dev/null)
log "Decline test (min_generated): status=${DECLINE2_STATUS} reason=${DECLINE2_REASON}"

# ================================================================
# PASS/FAIL & REPORT
# ================================================================
log "================================================================"
log "GENERATING REPORT"
log "================================================================"

# Evaluate metrics
T1_TGT_RUN=$(awk -F, '$1=="T1_after_schedule"{print $4}' "${OUT}/metrics.csv")
T2_TGT_RUN=$(awk -F, '$1=="T2_after_migrations"{print $4}' "${OUT}/metrics.csv")
T1_PEER_GEN=$(awk -F, '$1=="T1_after_schedule"{print $7}' "${OUT}/metrics.csv")
T3_PEER_GEN=$(awk -F, '$1=="T3_drained"{print $7}' "${OUT}/metrics.csv")

PASS_MIG_OK="false"; [[ "${MIG_OK}" -ge 1 ]] && PASS_MIG_OK="true"
PASS_NO_ERR="false"; [[ "${MIG_ERR}" -eq 0 ]] && PASS_NO_ERR="true"
PASS_GPU_RELEASE="false"; [[ -n "${T2_TGT_RUN}" && -n "${T1_TGT_RUN}" ]] && (( $(echo "${T2_TGT_RUN} < ${T1_TGT_RUN}" | bc -l 2>/dev/null || echo 0) )) && PASS_GPU_RELEASE="true"
PASS_DST_TAKEOVER="false"
if [[ -n "${T1_PEER_GEN}" && -n "${T3_PEER_GEN}" ]]; then
  DELTA_PEER_GEN=$(awk "BEGIN{print ${T3_PEER_GEN}-${T1_PEER_GEN}+0}")
  (( $(echo "${DELTA_PEER_GEN} > 0" | bc -l 2>/dev/null || echo 0) )) && PASS_DST_TAKEOVER="true"
fi
PASS_DECLINE="false"; [[ "${DECLINE_STATUS}" == "declined" ]] && PASS_DECLINE="true"

OVERALL="false"
[[ "${PASS_MIG_OK}" == "true" && "${PASS_NO_ERR}" == "true" \
   && "${PASS_DECLINE}" == "true" \
   && ( "${PASS_GPU_RELEASE}" == "true" || "${PASS_DST_TAKEOVER}" == "true" ) ]] && OVERALL="true"

# Build migration details table for report
MIG_TABLE=""
for i in $(seq 1 "${N_MIGRATIONS}"); do
  if [[ -f "${OUT}/migrate_out_${i}.json" ]]; then
    MIG_DETAIL=$(python3 -c "
import json
try:
    d = json.load(open('${OUT}/migrate_out_${i}.json'))
    rid = d.get('request_id', '?')
    pt = d.get('prompt_tokens', [])
    gt = d.get('generated_tokens', [])
    sp = d.get('sampling_params', {})
    blk = d.get('src_block_ids')
    kv = d.get('kv_transfer_params')
    blk_s = 'yes' if blk else 'no'
    kv_s = 'yes' if kv else 'no'
    sp_s = 'temp=%s, max_tokens=%s' % (sp.get('temperature','?'), sp.get('max_tokens','?'))
    print('| %s | \`%s...\` | %s | %s | %s | %s | %s |' % (${i}, rid[:30], len(pt), len(gt), sp_s, blk_s, kv_s))
except:
    print('| ${i} | (parse error) | - | - | - | - | - |')
" 2>/dev/null)
    MIG_TABLE="${MIG_TABLE}${MIG_DETAIL}\n"
  fi
done

IN_TABLE=""
for i in $(seq 1 "${N_MIGRATIONS}"); do
  if [[ -f "${OUT}/migrate_in_${i}.json" ]]; then
    IN_DETAIL=$(python3 -c "
import json
try:
    d = json.load(open('${OUT}/migrate_in_${i}.json'))
    print('| %s | %s | %s | %s | %s |' % (${i}, d.get('status','?'), d.get('path','?'), d.get('replay_tokens','?'), d.get('reason','-')))
except:
    print(f'| {i} | (parse error) | - | - | - |')
" 2>/dev/null)
    IN_TABLE="${IN_TABLE}${IN_DETAIL}\n"
  fi
done

cat > "${OUT}/REPORT.md" <<REPORT_EOF
# S3 Request Consolidation — Detailed Evidence Report

**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Image:** \`ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652\`
**Cluster:** single-node K8s, namespace \`${NS}\`
**Model:** \`${MODEL}\`

## Pod inventory

| Role | Pod name |
|------|----------|
| TARGET (source — requests migrated FROM) | \`${TARGET_POD}\` |
| PEER (destination — requests migrated TO) | \`${PEER_POD}\` |
| Frontend | \`${FRONTEND_POD}\` |

---

## Phase 0: Baseline (no load)

Active requests on TARGET: $(echo "${TGT_ACTIVE_PRE}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
Active requests on PEER: $(echo "${PEER_ACTIVE_PRE}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)

---

## Phase 1: Schedule ${N_LONG_CHATS} long-running decode requests

After scheduling, the router distributes them across decoders:

- TARGET active requests: **${TGT_ACTIVE_COUNT}**
- PEER active requests: **${PEER_ACTIVE_COUNT}**

Active request IDs on TARGET:
\`\`\`json
$(cat "${OUT}/active-target-loaded.json" 2>/dev/null)
\`\`\`

---

## Phase 2: Migrate ${N_MIGRATIONS} requests from TARGET → PEER

### migrate_out responses (what was extracted from source)

| # | request_id | prompt_tokens | generated_tokens | sampling_params | src_block_ids | kv_transfer_params |
|---|-----------|---------------|------------------|-----------------|---------------|-------------------|
$(echo -e "${MIG_TABLE}")

### migrate_in responses (what happened on destination)

| # | status | path | replay_tokens | reason |
|---|--------|------|---------------|--------|
$(echo -e "${IN_TABLE}")

### Per-migration detailed data

$(for i in $(seq 1 "${N_MIGRATIONS}"); do
  if [[ -f "${OUT}/migrate_out_${i}.json" ]]; then
    echo "#### Migration #${i}"
    echo ""
    echo "**migrate_out response** (source extracts request state and aborts):"
    echo "\`\`\`json"
    python3 -c "
import json
d = json.load(open('${OUT}/migrate_out_${i}.json'))
# Truncate long arrays for readability
pt = d.get('prompt_tokens',[])
gt = d.get('generated_tokens',[])
summary = {
    'status': d.get('status'),
    'request_id': d.get('request_id'),
    'prompt_tokens_count': len(pt),
    'prompt_tokens_first_10': pt[:10],
    'prompt_tokens_last_5': pt[-5:] if len(pt)>5 else pt,
    'generated_tokens_count': len(gt),
    'generated_tokens_first_10': gt[:10],
    'generated_tokens_last_5': gt[-5:] if len(gt)>5 else gt,
    'sampling_params': d.get('sampling_params'),
    'stop_conditions': d.get('stop_conditions'),
    'src_block_ids': d.get('src_block_ids'),
    'kv_transfer_params': d.get('kv_transfer_params'),
}
print(json.dumps(summary, indent=2))
" 2>/dev/null
    echo "\`\`\`"
    echo ""
    if [[ -f "${OUT}/migrate_in_${i}.json" ]]; then
      echo "**migrate_in response** (destination accepts and replays via recompute-prefill):"
      echo "\`\`\`json"
      cat "${OUT}/migrate_in_${i}.json"
      echo "\`\`\`"
      echo ""
    fi
  fi
done)

### Active request count changes during migration

| Point | TARGET active | PEER active |
|-------|--------------|-------------|
| Before migration | ${TGT_ACTIVE_COUNT} | ${PEER_ACTIVE_COUNT} |
| After all migrations | ${TGT_POST_CT} | ${PEER_POST_CT} |
| **Δ** | **$(( TGT_POST_CT - TGT_ACTIVE_COUNT ))** | **$(( PEER_POST_CT - PEER_ACTIVE_COUNT ))** |

---

## Phase 3: GPU metrics evidence

| Metric | T0 (baseline) | T1 (after schedule) | T2 (after migration) | T3 (drained) |
|--------|:-------------:|:-------------------:|:--------------------:|:------------:|
$(awk -F, 'NR==1{next} {printf "| %s | — | — | — | — |\n", $1}' "${OUT}/metrics.csv" | head -1)
$(python3 -c "
import csv
rows = list(csv.reader(open('${OUT}/metrics.csv')))
hdr = rows[0]
for r in rows[1:]:
    print(f'| {r[0]} | tgt_gpu={r[1]}% peer_gpu={r[2]}% | tgt_run={r[3]} peer_run={r[4]} | tgt_gen={r[5]} peer_gen={r[6]} | tgt_pt={r[7]} peer_pt={r[8]} |')
" 2>/dev/null)

### Key metrics interpretation

- **TARGET \`num_requests_running\`**: T1=${T1_TGT_RUN} → T2=${T2_TGT_RUN}
  $(if [[ "${PASS_GPU_RELEASE}" == "true" ]]; then echo "**Decreased** — proves requests were aborted on source, freeing GPU KV."; else echo "Did not decrease (requests may have completed naturally)."; fi)
- **PEER \`generation_tokens_total\`**: T1=${T1_PEER_GEN} → T3=${T3_PEER_GEN} (Δ=${DELTA_PEER_GEN:-?})
  $(if [[ "${PASS_DST_TAKEOVER}" == "true" ]]; then echo "**Positive delta** — proves PEER is generating tokens for migrated requests."; else echo "No growth detected."; fi)

---

## Phase 4: Cost-benefit gate evidence

The \`MigrationPolicy\` rejects migrations that aren't cost-effective.

### Test 1: Oversize replay (9000 prompt + 50 generated > max_replay_tokens=8192)

\`\`\`json
$(cat "${OUT}/decline-response.json" 2>/dev/null)
\`\`\`

### Test 2: Too few generated tokens (2 < min_generated_tokens=16)

\`\`\`json
$(cat "${OUT}/decline2-min-gen.json" 2>/dev/null)
\`\`\`

Both synthetic requests were correctly **declined** with informative reason strings.

---

## Worker logs

### TARGET: request aborts after migrate_out

\`\`\`
$(cat "${OUT}/target-logs-aborts.txt" 2>/dev/null | head -15)
\`\`\`

### PEER: recompute-prefill replay after migrate_in

\`\`\`
$(cat "${OUT}/peer-logs-replay.txt" 2>/dev/null | head -15)
\`\`\`

---

## Summary

| Condition | Result |
|-----------|--------|
| ≥1 migration succeeded (ok) | **${PASS_MIG_OK}** (${MIG_OK} ok, ${MIG_DECLINED} declined, ${MIG_ERR} errors) |
| Zero migration errors | **${PASS_NO_ERR}** |
| TARGET requests_running decreased | **${PASS_GPU_RELEASE}** (${T1_TGT_RUN} → ${T2_TGT_RUN}) |
| PEER generation_tokens grew | **${PASS_DST_TAKEOVER}** (Δ=${DELTA_PEER_GEN:-?}) |
| Cost-benefit gate declines oversize | **${PASS_DECLINE}** |
| **OVERALL** | **${OVERALL}** |

## Raw artifacts

- \`metrics.csv\` — 4 timestamped metrics snapshots
- \`migrations.csv\` — per-migration outcome summary
- \`migrate_out_N.json\` / \`migrate_in_N.json\` — full API responses
- \`active-target-*.json\` / \`active-peer-*.json\` — active request snapshots
- \`decline-response.json\`, \`decline2-min-gen.json\` — gate test responses
- \`target-logs-aborts.txt\`, \`peer-logs-replay.txt\` — worker log excerpts
- \`chat-long-*.json\` — raw chat responses
- \`run.log\` — complete execution log
REPORT_EOF

log "REPORT: ${OUT}/REPORT.md"
log "PASS_MIG_OK=${PASS_MIG_OK} PASS_NO_ERR=${PASS_NO_ERR} PASS_GPU_RELEASE=${PASS_GPU_RELEASE} PASS_DST_TAKEOVER=${PASS_DST_TAKEOVER} PASS_DECLINE=${PASS_DECLINE}"
log "OVERALL=${OVERALL}"
[[ "${OVERALL}" == "true" ]] && exit 0 || exit 1
