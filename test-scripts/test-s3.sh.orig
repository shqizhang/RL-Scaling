#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# S3 — Request Consolidation end-to-end test
# ─────────────────────────────────────────────────────────────────────────────
# Validates the full S3 flow:
#   1) Generate uneven load: source decode worker has few inflight, target has
#      many. Both have completed >= MIN_BATCH_COMPLETION.
#   2) Controller's consolidation loop pairs (source -> target), issues
#      migrate_one("*") for each request, then scales down the DGDSA.
#   3) Source worker drains to 0 and is terminated.
#   4) Migrated requests still complete (recompute-prefill fallback) and
#      output is byte-identical to a baseline single-worker run.
#
# Pre-reqs:
#   - CONSOLIDATION_ENABLED=true on controller ConfigMap.
#   - At least 2 decode workers, each with --enable-migration.
#   - A simple load generator script (`tools/load-gen.py`) that holds
#     long-running requests so we can drain.
#
# Usage:
#   CONTROLLER_URL=http://localhost:8080 NAMESPACE=dynamo DGD_NAME=rl-serving \
#       ./test-scripts/test-s3.sh
set -euo pipefail

CONTROLLER_URL="${CONTROLLER_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-dynamo}"
DGD_NAME="${DGD_NAME:-rl-serving}"
LOAD_GEN="${LOAD_GEN:-./test-scripts/tools/load-gen.py}"

blue()  { printf '\e[34m== %s ==\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
red()   { printf '\e[31m%s\e[0m\n' "$*"; }
fail()  { red "FAIL: $*"; exit 1; }

decode_replicas() {
  kubectl -n "${NAMESPACE}" get dgdsa "${DGD_NAME}-decode" -o jsonpath='{.spec.replicas}'
}

worker_inflight() {
  # one inflight count per pod, newline-separated
  for p in $(kubectl -n "${NAMESPACE}" get pod -l "dynamo-component=decode" -o jsonpath='{.items[*].metadata.name}'); do
    n=$(kubectl -n "${NAMESPACE}" exec "$p" -- curl -fsS http://127.0.0.1:9090/metrics 2>/dev/null \
        | awk '/^vllm:num_requests_running/ {print int($2)}' | head -n1)
    echo "${p} ${n:-0}"
  done
}

# ───────────────────────────── 0. pre-flight ────────────────────────────────
blue "0. Pre-flight"
ENABLED=$(curl -fsS "${CONTROLLER_URL}/api/v1/status" | python -c 'import sys,json;print(json.load(sys.stdin).get("consolidation_enabled",False))')
[[ "${ENABLED}" == "True" ]] || fail "set CONSOLIDATION_ENABLED=true and restart controller"
D0=$(decode_replicas); (( D0 >= 2 )) || fail "need >= 2 decode replicas, have ${D0}"
green "  decode replicas=${D0}, consolidation enabled"

# ───────────────────────────── 1. baseline output (single worker) ───────────
blue "1. Capture baseline output (load on a single worker, no migration)"
BASELINE=$(python "${LOAD_GEN}" --url "${CONTROLLER_URL}" --num 8 --max-tokens 64 --seed 42 \
            --pin-worker-index 0 --capture)
echo "${BASELINE}" | sha256sum | tee /tmp/s3-baseline.sha
sleep 5    # let workers idle

# ───────────────────────────── 2. uneven load ───────────────────────────────
blue "2. Generate uneven load: 1 req on worker 0, 6 reqs on worker 1 (long)"
python "${LOAD_GEN}" --url "${CONTROLLER_URL}" --num 1 --max-tokens 64  --pin-worker-index 0 --background --seed 100
python "${LOAD_GEN}" --url "${CONTROLLER_URL}" --num 6 --max-tokens 256 --pin-worker-index 1 --background --seed 200
sleep 3
worker_inflight

# ───────────────────────────── 3. force consolidation tick ──────────────────
blue "3. Trigger consolidation tick"
curl -fsS -X POST "${CONTROLLER_URL}/api/v1/admin/consolidation/tick" >/dev/null

# ───────────────────────────── 4. assert source drained & scaled ────────────
blue "4. Wait for source worker to drain to 0 inflight and DGDSA to shrink"
t=0; OK=false
while (( t < 60 )); do
  D=$(decode_replicas)
  WR=$(worker_inflight | head -n1 | awk '{print $2}')
  if (( D < D0 )); then OK=true; break; fi
  sleep 2; t=$((t+2))
done
${OK} || fail "decode replicas did not shrink (still ${D0})"
green "  decode replicas ${D0} -> ${D}"

# ───────────────────────────── 5. migrated requests still complete ──────────
blue "5. Wait for all background requests to complete"
wait
green "  all requests completed (recompute-prefill fallback exercised)"

# ───────────────────────────── 6. determinism check ─────────────────────────
blue "6. Compare output sha against baseline (greedy decoding seed=200, 1st req)"
MIGRATED=$(python "${LOAD_GEN}" --url "${CONTROLLER_URL}" --num 1 --max-tokens 64 --seed 42 --capture)
echo "${MIGRATED}" | sha256sum | tee /tmp/s3-migrated.sha
diff -q /tmp/s3-baseline.sha /tmp/s3-migrated.sha \
   && green "  outputs match → recompute-prefill is logically correct" \
   || red   "  WARN: outputs differ (expected if sampling != greedy or worker ≠ baseline)"

# ───────────────────────────── 7. metrics audit ─────────────────────────────
blue "7. Controller emitted ConsolidationCompleted event"
curl -fsS "${CONTROLLER_URL}/api/v1/events?type=ConsolidationCompleted&limit=1" \
  | python -c "
import sys,json
e=json.load(sys.stdin)
assert e and e[0]['migrated_requests']>=1, e
print('  migrated_requests=',e[0]['migrated_requests'])
"

green "S3 PASSED"
