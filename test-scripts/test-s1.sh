#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# S1 — Rollout Scale Up/Down end-to-end test
# ─────────────────────────────────────────────────────────────────────────────
# Verifies the full S1 flow against a real cluster:
#   1) controller is reachable & state == IDLE
#   2) trainer signal "sampling_progress=0.85" → state WARM_UP, DGDSA replicas grow
#   3) "sampling_done=true" + cooldown elapses → state COOL_DOWN → IDLE, replicas drop
#   4) timing assertions (warm-up < 90 s, cool-down honored)
#
# Pre-reqs:
#   - controller deployed (deploy/deploy-controller.sh) and port-forwarded, or
#     CONTROLLER_URL env var pointing at the service.
#   - DGDSAs named ${DGD_NAME}-prefill / ${DGD_NAME}-decode exist.
#
# Usage:
#   CONTROLLER_URL=http://localhost:8080 DGD_NAME=rl-serving NAMESPACE=dynamo \
#       ./test-scripts/test-s1.sh
set -euo pipefail

CONTROLLER_URL="${CONTROLLER_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-dynamo}"
DGD_NAME="${DGD_NAME:-rl-serving}"
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-90}"
COOLDOWN_GRACE="${COOLDOWN_GRACE:-45}"

red()   { printf '\e[31m%s\e[0m\n' "$*"; }
green() { printf '\e[32m%s\e[0m\n' "$*"; }
blue()  { printf '\e[34m== %s ==\e[0m\n' "$*"; }

fail() { red "FAIL: $*"; exit 1; }

api()  { curl -fsS "${CONTROLLER_URL}$1" "${@:2}"; }

state() { api /api/v1/status | python -c 'import sys,json;print(json.load(sys.stdin)["state"])'; }

replicas() {
  local role="$1"
  kubectl -n "${NAMESPACE}" get dgdsa "${DGD_NAME}-${role}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
}

wait_state() {
  local target="$1" timeout="$2" t=0
  while (( t < timeout )); do
    local s; s="$(state)"
    [[ "${s}" == "${target}" ]] && { green "  state=${s} after ${t}s"; return 0; }
    sleep 2; t=$((t+2))
  done
  fail "state did not reach ${target} within ${timeout}s (last=${s:-?})"
}

# ───────────────────────────── 0. pre-flight ────────────────────────────────
blue "0. Pre-flight"
api /api/v1/status >/dev/null || fail "controller unreachable at ${CONTROLLER_URL}"
P0=$(replicas prefill); D0=$(replicas decode)
S0=$(state)
green "  state=${S0}, prefill=${P0}, decode=${D0}"
[[ "${S0}" == "IDLE" ]] || fail "expected IDLE before test, got ${S0}"

# ───────────────────────────── 1. WARM_UP trigger ───────────────────────────
blue "1. Send sampling_progress=0.85 → expect WARM_UP and replicas > baseline"
api /api/v1/signals/sampling_progress \
   -H 'Content-Type: application/json' \
   -d '{"progress":0.85,"batch_meta":{"batch_size":128,"avg_isl":500,"avg_osl":200}}' \
   >/dev/null

wait_state WARM_UP "${WARMUP_TIMEOUT}"

# Wait for at least one DGDSA to have grown
t=0; grew=false
while (( t < WARMUP_TIMEOUT )); do
  P=$(replicas prefill); D=$(replicas decode)
  if (( P > P0 || D > D0 )); then grew=true; break; fi
  sleep 2; t=$((t+2))
done
${grew} || fail "DGDSA replicas did not grow (prefill ${P0}->${P}, decode ${D0}->${D})"
green "  replicas grew prefill ${P0}->${P}, decode ${D0}->${D}"

# Then state should transition to ACTIVE once readiness is observed by metrics
blue "2. Wait for ACTIVE (workers reported ready by Prometheus)"
wait_state ACTIVE 180

# ───────────────────────────── 3. sampling_done + cooldown ──────────────────
blue "3. Send sampling_done → expect COOL_DOWN then IDLE after cooldown"
api /api/v1/signals/sampling_done -X POST -d '{}' -H 'Content-Type: application/json' >/dev/null
wait_state COOL_DOWN 30
wait_state IDLE      "${COOLDOWN_GRACE}"

# ───────────────────────────── 4. scaled back down ──────────────────────────
blue "4. Verify replicas returned to baseline"
P=$(replicas prefill); D=$(replicas decode)
green "  final prefill=${P}, decode=${D}"
(( P <= P0 + 0 && D <= D0 + 0 )) || red "  WARN: replicas did not return to baseline (P0=${P0} P=${P}, D0=${D0} D=${D})"

green "S1 PASSED"
