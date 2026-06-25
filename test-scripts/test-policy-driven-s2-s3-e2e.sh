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
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
MODE="${MODE:-both}"                         # baseline|strategy|both
STRATEGY_DRIVER="${STRATEGY_DRIVER:-sidecar}" # auto|sidecar|none

FRONTEND_LOCAL="${FRONTEND_LOCAL:-18000}"
METRIC_BASE="${METRIC_BASE:-19200}"
SIDECAR_BASE="${SIDECAR_BASE:-19300}"

N_REQ="${N_REQ:-48}"
CONCURRENCY="${CONCURRENCY:-8}"
MAX_TOKENS="${MAX_TOKENS:-768}"
PROMPT_WORDS="${PROMPT_WORDS:-120}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-300}"
SCENARIO_PAUSE_SECONDS="${SCENARIO_PAUSE_SECONDS:-10}"

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
ROLE_SWITCH_DELAY="${ROLE_SWITCH_DELAY:-8}"
CONSOLIDATION_DELAY="${CONSOLIDATION_DELAY:-20}"
MIG_LOOPS="${MIG_LOOPS:-4}"
MIGRATION_SPACING="${MIGRATION_SPACING:-1}"

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

mapfile -t DECODE_PODS < <(discover_ready_pods VllmDecodeWorker)
mapfile -t PREFILL_PODS < <(discover_ready_pods VllmPrefillWorker || true)
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 ready decode pods, have ${#DECODE_PODS[@]}"

FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || die "frontend not found"

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
dgd,${DGD}
model,${MODEL}
mode,${MODE}
strategy_driver,${STRATEGY_DRIVER}
n_req,${N_REQ}
concurrency,${CONCURRENCY}
max_tokens,${MAX_TOKENS}
prompt_words,${PROMPT_WORDS}
sample_interval,${SAMPLE_INTERVAL}
role_switch_delay,${ROLE_SWITCH_DELAY}
consolidation_delay,${CONSOLIDATION_DELAY}
mig_loops,${MIG_LOOPS}
migration_spacing,${MIGRATION_SPACING}
controller_label,${CONTROLLER_LABEL}
EOF

# ---------------------------------------------------------------- metrics helpers
metric_sum() {
  local port="$1" regex="$2"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk -v r="${regex}" '$0 ~ r && $0 !~ /^#/ {s+=$NF} END{printf "%d", s+0}'
}

metric_last_float() {
  local port="$1" regex="$2"
  curl -fsS -m 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | awk -v r="${regex}" '$0 ~ r && $0 !~ /^#/ {v=$NF} END{if(v==""){printf "0"}else{printf "%s", v}}'
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

run_sidecar_strategy_actions() {
  local dir="$1"
  local switch_pod="${DECODE_PODS[0]}"
  local source_pod="${DECODE_PODS[0]}"
  local target_pod="${DECODE_PODS[1]}"

  # If there are >=3 decode pods, keep consolidation away from the switched pod.
  if [[ "${#DECODE_PODS[@]}" -ge 3 ]]; then
    switch_pod="${DECODE_PODS[0]}"
    source_pod="${DECODE_PODS[1]}"
    target_pod="${DECODE_PODS[2]}"
  fi

  (
    sleep "${ROLE_SWITCH_DELAY}"
    local port body t0 t1 resp wall
    port="${POD_SIDECAR_PORT[$switch_pod]}"
    body='{"target_role":"prefill"}'
    t0="$(date +%s.%N)"
    resp=$(curl -fsS -m 90 -X POST -H "Content-Type: application/json" --data "${body}" \
      "http://127.0.0.1:${port}/switch_role" 2>/dev/null || echo '{"status":"http_error"}')
    t1="$(date +%s.%N)"
    wall=$(awk -v a="${t0}" -v b="${t1}" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
    echo "${resp}" > "${dir}/switch-role-response.json"
    record_event "${dir}" "role_switch" "$(python3 - "${switch_pod}" "${wall}" "${resp}" <<'PY'
import json, sys
pod, wall, raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    body = json.loads(raw)
except Exception:
    body = {"raw": raw}
print(json.dumps({"pod": pod, "direction": "decode_to_prefill", "client_wall_ms": float(wall), "response": body}))
PY
)"
  ) &
  strategy_action_pids+=("$!")

  (
    sleep "${CONSOLIDATION_DELAY}"
    local source_port target_url i resp t0 t1 wall target_ip
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
      echo "${resp}" > "${dir}/migrate-${i}.json"
      record_event "${dir}" "request_consolidation" "$(python3 - "${source_pod}" "${target_pod}" "${i}" "${wall}" "${resp}" <<'PY'
import json, sys
source, target, iteration, wall, raw = sys.argv[1:6]
try:
    body = json.loads(raw)
except Exception:
    body = {"raw": raw}
print(json.dumps({"source": source, "target": target, "iteration": int(iteration), "client_wall_ms": float(wall), "response": body}))
PY
)"
      sleep "${MIGRATION_SPACING}"
    done
  ) &
  strategy_action_pids+=("$!")
}

capture_logs() {
  local scenario="$1" dir="$2" since="$3"
  mkdir -p "${dir}/logs"
  kubectl -n "${NS}" logs -l "${CONTROLLER_LABEL}" --since-time="${since}" --tail="${CAPTURE_LOG_LINES}" \
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
  python3 - "${scenario}" "${dir}" "${N_REQ}" <<'PY'
import csv, json, math, os, statistics, sys
scenario, out_dir, expected = sys.argv[1], sys.argv[2], int(sys.argv[3])
req_path = os.path.join(out_dir, "requests.csv")
metrics_path = os.path.join(out_dir, "pod_metrics.csv")
summary_path = os.path.join(out_dir, "summary.json")
throughput_path = os.path.join(out_dir, "pod_throughput.csv")

def pct(vals, p):
    vals = sorted(vals)
    if not vals:
        return 0.0
    idx = min(len(vals) - 1, max(0, int(math.ceil((p / 100.0) * len(vals))) - 1))
    return vals[idx]

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
    rows.sort(key=lambda r: float(r["ts"]))
    first, last = rows[0], rows[-1]
    elapsed = max(0.001, float(last["ts"]) - float(first["ts"]))
    prompt_delta = int(float(last["prompt_tokens_total"])) - int(float(first["prompt_tokens_total"]))
    gen_delta = int(float(last["generation_tokens_total"])) - int(float(first["generation_tokens_total"]))
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
        "max_running": max(float(r["num_requests_running"] or 0) for r in rows),
        "max_active_requests": max(float(r["active_requests"] or 0) for r in rows),
    })

with open(throughput_path, "w", newline="") as f:
    fields = ["scenario","role","pod","first_current_role","last_current_role","elapsed_s","prompt_tokens_delta","generation_tokens_delta","prompt_tps","generation_tps","max_running","max_active_requests"]
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(pod_rows)

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
    "cluster_prompt_tps": (total_prompt_delta / total_wall) if total_wall > 0 else 0.0,
    "cluster_generation_tps": (total_gen_delta / total_wall) if total_wall > 0 else 0.0,
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

  if [[ "${scenario}" == "strategy" && "${driver}" == "sidecar" ]]; then
    run_sidecar_strategy_actions "${dir}"
  elif [[ "${scenario}" == "strategy" && "${driver}" == "auto" ]]; then
    record_event "${dir}" "strategy_driver" '{"mode":"auto","note":"observing controller-triggered actions only"}'
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
    "prompt_tokens_delta", "generation_tokens_delta",
]
with open(os.path.join(out, "comparison.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    for row in (baseline, strategy):
        if row:
            w.writerow({k: row.get(k, "") for k in fields})

improvement = None
throughput_gain = None
latency_change = None
if baseline and strategy:
    b = baseline.get("end_to_end_wall_s", 0) or 0
    s = strategy.get("end_to_end_wall_s", 0) or 0
    if b > 0:
        improvement = (b - s) / b * 100.0
    bt = baseline.get("cluster_generation_tps", 0) or 0
    st = strategy.get("cluster_generation_tps", 0) or 0
    if bt > 0:
        throughput_gain = (st - bt) / bt * 100.0
    bl = baseline.get("latency_p95_s", 0) or 0
    sl = strategy.get("latency_p95_s", 0) or 0
    if bl > 0:
        latency_change = (bl - sl) / bl * 100.0

topology_rows = read_csv_rows("topology.csv")
config_rows = read_csv_rows("experiment_config.csv")

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
    lines.append(f"| p95 latency change | {fmt(latency_change)}% | positive means lower p95 latency |")
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
lines.append("## 3. Topology")
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
lines.append("## 4. End-to-End Timing And Throughput")
lines.append("")
lines.append("| scenario | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) | gen tok/s |")
lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for row in (baseline, strategy):
    if not row:
        continue
    lines.append(
    f"| {row['scenario']} | {row['completed_requests']} | {fmt(row.get('success_rate_pct'))} | "
        f"{fmt(row['end_to_end_wall_s'])} | {fmt(row['request_throughput_rps'])} | "
        f"{fmt(row['latency_p50_s'])} | {fmt(row['latency_p95_s'])} | "
    f"{fmt(row['latency_p99_s'])} | {fmt(row.get('ttft_p50_s'))} | {fmt(row['cluster_generation_tps'])} |"
    )
lines.append("")
lines.append("## 5. Strategy Trigger Evidence")
lines.append("")
if strategy:
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
lines.append("")
lines.append("## 6. Per-Scenario Reports")
lines.append("")
lines.append("| scenario | report | requests | pod throughput | raw metrics | logs |")
lines.append("|---|---|---|---|---|---|")
for scenario in ("baseline", "strategy"):
    if os.path.exists(os.path.join(out, scenario)):
        lines.append(
            f"| {scenario} | `{scenario}/REPORT.md` | `{scenario}/requests.csv` | "
            f"`{scenario}/pod_throughput.csv` | `{scenario}/pod_metrics.csv` | `{scenario}/logs/` |"
        )
lines.append("")
lines.append("## 7. Cache Control Note")
lines.append("")
lines.append("Each scenario uses a unique prompt salt and a separate warmup request. This reduces prefix/KV cache reuse between baseline and strategy. For stricter isolation, run each scenario on freshly restarted workers or clear worker KV state through the deployment-specific clear route before invoking this script.")
lines.append("")
lines.append("## 8. Artifact Index")
lines.append("")
lines.append("| artifact | exists | purpose |")
lines.append("|---|---|---|")
for artifact, purpose in [
    ("experiment_config.csv", "Run configuration captured at script start"),
    ("topology.csv", "Discovered frontend/prefill/decode topology"),
    ("comparison.csv", "Machine-readable scenario comparison"),
    ("baseline/REPORT.md", "Baseline scenario report"),
    ("strategy/REPORT.md", "Strategy scenario report"),
    ("strategy/event_timeline.csv", "Flattened strategy trigger timeline"),
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