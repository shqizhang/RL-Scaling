#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lib/common.sh — Dynamo 1.0.1 测试公共库
#
# 用法（在各测试脚本顶部）：
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
#
# 提供：颜色输出、env defaults、kubeconfig 自动检测、
#       端点检测（Ingress → port-forward fallback）、
#       Prometheus 端口转发与查询、Grafana 提示、
#       依赖检查、Dynamo 就绪检查、测试计数器
#
# 与 0.7.1 lib/common.sh 的差异:
#   - 增加 DGD_PLANNER_NAME / DGD_MOCKER_NAME
#   - 增加 GRAFANA_NS / GRAFANA_SVC / port_forward_grafana()
#   - 增加 port_forward_prometheus() (Prometheus 在 monitoring ns)
#   - render_template 白名单包含 PROM_ENDPOINT 等
# ═══════════════════════════════════════════════════════════════════

[[ -n "${_DYNAMO_COMMON_LOADED:-}" ]] && return 0
_DYNAMO_COMMON_LOADED=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal()   { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
section() {
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $*${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── 环境变量默认值 ────────────────────────────────────────────
export NAMESPACE="${NAMESPACE:-dynamo-system}"
export RELEASE_VERSION="${RELEASE_VERSION:-1.0.1}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
export MONITORING_NS="${MONITORING_NS:-monitoring}"
export INGRESS_NS="${INGRESS_NS:-ingress-nginx}"

# 三种 DGD 名称 (与 manifests/ 中保持一致)
export DGD_NAME="${DGD_NAME:-vllm-v1-disagg-router}"
export DGD_PLANNER_NAME="${DGD_PLANNER_NAME:-vllm-disagg-planner}"
export DGD_MOCKER_NAME="${DGD_MOCKER_NAME:-mocker-disagg}"

# Grafana / Prometheus 服务名 (kube-prometheus-stack 默认)
export GRAFANA_SVC="${GRAFANA_SVC:-kube-prometheus-stack-grafana}"
export PROM_SVC="${PROM_SVC:-kube-prometheus-stack-prometheus}"
export PROM_ENDPOINT="${PROM_ENDPOINT:-http://prometheus-kube-prometheus-prometheus.${MONITORING_NS}.svc.cluster.local:9090}"

# 副本数
export PREFILL_REPLICAS="${PREFILL_REPLICAS:-1}"
export DECODE_REPLICAS="${DECODE_REPLICAS:-1}"

# 负载测试参数
export CONCURRENCY="${CONCURRENCY:-10}"
export TOTAL_REQUESTS="${TOTAL_REQUESTS:-100}"
export MAX_TOKENS="${MAX_TOKENS:-100}"
export WAVE1="${WAVE1:-30}"
export WAVE2="${WAVE2:-60}"
export WAVE_DURATION="${WAVE_DURATION:-180}"

export ENDPOINT="${ENDPOINT:-}"

# Manifests 目录 — 指向 1.0.1/manifests
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${MANIFESTS_DIR:-$(cd "${_COMMON_DIR}/../../../1.0.1/manifests" 2>/dev/null && pwd)}"

TEMPLATE_VARS='${NAMESPACE} ${RELEASE_VERSION} ${MONITORING_NS} ${MODEL_NAME} ${DGD_NAME} ${PREFILL_REPLICAS} ${DECODE_REPLICAS} ${PROM_ENDPOINT}'

# kubeconfig
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    warn "KUBECONFIG: 使用 /etc/kubernetes/admin.conf"
  fi
fi

require_cmds() {
  local missing=()
  for cmd in "$@"; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
  [[ ${#missing[@]} -eq 0 ]] || fatal "缺少依赖: ${missing[*]}"
}

render_template() {
  local file="$1"
  [[ -f "$file" ]] || fatal "模板不存在: $file"
  envsubst "$TEMPLATE_VARS" < "$file"
}

# ─── port-forward 管理 ─────────────────────────────────────────
_PF_PIDS=()

_pf() {
  # _pf <local-port> <ns> <svc/name> <remote-port>
  local lport="$1" ns="$2" target="$3" rport="$4"
  pkill -f "kubectl port-forward.*${target}.*${lport}" 2>/dev/null || true
  sleep 1
  kubectl -n "$ns" port-forward "$target" "${lport}:${rport}" \
    --address 127.0.0.1 >/dev/null 2>&1 &
  _PF_PIDS+=($!)
  sleep 3
}

setup_endpoint() {
  if [[ -n "$ENDPOINT" ]]; then info "ENDPOINT=${ENDPOINT}"; return 0; fi
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost/v1/models" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    ENDPOINT="http://localhost/v1"; ok "Ingress OK, ENDPOINT=${ENDPOINT}"; return 0
  fi
  info "Ingress 不可达 (${code}), 启动 port-forward..."
  local svc="${1:-${DGD_NAME}-frontend}"
  _pf 8000 "$NAMESPACE" "svc/${svc}" 8000
  ENDPOINT="http://localhost:8000/v1"
  ok "ENDPOINT=${ENDPOINT}"
}

port_forward_prometheus() {
  info "port-forward Prometheus → http://localhost:9090"
  _pf 9090 "$MONITORING_NS" "svc/${PROM_SVC}" 9090
}

port_forward_grafana() {
  info "port-forward Grafana → http://localhost:3000  (admin/admin)"
  _pf 3000 "$MONITORING_NS" "svc/${GRAFANA_SVC}" 80
}

cleanup_portforwards() {
  for pid in "${_PF_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  pkill -f "kubectl port-forward.*8000" 2>/dev/null || true
  pkill -f "kubectl port-forward.*9090:9090" 2>/dev/null || true
  pkill -f "kubectl port-forward.*3000:80" 2>/dev/null || true
}

wait_deploy_ready() {
  local deploy="$1" ns="${2:-${NAMESPACE}}" timeout="${3:-300s}"
  info "等待 Deployment ${deploy} 就绪 (timeout=${timeout})..."
  kubectl rollout status "deployment/${deploy}" -n "$ns" --timeout="$timeout" \
    && ok "Deployment ${deploy} ready ✓" \
    || { warn "Deployment ${deploy} 超时"; return 1; }
}

check_dynamo_ready() {
  local n
  n=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
       | grep -v -E "Running|Completed" | grep -v "^$" | wc -l)
  if [[ "$n" -eq 0 ]]; then
    ok "ns/${NAMESPACE} 所有 Pod Running ✓"; return 0
  fi
  warn "${n} 个 Pod 未 Running:"
  kubectl get pods -n "$NAMESPACE" --no-headers | grep -v -E "Running|Completed"
  return 1
}

# Prometheus 查询 (要求先 port_forward_prometheus)
query_prom() {
  local q="$1" url="${2:-http://localhost:9090}"
  curl -sG --max-time 10 "${url}/api/v1/query" --data-urlencode "query=${q}" 2>/dev/null
}

# 仅取 result[0].value[1]
query_prom_value() {
  local q="$1" url="${2:-http://localhost:9090}"
  query_prom "$q" "$url" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    r=d.get("data",{}).get("result",[])
    print(r[0]["value"][1] if r else "")
except Exception:
    print("")
'
}

# ─── 测试计数器 ─────────────────────────────────────────────────
_PASS=0; _FAIL=0
pass() { ((_PASS++)); ok "$*"; }
fail() { ((_FAIL++)); echo -e "${RED}[FAIL]${NC}  $*"; }
print_summary() {
  echo ""
  echo "════════════════════════════════════════"
  echo "  Pass: ${_PASS}    Fail: ${_FAIL}"
  echo "════════════════════════════════════════"
  [[ "$_FAIL" -eq 0 ]]
}
