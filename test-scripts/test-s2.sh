#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# S2 — Elastic Role Switch end-to-end test
# ─────────────────────────────────────────────────────────────────────────────
# Validates the controller's role-switch decision path AND the worker's
# DualModeWorker state flip. Because the underlying NIXL/KV reconfig is still
# stubbed (see RL_SCALING_RUST_CHANGES.md), we only assert on the *observable*
# parts: HTTP /v1/role accepts the flip, the worker reports the new role, and
# inflight requests after the flip are routed to the new role.
#
# Pre-reqs:
#   - DGD must be deployed with `--dual-mode --initial-role decode` on at
#     least one decode worker (let's call it ${TARGET_POD}).
#   - ROLE_SWITCH_ENABLED=true in the controller ConfigMap.
#   - prometheus running and exposing dynamo metrics.
#
# Usage:
#   CONTROLLER_URL=http://localhost:8080 NAMESPACE=dynamo \
#       TARGET_POD=rl-serving-decodeworker-0 \
#       ./test-scripts/test-s2.sh
set -euo pipefail

CONTROLLER_URL="${CONTROLLER_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-dynamo}"
TARGET_POD="${TARGET_POD:?must set TARGET_POD to a dual-mode worker pod}"
WORKER_PORT="${WORKER_PORT:-9090}"

blue()  { printf '\e[34m== %s ==\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
red()   { printf '\e[31m%s\e[0m\n' "$*"; }
fail()  { red "FAIL: $*"; exit 1; }

worker_role() {
  kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -- \
      curl -fsS "http://127.0.0.1:${WORKER_PORT}/v1/role" \
      | python -c 'import sys,json;print(json.load(sys.stdin)["role"])'
}

# ───────────────────────────── 0. pre-flight ────────────────────────────────
blue "0. Worker reachable & dual-mode"
INITIAL_ROLE="$(worker_role)"
green "  initial worker role=${INITIAL_ROLE}"
[[ "${INITIAL_ROLE}" =~ ^(prefill|decode)$ ]] || fail "worker did not report dual-mode role"

# ───────────────────────────── 1. controller reports flag ───────────────────
blue "1. Controller has ROLE_SWITCH_ENABLED=true"
ENABLED=$(curl -fsS "${CONTROLLER_URL}/api/v1/status" | python -c 'import sys,json;print(json.load(sys.stdin).get("role_switch_enabled",False))')
[[ "${ENABLED}" == "True" ]] || fail "controller has ROLE_SWITCH_ENABLED=${ENABLED}, set it to true and restart"

# ───────────────────────────── 2. force a flip via the worker API ───────────
TARGET_ROLE="prefill"; [[ "${INITIAL_ROLE}" == "prefill" ]] && TARGET_ROLE="decode"
blue "2. Direct flip ${INITIAL_ROLE} → ${TARGET_ROLE} via worker /v1/role"
kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -- \
    curl -fsS -X POST "http://127.0.0.1:${WORKER_PORT}/v1/role" \
    -H 'Content-Type: application/json' \
    -d "{\"target_role\":\"${TARGET_ROLE}\"}" >/dev/null

# wait up to 30s for role to settle
t=0
while (( t < 30 )); do
  CUR="$(worker_role)"
  [[ "${CUR}" == "${TARGET_ROLE}" ]] && break
  sleep 2; t=$((t+2))
done
[[ "${CUR}" == "${TARGET_ROLE}" ]] || fail "worker role did not flip to ${TARGET_ROLE} (still ${CUR})"
green "  worker role now ${CUR}"

# ───────────────────────────── 3. controller observed the change ────────────
blue "3. Controller surfaced WorkerRoleChanged event in /api/v1/events"
curl -fsS "${CONTROLLER_URL}/api/v1/events?type=WorkerRoleChanged&limit=5" \
  | python -c "
import sys,json
events=json.load(sys.stdin)
assert any(e['target_role']=='${TARGET_ROLE}' for e in events), 'no matching event'
print('  ok')
"

# ───────────────────────────── 4. routing: inflight goes to new role ────────
blue "4. Send a generation request and assert it lands on a ${TARGET_ROLE} worker"
REQ_ID=$(uuidgen 2>/dev/null || python -c 'import uuid;print(uuid.uuid4())')
RESP=$(curl -fsS "${CONTROLLER_URL}/api/v1/debug/generate" \
        -H 'Content-Type: application/json' \
        -d "{\"request_id\":\"${REQ_ID}\",\"prompt\":\"hello\",\"max_tokens\":4}")
LANDED=$(echo "${RESP}" | python -c 'import sys,json;print(json.load(sys.stdin)["worker_role"])')
[[ "${LANDED}" == "${TARGET_ROLE}" ]] || fail "request landed on ${LANDED}, expected ${TARGET_ROLE}"
green "  request landed on ${LANDED}"

# ───────────────────────────── 5. flip back and confirm ─────────────────────
blue "5. Flip back to ${INITIAL_ROLE}"
kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -- \
    curl -fsS -X POST "http://127.0.0.1:${WORKER_PORT}/v1/role" \
    -H 'Content-Type: application/json' \
    -d "{\"target_role\":\"${INITIAL_ROLE}\"}" >/dev/null
sleep 5
CUR="$(worker_role)"
[[ "${CUR}" == "${INITIAL_ROLE}" ]] || fail "rollback failed (now ${CUR})"
green "S2 PASSED"
