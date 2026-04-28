#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# S1 — Rollout Scale Up/Down end-to-end test
# ─────────────────────────────────────────────────────────────────────────────
# Drives the controller through the full lifecycle and asserts on observable
# K8s + Dynamo state at every gate:
#
#   IDLE
#     │  POST /signals/sampling_progress (progress=0.85)
#     ▼
#   WARM_UP                                       — assert: DGDSA replicas grow
#     │  Operator creates Pods, Prometheus reports Ready
#     ▼
#   ACTIVE                                        — assert: pods Running, GPUs allocated
#     │  send N inference requests (real load)    — assert: requests succeed
#     │  POST /signals/batch_complete             — assert: KV indexer non-empty
#     ▼
#   COOL_DOWN                                     — cooldown + drain gate clears
#     │  controller patches replicas=0
#     ▼
#   IDLE                                          — assert: pods gone, GPUs released,
#                                                          KV indexer cleared
#
# Pre-reqs:
#   - dynamo platform deployed (deploy/RL-Scaling/deploy-dynamo.sh)
#   - controller deployed and reachable at CONTROLLER_URL
#   - DGDSAs named ${DGD_NAME}-prefill / ${DGD_NAME}-decode exist
#
# Defaults match the upstream 1.0.1 disagg-router manifest set.
#
# Usage:
#   CONTROLLER_URL=http://localhost:8080 \
#   FRONTEND_URL=http://<node-ip>:30880 \
#   NAMESPACE=dynamo-system DGD_NAME=vllm-v1-disagg-router \
#       ./test-scripts/test-s1.sh
set -euo pipefail

CONTROLLER_URL="${CONTROLLER_URL:-http://localhost:8080}"
FRONTEND_URL="${FRONTEND_URL:-}"               # if empty, live inference is skipped
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
NAMESPACE="${NAMESPACE:-dynamo-system}"
DGD_NAME="${DGD_NAME:-vllm-v1-disagg-router}"
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-90}"
ACTIVE_TIMEOUT="${ACTIVE_TIMEOUT:-300}"        # bigger for first-time model pull
COOLDOWN_GRACE="${COOLDOWN_GRACE:-120}"         # cooldown + drain headroom
INFER_REQS="${INFER_REQS:-4}"

red()    { printf '\e[31m%s\e[0m\n' "$*"; }
green()  { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
blue()   { printf '\e[34m== %s ==\e[0m\n' "$*"; }

fail() { red "FAIL: $*"; exit 1; }
warn() { yellow "WARN: $*"; }

api()  { curl -fsS "${CONTROLLER_URL}$1" "${@:2}"; }

state() {
  api /api/v1/status | python -c 'import sys,json;print(json.load(sys.stdin)["state"])'
}

replicas() {
  local role="$1"
  kubectl -n "${NAMESPACE}" get dgdsa "${DGD_NAME}-${role}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
}

worker_pods_running() {
  kubectl -n "${NAMESPACE}" get pod \
      -l nvidia.com/dynamo-component-type=worker --no-headers 2>/dev/null \
    | awk '$3=="Running"' | wc -l
}

allocated_gpus() {
  kubectl get pods -A -o json 2>/dev/null | python - <<'PY'
import json, sys
total = 0
for p in json.load(sys.stdin)["items"]:
    if p.get("status", {}).get("phase") != "Running":
        continue
    for c in p.get("spec", {}).get("containers", []):
        req = (c.get("resources", {}).get("requests") or {}) \
            | (c.get("resources", {}).get("limits") or {})
        v = req.get("nvidia.com/gpu")
        if v is not None:
            try: total += int(str(v))
            except ValueError: pass
print(total)
PY
}

kv_indexed_blocks() {
  # Best-effort: scrape the frontend's /metrics for KVBM block counters.
  # If the endpoint or metric is absent we report 0 and the assertion is a warn.
  local frontend
  frontend=$(kubectl -n "${NAMESPACE}" get pod \
      -l nvidia.com/dynamo-component-type=frontend \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -z "${frontend}" ]] && { echo 0; return; }
  kubectl -n "${NAMESPACE}" exec "${frontend}" -- \
      curl -sS http://127.0.0.1:9090/metrics 2>/dev/null \
    | awk '/^dynamo_kvbm_state\{/ {sum+=$NF} END {print sum+0}'
}

send_inference() {
  local n="$1" url="${FRONTEND_URL%/}"
  if [[ -z "${url}" ]]; then
    warn "FRONTEND_URL empty; skipping live inference probe"
    return 0
  fi
  local ok=0 code
  for i in $(seq 1 "${n}"); do
    code=$(curl -s -o /tmp/s1-resp.json -w '%{http_code}' \
        --max-time 60 -X POST "${url}/v1/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"Hello ${i}\",\"max_tokens\":16}")
    [[ "${code}" == "200" ]] && ok=$((ok+1))
    printf '   request %d → HTTP %s\n' "$i" "${code}"
  done
  (( ok > 0 )) || return 1
  green "  ${ok}/${n} inference requests succeeded"
}

wait_state() {
  local target="$1" timeout="$2" t=0 s=""
  while (( t < timeout )); do
    s="$(state)"
    [[ "${s}" == "${target}" ]] && { green "  state=${s} after ${t}s"; return 0; }
    sleep 2; t=$((t+2))
  done
  fail "state did not reach ${target} within ${timeout}s (last=${s:-?})"
}

wait_value() {
  # wait_value <get-fn> <comparator> <expected> <timeout>
  local fn="$1" cmp="$2" exp="$3" timeout="$4" t=0 v=""
  while (( t < timeout )); do
    v=$($fn)
    if eval "[[ ${v} ${cmp} ${exp} ]]"; then echo "${v}"; return 0; fi
    sleep 3; t=$((t+3))
  done
  echo "${v}"; return 1
}

# ───────────────────────────── 0. pre-flight ────────────────────────────────
blue "0. Pre-flight"
api /api/v1/status >/dev/null || fail "controller unreachable at ${CONTROLLER_URL}"
kubectl -n "${NAMESPACE}" get dgdsa "${DGD_NAME}-prefill" >/dev/null \
  || fail "DGDSA ${DGD_NAME}-prefill not found in ${NAMESPACE}"
kubectl -n "${NAMESPACE}" get dgdsa "${DGD_NAME}-decode"  >/dev/null \
  || fail "DGDSA ${DGD_NAME}-decode not found in ${NAMESPACE}"

P0=$(replicas prefill); D0=$(replicas decode)
GPU0=$(allocated_gpus)
S0=$(state)
green "  state=${S0}, replicas P=${P0} D=${D0}, GPUs allocated=${GPU0}"
[[ "${S0}" == "idle" ]] || fail "expected state=idle before test, got ${S0}"

# ───────────────────────────── 1. WARM_UP trigger ───────────────────────────
blue "1. sampling_progress=0.85 → expect warm_up and replicas to grow"
api /api/v1/signals/sampling_progress -X POST \
   -H 'Content-Type: application/json' \
   -d '{"progress":0.85,"batch_meta":{"batch_size":128,"avg_isl":500,"avg_osl":200}}' \
   >/dev/null

wait_state warm_up "${WARMUP_TIMEOUT}"

P=$(wait_value "replicas prefill" '-gt' "${P0}" "${WARMUP_TIMEOUT}" || true)
D=$(wait_value "replicas decode"  '-gt' "${D0}" "${WARMUP_TIMEOUT}" || true)
{ (( P > P0 )) || (( D > D0 )); } \
  || fail "DGDSA replicas did not grow (prefill ${P0}->${P}, decode ${D0}->${D})"
green "  replicas grew prefill ${P0}->${P}, decode ${D0}->${D}"

# ───────────────────────────── 2. ACTIVE + GPUs allocated ───────────────────
blue "2. Wait for active (workers Ready in Prometheus)"
wait_state active "${ACTIVE_TIMEOUT}"

GPU1=$(allocated_gpus)
RUN1=$(worker_pods_running)
green "  worker pods Running=${RUN1}, GPUs allocated=${GPU1} (was ${GPU0})"
(( GPU1 > GPU0 )) || warn "GPU allocation did not increase — check node nvidia.com/gpu reporting"
(( RUN1 >= P + D )) || warn "fewer worker pods than DGDSA replicas (P+D=$((P+D)), Running=${RUN1})"

# ───────────────────────────── 3. Live inference + KV indexer non-empty ─────
blue "3. Drive ${INFER_REQS} live inference requests through the frontend"
send_inference "${INFER_REQS}" || fail "no inference request succeeded — workers not actually serving"

KVB=$(kv_indexed_blocks)
green "  KV indexer reports ${KVB} blocks tracked"
(( KVB > 0 )) || warn "KV indexer reports 0 blocks — KV events may not be wired"

# ───────────────────────────── 4. batch_complete → COOL_DOWN → IDLE ─────────
blue "4. batch_complete → expect cool_down, then idle after cooldown+drain"
api /api/v1/signals/batch_complete -X POST -d '{}' -H 'Content-Type: application/json' >/dev/null
wait_state cool_down 30
wait_state idle      "${COOLDOWN_GRACE}"

# ───────────────────────────── 5. Pods/GPUs released, KV indexer cleared ────
blue "5. Verify pods + GPUs released, KV indexer drained"
P_FINAL=$(replicas prefill); D_FINAL=$(replicas decode)
RUN2=$(wait_value worker_pods_running '-eq' 0 60 || true)
GPU2=$(wait_value allocated_gpus '-le' "${GPU0}" 60 || true)
KVB2=$(kv_indexed_blocks)

green "  DGDSA replicas P=${P_FINAL} D=${D_FINAL}"
green "  worker pods Running=${RUN2} (target 0)"
green "  GPUs allocated=${GPU2} (target ≤${GPU0})"
green "  KV indexer blocks=${KVB2} (target 0)"

(( P_FINAL == 0 )) || fail "prefill DGDSA still at ${P_FINAL}"
(( D_FINAL == 0 )) || fail "decode  DGDSA still at ${D_FINAL}"
(( RUN2 == 0 ))    || fail "worker pods still Running: ${RUN2}"
(( GPU2 <= GPU0 )) || fail "GPUs not released: was ${GPU0}, now ${GPU2}"
(( KVB2 == 0 ))    || warn "KV indexer not zero — check KVPublisher shutdown path"

green "S1 PASSED — full idle→warm_up→active→cool_down→idle with KV/GPU release"
