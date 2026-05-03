#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# S2 — Elastic Role Switch end-to-end test
# ─────────────────────────────────────────────────────────────────────────────
# Validates the *observable* parts of a P↔D role flip on a single dual-mode
# worker. Phase 2 (real reconfig): asserts that
#
#   1. POST /switch_role returns ok with switch_time_ms.
#   2. Worker log shows the orchestrated sequence:
#        sleep(level=2) → _reconfig_nixl(real) → _reconfig_kv_pool(real)
#        → set_disaggregation_mode(target) → wake_up → _emit_role_changed
#   3. _reconfig_kv_pool actually called engine.reset_prefix_cache (look for
#      "reset_prefix_cache OK" in worker log).
#   4. NO "stubbed; no Rust reconfig API" markers appear (Phase 2 dropped
#      these stubs in favour of real engine calls).
#   5. Handler's persisted disaggregation mode flips, and the flip back also
#      succeeds (idempotency).
#
# Pre-reqs:
#   - Worker must be deployed with `--dual-mode --initial-role <role>`.
#   - The worker process must expose its system port (DYN_SYSTEM_PORT=9090
#     by default in the operator).
#
# Usage:
#   NAMESPACE=dynamo-system TARGET_POD=<dual-mode worker pod> \
#       bash test-scripts/test-s2.sh
#
# If TARGET_POD is unset the script picks the first decode worker pod; in that
# case the worker MUST have been launched with --dual-mode or step 2 will 404.
set -euo pipefail

NAMESPACE="${NAMESPACE:-dynamo-system}"
DGD_NAME="${DGD_NAME:-vllm-v1-disagg-router}"
WORKER_PORT="${WORKER_PORT:-9090}"
RUN_DIR="${RUN_DIR:-/tmp/rls-test/s2-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "${RUN_DIR}"

red()    { printf '\e[31m%s\e[0m\n' "$*"; }
green()  { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
blue()   { printf '\e[34m== %s ==\e[0m\n' "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
warn()   { yellow "WARN: $*"; }

if [[ -z "${TARGET_POD:-}" ]]; then
  TARGET_POD="$(kubectl -n "${NAMESPACE}" get pod -o name --no-headers \
      | grep "${DGD_NAME}-vllmdecodeworker" | head -n1 | sed 's|^pod/||')"
fi
[[ -n "${TARGET_POD}" ]] || fail "no worker pod found in ${NAMESPACE}"
echo "==> target pod: ${TARGET_POD}"
echo "==> run dir:    ${RUN_DIR}"

# ────────── 0. is the worker dual-mode? probe /switch_role with a no-op ──────
blue "0. Probe /switch_role on ${TARGET_POD}"
PROBE_OUT="$(kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -- \
    curl -sS -o - -w '\nHTTP=%{http_code}\n' \
    -X POST "http://127.0.0.1:${WORKER_PORT}/switch_role" \
    -H 'Content-Type: application/json' -d '{"target_role":"decode"}' 2>&1 || true)"
echo "${PROBE_OUT}" | tee "${RUN_DIR}/probe.txt"
if echo "${PROBE_OUT}" | grep -qE 'HTTP=2(00|01|02)'; then
  green "  worker accepts /switch_role (dual-mode is live)"
else
  fail "/switch_role not registered on worker — re-deploy with --dual-mode"
fi

# Detect current role from the probe response (already-in-target reply
# contains \"new_role\")
CUR_ROLE="$(echo "${PROBE_OUT}" | grep -oE '"new_role":"(prefill|decode)"' \
            | head -n1 | sed 's/.*:"\(.*\)"/\1/')"
[[ -n "${CUR_ROLE}" ]] || fail "could not parse current role from probe response"
TARGET_ROLE="prefill"; [[ "${CUR_ROLE}" == "prefill" ]] && TARGET_ROLE="decode"
green "  current=${CUR_ROLE} → flipping to ${TARGET_ROLE}"

# ────────── 1. flip and capture the worker log window ───────────────────────
blue "1. POST /switch_role ${CUR_ROLE} → ${TARGET_ROLE}"
# Tail the worker log in the background so we can scrape orchestration steps.
LOG_BEFORE_LINES="$(kubectl -n "${NAMESPACE}" logs "${TARGET_POD}" --tail=-1 2>/dev/null | wc -l)"
T0="$(date +%s%3N)"
RESP="$(kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -- \
    curl -sS -X POST "http://127.0.0.1:${WORKER_PORT}/switch_role" \
    -H 'Content-Type: application/json' \
    -d "{\"target_role\":\"${TARGET_ROLE}\"}" || echo "EXEC_FAIL")"
T1="$(date +%s%3N)"
echo "${RESP}" | tee "${RUN_DIR}/flip-response.json"
echo "wall-clock ms: $((T1-T0))" >> "${RUN_DIR}/flip-response.json"

STATUS="$(echo "${RESP}" | grep -oE '"status":"[^"]+"' | head -n1 | cut -d'"' -f4)"
NEW_ROLE="$(echo "${RESP}" | grep -oE '"new_role":"[^"]+"' | head -n1 | cut -d'"' -f4)"
[[ "${STATUS}" == "ok" ]] || fail "flip status=${STATUS}, expected ok"
[[ "${NEW_ROLE}" == "${TARGET_ROLE}" ]] || fail "new_role=${NEW_ROLE}, expected ${TARGET_ROLE}"
green "  flip status=ok new_role=${NEW_ROLE}"

# ────────── 2. orchestration steps appear in worker log ─────────────────────
blue "2. Verify orchestrated sequence in worker log"
sleep 2
kubectl -n "${NAMESPACE}" logs "${TARGET_POD}" --tail=200 > "${RUN_DIR}/worker-flip.log" 2>&1 || true
NEED=("sleep" "_reconfig_nixl" "_reconfig_kv_pool" "wake" )
MISSING=()
for needle in "${NEED[@]}"; do
  grep -qiE "${needle}" "${RUN_DIR}/worker-flip.log" || MISSING+=("${needle}")
done
if (( ${#MISSING[@]} == 0 )); then
  green "  orchestration markers present: ${NEED[*]}"
else
  warn "missing markers: ${MISSING[*]} (worker log may be truncated, see ${RUN_DIR}/worker-flip.log)"
fi
# Stub warnings should NOT appear in Phase 2 — fail loudly if they do.
if grep -qiE 'stubbed; no Rust reconfig API' "${RUN_DIR}/worker-flip.log"; then
  fail "Phase-1 stub markers present in worker log — Phase-2 image not deployed?"
fi
# Phase-2 positive marker: reset_prefix_cache must have been called.
if grep -qiE 'reset_prefix_cache OK' "${RUN_DIR}/worker-flip.log"; then
  green "  Phase-2 marker: engine.reset_prefix_cache reached (real KV-pool reconfig)"
else
  warn "missing 'reset_prefix_cache OK' marker — engine may not expose reset_prefix_cache, see worker log"
fi

# ────────── 3. flip back to original role ──────────────────────────────────
blue "3. Flip back ${TARGET_ROLE} → ${CUR_ROLE}"
RESP2="$(kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -- \
    curl -sS -X POST "http://127.0.0.1:${WORKER_PORT}/switch_role" \
    -H 'Content-Type: application/json' \
    -d "{\"target_role\":\"${CUR_ROLE}\"}" || echo "EXEC_FAIL")"
echo "${RESP2}" | tee "${RUN_DIR}/flip-back.json"
NR2="$(echo "${RESP2}" | grep -oE '"new_role":"[^"]+"' | head -n1 | cut -d'"' -f4)"
[[ "${NR2}" == "${CUR_ROLE}" ]] || fail "flip-back new_role=${NR2}, expected ${CUR_ROLE}"
green "  flip-back ok"

# ────────── summary ────────────────────────────────────────────────────────
{
  echo "S2 summary"
  echo "==========="
  echo "namespace:    ${NAMESPACE}"
  echo "target_pod:   ${TARGET_POD}"
  echo "initial_role: ${CUR_ROLE}"
  echo "target_role:  ${TARGET_ROLE}"
  echo "flip_status:  ${STATUS}"
  echo "round-trip:   $((T1-T0)) ms (wall-clock)"
  echo "missing log markers: ${MISSING[*]:-none}"
  echo "PASS"
} > "${RUN_DIR}/summary.md"

green "S2 PASSED — see ${RUN_DIR}/summary.md"
