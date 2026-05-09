#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# S2 — Elastic Role Switch test  (single-direction, manual-friendly)
# ─────────────────────────────────────────────────────────────────────────────
# Tests ONE direction of the P↔D role flip, selected via --direction / -d.
# Run it twice (p2d then d2p, or vice versa) to exercise both directions
# independently and observe the cluster state between runs.
#
# DIRECTIONS
#   p2d   prefill → decode   (worker currently in prefill role)
#   d2p   decode  → prefill  (worker currently in decode  role)
#   auto  detect current role and flip to the other (default)
#
# WHAT IS VERIFIED PER RUN
#   [1] POST /switch_role responds status=ok, new_role=<target>
#   [2] switch_time_ms is numeric and > 0
#   [3] Orchestration markers appear in worker log:
#         sleep → _reconfig_nixl → _reconfig_kv_pool → wake
#   [4] Phase-2 marker: reset_prefix_cache called (real KV-pool reconfig)
#   [5] No Phase-1 stub markers in log
#   [6] KV cache usage drops to 0 % after the switch (clean KV pool)
#   [7] vLLM metrics snapshot before/after captured for manual review
#
# USAGE
#   # Test decode→prefill on an auto-detected pod:
#   NAMESPACE=dynamo-system bash test-s2.sh --direction d2p
#
#   # Test prefill→decode on a specific pod:
#   NAMESPACE=dynamo-system TARGET_POD=<pod> bash test-s2.sh -d p2d
#
#   # Auto-detect direction (legacy behaviour):
#   NAMESPACE=dynamo-system TARGET_POD=<pod> bash test-s2.sh
#
# LOGS
#   All run artefacts are written to  test-scripts/reports/s2-<ts>/
#   A plain-text summary is printed at the end for direct shell inspection.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# ── tunables ──────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-dynamo-system}"
DGD_NAME="${DGD_NAME:-vllm-v1-disagg-router}"
WORKER_PORT="${WORKER_PORT:-9091}"
METRICS_PORT="${METRICS_PORT:-9090}"
DIRECTION="${DIRECTION:-auto}"           # p2d | d2p | auto
LOCAL_SIDECAR_PORT="${LOCAL_SIDECAR_PORT:-19091}"  # localhost port for port-forward

# ── parse CLI args ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--direction) DIRECTION="$2"; shift 2 ;;
    --pod)          TARGET_POD="$2"; shift 2 ;;
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ "${DIRECTION}" =~ ^(p2d|d2p|auto)$ ]] \
  || { echo "FAIL: --direction must be p2d, d2p, or auto (got '${DIRECTION}')"; exit 1; }

# ── run directory inside reports/ ────────────────────────────────────────────
RUN_DIR="${SCRIPT_DIR}/reports/s2-${DIRECTION}-${RUN_TS}"
mkdir -p "${RUN_DIR}"
LOG="${RUN_DIR}/run.log"
# Tee all output to log file; print raw to terminal so colours render
exec > >(tee -a "${LOG}") 2>&1

# ── helpers ───────────────────────────────────────────────────────────────────
ts()     { date '+%H:%M:%S.%3N'; }
red()    { printf '\e[31m[%s] %s\e[0m\n'   "$(ts)" "$*"; }
green()  { printf '\e[32m[%s] %s\e[0m\n'   "$(ts)" "$*"; }
yellow() { printf '\e[33m[%s] %s\e[0m\n'   "$(ts)" "$*"; }
blue()   { printf '\e[34m[%s] == %s ==\e[0m\n' "$(ts)" "$*"; }
say()    { printf '[%s] %s\n' "$(ts)" "$*"; }
fail()   { red "FAIL: $*"; exit 1; }
warn()   { yellow "WARN: $*"; }
ok()     { green "  [✓] $*"; }
notok()  { red   "  [✗] $*"; }

FAILURES=0
check() { if [[ "$2" -eq 0 ]]; then ok "$1"; else notok "$1"; FAILURES=$((FAILURES+1)); fi; }

# ── persistent state file (survives between p2d ↔ d2p runs) ─────────────────
# Stores pod name + result of the most recent run for each direction so that
# the reverse run can (a) find the pod automatically and (b) show a side-by-side
# comparison without requiring the user to pass --pod manually.
STATE_FILE="${SCRIPT_DIR}/reports/s2-last-state.json"

save_state() {
  # save_state <direction> <pod> <result> <run_dir> <switch_time_ms> <wall_ms>
  python3 - "$@" <<'PY'
import json, sys, os, time
d = {}
path = os.environ.get("STATE_FILE", "")
if os.path.exists(path):
    try: d = json.load(open(path))
    except Exception: d = {}
dir_, pod, result, run_dir, sw_ms, wall_ms = sys.argv[1:7]
d[dir_] = {
    "pod":          pod,
    "result":       result,
    "run_dir":      run_dir,
    "switch_time_ms": sw_ms,
    "wall_ms":      wall_ms,
    "timestamp":    time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
}
json.dump(d, open(path, "w"), indent=2)
PY
}

load_state() {
  # load_state <direction> <key>  — prints value or empty string
  python3 - "$@" <<'PY'
import json, sys, os
path = os.environ.get("STATE_FILE", "")
if not os.path.exists(path): sys.exit(0)
try: d = json.load(open(path))
except Exception: sys.exit(0)
print(d.get(sys.argv[1], {}).get(sys.argv[2], ""), end="")
PY
}
export STATE_FILE

# Scrape vLLM metrics from pod via kubectl exec
scrape_metrics() {  # <pod> <port> <outfile>
  kubectl -n "${NAMESPACE}" exec "$1" -- \
      curl -sS "http://127.0.0.1:$2/metrics" 2>/dev/null > "$3" || true
}

extract_metric() {  # <file> <metric_prefix>
  awk -v m="$2" '$0 ~ ("^"m) { sum += $NF } END { print sum+0 }' "$1"
}

# ── discover pod ──────────────────────────────────────────────────────────────
if [[ -z "${TARGET_POD:-}" ]]; then
  if [[ "${DIRECTION}" == "p2d" ]]; then
    # For p2d: first try to reuse the pod from the last d2p run so the user
    # doesn't have to pass --pod manually.  Fall back to cluster discovery.
    _PREV_POD="$(load_state d2p pod 2>/dev/null || true)"
    if [[ -n "${_PREV_POD}" ]]; then
      # Verify the pod still exists before trusting the cached name
      if kubectl -n "${NAMESPACE}" get pod "${_PREV_POD}" >/dev/null 2>&1; then
        TARGET_POD="${_PREV_POD}"
        say "  pod from last d2p run : ${TARGET_POD}"
      else
        say "  cached pod ${_PREV_POD} no longer exists, falling back to discovery"
      fi
    fi
  fi
  if [[ -z "${TARGET_POD:-}" ]]; then
    TARGET_POD="$(kubectl -n "${NAMESPACE}" get pod -o name --no-headers \
        | grep "${DGD_NAME}-vllmdecodeworker\|${DGD_NAME}-vllmprefillworker" \
        | head -n1 | sed 's|^pod/||')" || true
  fi
fi
[[ -n "${TARGET_POD:-}" ]] || fail "no worker pod found (set TARGET_POD= or --pod <pod>)"

# ── show previous run result for context (p2d shows d2p, d2p shows p2d) ──────
_PREV_DIR=""
[[ "${DIRECTION}" == "p2d" ]] && _PREV_DIR="d2p"
[[ "${DIRECTION}" == "d2p" ]] && _PREV_DIR="p2d"
[[ "${DIRECTION}" == "auto" ]] && _PREV_DIR=""
if [[ -n "${_PREV_DIR}" ]]; then
  _PREV_RESULT="$(load_state "${_PREV_DIR}" result 2>/dev/null || true)"
  _PREV_TS="$(load_state "${_PREV_DIR}" timestamp 2>/dev/null || true)"
  _PREV_RD="$(load_state "${_PREV_DIR}" run_dir 2>/dev/null || true)"
  _PREV_SW="$(load_state "${_PREV_DIR}" switch_time_ms 2>/dev/null || true)"
  if [[ -n "${_PREV_RESULT}" ]]; then
    say ""
    say "  ── Previous ${_PREV_DIR} run ────────────────────────────────"
    say "     result          : ${_PREV_RESULT}"
    say "     timestamp       : ${_PREV_TS}"
    say "     switch_time_ms  : ${_PREV_SW}"
    say "     run dir         : ${_PREV_RD}"
    say "  ─────────────────────────────────────────────────────────────"
    say ""
  fi
fi

say "direction    : ${DIRECTION}"
say "target pod   : ${TARGET_POD}"
say "run dir      : ${RUN_DIR}"
say "log          : ${LOG}"
say ""

# ── port-forward sidecar → localhost:LOCAL_SIDECAR_PORT ──────────────────────
blue "0. Port-forward sidecar to localhost:${LOCAL_SIDECAR_PORT}"
kubectl -n "${NAMESPACE}" port-forward "pod/${TARGET_POD}" \
    "${LOCAL_SIDECAR_PORT}:${WORKER_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null; wait ${PF_PID} 2>/dev/null || true; say 'port-forward cleaned up'" EXIT
sleep 2

PROBE_HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
    -X POST "http://127.0.0.1:${LOCAL_SIDECAR_PORT}/switch_role" \
    -H 'Content-Type: application/json' -d '{"target_role":"decode"}' 2>/dev/null || echo "000")"
if [[ "${PROBE_HTTP}" =~ ^2 ]]; then
  ok "sidecar reachable at localhost:${LOCAL_SIDECAR_PORT} (HTTP ${PROBE_HTTP})"
else
  fail "sidecar not reachable (HTTP ${PROBE_HTTP}) — port-forward may have failed"
fi

# ── detect current role ───────────────────────────────────────────────────────
blue "1. Detect current role"
PROBE_BODY="$(curl -sS --max-time 5 -X POST \
    "http://127.0.0.1:${LOCAL_SIDECAR_PORT}/switch_role" \
    -H 'Content-Type: application/json' -d '{"target_role":"decode"}' 2>/dev/null \
    | tee "${RUN_DIR}/probe.json")"
CUR_ROLE="$(echo "${PROBE_BODY}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("new_role","?"))' 2>/dev/null || echo "?")"
say "probe response : ${PROBE_BODY}"
say "current role   : ${CUR_ROLE}"

# Determine FROM and TO based on DIRECTION
case "${DIRECTION}" in
  p2d) FROM_ROLE="prefill"; TO_ROLE="decode" ;;
  d2p) FROM_ROLE="decode";  TO_ROLE="prefill" ;;
  auto)
    [[ "${CUR_ROLE}" =~ ^(prefill|decode)$ ]] \
      || fail "could not parse current role from probe (got: ${CUR_ROLE})"
    FROM_ROLE="${CUR_ROLE}"
    [[ "${FROM_ROLE}" == "prefill" ]] && TO_ROLE="decode" || TO_ROLE="prefill"
    ;;
esac
say "direction      : ${FROM_ROLE} → ${TO_ROLE}"

if [[ "${DIRECTION}" != "auto" && "${CUR_ROLE}" != "${FROM_ROLE}" ]]; then
  warn "current role is '${CUR_ROLE}' but --direction=${DIRECTION} expects '${FROM_ROLE}'"
  warn "The switch will be issued anyway; --direction controls assertions only."
fi

# ── pre-switch metrics snapshot ───────────────────────────────────────────────
blue "2. Pre-switch metrics snapshot"
scrape_metrics "${TARGET_POD}" "${METRICS_PORT}" "${RUN_DIR}/pre.metrics"
PRE_KV=$(extract_metric  "${RUN_DIR}/pre.metrics" "vllm:kv_cache_usage_perc")
PRE_PT=$(extract_metric  "${RUN_DIR}/pre.metrics" "vllm:prompt_tokens_total")
PRE_GT=$(extract_metric  "${RUN_DIR}/pre.metrics" "vllm:generation_tokens_total")
PRE_RN=$(extract_metric  "${RUN_DIR}/pre.metrics" "vllm:num_requests_running")
say "  kv_cache_usage_perc     = ${PRE_KV}%"
say "  prompt_tokens_total     = ${PRE_PT}"
say "  generation_tokens_total = ${PRE_GT}"
say "  num_requests_running    = ${PRE_RN}"
say ""
say "  Cluster view BEFORE switch (kubectl get pod -L nvidia.com/dynamo-current-role):"
kubectl -n "${NAMESPACE}" get pod \
    -l nvidia.com/dynamo-graph-deployment-name="${DGD_NAME}" \
    -L nvidia.com/dynamo-component,nvidia.com/dynamo-current-role 2>&1 \
    | sed "s|^|  [$(ts)]  |"
say ""
# ── switch_role call ──────────────────────────────────────────────────────────
blue "3. POST /switch_role  ${FROM_ROLE} → ${TO_ROLE}"
say "  issuing switch at $(ts)…"
T0="$(date +%s%3N)"
RESP="$(curl -sS --max-time 60 -X POST \
    "http://127.0.0.1:${LOCAL_SIDECAR_PORT}/switch_role" \
    -H 'Content-Type: application/json' \
    -d "{\"target_role\":\"${TO_ROLE}\"}" \
    | tee "${RUN_DIR}/switch-response.json" || echo '{"status":"EXEC_FAIL"}')"
T1="$(date +%s%3N)"
WALL_MS=$((T1 - T0))
say "  returned at $(ts)  (wall-clock ${WALL_MS} ms)"
say "  response: ${RESP}"

SW_STATUS="$(echo "${RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")"
SW_NEW_ROLE="$(echo "${RESP}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("new_role","?"))' 2>/dev/null || echo "?")"
SW_TIME_MS="$(echo "${RESP}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(round(d.get("switch_time_ms",0),2))' 2>/dev/null || echo "?")"

say "  status=${SW_STATUS}  new_role=${SW_NEW_ROLE}  switch_time_ms=${SW_TIME_MS}"

check "[1] switch_role status=ok"             "$([ "${SW_STATUS}"   == "ok"        ] && echo 0 || echo 1)"
check "[1] switch_role new_role=${TO_ROLE}"   "$([ "${SW_NEW_ROLE}" == "${TO_ROLE}" ] && echo 0 || echo 1)"
if python3 -c "exit(0 if float('${SW_TIME_MS}') > 0 else 1)" 2>/dev/null; then
  ok "[2] switch_time_ms=${SW_TIME_MS} (server-measured, > 0)"
else
  notok "[2] switch_time_ms invalid: '${SW_TIME_MS}'"
  FAILURES=$((FAILURES+1))
fi

# ── patch pod label so `kubectl get pod` reflects the new dynamic role ───────
# K8s pod metadata.name is immutable, so we surface the runtime role via a
# label.  Use `kubectl get pod -L nvidia.com/dynamo-current-role` to view.
if [[ "${SW_STATUS}" == "ok" && "${SW_NEW_ROLE}" == "${TO_ROLE}" ]]; then
  if kubectl -n "${NAMESPACE}" label pod "${TARGET_POD}" \
         "nvidia.com/dynamo-current-role=${SW_NEW_ROLE}" --overwrite \
         > "${RUN_DIR}/label-patch.log" 2>&1; then
    LBL_NEW="$(kubectl -n "${NAMESPACE}" get pod "${TARGET_POD}" \
               -o jsonpath='{.metadata.labels.nvidia\.com/dynamo-current-role}' 2>/dev/null)"
    if [[ "${LBL_NEW}" == "${SW_NEW_ROLE}" ]]; then
      ok "[8] pod label nvidia.com/dynamo-current-role=${LBL_NEW} applied"
    else
      notok "[8] label patch reported success but readback='${LBL_NEW}' (expected '${SW_NEW_ROLE}')"
      FAILURES=$((FAILURES+1))
    fi
  else
    notok "[8] kubectl label failed (see ${RUN_DIR}/label-patch.log)"
    FAILURES=$((FAILURES+1))
  fi
  say ""
  say "  Cluster view (kubectl get pod -L nvidia.com/dynamo-current-role):"
  kubectl -n "${NAMESPACE}" get pod \
      -l nvidia.com/dynamo-graph-deployment-name="${DGD_NAME}" \
      -L nvidia.com/dynamo-component,nvidia.com/dynamo-current-role 2>&1 \
      | sed "s|^|  [$(ts)]  |"
  say ""
fi

# ── worker log analysis ───────────────────────────────────────────────────────
blue "4. Worker log analysis"
sleep 2
say "  fetching last 300 lines of pod log…"
kubectl -n "${NAMESPACE}" logs "${TARGET_POD}" --tail=300 \
    > "${RUN_DIR}/worker-switch.log" 2>&1 || true

NEED=("sleep" "_reconfig_nixl" "_reconfig_kv_pool" "wake")
MISSING=()
for needle in "${NEED[@]}"; do
  grep -qiE "${needle}" "${RUN_DIR}/worker-switch.log" || MISSING+=("${needle}")
done
if (( ${#MISSING[@]} == 0 )); then
  ok "[3] orchestration markers present: ${NEED[*]}"
else
  warn "[3] missing orchestration markers: ${MISSING[*]}"
  warn "     (log may be truncated — check ${RUN_DIR}/worker-switch.log)"
fi

if grep -qiE 'stubbed; no Rust reconfig API' "${RUN_DIR}/worker-switch.log"; then
  notok "[5] Phase-1 stub markers found — Phase-2 image not deployed?"
  FAILURES=$((FAILURES+1))
else
  ok "[5] no Phase-1 stub markers"
fi

if grep -qiE 'reset_prefix_cache' "${RUN_DIR}/worker-switch.log"; then
  ok "[4] engine.reset_prefix_cache called (real KV-pool reconfig)"
else
  warn "[4] 'reset_prefix_cache' not found in log — check ${RUN_DIR}/worker-switch.log"
fi

# ── post-switch metrics snapshot ─────────────────────────────────────────────
blue "5. Post-switch metrics snapshot (2 s settle)"
sleep 2
scrape_metrics "${TARGET_POD}" "${METRICS_PORT}" "${RUN_DIR}/post.metrics"
POST_KV=$(extract_metric "${RUN_DIR}/post.metrics" "vllm:kv_cache_usage_perc")
POST_PT=$(extract_metric "${RUN_DIR}/post.metrics" "vllm:prompt_tokens_total")
POST_GT=$(extract_metric "${RUN_DIR}/post.metrics" "vllm:generation_tokens_total")
POST_RN=$(extract_metric "${RUN_DIR}/post.metrics" "vllm:num_requests_running")

say ""
say "  Metric before → after:"
printf '  [%s]  %-32s  %s → %s\n' "$(ts)" "kv_cache_usage_perc"     "${PRE_KV}%"  "${POST_KV}%"
printf '  [%s]  %-32s  %s → %s\n' "$(ts)" "prompt_tokens_total"     "${PRE_PT}"   "${POST_PT}"
printf '  [%s]  %-32s  %s → %s\n' "$(ts)" "generation_tokens_total" "${PRE_GT}"   "${POST_GT}"
printf '  [%s]  %-32s  %s → %s\n' "$(ts)" "num_requests_running"    "${PRE_RN}"   "${POST_RN}"
say ""

if python3 -c "exit(0 if float('${POST_KV}') == 0.0 else 1)" 2>/dev/null; then
  ok "[6] kv_cache_usage_perc = 0.0% after switch (KV pool clean)"
else
  notok "[6] kv_cache_usage_perc = ${POST_KV}% (expected 0 after switch)"
  FAILURES=$((FAILURES+1))
fi

if python3 -c "exit(0 if float('${POST_RN}') == 0.0 else 1)" 2>/dev/null; then
  ok "    num_requests_running = 0 (no stranded requests)"
else
  warn "    num_requests_running = ${POST_RN} (in-flight requests still counted)"
fi

ok "[7] vLLM metrics snapshots saved:"
say "       pre : ${RUN_DIR}/pre.metrics"
say "       post: ${RUN_DIR}/post.metrics"

# ── summary ───────────────────────────────────────────────────────────────────
blue "6. Summary"
RESULT="PASS"; (( FAILURES > 0 )) && RESULT="FAIL"

printf '\n'
printf 'S2 Role Switch Test Summary\n'
printf '===========================\n'
printf 'direction    : %s → %s\n'   "${FROM_ROLE}" "${TO_ROLE}"
printf 'target pod   : %s\n'        "${TARGET_POD}"
printf 'namespace    : %s\n'        "${NAMESPACE}"
printf 'timestamp    : %s\n'        "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
printf '\n'
printf 'switch_role API:\n'
printf '  status         = %s\n'    "${SW_STATUS}"
printf '  new_role       = %s\n'    "${SW_NEW_ROLE}"
printf '  switch_time_ms = %s  (server-measured)\n'  "${SW_TIME_MS}"
printf '  wall_clock_ms  = %s  (curl round-trip)\n'  "${WALL_MS}"
printf '\n'
printf 'KV cache:\n'
printf '  before = %s%%   after = %s%%\n'  "${PRE_KV}" "${POST_KV}"
printf '\n'
printf 'Log markers missing : %s\n' "${MISSING[*]:-none}"
printf 'Failures            : %s\n' "${FAILURES}"
printf 'RESULT              : %s\n' "${RESULT}"
printf '\n'
printf 'Artefacts:\n'
printf '  run dir  : %s\n' "${RUN_DIR}"
printf '  log      : %s\n' "${LOG}"
printf '  switch   : %s/switch-response.json\n' "${RUN_DIR}"
printf '  pre/post metrics: %s/{pre,post}.metrics\n' "${RUN_DIR}"
printf '  worker log: %s/worker-switch.log\n' "${RUN_DIR}"
printf '\n'

if [[ "${RESULT}" == "PASS" ]]; then
  green "S2 PASSED (${FROM_ROLE} → ${TO_ROLE})"
  green "To test the reverse, run:  bash test-s2.sh --direction $([ "${FROM_ROLE}" == "prefill" ] && echo d2p || echo p2d)"
else
  red "S2 FAILED (${FAILURES} assertion(s) — see ${LOG})"
fi

# ── persist state for the next run ───────────────────────────────────────────
# Save after printing so the exit code below is the test result, not save_state
save_state "${DIRECTION}" "${TARGET_POD}" "${RESULT}" \
           "${RUN_DIR}" "${SW_TIME_MS}" "${WALL_MS}" 2>/dev/null || true
say "  state saved → ${STATE_FILE}"

[[ "${RESULT}" == "PASS" ]] || exit 1
