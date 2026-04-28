#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lib/common.sh — Dynamo 0.7.1 测试公共库
#
# 用法（在各测试脚本顶部）：
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# 提供：颜色输出、环境变量默认值、kubeconfig 自动检测、
#       端点检测（Ingress → port-forward fallback）、
#       模板渲染、依赖检查、Dynamo 就绪检查
# ═══════════════════════════════════════════════════════════════════

# ─── 防重复 source ──────────────────────────────────────────────
[[ -n "${_DYNAMO_COMMON_LOADED:-}" ]] && return 0
_DYNAMO_COMMON_LOADED=1

# ─── 颜色 / 输出函数 ────────────────────────────────────────────
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
# 必须 export，否则 envsubst（子进程）无法读取
export NAMESPACE="${NAMESPACE:-dynamo-system}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
export MONITORING_NS="${MONITORING_NS:-monitoring}"
export DGD_NAME="${DGD_NAME:-vllm-v1-disagg-router}"
export INGRESS_NS="${INGRESS_NS:-ingress-nginx}"

# 负载测试参数
export CONCURRENCY="${CONCURRENCY:-10}"
export TOTAL_REQUESTS="${TOTAL_REQUESTS:-100}"
export MAX_TOKENS="${MAX_TOKENS:-100}"

# 推理 API endpoint（空时自动检测）
export ENDPOINT="${ENDPOINT:-}"

# ─── Manifests 目录 ───────────────────────────────────────────
# 从 lib/common.sh 所在位置向上定位到 0.7.1/manifests
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${MANIFESTS_DIR:-$(cd "${_COMMON_DIR}/../../../0.7.1/manifests" 2>/dev/null && pwd)}"

# envsubst 变量替换白名单（防止误替换 YAML 中其他 ${} 语法）
TEMPLATE_VARS='${NAMESPACE} ${MONITORING_NS} ${MODEL_NAME} ${DGD_NAME}'

# ─── kubeconfig 自动检测 ────────────────────────────────────────
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    warn "KUBECONFIG: 使用 /etc/kubernetes/admin.conf（root 身份运行）"
  fi
fi

# ─── 依赖检查 ──────────────────────────────────────────────────
require_cmds() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || fatal "缺少依赖命令：${missing[*]}"
}

# ─── 模板渲染（envsubst 白名单模式） ────────────────────────────
# 用法：render_template <template_file>
render_template() {
  local file="$1"
  [[ -f "$file" ]] || fatal "模板文件不存在：$file"
  envsubst "$TEMPLATE_VARS" < "$file"
}

# ─── 端点检测（Ingress 优先 → port-forward fallback） ──────────
_PF_PIDS=()

setup_endpoint() {
  if [[ -n "$ENDPOINT" ]]; then
    info "使用指定 ENDPOINT: ${ENDPOINT}"
    return 0
  fi

  # 尝试 Ingress（不需要 port-forward）
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://localhost/v1/models" 2>/dev/null || echo "000")
  if [[ "$http_code" == "200" ]]; then
    ENDPOINT="http://localhost/v1"
    ok "检测到 Ingress，ENDPOINT = ${ENDPOINT}"
    return 0
  fi

  # Fallback：port-forward
  info "Ingress 不可达（HTTP ${http_code}），启动 port-forward..."
  pkill -f "kubectl port-forward.*${DGD_NAME}-frontend.*8000" 2>/dev/null || true
  sleep 1
  kubectl port-forward "svc/${DGD_NAME}-frontend" 8000:8000 -n "${NAMESPACE}" \
    --address 127.0.0.1 >/dev/null 2>&1 &
  _PF_PIDS+=($!)
  sleep 4
  ENDPOINT="http://localhost:8000/v1"
  ok "使用 port-forward，ENDPOINT = ${ENDPOINT}"
}

# ─── port-forward 清理（供各脚本 trap EXIT 使用） ───────────────
cleanup_portforwards() {
  for pid in "${_PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  pkill -f "kubectl port-forward.*9090:9090" 2>/dev/null || true
  pkill -f "kubectl port-forward.*3000:80" 2>/dev/null || true
  pkill -f "kubectl port-forward.*${DGD_NAME}-frontend.*8000" 2>/dev/null || true
}

# ─── 等待 Deployment rollout ───────────────────────────────────
# 用法：wait_deploy_ready <deployment_name> [namespace] [timeout]
wait_deploy_ready() {
  local deploy="$1"
  local ns="${2:-${NAMESPACE}}"
  local timeout="${3:-300s}"
  info "等待 Deployment ${deploy} 就绪（超时 ${timeout}）..."
  if kubectl rollout status "deployment/${deploy}" -n "${ns}" --timeout="${timeout}"; then
    ok "Deployment ${deploy} 就绪 ✓"
    return 0
  else
    warn "Deployment ${deploy} 未在 ${timeout} 内就绪"
    return 1
  fi
}

# ─── Dynamo 就绪检查 ────────────────────────────────────────────
check_dynamo_ready() {
  local not_ready
  not_ready=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v -E "Running|Completed" | grep -v "^$" | wc -l)
  if [[ "$not_ready" -eq 0 ]]; then
    ok "Dynamo namespace ${NAMESPACE} 所有 Pod Running ✓"
    return 0
  else
    warn "${not_ready} 个 Pod 未 Running（${NAMESPACE}）："
    kubectl get pods -n "${NAMESPACE}" --no-headers | grep -v -E "Running|Completed"
    return 1
  fi
}

# ─── Prometheus 查询辅助 ────────────────────────────────────────
# 用法：query_prom <promql> [prom_url]
query_prom() {
  local query="$1"
  local prom_url="${2:-http://localhost:9090}"
  curl -sG --max-time 10 "${prom_url}/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null
}

# ─── 测试计数器 ─────────────────────────────────────────────────
_PASS=0; _FAIL=0
pass() { ((_PASS++)); ok "$*"; }
fail() { ((_FAIL++)); echo -e "${RED}[FAIL]${NC}  $*"; }
print_summary() {
  echo ""
  echo -e "${BOLD}────────────────────────────────────────${NC}"
  echo -e "${BOLD}  测试结果：${GREEN}${_PASS} 通过${NC}  ${RED}${_FAIL} 失败${NC}"
  echo -e "${BOLD}────────────────────────────────────────${NC}"
  [[ $_FAIL -eq 0 ]]
}
