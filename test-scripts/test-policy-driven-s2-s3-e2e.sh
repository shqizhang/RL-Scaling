#!/usr/bin/env bash
# ============================================================================
# test-policy-driven-s2-s3-e2e.sh
#
# End-to-end baseline-vs-strategy timing and throughput experiment for
# RL-Scaling S2/S3.  The script discovers the current Dynamo topology, sends
# the same style of workload in two modes, samples per-pod vLLM metrics, and
# writes a comparison report.
#
# Modes:
#   MODE=baseline  : run workload and collect metrics; do not trigger actions.
#   MODE=strategy  : run workload and collect metrics; observe or trigger S2/S3.
#   MODE=both      : run baseline then strategy and compare.
#
# Strategy drivers:
#   STRATEGY_DRIVER=auto
#       Do not manually call sidecar actions. Use this when the deployed
#       controller actually runs S2/S3 policy. The script records metrics,
#       sidecar roles, active request counts, controller logs, and worker logs.
#   STRATEGY_DRIVER=sidecar
#       Current practical E2E mode for this branch: while workload is running,
#       call worker sidecars to execute role switch and request consolidation,
#       then record the action timing and throughput impact.
#   STRATEGY_DRIVER=none
#       Equivalent to baseline action behavior.
#
# Key outputs:
#   reports/policy-e2e-<TS>/REPORT.md
#   reports/policy-e2e-<TS>/comparison.csv
#   reports/policy-e2e-<TS>/<scenario>/requests.csv
#   reports/policy-e2e-<TS>/<scenario>/pod_metrics.csv
#   reports/policy-e2e-<TS>/<scenario>/pod_throughput.csv
#   reports/policy-e2e-<TS>/<scenario>/strategy_events.jsonl
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-${SCRIPT_DIR}/reports/policy-e2e-${TS}}"
mkdir -p "${OUT}"

NS="${NS:-dynamo-system}"
CONTROLLER_NS="${CONTROLLER_NS:-dynamo}"
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
MODE="${MODE:-both}"                         # baseline|strategy|both
STRATEGY_DRIVER="${STRATEGY_DRIVER:-sidecar}" # auto|sidecar|none

FRONTEND_LOCAL="${FRONTEND_LOCAL:-18000}"
METRIC_BASE="${METRIC_BASE:-19200}"
SIDECAR_BASE="${SIDECAR_BASE:-19300}"
CONTROLLER_LOCAL="${CONTROLLER_LOCAL:-18081}"

N_REQ="${N_REQ:-48}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-768}"
PROMPT_WORDS="${PROMPT_WORDS:-120}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-300}"
SCENARIO_PAUSE_SECONDS="${SCENARIO_PAUSE_SECONDS:-10}"

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
GPU_SAMPLE_INTERVAL="${GPU_SAMPLE_INTERVAL:-5}"
ROLE_SWITCH_DELAY="${ROLE_SWITCH_DELAY:-8}"
CONSOLIDATION_DELAY="${CONSOLIDATION_DELAY:-20}"
AUTO_PROGRESS_DELAY="${AUTO_PROGRESS_DELAY:-18}"
AUTO_PROGRESS_VALUE="${AUTO_PROGRESS_VALUE:-0.9}"
MIG_LOOPS="${MIG_LOOPS:-4}"
MIGRATION_SPACING="${MIGRATION_SPACING:-1}"
STRATEGY_ACTION_TIMEOUT="${STRATEGY_ACTION_TIMEOUT:-120}"
CONSOLIDATION_MIN_ACTIVE="${CONSOLIDATION_MIN_ACTIVE:-1}"
CONSOLIDATION_ACTIVE_MAX="${CONSOLIDATION_ACTIVE_MAX:-6}"
MIG_STOP_ON_SUCCESS="${MIG_STOP_ON_SUCCESS:-1}"
ROLE_SWITCH_SOURCE_ACTIVE_MAX="${ROLE_SWITCH_SOURCE_ACTIVE_MAX:-0}"
ROLE_SWITCH_TARGET_ROLE="${ROLE_SWITCH_TARGET_ROLE:-prefill}"

CONTROLLER_LABEL="${CONTROLLER_LABEL:-app=rl-scaling-controller}"
CAPTURE_LOG_LINES="${CAPTURE_LOG_LINES:-800}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${OUT}/run.log"; }
die() { log "FATAL: $*"; exit 1; }

cleanup_pids=()
scenario_pids=()
strategy_action_pids=()
trap 'for p in "${cleanup_pids[@]:-}" "${scenario_pids[@]:-}" "${strategy_action_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done' EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_cmd kubectl
require_cmd curl
require_cmd python3
require_cmd awk

if [[ "${MODE}" != "baseline" && "${MODE}" != "strategy" && "${MODE}" != "both" ]]; then
  die "MODE must be baseline, strategy, or both"
fi
if [[ "${STRATEGY_DRIVER}" != "auto" && "${STRATEGY_DRIVER}" != "sidecar" && "${STRATEGY_DRIVER}" != "none" ]]; then
  die "STRATEGY_DRIVER must be auto, sidecar, or none"
fi

# ---------------------------------------------------------------- discovery
discover_ready_pods() {
  local component="$1"
  kubectl -n "${NS}" get pod \
    -l "nvidia.com/dynamo-component=${component},nvidia.com/dynamo-graph-deployment-name=${DGD}" \
    --field-selector=status.phase=Running \
    -o json 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in item.get("status", {}).get("conditions", [])
    )
    if ready:
        print(item["metadata"]["name"])
' | sort
}

mapfile -t DECODE_PODS < <(discover_ready_pods VllmDecodeWorker | tr -d '\r')
mapfile -t PREFILL_PODS < <(discover_ready_pods VllmPrefillWorker | tr -d '\r' || true)
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 ready decode pods, have ${#DECODE_PODS[@]}"

FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | tr -d '\r') || die "frontend not found"

log "DGD=${DGD} namespace=${NS} model=${MODEL}"
log "FRONTEND=${FRONTEND_POD}"
log "DECODE_PODS=${DECODE_PODS[*]}"
log "PREFILL_PODS=${PREFILL_PODS[*]:-none}"

# ---------------------------------------------------------------- port-forward
start_pf() {
  local pod="$1" lport="$2" rport="$3" tag="$4"
  kubectl -n "${NS}" port-forward "pod/${pod}" "${lport}:${rport}" \
    > "${OUT}/pf-${tag}.log" 2>&1 &
  cleanup_pids+=("$!")
  for _ in $(seq 1 40); do
    (echo > "/dev/tcp/127.0.0.1/${lport}") 2>/dev/null && return 0
    sleep 0.25
  done
  die "port-forward ${tag} ${lport}:${rport} not reachable"
}

start_pf "${FRONTEND_POD}" "${FRONTEND_LOCAL}" 8000 "frontend"

ALL_PODS=()
ALL_ROLES=()
declare -A POD_ROLE POD_METRIC_PORT POD_SIDECAR_PORT POD_IP

for pod in "${DECODE_PODS[@]}"; do
  ALL_PODS+=("${pod}")
  ALL_ROLES+=("decode")
done
for pod in "${PREFILL_PODS[@]:-}"; do
  [[ -n "${pod}" ]] || continue
  ALL_PODS+=("${pod}")
  ALL_ROLES+=("prefill")
done

for i in "${!ALL_PODS[@]}"; do
  pod="${ALL_PODS[$i]}"
  role="${ALL_ROLES[$i]}"
  POD_ROLE["${pod}"]="${role}"
  POD_METRIC_PORT["${pod}"]=$(( METRIC_BASE + i ))
  start_pf "${pod}" "${POD_METRIC_PORT[$pod]}" 9090 "metric-${i}-${role}"
  POD_IP["${pod}"]=$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
done

for i in "${!DECODE_PODS[@]}"; do
  pod="${DECODE_PODS[$i]}"
  POD_SIDECAR_PORT["${pod}"]=$(( SIDECAR_BASE + i ))
  start_pf "${pod}" "${POD_SIDECAR_PORT[$pod]}" 9091 "sidecar-${i}"
done

cat > "${OUT}/topology.csv" <<EOF
role,pod,pod_ip,metric_local_port,sidecar_local_port
EOF
for pod in "${ALL_PODS[@]}"; do
  printf '%s,%s,%s,%s,%s\n' \
    "${POD_ROLE[$pod]}" "${pod}" "${POD_IP[$pod]:-}" \
    "${POD_METRIC_PORT[$pod]}" "${POD_SIDECAR_PORT[$pod]:-}" \
    >> "${OUT}/topology.csv"
done

cat > "${OUT}/experiment_config.csv" <<EOF
key,value
timestamp,${TS}
namespace,${NS}
controller_namespace,${CONTROLLER_NS}
dgd,${DGD}
model,${MODEL}
mode,${MODE}
strategy_driver,${STRATEGY_DRIVER}
n_req,${N_REQ}
concurrency,${CONCURRENCY}
max_tokens,${MAX_TOKENS}
prompt_words,${PROMPT_WORDS}
sample_interval,${SAMPLE_INTERVAL}
gpu_sample_interval,${GPU_SAMPLE_INTERVAL}
role_switch_delay,${ROLE_SWITCH_DELAY}
consolidation_delay,${CONSOLIDATION_DELAY}
auto_progress_delay,${AUTO_PROGRESS_DELAY}
auto_progress_value,${AUTO_PROGRESS_VALUE}
mig_loops,${MIG_LOOPS}
migration_spacing,${MIGRATION_SPACING}
strategy_action_timeout,${STRATEGY_ACTION_TIMEOUT}
consolidation_min_active,${CONSOLIDATION_MIN_ACTIVE}
consolidation_active_max,${CONSOLIDATION_ACTIVE_MAX}
mig_stop_on_success,${MIG_STOP_ON_SUCCESS}
role_switch_source_active_max,${ROLE_SWITCH_SOURCE_ACTIVE_MAX}
role_switch_target_role,${ROLE_SWITCH_TARGET_ROLE}
controller_label,${CONTROLLER_LABEL}
EOF

{
  echo "key,value"
  kubectl -n "${CONTROLLER_NS}" get cm rl-scaling-controller-config -o json 2>/dev/null \
    | python3 -c 'import csv,json,sys
try:
    data=json.load(sys.stdin).get("data",{})
except Exception:
    data={}
w=csv.writer(sys.stdout)
for k in sorted(data):
    w.writerow([f"configmap.{k}", data[k]])' || true
  kubectl -n "${CONTROLLER_NS}" get deploy rl-scaling-controller -o json 2>/dev/null \
    | python3 -c 'import csv,json,sys
try:
    obj=json.load(sys.stdin)
except Exception:
    obj={}
containers=obj.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[])
w=csv.writer(sys.stdout)
if containers:
    image=containers[0].get("image","")
    if image:
        w.writerow(["deployment.image", image])
    for env in containers[0].get("env",[]) or []:
        if "value" in env:
            w.writerow(["deployment.env."+env.get("name",""), env.get("value","")])' || true
} > "${OUT}/controller_config.csv"

# ---------------------------------------------------------------- metrics helpers
metric_sum() {
  local port="$1" regex="$2"
  (curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null || true) \
    | awk -v r="${regex}" '$0 ~ r && $0 !~ /^#/ {s+=$NF} END{printf "%d", s+0}'
}

metric_last_float() {
  local port="$1" regex="$2"
  (curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null || true) \
    | awk -v r="${regex}" '
      $0 ~ r && $0 !~ /^#/ {
        candidate=$NF
        if (candidate ~ /^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/) {
          v=candidate
        }
      }
      END{if(v==""){printf "0"}else{printf "%s", v}}
    '
}

sidecar_role() {
  local pod="$1" port="${POD_SIDECAR_PORT[$pod]:-}"
  [[ -n "${port}" ]] || { printf 'n/a'; return; }
  curl -fsS -m 2 "http://127.0.0.1:${port}/v1/role" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("current_role","unknown"))' 2>/dev/null \
    || printf 'unknown'
}

active_count() {
  local pod="$1" port="${POD_SIDECAR_PORT[$pod]:-}"
  [[ -n "${port}" ]] || { printf '0'; return; }
  curl -fsS -m 2 "http://127.0.0.1:${port}/v1/active_requests" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null \
    || printf '0'
}

sample_metrics_loop() {
  local scenario="$1" dir="$2" stop_file="$3"
  local csv="${dir}/pod_metrics.csv"
  echo "ts,scenario,role,pod,current_role,prompt_tokens_total,generation_tokens_total,num_requests_running,active_requests" > "${csv}"
  while [[ ! -f "${stop_file}" ]]; do
    local ts_now
    ts_now="$(date +%s.%N)"
    for pod in "${ALL_PODS[@]}"; do
      local port role current_role prompt gen running active
      port="${POD_METRIC_PORT[$pod]}"
      role="${POD_ROLE[$pod]}"
      current_role="${role}"
      [[ "${role}" == "decode" ]] && current_role="$(sidecar_role "${pod}")"
      prompt="$(metric_sum "${port}" '^vllm:prompt_tokens_total[ {]')"
      gen="$(metric_sum "${port}" '^vllm:generation_tokens_total[ {]')"
      running="$(metric_last_float "${port}" '^vllm:num_requests_running[ {]')"
      active="0"
      [[ "${role}" == "decode" ]] && active="$(active_count "${pod}")"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${ts_now}" "${scenario}" "${role}" "${pod}" "${current_role}" \
        "${prompt}" "${gen}" "${running}" "${active}" >> "${csv}"
    done
    sleep "${SAMPLE_INTERVAL}"
  done
}

sample_gpu_loop() {
  local scenario="$1" dir="$2" stop_file="$3"
  local csv="${dir}/gpu_metrics.csv"
  echo "ts,scenario,role,pod,gpu_util_pct,mem_used_mib,mem_total_mib" > "${csv}"
  while [[ ! -f "${stop_file}" ]]; do
    local ts_now
    ts_now="$(date +%s.%N)"
    for pod in "${ALL_PODS[@]}"; do
      local role raw util mem_used mem_total
      role="${POD_ROLE[$pod]}"
      raw="$(kubectl -n "${NS}" exec "${pod}" -- nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d '\r' || true)"
      if [[ -n "${raw}" ]]; then
        util="$(echo "${raw}" | awk -F, '{gsub(/ /,"",$1); print $1+0}')"
        mem_used="$(echo "${raw}" | awk -F, '{gsub(/ /,"",$2); print $2+0}')"
        mem_total="$(echo "${raw}" | awk -F, '{gsub(/ /,"",$3); print $3+0}')"
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
          "${ts_now}" "${scenario}" "${role}" "${pod}" "${util}" "${mem_used}" "${mem_total}" >> "${csv}"
      fi
    done
    sleep "${GPU_SAMPLE_INTERVAL}"
  done
}

# ---------------------------------------------------------------- workload
prompt_text() {
  local scenario="$1" idx="$2" salt="$3"
  python3 - "$scenario" "$idx" "$salt" "$PROMPT_WORDS" <<'PY'
import sys
scenario, idx, salt, words = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
base = (
    "Analyze a reinforcement learning rollout serving system with disaggregated "
    "prefill and decode workers. Explain scheduling, cache behavior, tail latency, "
    "request migration, role switching, GPU utilization, and throughput tradeoffs. "
)
tokens = (base.split() * ((words // len(base.split())) + 2))[:words]
print(f"Scenario {scenario}, request {idx}, salt {salt}. " + " ".join(tokens))
PY
}

submit_one() {
  local scenario="$1" dir="$2" idx="$3" salt="$4"
  local prompt payload start end curl_out code total ttft
  prompt="$(prompt_text "${scenario}" "${idx}" "${salt}")"
  payload=$(python3 - "$MODEL" "$prompt" "$MAX_TOKENS" <<'PY'
import json, sys
model, prompt, max_tokens = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": max_tokens,
    "temperature": 0.7,
    "stream": False,
}, ensure_ascii=True))
PY
)
  start="$(date +%s.%N)"
  curl_out=$(curl -s -m "${REQUEST_TIMEOUT}" \
    -o "${dir}/responses/response-${idx}.json" \
    -w '%{http_code},%{time_total},%{time_starttransfer}' \
    -H "Content-Type: application/json" \
    --data "${payload}" \
    "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions" 2>/dev/null || echo "000,0,0")
  end="$(date +%s.%N)"
  code="$(echo "${curl_out}" | awk -F, '{print $1}')"
  total="$(echo "${curl_out}" | awk -F, '{print $2}')"
  ttft="$(echo "${curl_out}" | awk -F, '{print $3}')"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${idx}" "${scenario}" "${start}" "${end}" "${code}" "${total}" "${ttft}" "${salt}" \
    >> "${dir}/requests.csv"
}

run_workload() {
  local scenario="$1" dir="$2" salt="$3"
  echo "idx,scenario,start_ts,end_ts,http_code,curl_total_s,curl_ttft_s,salt" > "${dir}/requests.csv"
  mkdir -p "${dir}/responses"
  local batch_pids=()
  for i in $(seq 1 "${N_REQ}"); do
    submit_one "${scenario}" "${dir}" "${i}" "${salt}" &
    batch_pids+=("$!")
    if (( ${#batch_pids[@]} >= CONCURRENCY )); then
      for p in "${batch_pids[@]}"; do
        wait "${p}" 2>/dev/null || true
      done
      batch_pids=()
    fi
  done
  for p in "${batch_pids[@]}"; do
    wait "${p}" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------- strategy actions
record_event() {
  local dir="$1" type="$2" json="$3"
  python3 - "$type" "$json" >> "${dir}/strategy_events.jsonl" <<'PY'
import json, sys, time
typ, raw = sys.argv[1], sys.argv[2]
try:
    payload = json.loads(raw)
except Exception:
    payload = {"raw": raw}
print(json.dumps({"ts": time.time(), "type": typ, "payload": payload}, sort_keys=True))
PY
}

with_controller_pf() {
  local callback="$1"
  kubectl -n "${CONTROLLER_NS}" port-forward svc/rl-scaling-controller "${CONTROLLER_LOCAL}:8080" \
    > "${OUT}/pf-controller.log" 2>&1 &
  local pf_pid="$!"
  cleanup_pids+=("${pf_pid}")
  for _ in $(seq 1 40); do
    (echo > "/dev/tcp/127.0.0.1/${CONTROLLER_LOCAL}") 2>/dev/null && break
    sleep 0.25
  done
  "${callback}"
  kill "${pf_pid}" 2>/dev/null || true
}

send_auto_progress_signal() {
  local dir="$1"
  local payload response
  payload="$(python3 - "${AUTO_PROGRESS_VALUE}" <<'PY'
import json, sys
progress = float(sys.argv[1])
print(json.dumps({
    "progress": progress,
    "batch_meta": {"batch_size": 1, "avg_isl": 128, "avg_osl": 768, "total_tokens": 896},
}))
PY
)"
  response="$(curl -fsS -m 10 -H "Content-Type: application/json" \
    --data "${payload}" \
    "http://127.0.0.1:${CONTROLLER_LOCAL}/api/v1/signals/sampling_progress" 2>/dev/null || true)"
  record_event "${dir}" "controller_sampling_progress" "$(python3 - "${AUTO_PROGRESS_VALUE}" "${response}" <<'PY'
import json, sys
progress, raw = float(sys.argv[1]), sys.argv[2]
try:
    response = json.loads(raw) if raw else {}
except Exception:
    response = {"raw": raw}
print(json.dumps({"progress": progress, "response": response}, sort_keys=True))
PY
)"
}

record_controller_status() {
  local dir="$1"
  local response
  response="$(curl -fsS -m 10 "http://127.0.0.1:${CONTROLLER_LOCAL}/api/v1/status" 2>/dev/null || true)"
  record_event "${dir}" "controller_status" "$(python3 - "${response}" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    body = json.loads(raw) if raw else {}
except Exception:
    body = {"raw": raw}
print(json.dumps({"response": body}, sort_keys=True))
PY
)"
}

run_sidecar_strategy_actions() {
  local dir="$1"
  (
    sleep "${CONSOLIDATION_DELAY}"
    local deadline now source_pod target_pod source_active target_active
    local source_port target_url target_ip i resp t0 t1 wall status
    local mig_success=0
    local switch_pod

    deadline=$(( $(date +%s) + STRATEGY_ACTION_TIMEOUT ))
    source_pod=""
    target_pod=""

    while true; do
      now=$(date +%s)
      [[ "${now}" -ge "${deadline}" ]] && break

      source_pod=""
      target_pod=""
      source_active=-1
      target_active=999999

      for pod in "${DECODE_PODS[@]}"; do
        local a
        a=$(active_count "${pod}")
        [[ -z "${a}" ]] && a=0
        if (( a > source_active )); then
          source_active=${a}
          source_pod="${pod}"
        fi
      done

      for pod in "${DECODE_PODS[@]}"; do
        [[ "${pod}" == "${source_pod}" ]] && continue
        local a
        a=$(active_count "${pod}")
        [[ -z "${a}" ]] && a=0
        if (( a < target_active )); then
          target_active=${a}
          target_pod="${pod}"
        fi
      done

      if [[ -n "${source_pod}" && -n "${target_pod}" ]] \
        && (( source_active >= CONSOLIDATION_MIN_ACTIVE )) \
        && (( source_active <= CONSOLIDATION_ACTIVE_MAX )); then
        break
      fi
      sleep 1
    done

    if [[ -z "${source_pod}" || -z "${target_pod}" ]]; then
      record_event "${dir}" "request_consolidation_skipped" "$(python3 - <<'PY'
import json
print(json.dumps({"status":"skipped","reason":"no_eligible_source_target_within_timeout"}))
PY
)"
      return
    fi

    source_port="${POD_SIDECAR_PORT[$source_pod]}"
    target_ip="${POD_IP[$target_pod]}"
    target_url="http://${target_ip}:9091"

    for i in $(seq 1 "${MIG_LOOPS}"); do
      t0="$(date +%s.%N)"
      resp=$(curl -fsS -m 90 -X POST -H "Content-Type: application/json" \
        --data "{\"request_id\":\"*\",\"target_url\":\"${target_url}\"}" \
        "http://127.0.0.1:${source_port}/migrate" 2>/dev/null || echo '{"status":"http_error"}')
      t1="$(date +%s.%N)"
      wall=$(awk -v a="${t0}" -v b="${t1}" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
      status=$(python3 -c 'import json,sys
raw=sys.stdin.read().strip()
try:
    print(json.loads(raw).get("status","parse_error"))
except Exception:
    print("parse_error")' <<< "${resp}")
      echo "${resp}" > "${dir}/migrate-${i}.json"
      record_event "${dir}" "request_consolidation" "$(python3 - "${source_pod}" "${target_pod}" "${i}" "${wall}" "${source_active}" "${target_active}" "${resp}" <<'PY'
import json, sys
source, target, iteration, wall, src_active, dst_active, raw = sys.argv[1:8]
try:
    body = json.loads(raw)
except Exception:
    body = {"raw": raw}
print(json.dumps({
    "source": source,
    "target": target,
    "iteration": int(iteration),
    "client_wall_ms": float(wall),
    "source_active_at_select": int(float(src_active)),
    "target_active_at_select": int(float(dst_active)),
    "response": body,
}))
PY
)"
      if [[ "${status}" == "ok" ]]; then
        mig_success=1
        if [[ "${MIG_STOP_ON_SUCCESS}" == "1" ]]; then
          break
        fi
      fi
      sleep "${MIGRATION_SPACING}"
    done

    sleep "${ROLE_SWITCH_DELAY}"
    switch_pod="${source_pod}"
    if (( mig_success == 1 )); then
      local switch_deadline active_now body port
      switch_deadline=$(( $(date +%s) + STRATEGY_ACTION_TIMEOUT ))
      while true; do
        active_now=$(active_count "${switch_pod}")
        [[ -z "${active_now}" ]] && active_now=0
        if (( active_now <= ROLE_SWITCH_SOURCE_ACTIVE_MAX )); then
          break
        fi
        [[ "$(date +%s)" -ge "${switch_deadline}" ]] && break
        sleep 1
      done

      if (( active_now <= ROLE_SWITCH_SOURCE_ACTIVE_MAX )); then
        local t0s t1s walls resps
        port="${POD_SIDECAR_PORT[$switch_pod]}"
        body="{\"target_role\":\"${ROLE_SWITCH_TARGET_ROLE}\"}"
        t0s="$(date +%s.%N)"
        resps=$(curl -fsS -m 90 -X POST -H "Content-Type: application/json" --data "${body}" \
          "http://127.0.0.1:${port}/switch_role" 2>/dev/null || echo '{"status":"http_error"}')
        t1s="$(date +%s.%N)"
        walls=$(awk -v a="${t0s}" -v b="${t1s}" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
        echo "${resps}" > "${dir}/switch-role-response.json"
        record_event "${dir}" "role_switch" "$(python3 - "${switch_pod}" "${ROLE_SWITCH_TARGET_ROLE}" "${walls}" "${active_now}" "${resps}" <<'PY'
import json, sys
pod, direction, wall, active_now, raw = sys.argv[1:6]
try:
    body = json.loads(raw)
except Exception:
    body = {"raw": raw}
print(json.dumps({
    "pod": pod,
    "direction": f"decode_to_{direction}",
    "active_requests_before_switch": int(float(active_now)),
    "client_wall_ms": float(wall),
    "response": body,
}))
PY
)"
      else
        record_event "${dir}" "role_switch_skipped" "$(python3 - "${switch_pod}" "${active_now}" <<'PY'
import json, sys
pod, active = sys.argv[1], sys.argv[2]
print(json.dumps({"status":"skipped","pod":pod,"reason":"source_not_drained","active_requests":int(float(active))}))
PY
)"
      fi
    else
      record_event "${dir}" "role_switch_skipped" "$(python3 - <<'PY'
import json
print(json.dumps({"status":"skipped","reason":"migration_not_successful"}))
PY
)"
    fi
  ) &
  strategy_action_pids+=("$!")
}

run_auto_strategy_actions() {
  local dir="$1"
  (
    sleep "${AUTO_PROGRESS_DELAY}"
    kubectl -n "${CONTROLLER_NS}" port-forward svc/rl-scaling-controller "${CONTROLLER_LOCAL}:8080" \
      > "${OUT}/pf-controller-auto.log" 2>&1 &
    local controller_pf_pid="$!"
    for _ in $(seq 1 40); do
      (echo > "/dev/tcp/127.0.0.1/${CONTROLLER_LOCAL}") 2>/dev/null && break
      sleep 0.25
    done
    send_auto_progress_signal "${dir}"
    record_controller_status "${dir}"
    sleep 5
    record_controller_status "${dir}"
    kill "${controller_pf_pid}" 2>/dev/null || true
  ) &
  strategy_action_pids+=("$!")
}

capture_logs() {
  local scenario="$1" dir="$2" since="$3"
  mkdir -p "${dir}/logs"
  kubectl -n "${CONTROLLER_NS}" logs -l "${CONTROLLER_LABEL}" --since-time="${since}" --tail="${CAPTURE_LOG_LINES}" \
    > "${dir}/logs/controller.log" 2>/dev/null || true
  for pod in "${ALL_PODS[@]}"; do
    kubectl -n "${NS}" logs "${pod}" --since-time="${since}" --tail="${CAPTURE_LOG_LINES}" \
      > "${dir}/logs/${pod}.log" 2>/dev/null || true
  done
  grep -RniE 'switch_role|DualMode|Migration|migrate|consolidation|role switch' "${dir}/logs" \
    > "${dir}/strategy-log-excerpts.txt" 2>/dev/null || true
  printf '%s\n' "${scenario}" > "${dir}/scenario.txt"
}

analyze_scenario() {
  local scenario="$1" dir="$2"
  python3 - "${scenario}" "${dir}" "${N_REQ}" "${GPU_SAMPLE_INTERVAL}" <<'PY'
import csv, json, math, os, statistics, sys
scenario, out_dir, expected, gpu_interval = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
req_path = os.path.join(out_dir, "requests.csv")
metrics_path = os.path.join(out_dir, "pod_metrics.csv")
gpu_path = os.path.join(out_dir, "gpu_metrics.csv")
responses_dir = os.path.join(out_dir, "responses")
summary_path = os.path.join(out_dir, "summary.json")
throughput_path = os.path.join(out_dir, "pod_throughput.csv")

def pct(vals, p):
    vals = sorted(vals)
    if not vals:
        return 0.0
    idx = min(len(vals) - 1, max(0, int(math.ceil((p / 100.0) * len(vals))) - 1))
    return vals[idx]

def safe_float(value, default=0.0):
    try:
        return float(value or default)
    except Exception:
        return default

requests = []
with open(req_path, newline="") as f:
    for row in csv.DictReader(f):
        requests.append(row)

starts = [float(r["start_ts"]) for r in requests]
ends = [float(r["end_ts"]) for r in requests]
latencies = [float(r["curl_total_s"] or 0) for r in requests]
ttfts = [float(r["curl_ttft_s"] or 0) for r in requests]
ok = sum(1 for r in requests if r["http_code"] == "200")
total_wall = (max(ends) - min(starts)) if starts and ends else 0.0
success_rate = (ok / len(requests) * 100.0) if requests else 0.0

user_prompt_tokens = 0
user_completion_tokens = 0
user_total_tokens = 0
for row in requests:
    idx = str(row.get("idx", ""))
    if not idx.isdigit():
        continue
    path = os.path.join(responses_dir, f"response-{idx}.json")
    if not os.path.exists(path):
        continue
    try:
        with open(path, encoding="utf-8") as f:
            payload = json.load(f)
    except Exception:
        continue
    usage = payload.get("usage") or {}
    if not isinstance(usage, dict):
        usage = {}
    prompt_tokens = int(safe_float(usage.get("prompt_tokens")))
    completion_tokens = int(safe_float(usage.get("completion_tokens")))
    total_tokens = int(safe_float(usage.get("total_tokens")))
    user_prompt_tokens += prompt_tokens
    user_completion_tokens += completion_tokens
    user_total_tokens += total_tokens or (prompt_tokens + completion_tokens)

samples_by_pod = {}
if os.path.exists(metrics_path):
    with open(metrics_path, newline="") as f:
        for row in csv.DictReader(f):
            pod = row["pod"]
            samples_by_pod.setdefault(pod, []).append(row)

pod_rows = []
total_prompt_delta = 0
total_gen_delta = 0
for pod, rows in sorted(samples_by_pod.items()):
    rows.sort(key=lambda r: safe_float(r["ts"]))
    first, last = rows[0], rows[-1]
    elapsed = max(0.001, safe_float(last["ts"]) - safe_float(first["ts"]))
    prompt_delta = int(safe_float(last["prompt_tokens_total"])) - int(safe_float(first["prompt_tokens_total"]))
    gen_delta = int(safe_float(last["generation_tokens_total"])) - int(safe_float(first["generation_tokens_total"]))
    total_prompt_delta += max(0, prompt_delta)
    total_gen_delta += max(0, gen_delta)
    pod_rows.append({
        "scenario": scenario,
        "role": first["role"],
        "pod": pod,
        "first_current_role": first.get("current_role", ""),
        "last_current_role": last.get("current_role", ""),
        "elapsed_s": elapsed,
        "prompt_tokens_delta": prompt_delta,
        "generation_tokens_delta": gen_delta,
        "prompt_tps": prompt_delta / elapsed,
        "generation_tps": gen_delta / elapsed,
        "max_running": max(safe_float(r["num_requests_running"]) for r in rows),
        "max_active_requests": max(safe_float(r["active_requests"]) for r in rows),
    })

with open(throughput_path, "w", newline="") as f:
    fields = ["scenario","role","pod","first_current_role","last_current_role","elapsed_s","prompt_tokens_delta","generation_tokens_delta","prompt_tps","generation_tps","max_running","max_active_requests"]
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(pod_rows)

gpu_rows = []
if os.path.exists(gpu_path):
    with open(gpu_path, newline="") as f:
        for row in csv.DictReader(f):
            gpu_rows.append(row)
gpu_utils = [safe_float(r.get("gpu_util_pct")) for r in gpu_rows]
gpu_mem = [safe_float(r.get("mem_used_mib")) for r in gpu_rows]
gpu_active = sum(1 for v in gpu_utils if v > 0)
gpu_rows_by_pod = {}
for row in gpu_rows:
    gpu_rows_by_pod.setdefault(row.get("pod", ""), []).append(row)
gpu_observed_seconds = 0.0
gpu_active_seconds = 0.0
gpu_effective_seconds = 0.0
for pod, rows in gpu_rows_by_pod.items():
    rows.sort(key=lambda r: safe_float(r.get("ts")))
    for idx, row in enumerate(rows):
        ts = safe_float(row.get("ts"))
        if idx + 1 < len(rows):
            dt = safe_float(rows[idx + 1].get("ts")) - ts
            if dt <= 0:
                dt = gpu_interval
        else:
            dt = gpu_interval
        util = max(0.0, min(100.0, safe_float(row.get("gpu_util_pct"))))
        gpu_observed_seconds += dt
        gpu_effective_seconds += (util / 100.0) * dt
        if util > 0:
            gpu_active_seconds += dt

events_path = os.path.join(out_dir, "strategy_events.jsonl")
event_counts = {}
events = []
if os.path.exists(events_path):
    with open(events_path) as f:
        for line in f:
            if not line.strip():
                continue
            try:
                event = json.loads(line)
                typ = event.get("type", "unknown")
                events.append(event)
            except Exception:
                typ = "parse_error"
            event_counts[typ] = event_counts.get(typ, 0) + 1

timeline_path = os.path.join(out_dir, "event_timeline.csv")
with open(timeline_path, "w", newline="") as f:
    fields = ["ts", "type", "subject", "target", "status", "client_wall_ms"]
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    for event in events:
        payload = event.get("payload", {}) or {}
        response = payload.get("response", {}) if isinstance(payload.get("response"), dict) else {}
        w.writerow({
            "ts": event.get("ts", ""),
            "type": event.get("type", ""),
            "subject": payload.get("pod") or payload.get("source") or payload.get("mode") or "",
            "target": payload.get("target") or payload.get("direction") or "",
            "status": response.get("status", "") if isinstance(response, dict) else "",
            "client_wall_ms": payload.get("client_wall_ms", ""),
        })

summary = {
    "scenario": scenario,
    "expected_requests": expected,
    "completed_requests": len(requests),
    "http_200": ok,
    "http_non_200": len(requests) - ok,
    "success_rate_pct": success_rate,
    "end_to_end_wall_s": total_wall,
    "request_throughput_rps": (ok / total_wall) if total_wall > 0 else 0.0,
    "latency_avg_s": (statistics.mean(latencies) if latencies else 0.0),
    "latency_p50_s": pct(latencies, 50),
    "latency_p95_s": pct(latencies, 95),
    "latency_p99_s": pct(latencies, 99),
    "ttft_avg_s": (statistics.mean(ttfts) if ttfts else 0.0),
    "ttft_p50_s": pct(ttfts, 50),
    "ttft_p95_s": pct(ttfts, 95),
    "ttft_p99_s": pct(ttfts, 99),
    "prompt_tokens_delta": total_prompt_delta,
    "generation_tokens_delta": total_gen_delta,
    "user_prompt_tokens": user_prompt_tokens,
    "user_completion_tokens": user_completion_tokens,
    "user_total_tokens": user_total_tokens,
    "engine_replay_or_overhead_tokens": max(0, total_gen_delta - user_completion_tokens),
    "cluster_prompt_tps": (total_prompt_delta / total_wall) if total_wall > 0 else 0.0,
    "cluster_generation_tps": (total_gen_delta / total_wall) if total_wall > 0 else 0.0,
    "user_completion_tps": (user_completion_tokens / total_wall) if total_wall > 0 else 0.0,
    "gpu_sample_count": len(gpu_rows),
    "gpu_util_avg_pct": (statistics.mean(gpu_utils) if gpu_utils else 0.0),
    "gpu_util_max_pct": (max(gpu_utils) if gpu_utils else 0.0),
    "gpu_mem_used_avg_mib": (statistics.mean(gpu_mem) if gpu_mem else 0.0),
    "gpu_mem_used_max_mib": (max(gpu_mem) if gpu_mem else 0.0),
    "gpu_active_sample_pct": (gpu_active / len(gpu_utils) * 100.0 if gpu_utils else 0.0),
    "gpu_observed_seconds": gpu_observed_seconds,
    "gpu_active_seconds": gpu_active_seconds,
    "gpu_effective_seconds": gpu_effective_seconds,
    "gpu_effective_hours": gpu_effective_seconds / 3600.0,
    "event_counts": event_counts,
    "pod_count": len(pod_rows),
}
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)

scenario_report = os.path.join(out_dir, "REPORT.md")
with open(scenario_report, "w", encoding="utf-8") as f:
    f.write(f"# Scenario Report: {scenario}\n\n")
    f.write("## 1. Run Result\n\n")
    f.write("| metric | value |\n|---|---:|\n")
    for key in [
        "expected_requests", "completed_requests", "http_200", "http_non_200", "success_rate_pct",
        "end_to_end_wall_s", "request_throughput_rps", "latency_avg_s", "latency_p50_s",
        "latency_p95_s", "latency_p99_s", "ttft_avg_s", "ttft_p50_s", "ttft_p95_s", "ttft_p99_s",
        "cluster_prompt_tps", "cluster_generation_tps", "prompt_tokens_delta", "generation_tokens_delta",
        "user_prompt_tokens", "user_completion_tokens", "user_completion_tps", "engine_replay_or_overhead_tokens",
        "gpu_sample_count", "gpu_util_avg_pct", "gpu_util_max_pct", "gpu_mem_used_avg_mib",
        "gpu_mem_used_max_mib", "gpu_active_sample_pct", "gpu_active_seconds",
        "gpu_effective_seconds", "gpu_effective_hours",
    ]:
        value = summary.get(key, "")
        if isinstance(value, float):
            value = f"{value:.6f}"
        f.write(f"| {key} | {value} |\n")
    f.write("\n## 2. Pod Throughput\n\n")
    f.write("| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |\n")
    f.write("|---|---|---|---:|---:|---:|---:|---:|---:|\n")
    for row in pod_rows:
        f.write(
            f"| {row['role']} | {row['pod']} | {row['first_current_role']} -> {row['last_current_role']} | "
            f"{row['prompt_tokens_delta']} | {row['generation_tokens_delta']} | "
            f"{row['prompt_tps']:.3f} | {row['generation_tps']:.3f} | "
            f"{row['max_running']:.0f} | {row['max_active_requests']:.0f} |\n"
        )
    f.write("\n## 3. Strategy Timeline\n\n")
    if events:
        f.write("| ts | type | subject | target/direction | status | client wall ms |\n")
        f.write("|---:|---|---|---|---|---:|\n")
        for event in events:
            payload = event.get("payload", {}) or {}
            response = payload.get("response", {}) if isinstance(payload.get("response"), dict) else {}
            f.write(
                f"| {event.get('ts', '')} | {event.get('type', '')} | "
                f"{payload.get('pod') or payload.get('source') or payload.get('mode') or ''} | "
                f"{payload.get('target') or payload.get('direction') or ''} | "
                f"{response.get('status', '') if isinstance(response, dict) else ''} | "
                f"{payload.get('client_wall_ms', '')} |\n"
            )
    else:
        f.write("No strategy event records were captured for this scenario.\n")
    f.write("\n## 4. Artifact Index\n\n")
    f.write("| artifact | purpose |\n|---|---|\n")
    for artifact, purpose in [
        ("summary.json", "Machine-readable scenario summary"),
        ("requests.csv", "Per-request timing and HTTP status"),
        ("pod_metrics.csv", "Raw per-pod metric samples"),
        ("gpu_metrics.csv", "Raw per-pod GPU utilization and memory samples"),
        ("pod_throughput.csv", "Per-pod throughput summary"),
        ("event_timeline.csv", "Flattened strategy event timeline"),
        ("strategy_events.jsonl", "Raw strategy event payloads"),
        ("strategy-log-excerpts.txt", "Filtered controller/worker log excerpts"),
        ("logs/", "Controller and worker logs"),
    ]:
        f.write(f"| `{artifact}` | {purpose} |\n")
PY
}

run_scenario() {
  local scenario="$1"
  local driver="$2"
  local dir="${OUT}/${scenario}"
  local stop_file="${dir}/STOP_METRICS"
  local salt="${scenario}-${TS}-$(date +%s%N)"
  mkdir -p "${dir}"
  : > "${dir}/strategy_events.jsonl"
  rm -f "${stop_file}"

  local since
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "==== ${scenario}: driver=${driver}, requests=${N_REQ}, concurrency=${CONCURRENCY}, max_tokens=${MAX_TOKENS}, salt=${salt}"
  strategy_action_pids=()

  # Warm with a unique salt. This avoids measuring first-touch overhead only,
  # while keeping the measured prompts unique enough to reduce prefix-cache reuse.
  mkdir -p "${dir}/responses"
  submit_one "${scenario}-warmup" "${dir}" "warmup" "${salt}-warmup" || true
  rm -f "${dir}/requests.csv"

  sample_metrics_loop "${scenario}" "${dir}" "${stop_file}" &
  local sampler_pid="$!"
  scenario_pids+=("${sampler_pid}")
  sample_gpu_loop "${scenario}" "${dir}" "${stop_file}" &
  local gpu_sampler_pid="$!"
  scenario_pids+=("${gpu_sampler_pid}")

  if [[ "${scenario}" == "strategy" && "${driver}" == "sidecar" ]]; then
    run_sidecar_strategy_actions "${dir}"
  elif [[ "${scenario}" == "strategy" && "${driver}" == "auto" ]]; then
    record_event "${dir}" "strategy_driver" '{"mode":"auto","note":"observing controller-triggered actions only"}'
    run_auto_strategy_actions "${dir}"
  else
    record_event "${dir}" "strategy_driver" '{"mode":"none","note":"baseline/passive observation"}'
  fi

  run_workload "${scenario}" "${dir}" "${salt}"
  for p in "${strategy_action_pids[@]:-}"; do
    wait "${p}" 2>/dev/null || true
  done
  sleep 2
  touch "${stop_file}"
  wait "${sampler_pid}" 2>/dev/null || true
  wait "${gpu_sampler_pid}" 2>/dev/null || true

  capture_logs "${scenario}" "${dir}" "${since}"
  analyze_scenario "${scenario}" "${dir}"
  log "${scenario} summary: $(tr -d '\n' < "${dir}/summary.json")"
}

generate_report() {
  python3 - "${OUT}" "${MODE}" "${STRATEGY_DRIVER}" "${DGD}" "${NS}" "${MODEL}" <<'PY'
import csv, json, os, sys
out, mode, driver, dgd, ns, model = sys.argv[1:7]

def load_summary(name):
    path = os.path.join(out, name, "summary.json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)

def fmt(v, digits=3):
  if v is None:
    return "n/a"
  if isinstance(v, (int, float)):
    return f"{v:.{digits}f}"
  return str(v)

def artifact_exists(path):
  return "yes" if os.path.exists(os.path.join(out, path)) else "no"

def read_csv_rows(path):
  full = os.path.join(out, path)
  if not os.path.exists(full):
    return []
  with open(full, newline="", encoding="utf-8") as f:
    return list(csv.DictReader(f))

baseline = load_summary("baseline")
strategy = load_summary("strategy")
fields = [
    "scenario", "completed_requests", "http_200", "http_non_200",
  "success_rate_pct", "end_to_end_wall_s", "request_throughput_rps",
    "latency_p50_s", "latency_p95_s", "latency_p99_s",
    "ttft_p50_s", "ttft_p95_s", "cluster_prompt_tps", "cluster_generation_tps",
    "prompt_tokens_delta", "generation_tokens_delta", "user_prompt_tokens",
    "user_completion_tokens", "user_completion_tps", "engine_replay_or_overhead_tokens",
    "gpu_sample_count", "gpu_util_avg_pct", "gpu_util_max_pct",
    "gpu_mem_used_avg_mib", "gpu_mem_used_max_mib", "gpu_active_sample_pct",
    "gpu_active_seconds", "gpu_effective_seconds", "gpu_effective_hours",
]
with open(os.path.join(out, "comparison.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    for row in (baseline, strategy):
        if row:
            w.writerow({k: row.get(k, "") for k in fields})

improvement = None
throughput_gain = None
user_throughput_gain = None
latency_change = None
gpu_effective_change = None
if baseline and strategy:
    b = baseline.get("end_to_end_wall_s", 0) or 0
    s = strategy.get("end_to_end_wall_s", 0) or 0
    if b > 0:
        improvement = (b - s) / b * 100.0
    bt = baseline.get("cluster_generation_tps", 0) or 0
    st = strategy.get("cluster_generation_tps", 0) or 0
    if bt > 0:
        throughput_gain = (st - bt) / bt * 100.0
    but = baseline.get("user_completion_tps", 0) or 0
    sut = strategy.get("user_completion_tps", 0) or 0
    if but > 0:
        user_throughput_gain = (sut - but) / but * 100.0
    bl = baseline.get("latency_p95_s", 0) or 0
    sl = strategy.get("latency_p95_s", 0) or 0
    if bl > 0:
        latency_change = (bl - sl) / bl * 100.0
    bg = baseline.get("gpu_effective_seconds", 0) or 0
    sg = strategy.get("gpu_effective_seconds", 0) or 0
    if bg > 0:
        gpu_effective_change = (bg - sg) / bg * 100.0

topology_rows = read_csv_rows("topology.csv")
config_rows = read_csv_rows("experiment_config.csv")
controller_config_rows = read_csv_rows("controller_config.csv")
controller_config = {row.get("key", ""): row.get("value", "") for row in controller_config_rows}

def cfg_value(name, default="n/a"):
    return (
        controller_config.get(f"deployment.env.{name}")
        or controller_config.get(f"configmap.{name}")
        or default
    )

lines = []
lines.append("# Policy-driven S2/S3 E2E Test Report")
lines.append("")
lines.append("## 1. Executive Summary")
lines.append("")
lines.append(f"DGD: `{dgd}` | namespace: `{ns}` | model: `{model}` | mode: `{mode}` | strategy driver: `{driver}`")
lines.append("")
if baseline and strategy:
    lines.append("| comparison target | result | interpretation |")
    lines.append("|---|---:|---|")
    lines.append(f"| end-to-end wall time change | {fmt(improvement)}% | positive means strategy completed faster |")
    lines.append(f"| generation throughput change | {fmt(throughput_gain)}% | positive means more generation tokens/s |")
    lines.append(f"| user-visible completion throughput change | {fmt(user_throughput_gain)}% | positive means more response completion tokens/s, excluding engine replay |")
    lines.append(f"| p95 latency change | {fmt(latency_change)}% | positive means lower p95 latency |")
    lines.append(f"| GPU effective seconds change | {fmt(gpu_effective_change)}% | positive means fewer utilization-weighted GPU seconds for the same workload |")
else:
    ran = "baseline" if baseline else "strategy" if strategy else "none"
    lines.append(f"Single-scenario report generated for `{ran}`. Run with `MODE=both` to produce baseline-vs-strategy comparison.")
lines.append("")
lines.append("## 2. Test Configuration")
lines.append("")
lines.append("| key | value |")
lines.append("|---|---|")
for row in config_rows:
    lines.append(f"| `{row.get('key', '')}` | `{row.get('value', '')}` |")
lines.append("")
lines.append("## 3. Controller Strategy Logic")
lines.append("")
lines.append("| strategy | formal trigger condition | deployed value in this run | validation evidence |")
lines.append("|---|---|---|---|")
lines.append(
    "| Baseline | `ROLE_SWITCH_ENABLED=false` and `CONSOLIDATION_ENABLED=false`; controller observes traffic but does not call S2/S3 sidecars | "
    f"`ROLE_SWITCH_ENABLED={cfg_value('ROLE_SWITCH_ENABLED')}`, `CONSOLIDATION_ENABLED={cfg_value('CONSOLIDATION_ENABLED')}` | baseline has no S2/S3 controller execution log lines |"
)
lines.append(
    "| S2 PD Role Switch | prefill-heavy trigger: `prefill_queue_depth >= PREFILL_QUEUE_THRESHOLD` and `decode_utilization <= DECODE_IDLE_THRESHOLD`; decode-heavy trigger: `decode_queue_depth >= DECODE_QUEUE_THRESHOLD` and `prefill_utilization <= PREFILL_IDLE_THRESHOLD`; actions are rate-limited by `MIN_SWITCH_INTERVAL` | "
    f"`PREFILL_QUEUE_THRESHOLD={cfg_value('PREFILL_QUEUE_THRESHOLD')}`, `DECODE_QUEUE_THRESHOLD={cfg_value('DECODE_QUEUE_THRESHOLD')}`, `DECODE_IDLE_THRESHOLD={cfg_value('DECODE_IDLE_THRESHOLD')}`, `PREFILL_IDLE_THRESHOLD={cfg_value('PREFILL_IDLE_THRESHOLD')}`, `MIN_SWITCH_INTERVAL={cfg_value('MIN_SWITCH_INTERVAL')}` | controller status/logs expose `s2_history`, `S2 role switch decision`, and `S2 role switch result` |"
)
lines.append(
    "| S3 Request Consolidation | batch progress must be `>= MIN_BATCH_COMPLETION`; source decode worker must have `1..CONSOLIDATION_THRESHOLD` in-flight requests; target worker must have available capacity at least equal to source active request count; migration must be cost-beneficial; the same plan must remain stable for `CONSOLIDATION_STABLE_SAMPLES` controller ticks and respect `CONSOLIDATION_MIN_INTERVAL` cooldown | "
    f"`MIN_BATCH_COMPLETION={cfg_value('MIN_BATCH_COMPLETION')}`, `CONSOLIDATION_THRESHOLD={cfg_value('CONSOLIDATION_THRESHOLD')}`, `CONSOLIDATION_STABLE_SAMPLES={cfg_value('CONSOLIDATION_STABLE_SAMPLES')}`, `CONSOLIDATION_MIN_INTERVAL={cfg_value('CONSOLIDATION_MIN_INTERVAL')}`, `CONSOLIDATION_SCALE_DOWN_ENABLED={cfg_value('CONSOLIDATION_SCALE_DOWN_ENABLED')}` | controller logs expose waiting/decision/executed records; worker logs expose migration complete/rollback records |"
)
lines.append("")
lines.append("## 4. Topology")
lines.append("")
if topology_rows:
    lines.append("| role | pod | pod IP | metric port | sidecar port |")
    lines.append("|---|---|---|---:|---:|")
    for row in topology_rows:
        lines.append(
            f"| {row.get('role', '')} | `{row.get('pod', '')}` | `{row.get('pod_ip', '')}` | "
            f"{row.get('metric_local_port', '')} | {row.get('sidecar_local_port', '')} |"
        )
else:
    lines.append("Topology was not captured.")
lines.append("")
lines.append("## 5. End-to-End Timing And Throughput")
lines.append("")
lines.append("### Metric Meanings")
lines.append("")
lines.append("| metric | meaning | measurement boundary | why it matters |")
lines.append("|---|---|---|---|")
lines.append("| completed | requests for which the client process returned a row in `requests.csv` | one row per submitted HTTP request | confirms workload size and whether requests finished inside timeout |")
lines.append("| success % | `http_200 / completed * 100` | HTTP status returned by Dynamo frontend `/v1/chat/completions` | validates service correctness while strategy actions occur |")
lines.append("| wall time | `max(end_ts) - min(start_ts)` across measured requests | starts when the first measured curl is launched; ends when the last measured curl returns | represents end-to-end batch completion time |")
lines.append("| req/s | successful frontend HTTP requests per second, `http_200 / wall time` | same wall-time window as above | user-visible request throughput |")
lines.append("| p50 latency | median per-request curl total time | each request start to complete response body | typical user request latency |")
lines.append("| p95/p99 latency | 95th/99th percentile per-request curl total time | each request start to complete response body | tail latency, sensitive to queueing and stragglers |")
lines.append("| p50 TTFT | median curl `time_starttransfer` | request start to first response byte | approximates time-to-first-token / first-byte responsiveness |")
lines.append("| engine gen tok/s | cluster generation token delta divided by wall time | vLLM `generation_tokens_total` sampled before/after scenario | model-side decode throughput; can include migration replay tokens |")
lines.append("| user completion tok/s | sum of HTTP response `usage.completion_tokens` divided by wall time | successful non-streaming frontend responses in `responses/` | user-visible output throughput, excluding internal replay |")
lines.append("| replay/overhead tokens | `engine_generation_tokens_delta - user_completion_tokens`, clamped at 0 | vLLM counters minus frontend response usage | indicates extra engine work such as migration replay/recompute |")
lines.append("| GPU active sample % | share of GPU samples where `nvidia-smi utilization.gpu > 0` | sampled per worker pod every configured GPU interval | coarse proxy for GPU active time / effective-hour utilization |")
lines.append("| GPU effective seconds | sum of `gpu_util_pct / 100 * sample_duration` across worker pods | `nvidia-smi` utilization samples integrated over time | utilization-weighted GPU time; lower is better for equal completed work |")
lines.append("| GPU memory MiB | device memory used by worker pod at sample time | `nvidia-smi memory.used` | shows whether consolidation/switching changes memory footprint or leaves workers occupied |")
lines.append("")
lines.append("### Results")
lines.append("")
lines.append("| scenario | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) | engine gen tok/s | user completion tok/s | replay/overhead tok | GPU active % | GPU effective s | avg GPU util % | max GPU mem MiB |")
lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for row in (baseline, strategy):
    if not row:
        continue
    lines.append(
    f"| {row['scenario']} | {row['completed_requests']} | {fmt(row.get('success_rate_pct'))} | "
        f"{fmt(row['end_to_end_wall_s'])} | {fmt(row['request_throughput_rps'])} | "
        f"{fmt(row['latency_p50_s'])} | {fmt(row['latency_p95_s'])} | "
    f"{fmt(row['latency_p99_s'])} | {fmt(row.get('ttft_p50_s'))} | {fmt(row['cluster_generation_tps'])} | "
    f"{fmt(row.get('user_completion_tps'))} | {fmt(row.get('engine_replay_or_overhead_tokens'), 0)} | "
    f"{fmt(row.get('gpu_active_sample_pct'))} | {fmt(row.get('gpu_effective_seconds'))} | "
    f"{fmt(row.get('gpu_util_avg_pct'))} | {fmt(row.get('gpu_mem_used_max_mib'))} |"
    )
lines.append("")
lines.append("## 6. Strategy Trigger Evidence")
lines.append("")
if strategy:
    if driver == "auto":
        lines.append("`STRATEGY_DRIVER=auto` means this script did not call worker sidecar action endpoints. S2/S3 evidence must come from controller `/api/v1/status`, controller logs, and worker logs captured under `strategy/logs/`.")
        lines.append("")
    lines.append(f"Event counts: `{json.dumps(strategy.get('event_counts', {}), sort_keys=True)}`")
    timeline = read_csv_rows("strategy/event_timeline.csv")
    if timeline:
        lines.append("")
        lines.append("| ts | type | subject | target/direction | status | client wall ms |")
        lines.append("|---:|---|---|---|---|---:|")
        for row in timeline:
            lines.append(
                f"| {row.get('ts', '')} | {row.get('type', '')} | `{row.get('subject', '')}` | "
                f"`{row.get('target', '')}` | {row.get('status', '')} | {row.get('client_wall_ms', '')} |"
            )
else:
    lines.append("No strategy scenario was run.")
lines.append("")
lines.append("Raw event payloads are in `strategy/strategy_events.jsonl`; flattened event rows are in `strategy/event_timeline.csv`.")
lines.append("For auto runs, inspect `strategy/strategy-log-excerpts.txt` for `S2 role switch decision`, `S2 role switch result`, `S3 consolidation decision`, and `S3 consolidation executed` log lines.")
lines.append("")
lines.append("## 7. Per-Scenario Reports")
lines.append("")
lines.append("| scenario | report | requests | pod throughput | raw metrics | logs |")
lines.append("|---|---|---|---|---|---|")
for scenario in ("baseline", "strategy"):
    if os.path.exists(os.path.join(out, scenario)):
        lines.append(
            f"| {scenario} | `{scenario}/REPORT.md` | `{scenario}/requests.csv` | "
            f"`{scenario}/pod_throughput.csv` | `{scenario}/pod_metrics.csv`, `{scenario}/gpu_metrics.csv` | `{scenario}/logs/` |"
        )
lines.append("")
lines.append("## 8. Cache Control Note")
lines.append("")
lines.append("Each scenario uses a unique prompt salt and a separate warmup request. This reduces prefix/KV cache reuse between baseline and strategy. For stricter isolation, run each scenario on freshly restarted workers or clear worker KV state through the deployment-specific clear route before invoking this script.")
lines.append("")
lines.append("## 9. Artifact Index")
lines.append("")
lines.append("| artifact | exists | purpose |")
lines.append("|---|---|---|")
for artifact, purpose in [
    ("experiment_config.csv", "Run configuration captured at script start"),
    ("topology.csv", "Discovered frontend/prefill/decode topology"),
    ("comparison.csv", "Machine-readable scenario comparison"),
    ("controller_config.csv", "Controller ConfigMap and deployment env captured at test start"),
    ("baseline/REPORT.md", "Baseline scenario report"),
    ("strategy/REPORT.md", "Strategy scenario report"),
    ("strategy/event_timeline.csv", "Flattened strategy trigger timeline"),
    ("strategy/gpu_metrics.csv", "Raw strategy GPU utilization and memory samples"),
]:
    lines.append(f"| `{artifact}` | {artifact_exists(artifact)} | {purpose} |")

with open(os.path.join(out, "REPORT.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY
}

# ---------------------------------------------------------------- main
case "${MODE}" in
  baseline)
    run_scenario baseline none
    ;;
  strategy)
    run_scenario strategy "${STRATEGY_DRIVER}"
    ;;
  both)
    run_scenario baseline none
    log "pausing ${SCENARIO_PAUSE_SECONDS}s between baseline and strategy"
    sleep "${SCENARIO_PAUSE_SECONDS}"
    run_scenario strategy "${STRATEGY_DRIVER}"
    ;;
esac

generate_report
log "Report written: ${OUT}/REPORT.md"
