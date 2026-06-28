#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-${SCRIPT_DIR}/reports/policy-two-stage-${TS}}"
mkdir -p "${OUT}"

NS="${NS:-dynamo-system}"
DGD="${DGD:-vllm-v1-disagg-router}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"

FRONTEND_LOCAL="${FRONTEND_LOCAL:-18100}"
METRIC_BASE="${METRIC_BASE:-19600}"
SIDECAR_BASE="${SIDECAR_BASE:-19700}"

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-300}"
CAPTURE_LOG_LINES="${CAPTURE_LOG_LINES:-600}"
CONTROLLER_LABEL="${CONTROLLER_LABEL:-app=rl-scaling-controller}"

S3_PRE_REQ="${S3_PRE_REQ:-24}"
S3_POST_REQ="${S3_POST_REQ:-24}"
S3_PRE_CONCURRENCY="${S3_PRE_CONCURRENCY:-6}"
S3_POST_CONCURRENCY="${S3_POST_CONCURRENCY:-6}"
S3_ACTION_DELAY="${S3_ACTION_DELAY:-6}"
S3_PROMPT_WORDS="${S3_PROMPT_WORDS:-120}"
S3_LONG_MAX_TOKENS="${S3_LONG_MAX_TOKENS:-1536}"
S3_SHORT_MAX_TOKENS="${S3_SHORT_MAX_TOKENS:-384}"

S2_PRE_REQ="${S2_PRE_REQ:-24}"
S2_POST_REQ="${S2_POST_REQ:-32}"
S2_PRE_CONCURRENCY="${S2_PRE_CONCURRENCY:-6}"
S2_POST_CONCURRENCY="${S2_POST_CONCURRENCY:-8}"
S2_ACTION_DELAY="${S2_ACTION_DELAY:-6}"
S2_PRE_PROMPT_WORDS="${S2_PRE_PROMPT_WORDS:-120}"
S2_POST_PROMPT_WORDS="${S2_POST_PROMPT_WORDS:-640}"
S2_PRE_LONG_MAX_TOKENS="${S2_PRE_LONG_MAX_TOKENS:-1536}"
S2_PRE_SHORT_MAX_TOKENS="${S2_PRE_SHORT_MAX_TOKENS:-384}"
S2_POST_MAX_TOKENS="${S2_POST_MAX_TOKENS:-192}"

ACTION_TIMEOUT="${ACTION_TIMEOUT:-120}"
CONSOLIDATION_MIN_ACTIVE="${CONSOLIDATION_MIN_ACTIVE:-1}"
CONSOLIDATION_ACTIVE_MAX="${CONSOLIDATION_ACTIVE_MAX:-6}"
MIG_LOOPS="${MIG_LOOPS:-6}"
MIGRATION_SPACING="${MIGRATION_SPACING:-1}"
ROLE_SWITCH_TARGET_ROLE="${ROLE_SWITCH_TARGET_ROLE:-prefill}"
ROLE_SWITCH_SOURCE_ACTIVE_MAX="${ROLE_SWITCH_SOURCE_ACTIVE_MAX:-0}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${OUT}/run.log"; }
die() { log "FATAL: $*"; exit 1; }

cleanup_pids=()
trap 'for p in "${cleanup_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done' EXIT

LAST_SOURCE_POD=""
LAST_TARGET_POD=""
LAST_MIGRATION_OK="0"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_cmd kubectl
require_cmd curl
require_cmd python3
require_cmd awk

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
'
}

mapfile -t DECODE_PODS < <(discover_ready_pods VllmDecodeWorker | sort)
mapfile -t PREFILL_PODS < <(discover_ready_pods VllmPrefillWorker | sort || true)
[[ "${#DECODE_PODS[@]}" -ge 2 ]] || die "need >=2 ready decode pods"

FRONTEND_POD=$(kubectl -n "${NS}" get pod \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD},nvidia.com/dynamo-component=Frontend" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || die "frontend not found"

log "DGD=${DGD} namespace=${NS} model=${MODEL}"
log "FRONTEND=${FRONTEND_POD}"
log "DECODE_PODS=${DECODE_PODS[*]}"
log "PREFILL_PODS=${PREFILL_PODS[*]:-none}"

start_pf() {
  local pod="$1" lport="$2" rport="$3" tag="$4"
  kubectl -n "${NS}" port-forward "pod/${pod}" "${lport}:${rport}" > "${OUT}/pf-${tag}.log" 2>&1 &
  cleanup_pids+=("$!")
  for _ in $(seq 1 40); do
    (echo > "/dev/tcp/127.0.0.1/${lport}") 2>/dev/null && return 0
    sleep 0.25
  done
  die "port-forward failed for ${pod}:${rport}"
}

start_pf "${FRONTEND_POD}" "${FRONTEND_LOCAL}" 8000 frontend

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
    "${POD_METRIC_PORT[$pod]}" "${POD_SIDECAR_PORT[$pod]:-}" >> "${OUT}/topology.csv"
done

cat > "${OUT}/experiment_config.csv" <<EOF
key,value
timestamp,${TS}
namespace,${NS}
dgd,${DGD}
model,${MODEL}
s3_pre_req,${S3_PRE_REQ}
s3_post_req,${S3_POST_REQ}
s3_pre_concurrency,${S3_PRE_CONCURRENCY}
s3_post_concurrency,${S3_POST_CONCURRENCY}
s3_action_delay,${S3_ACTION_DELAY}
s3_prompt_words,${S3_PROMPT_WORDS}
s3_long_max_tokens,${S3_LONG_MAX_TOKENS}
s3_short_max_tokens,${S3_SHORT_MAX_TOKENS}
s2_pre_req,${S2_PRE_REQ}
s2_post_req,${S2_POST_REQ}
s2_pre_concurrency,${S2_PRE_CONCURRENCY}
s2_post_concurrency,${S2_POST_CONCURRENCY}
s2_action_delay,${S2_ACTION_DELAY}
s2_pre_prompt_words,${S2_PRE_PROMPT_WORDS}
s2_post_prompt_words,${S2_POST_PROMPT_WORDS}
s2_pre_long_max_tokens,${S2_PRE_LONG_MAX_TOKENS}
s2_pre_short_max_tokens,${S2_PRE_SHORT_MAX_TOKENS}
s2_post_max_tokens,${S2_POST_MAX_TOKENS}
action_timeout,${ACTION_TIMEOUT}
consolidation_min_active,${CONSOLIDATION_MIN_ACTIVE}
consolidation_active_max,${CONSOLIDATION_ACTIVE_MAX}
mig_loops,${MIG_LOOPS}
migration_spacing,${MIGRATION_SPACING}
role_switch_target_role,${ROLE_SWITCH_TARGET_ROLE}
role_switch_source_active_max,${ROLE_SWITCH_SOURCE_ACTIVE_MAX}
EOF

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

record_event() {
  local dir="$1" typ="$2" raw="$3"
  python3 - "${typ}" "${raw}" >> "${dir}/strategy_events.jsonl" <<'PY'
import json, sys, time
typ, raw = sys.argv[1], sys.argv[2]
try:
    payload = json.loads(raw)
except Exception:
    payload = {"raw": raw}
print(json.dumps({"ts": time.time(), "type": typ, "payload": payload}, sort_keys=True))
PY
}

sample_metrics_loop() {
  local stage="$1" mode="$2" dir="$3" stop_file="$4"
  local csv="${dir}/pod_metrics.csv"
  echo "ts,stage,mode,role,pod,current_role,prompt_tokens_total,generation_tokens_total,num_requests_running,active_requests" > "${csv}"
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
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${ts_now}" "${stage}" "${mode}" "${role}" "${pod}" "${current_role}" \
        "${prompt}" "${gen}" "${running}" "${active}" >> "${csv}"
    done
    sleep "${SAMPLE_INTERVAL}"
  done
}

request_spec() {
  local stage="$1" phase="$2" idx="$3"
  local words max_tokens
  case "${stage}:${phase}" in
    s3-tail-drain:pre|s3-tail-drain:post)
      words="${S3_PROMPT_WORDS}"
      if (( idx % 4 == 0 )); then
        max_tokens="${S3_LONG_MAX_TOKENS}"
      else
        max_tokens="${S3_SHORT_MAX_TOKENS}"
      fi
      ;;
    s2-after-drain:pre)
      words="${S2_PRE_PROMPT_WORDS}"
      if (( idx % 4 == 0 )); then
        max_tokens="${S2_PRE_LONG_MAX_TOKENS}"
      else
        max_tokens="${S2_PRE_SHORT_MAX_TOKENS}"
      fi
      ;;
    s2-after-drain:post)
      words="${S2_POST_PROMPT_WORDS}"
      max_tokens="${S2_POST_MAX_TOKENS}"
      ;;
    *)
      words="120"
      max_tokens="256"
      ;;
  esac
  printf '%s,%s\n' "${words}" "${max_tokens}"
}

prompt_text() {
  local stage="$1" mode="$2" phase="$3" idx="$4" salt="$5" words="$6"
  python3 - "$stage" "$mode" "$phase" "$idx" "$salt" "$words" <<'PY'
import sys
stage, mode, phase, idx, salt, words = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
base = (
    "Analyze a disaggregated prefill/decode cluster under frontend pressure. "
    "Explain request routing, queueing, tail latency, cache transfer, role switching, "
    "batch completion, GPU utilization, and throughput tradeoffs with concrete evidence. "
)
tokens = (base.split() * ((words // len(base.split())) + 3))[:words]
print(f"Stage {stage}, mode {mode}, phase {phase}, request {idx}, salt {salt}. " + " ".join(tokens))
PY
}

submit_one() {
  local stage="$1" mode="$2" phase="$3" dir="$4" idx="$5" salt="$6" words="$7" max_tokens="$8"
  local prompt payload start end curl_out code total ttft
  prompt="$(prompt_text "${stage}" "${mode}" "${phase}" "${idx}" "${salt}" "${words}")"
  payload=$(python3 - "$MODEL" "$prompt" "$max_tokens" <<'PY'
import json, sys
model, prompt, max_tokens = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": max_tokens,
    "temperature": 0.0,
    "stream": False,
}, ensure_ascii=True))
PY
)
  start="$(date +%s.%N)"
  curl_out=$(curl -s -m "${REQUEST_TIMEOUT}" \
    -o "${dir}/responses/${phase}-response-${idx}.json" \
    -w '%{http_code},%{time_total},%{time_starttransfer}' \
    -H 'Content-Type: application/json' \
    --data "${payload}" \
    "http://127.0.0.1:${FRONTEND_LOCAL}/v1/chat/completions" 2>/dev/null || echo '000,0,0')
  end="$(date +%s.%N)"
  code="$(echo "${curl_out}" | awk -F, '{print $1}')"
  total="$(echo "${curl_out}" | awk -F, '{print $2}')"
  ttft="$(echo "${curl_out}" | awk -F, '{print $3}')"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${idx}" "${stage}" "${mode}" "${phase}" "${start}" "${end}" "${code}" \
    "${total}" "${ttft}" "${words}" "${max_tokens}" >> "${dir}/requests.csv"
}

run_wave() {
  local stage="$1" mode="$2" phase="$3" dir="$4" salt="$5" count="$6" concurrency="$7"
  local batch_pids=()
  for i in $(seq 1 "${count}"); do
    IFS=, read -r words max_tokens <<< "$(request_spec "${stage}" "${phase}" "${i}")"
    submit_one "${stage}" "${mode}" "${phase}" "${dir}" "${i}" "${salt}" "${words}" "${max_tokens}" &
    batch_pids+=("$!")
    if (( ${#batch_pids[@]} >= concurrency )); then
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

select_source_target() {
  local source_pod="" target_pod="" source_active=-1 target_active=999999
  for pod in "${DECODE_PODS[@]}"; do
    local active
    active="$(active_count "${pod}")"
    [[ -z "${active}" ]] && active=0
    if (( active > source_active )); then
      source_active=${active}
      source_pod="${pod}"
    fi
  done
  for pod in "${DECODE_PODS[@]}"; do
    [[ "${pod}" == "${source_pod}" ]] && continue
    local active
    active="$(active_count "${pod}")"
    [[ -z "${active}" ]] && active=0
    if (( active < target_active )); then
      target_active=${active}
      target_pod="${pod}"
    fi
  done
  printf '%s,%s,%s,%s\n' "${source_pod}" "${source_active}" "${target_pod}" "${target_active}"
}

perform_best_effort_consolidation() {
  local dir="$1" label="$2"
  local deadline source_pod source_active target_pod target_active source_port target_ip target_url
  local i t0 t1 wall resp status

  LAST_SOURCE_POD=""
  LAST_TARGET_POD=""
  LAST_MIGRATION_OK="0"
  deadline=$(( $(date +%s) + ACTION_TIMEOUT ))

  while true; do
    IFS=, read -r source_pod source_active target_pod target_active <<< "$(select_source_target)"
    if [[ -n "${source_pod}" && -n "${target_pod}" ]] \
      && (( source_active >= CONSOLIDATION_MIN_ACTIVE )) \
      && (( source_active <= CONSOLIDATION_ACTIVE_MAX )); then
      break
    fi
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      record_event "${dir}" "request_consolidation_skipped" "$(python3 - "$label" <<'PY'
import json, sys
print(json.dumps({"label": sys.argv[1], "status": "skipped", "reason": "no_eligible_source_target_within_timeout"}))
PY
)"
      return 1
    fi
    sleep 1
  done

  source_port="${POD_SIDECAR_PORT[$source_pod]}"
  target_ip="${POD_IP[$target_pod]}"
  target_url="http://${target_ip}:9091"
  LAST_SOURCE_POD="${source_pod}"
  LAST_TARGET_POD="${target_pod}"

  for i in $(seq 1 "${MIG_LOOPS}"); do
    t0="$(date +%s.%N)"
    resp=$(curl -fsS -m 90 -X POST -H 'Content-Type: application/json' \
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
    echo "${resp}" > "${dir}/${label}-migrate-${i}.json"
    record_event "${dir}" "request_consolidation" "$(python3 - "${label}" "${source_pod}" "${target_pod}" "${i}" "${wall}" "${source_active}" "${target_active}" "${resp}" <<'PY'
import json, sys
label, source, target, iteration, wall, source_active, target_active, raw = sys.argv[1:9]
try:
    body = json.loads(raw)
except Exception:
    body = {"raw": raw}
print(json.dumps({
    "label": label,
    "source": source,
    "target": target,
    "iteration": int(iteration),
    "client_wall_ms": float(wall),
    "source_active_at_select": int(float(source_active)),
    "target_active_at_select": int(float(target_active)),
    "response": body,
}))
PY
)"
    if [[ "${status}" == "ok" ]]; then
      LAST_MIGRATION_OK="1"
      return 0
    fi
    sleep "${MIGRATION_SPACING}"
  done
  return 1
}

perform_role_switch() {
  local dir="$1" pod="$2" target_role="$3"
  local active_now deadline t0 t1 wall resp port body
  deadline=$(( $(date +%s) + ACTION_TIMEOUT ))
  while true; do
    active_now="$(active_count "${pod}")"
    [[ -z "${active_now}" ]] && active_now=0
    if (( active_now <= ROLE_SWITCH_SOURCE_ACTIVE_MAX )); then
      break
    fi
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      record_event "${dir}" "role_switch_skipped" "$(python3 - "${pod}" "${active_now}" <<'PY'
import json, sys
print(json.dumps({"status": "skipped", "pod": sys.argv[1], "reason": "source_not_drained", "active_requests": int(float(sys.argv[2]))}))
PY
)"
      return 1
    fi
    sleep 1
  done
  port="${POD_SIDECAR_PORT[$pod]}"
  body="{\"target_role\":\"${target_role}\"}"
  t0="$(date +%s.%N)"
  resp=$(curl -fsS -m 90 -X POST -H 'Content-Type: application/json' --data "${body}" \
    "http://127.0.0.1:${port}/switch_role" 2>/dev/null || echo '{"status":"http_error"}')
  t1="$(date +%s.%N)"
  wall=$(awk -v a="${t0}" -v b="${t1}" 'BEGIN{printf "%.3f", (b-a)*1000.0}')
  echo "${resp}" > "${dir}/switch-role-response.json"
  record_event "${dir}" "role_switch" "$(python3 - "${pod}" "${target_role}" "${active_now}" "${wall}" "${resp}" <<'PY'
import json, sys
pod, target_role, active_now, wall, raw = sys.argv[1:6]
try:
    body = json.loads(raw)
except Exception:
    body = {"raw": raw}
print(json.dumps({
    "pod": pod,
    "direction": f"decode_to_{target_role}",
    "active_requests_before_switch": int(float(active_now)),
    "client_wall_ms": float(wall),
    "response": body,
}))
PY
)"
}

capture_logs() {
  local dir="$1" since="$2"
  mkdir -p "${dir}/logs"
  kubectl -n "${NS}" logs -l "${CONTROLLER_LABEL}" --since-time="${since}" --tail="${CAPTURE_LOG_LINES}" > "${dir}/logs/controller.log" 2>/dev/null || true
  for pod in "${ALL_PODS[@]}"; do
    kubectl -n "${NS}" logs "${pod}" --since-time="${since}" --tail="${CAPTURE_LOG_LINES}" > "${dir}/logs/${pod}.log" 2>/dev/null || true
  done
  grep -RniE 'switch_role|DualMode|Migration|migrate|consolidation|role switch' "${dir}/logs" > "${dir}/strategy-log-excerpts.txt" 2>/dev/null || true
}

analyze_run() {
  local stage="$1" mode="$2" dir="$3"
  python3 - "${stage}" "${mode}" "${dir}" <<'PY'
import csv, json, math, os, statistics, sys
stage, mode, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
req_path = os.path.join(out_dir, "requests.csv")
summary_path = os.path.join(out_dir, "summary.json")
phase_csv = os.path.join(out_dir, "phase_summary.csv")
metrics_path = os.path.join(out_dir, "pod_metrics.csv")
throughput_path = os.path.join(out_dir, "pod_throughput.csv")
events_path = os.path.join(out_dir, "strategy_events.jsonl")

def pct(vals, p):
    vals = sorted(vals)
    if not vals:
        return 0.0
    idx = min(len(vals) - 1, max(0, int(math.ceil((p / 100.0) * len(vals))) - 1))
    return vals[idx]

requests = []
with open(req_path, newline="") as f:
    requests = list(csv.DictReader(f))

phase_summaries = {}
for phase in ("pre", "post"):
    rows = [r for r in requests if r["phase"] == phase]
    starts = [float(r["start_ts"]) for r in rows]
    ends = [float(r["end_ts"]) for r in rows]
    lats = [float(r["curl_total_s"] or 0) for r in rows]
    ttfts = [float(r["curl_ttft_s"] or 0) for r in rows]
    ok = sum(1 for r in rows if r["http_code"] == "200")
    wall = (max(ends) - min(starts)) if starts and ends else 0.0
    phase_summaries[phase] = {
        "phase": phase,
        "completed_requests": len(rows),
        "http_200": ok,
        "http_non_200": len(rows) - ok,
        "success_rate_pct": (ok / len(rows) * 100.0) if rows else 0.0,
        "end_to_end_wall_s": wall,
        "request_throughput_rps": (ok / wall) if wall > 0 else 0.0,
        "latency_p50_s": pct(lats, 50),
        "latency_p95_s": pct(lats, 95),
        "latency_p99_s": pct(lats, 99),
        "ttft_p50_s": pct(ttfts, 50),
        "ttft_p95_s": pct(ttfts, 95),
    }

samples_by_pod = {}
if os.path.exists(metrics_path):
    with open(metrics_path, newline="") as f:
        for row in csv.DictReader(f):
            samples_by_pod.setdefault(row["pod"], []).append(row)

pod_rows = []
prompt_delta_total = 0
gen_delta_total = 0
for pod, rows in sorted(samples_by_pod.items()):
    rows.sort(key=lambda r: float(r["ts"]))
    first, last = rows[0], rows[-1]
    elapsed = max(0.001, float(last["ts"]) - float(first["ts"]))
    prompt_delta = int(float(last["prompt_tokens_total"])) - int(float(first["prompt_tokens_total"]))
    gen_delta = int(float(last["generation_tokens_total"])) - int(float(first["generation_tokens_total"]))
    prompt_delta_total += max(0, prompt_delta)
    gen_delta_total += max(0, gen_delta)
    pod_rows.append({
        "stage": stage,
        "mode": mode,
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
    fields = ["stage","mode","role","pod","first_current_role","last_current_role","elapsed_s","prompt_tokens_delta","generation_tokens_delta","prompt_tps","generation_tps","max_running","max_active_requests"]
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(pod_rows)

events = []
event_counts = {}
if os.path.exists(events_path):
    with open(events_path) as f:
        for line in f:
            if not line.strip():
                continue
            event = json.loads(line)
            events.append(event)
            typ = event.get("type", "unknown")
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
            "subject": payload.get("pod") or payload.get("source") or payload.get("label") or "",
            "target": payload.get("target") or payload.get("direction") or "",
            "status": response.get("status", "") if isinstance(response, dict) else "",
            "client_wall_ms": payload.get("client_wall_ms", ""),
        })

starts = [float(r["start_ts"]) for r in requests]
ends = [float(r["end_ts"]) for r in requests]
ok = sum(1 for r in requests if r["http_code"] == "200")
overall_wall = (max(ends) - min(starts)) if starts and ends else 0.0
summary = {
    "stage": stage,
    "mode": mode,
    "completed_requests": len(requests),
    "http_200": ok,
    "http_non_200": len(requests) - ok,
    "success_rate_pct": (ok / len(requests) * 100.0) if requests else 0.0,
    "end_to_end_wall_s": overall_wall,
    "request_throughput_rps": (ok / overall_wall) if overall_wall > 0 else 0.0,
    "cluster_prompt_tps": (prompt_delta_total / overall_wall) if overall_wall > 0 else 0.0,
    "cluster_generation_tps": (gen_delta_total / overall_wall) if overall_wall > 0 else 0.0,
    "prompt_tokens_delta": prompt_delta_total,
    "generation_tokens_delta": gen_delta_total,
    "event_counts": event_counts,
    "phase_summaries": phase_summaries,
}
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)

with open(phase_csv, "w", newline="") as f:
    fields = ["phase","completed_requests","http_200","http_non_200","success_rate_pct","end_to_end_wall_s","request_throughput_rps","latency_p50_s","latency_p95_s","latency_p99_s","ttft_p50_s","ttft_p95_s"]
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    for phase in ("pre", "post"):
      w.writerow(phase_summaries[phase])

report_path = os.path.join(out_dir, "REPORT.md")
with open(report_path, "w", encoding="utf-8") as f:
    f.write(f"# Run Report: {stage} / {mode}\n\n")
    f.write("## Overall\n\n")
    f.write("| metric | value |\n|---|---:|\n")
    for key in ["completed_requests","http_200","http_non_200","success_rate_pct","end_to_end_wall_s","request_throughput_rps","cluster_prompt_tps","cluster_generation_tps","prompt_tokens_delta","generation_tokens_delta"]:
        value = summary[key]
        if isinstance(value, float):
            value = f"{value:.6f}"
        f.write(f"| {key} | {value} |\n")
    f.write("\n## Phase Metrics\n\n")
    f.write("| phase | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) |\n")
    f.write("|---|---:|---:|---:|---:|---:|---:|---:|---:|\n")
    for phase in ("pre", "post"):
        row = phase_summaries[phase]
        f.write(
            f"| {phase} | {row['completed_requests']} | {row['success_rate_pct']:.3f} | {row['end_to_end_wall_s']:.3f} | {row['request_throughput_rps']:.3f} | {row['latency_p50_s']:.3f} | {row['latency_p95_s']:.3f} | {row['latency_p99_s']:.3f} | {row['ttft_p50_s']:.3f} |\n"
        )
    f.write("\n## Pod Throughput\n\n")
    f.write("| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |\n")
    f.write("|---|---|---|---:|---:|---:|---:|---:|---:|\n")
    for row in pod_rows:
        f.write(
            f"| {row['role']} | {row['pod']} | {row['first_current_role']} -> {row['last_current_role']} | {row['prompt_tokens_delta']} | {row['generation_tokens_delta']} | {row['prompt_tps']:.3f} | {row['generation_tps']:.3f} | {row['max_running']:.0f} | {row['max_active_requests']:.0f} |\n"
        )
    f.write("\n## Strategy Timeline\n\n")
    if events:
        f.write("| ts | type | subject | target/direction | status | client wall ms |\n")
        f.write("|---:|---|---|---|---|---:|\n")
        for event in events:
            payload = event.get("payload", {}) or {}
            response = payload.get("response", {}) if isinstance(payload.get("response"), dict) else {}
            f.write(
                f"| {event.get('ts', '')} | {event.get('type', '')} | {payload.get('pod') or payload.get('source') or payload.get('label') or ''} | {payload.get('target') or payload.get('direction') or ''} | {response.get('status', '') if isinstance(response, dict) else ''} | {payload.get('client_wall_ms', '')} |\n"
            )
    else:
        f.write("No strategy events captured.\n")
PY
}

run_stage_mode() {
  local stage="$1" mode="$2"
  local dir="${OUT}/${stage}/${mode}"
  local stop_file="${dir}/STOP_METRICS"
  local salt="${stage}-${mode}-${TS}-$(date +%s%N)"
  local since pre_pid post_pid
  mkdir -p "${dir}/responses"
  : > "${dir}/strategy_events.jsonl"
  rm -f "${stop_file}"
  echo 'idx,stage,mode,phase,start_ts,end_ts,http_code,curl_total_s,curl_ttft_s,prompt_words,max_tokens' > "${dir}/requests.csv"

  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  submit_one "${stage}" "${mode}" warmup "${dir}" warmup "${salt}-warmup" 64 64 || true
  rm -f "${dir}/requests.csv"
  echo 'idx,stage,mode,phase,start_ts,end_ts,http_code,curl_total_s,curl_ttft_s,prompt_words,max_tokens' > "${dir}/requests.csv"

  log "==== ${stage}/${mode}"
  sample_metrics_loop "${stage}" "${mode}" "${dir}" "${stop_file}" &
  local sampler_pid="$!"

  case "${stage}" in
    s3-tail-drain)
      run_wave "${stage}" "${mode}" pre "${dir}" "${salt}-pre" "${S3_PRE_REQ}" "${S3_PRE_CONCURRENCY}" &
      pre_pid="$!"
      sleep "${S3_ACTION_DELAY}"
      if [[ "${mode}" == strategy ]]; then
        perform_best_effort_consolidation "${dir}" "s3_tail" || true
      else
        record_event "${dir}" "phase_boundary" '{"label":"s3_tail","mode":"baseline"}'
      fi
      run_wave "${stage}" "${mode}" post "${dir}" "${salt}-post" "${S3_POST_REQ}" "${S3_POST_CONCURRENCY}" &
      post_pid="$!"
      wait "${pre_pid}" 2>/dev/null || true
      wait "${post_pid}" 2>/dev/null || true
      ;;
    s2-after-drain)
      run_wave "${stage}" "${mode}" pre "${dir}" "${salt}-pre" "${S2_PRE_REQ}" "${S2_PRE_CONCURRENCY}" &
      pre_pid="$!"
      sleep "${S2_ACTION_DELAY}"
      if [[ "${mode}" == strategy ]]; then
        perform_best_effort_consolidation "${dir}" "s2_prep" || true
      else
        record_event "${dir}" "phase_boundary" '{"label":"s2_prep","mode":"baseline"}'
      fi
      wait "${pre_pid}" 2>/dev/null || true
      if [[ "${mode}" == strategy && "${LAST_MIGRATION_OK}" == 1 && -n "${LAST_SOURCE_POD}" ]]; then
        perform_role_switch "${dir}" "${LAST_SOURCE_POD}" "${ROLE_SWITCH_TARGET_ROLE}" || true
      fi
      run_wave "${stage}" "${mode}" post "${dir}" "${salt}-post" "${S2_POST_REQ}" "${S2_POST_CONCURRENCY}"
      ;;
    *)
      die "unknown stage ${stage}"
      ;;
  esac

  sleep 2
  touch "${stop_file}"
  wait "${sampler_pid}" 2>/dev/null || true
  capture_logs "${dir}" "${since}"
  analyze_run "${stage}" "${mode}" "${dir}"
  log "summary ${stage}/${mode}: $(tr -d '\n' < "${dir}/summary.json")"
}

generate_stage_report() {
  local stage="$1"
  python3 - "${OUT}" "${stage}" <<'PY'
import csv, json, os, sys
out, stage = sys.argv[1], sys.argv[2]
base_path = os.path.join(out, stage, "baseline", "summary.json")
strat_path = os.path.join(out, stage, "strategy", "summary.json")
with open(base_path) as f:
    baseline = json.load(f)
with open(strat_path) as f:
    strategy = json.load(f)

def fmt(v):
    return f"{v:.3f}" if isinstance(v, (int, float)) else str(v)

report = os.path.join(out, stage, "REPORT.md")
lines = [f"# Stage Report: {stage}", "", "## Comparison", "", "| metric | baseline | strategy | strategy vs baseline |", "|---|---:|---:|---:|"]
for phase in ("pre", "post"):
    b = baseline["phase_summaries"][phase]
    s = strategy["phase_summaries"][phase]
    delta = ((b["request_throughput_rps"] and ((s["request_throughput_rps"] - b["request_throughput_rps"]) / b["request_throughput_rps"] * 100.0)) or 0.0)
    lines.append(f"| {phase} req/s | {fmt(b['request_throughput_rps'])} | {fmt(s['request_throughput_rps'])} | {fmt(delta)}% |")
    delta_wall = ((b["end_to_end_wall_s"] and ((b["end_to_end_wall_s"] - s["end_to_end_wall_s"]) / b["end_to_end_wall_s"] * 100.0)) or 0.0)
    lines.append(f"| {phase} wall time (s) | {fmt(b['end_to_end_wall_s'])} | {fmt(s['end_to_end_wall_s'])} | {fmt(delta_wall)}% |")
    delta_p95 = ((b["latency_p95_s"] and ((b["latency_p95_s"] - s["latency_p95_s"]) / b["latency_p95_s"] * 100.0)) or 0.0)
    lines.append(f"| {phase} p95 latency (s) | {fmt(b['latency_p95_s'])} | {fmt(s['latency_p95_s'])} | {fmt(delta_p95)}% |")
lines.append(f"| overall wall time (s) | {fmt(baseline['end_to_end_wall_s'])} | {fmt(strategy['end_to_end_wall_s'])} | {fmt(((baseline['end_to_end_wall_s'] - strategy['end_to_end_wall_s']) / baseline['end_to_end_wall_s'] * 100.0) if baseline['end_to_end_wall_s'] else 0.0)}% |")
lines.append(f"| overall generation tok/s | {fmt(baseline['cluster_generation_tps'])} | {fmt(strategy['cluster_generation_tps'])} | {fmt(((strategy['cluster_generation_tps'] - baseline['cluster_generation_tps']) / baseline['cluster_generation_tps'] * 100.0) if baseline['cluster_generation_tps'] else 0.0)}% |")
lines.extend(["", "## Strategy Evidence", "", f"Baseline events: `{json.dumps(baseline.get('event_counts', {}), sort_keys=True)}`", f"Strategy events: `{json.dumps(strategy.get('event_counts', {}), sort_keys=True)}`", "", "## Artifacts", "", f"- `baseline/REPORT.md`", f"- `strategy/REPORT.md`"])
with open(report, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY
}

generate_top_report() {
  python3 - "${OUT}" <<'PY'
import json, os, sys
out = sys.argv[1]
stages = ["s3-tail-drain", "s2-after-drain"]

def load(stage, mode):
    with open(os.path.join(out, stage, mode, "summary.json")) as f:
        return json.load(f)

lines = ["# Two-stage Policy-driven E2E Report", "", "## Executive Summary", "", "| stage | post req/s baseline | post req/s strategy | post wall baseline (s) | post wall strategy (s) | overall wall baseline (s) | overall wall strategy (s) | overall gen tok/s baseline | overall gen tok/s strategy |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
for stage in stages:
    b = load(stage, "baseline")
    s = load(stage, "strategy")
    bp = b["phase_summaries"]["post"]
    sp = s["phase_summaries"]["post"]
    lines.append(
        f"| {stage} | {bp['request_throughput_rps']:.3f} | {sp['request_throughput_rps']:.3f} | {bp['end_to_end_wall_s']:.3f} | {sp['end_to_end_wall_s']:.3f} | {b['end_to_end_wall_s']:.3f} | {s['end_to_end_wall_s']:.3f} | {b['cluster_generation_tps']:.3f} | {s['cluster_generation_tps']:.3f} |"
    )
lines.extend(["", "## Stage Reports", "", "- `s3-tail-drain/REPORT.md`", "- `s2-after-drain/REPORT.md`", "", "## Artifact Index", "", "- `topology.csv`", "- `experiment_config.csv`"])
with open(os.path.join(out, "REPORT.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY
}

run_stage_mode s3-tail-drain baseline
run_stage_mode s3-tail-drain strategy
run_stage_mode s2-after-drain baseline
run_stage_mode s2-after-drain strategy

generate_stage_report s3-tail-drain
generate_stage_report s2-after-drain
generate_top_report
log "Report written: ${OUT}/REPORT.md"