#!/bin/bash
# ============================================================
# 01-deploy-dynamo-1.0.1.sh — Dynamo 1.0.1 推理服务一键部署
#
# 与 0.7.1 版本的关键差异:
#   ① 平台层: 无 etcd (K8s 原生 Discovery), NATS 保留 (Event Plane)
#   ② 无独立 dynamo-crds chart — CRDs 内置于 dynamo-platform chart
#   ③ DGD 格式变更: 无 dynamoNamespace, GPU 资源声明 resources.limits.gpu
#   ④ 新增 DGDSA CRD: 为 S2/S3/S4 RL 扩缩容提供 scale subresource
#   ⑤ Webhook 现在是强制项 (built-in cert-controller 自动管理 TLS)
#   ⑥ 事件平面: ZMQ 内置于 Worker 容器, 无需外部 broker
#   ⑦ 镜像: nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1
#
# 部署顺序:
#   Stage 0  — 预飞检查 (工具链 / GPU / CDI / Driver 版本)
#   Stage 1  — 清理旧版本 (可选)
#   Stage 2  — 创建 Namespace + Secrets
#   Stage 3  — 安装 Dynamo Platform (Operator + NATS)
#   Stage 4  — 部署推理服务 (DGD)
#   Stage 5  — 部署 DGDSA (RL 扩缩容接口)
#   Stage 6  — 部署 ingress-nginx
#   Stage 7  — 部署 Ingress 规则
#   Stage 8  — 等待就绪 + 冒烟测试
#
# 前置条件:
#   - kubectl / helm v3.8+ / envsubst 可用
#   - K8s 集群正常, GPU 可调度 (00-upgrade-cuda.sh --post-reboot 已完成)
#   - Prometheus 已部署 (../k8s/deploy-Prometheus-Grafana.sh 已执行)
#   - HF_TOKEN / NGC_API_KEY 已设置
#
# 使用方法:
#   export HF_TOKEN=hf_your_token
#   export NGC_API_KEY=nvapi-your_key
#   bash 01-deploy-dynamo-1.0.1.sh
#
# 关联文件:
#   manifests/                     ← 所有 K8s YAML 模板
#   ../k8s/deploy-Prometheus-Grafana.sh  ← 前置监控脚本
# ============================================================
set -euo pipefail

# ── 命令行参数 ────────────────────────────────────────────────────
# DEPLOY_MODE:
#   router  (默认)  —— 部署 vllm-disagg-router (Frontend + KV Router + P/D Worker + DGDSA)
#   planner          —— 部署 vllm-disagg-planner (含 Planner 自动扩缩容)
#   mocker           —— 部署 mocker DGD (无 GPU, 验证 router/planner)
# SKIP_MONITORING: 1 跳过部署 kube-prometheus-stack + Grafana 仪表盘
DEPLOY_MODE="router"
SKIP_MONITORING=0
for arg in "$@"; do
  case "$arg" in
    --router)           DEPLOY_MODE="router" ;;
    --planner)          DEPLOY_MODE="planner" ;;
    --mocker)           DEPLOY_MODE="mocker" ;;
    --skip-monitoring)  SKIP_MONITORING=1 ;;
    -h|--help)
      grep '^#' "$0" | sed -n '2,40p'; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

# ── 脚本目录定位 ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

# ── 颜色输出 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${BLUE}════════════════════════════════════════════════════════════${NC}"; \
          echo -e "${BLUE}  $*${NC}"; \
          echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"; }

# ── 临时文件管理 ─────────────────────────────────────────────
TMPFILES=()
cleanup_tmpfiles() {
  for f in "${TMPFILES[@]}"; do rm -f "$f" 2>/dev/null || true; done
}
trap cleanup_tmpfiles EXIT

# ── 模板渲染函数 ─────────────────────────────────────────────
# 仅替换显式列出的变量，避免破坏 YAML 中其他 $ 引用
TEMPLATE_VARS='${NAMESPACE} ${RELEASE_VERSION} ${MODEL_NAME} ${DECODE_REPLICAS} ${PREFILL_REPLICAS} ${PROM_ENDPOINT} ${MONITORING_NS} ${GPU_MEMORY_UTIL} ${NODE_IP} ${FRONTEND_SVC}'

render_template() {
  local template="$1"
  [[ ! -f "$template" ]] && { error "模板不存在: $template"; exit 1; }
  envsubst "${TEMPLATE_VARS}" < "$template"
}

render_to_tmpfile() {
  local template="$1"
  local tmpfile
  tmpfile=$(mktemp /tmp/dynamo-rendered-XXXXXX.yaml)
  TMPFILES+=("$tmpfile")
  render_template "$template" > "$tmpfile"
  echo "$tmpfile"
}

# ── 可配置变量 ───────────────────────────────────────────────
export NAMESPACE="${NAMESPACE:-dynamo-system}"
export RELEASE_VERSION="${RELEASE_VERSION:-1.0.1}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
export HF_TOKEN="${HF_TOKEN:-}"
export NGC_API_KEY="${NGC_API_KEY:-}"
export MONITORING_NS="${MONITORING_NS:-monitoring}"
export PREFILL_REPLICAS="${PREFILL_REPLICAS:-1}"
export DECODE_REPLICAS="${DECODE_REPLICAS:-1}"
export GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.90}"
export NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

# Prometheus 地址 (kube-prometheus-stack 默认服务名)
export PROM_ENDPOINT="${PROM_ENDPOINT:-http://prometheus-kube-prometheus-prometheus.${MONITORING_NS}.svc.cluster.local:9090}"

CHART_DIR="${HOME}/dynamo-charts-1.0.1"

echo ""
echo "============================================================"
echo "  Dynamo ${RELEASE_VERSION} 一键部署脚本"
echo "============================================================"
echo "  Namespace:        ${NAMESPACE}"
echo "  Dynamo Version:   ${RELEASE_VERSION}"
echo "  Deploy Mode:      ${DEPLOY_MODE}"
echo "  Skip Monitoring:  ${SKIP_MONITORING}"
echo "  Model:            ${MODEL_NAME}"
echo "  Prefill Replicas: ${PREFILL_REPLICAS}"
echo "  Decode Replicas:  ${DECODE_REPLICAS}"
echo "  GPU Required:     $((PREFILL_REPLICAS + DECODE_REPLICAS))"
echo "  GPU Memory Util:  ${GPU_MEMORY_UTIL}"
echo "  Node IP:          ${NODE_IP}"
echo "  Monitoring NS:    ${MONITORING_NS}"
echo "  Manifests Dir:    ${MANIFEST_DIR}"
echo "============================================================"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 0: 预飞检查
# ════════════════════════════════════════════════════════════════
step "阶段 0: 预飞检查"

# 0.1 凭证检查
[[ -z "$HF_TOKEN" ]]    && { error "HF_TOKEN 未设置!  export HF_TOKEN=hf_xxx"; exit 1; }
[[ -z "$NGC_API_KEY" ]] && { error "NGC_API_KEY 未设置! export NGC_API_KEY=nvapi-xxx"; exit 1; }

# 0.2 工具链检查
for cmd in kubectl helm envsubst python3; do
  command -v "$cmd" &>/dev/null || { error "$cmd 未安装"; exit 1; }
done
info "工具链检查通过 ✓"

# 0.3 Manifests 目录检查
[[ ! -d "$MANIFEST_DIR" ]] && { error "YAML 模板目录不存在: $MANIFEST_DIR"; exit 1; }
info "Manifests 目录: ${MANIFEST_DIR} ✓"

# 0.4 KUBECONFIG 检测
if [[ -z "${KUBECONFIG:-}" ]]; then
  [[ -f "$HOME/.kube/config" ]]       && export KUBECONFIG="$HOME/.kube/config"
  [[ -f /etc/kubernetes/admin.conf ]] && { export KUBECONFIG=/etc/kubernetes/admin.conf; warn "使用 /etc/kubernetes/admin.conf"; }
fi
kubectl cluster-info &>/dev/null || { error "无法连接 K8s 集群，检查 KUBECONFIG"; exit 1; }
info "K8s 集群连接正常 ✓"

# 0.5 NVIDIA Driver 版本检查 (1.0.1 需要 driver 565+, 建议 570)
if [[ "$DEPLOY_MODE" == "mocker" ]]; then
  info "Mocker 模式: 跳过 GPU / Driver 检查"
else
  DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "0")
  DRIVER_MAJOR="${DRIVER_VER%%.*}"
  if [[ "$DRIVER_MAJOR" -lt 565 ]]; then
    error "NVIDIA Driver ${DRIVER_VER} 不满足要求! Dynamo 1.0.1 需要 driver 565+ (CUDA 12.6+)"
    error "请先执行: sudo bash 00-upgrade-cuda.sh"
    exit 1
  fi
  info "NVIDIA Driver ${DRIVER_VER} (CUDA $(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9.]+' || echo '?')) ✓"
fi

# 0.6 GPU 资源检查
if [[ "$DEPLOY_MODE" == "mocker" ]]; then
  info "Mocker 模式: 不需要 GPU"
else
  GPU_COUNT=$(kubectl get nodes -o json | python3 -c "
import json, sys
nodes = json.load(sys.stdin)['items']
total = sum(int(n['status']['allocatable'].get('nvidia.com/gpu', 0)) for n in nodes)
print(total)" 2>/dev/null || echo "0")
  REQUIRED_GPU=$((PREFILL_REPLICAS + DECODE_REPLICAS))
  [[ "$GPU_COUNT" -lt "$REQUIRED_GPU" ]] && {
    error "GPU 不足! 可用: ${GPU_COUNT}, 需要: ${REQUIRED_GPU}"
    exit 1
  }
  info "GPU 检查: 可用 ${GPU_COUNT} / 需要 ${REQUIRED_GPU} ✓"
fi

# 0.7 containerd CDI + nvidia runtime 检查
# 1.0.1 + GPU Operator v25/26 推荐 CDI 模式 (enable_cdi=true)，runtime 可以是 runc 或 nvidia
# 仅当两者都不满足时才报错
info "检查 containerd CDI / nvidia runtime..."
CFG_FILE=""
for f in /etc/containerd/conf.d/99-nvidia.toml /etc/containerd/conf.d/nvidia.toml /etc/containerd/config.toml; do
  [[ -r "$f" ]] && CFG_FILE="$f" && break
done
if [[ -n "$CFG_FILE" ]]; then
  CDI_ON=$(grep -E '^\s*enable_cdi\s*=\s*true' "$CFG_FILE" >/dev/null && echo true || echo false)
  HAS_NVIDIA_RT=$(grep -E 'runtimes\.nvidia\b|default_runtime_name\s*=\s*"nvidia"' "$CFG_FILE" >/dev/null && echo true || echo false)
  DEFAULT_RT=$(awk -F'"' '/default_runtime_name/ {print $2; exit}' "$CFG_FILE")
  info "  config: ${CFG_FILE}"
  info "  default_runtime_name=${DEFAULT_RT:-?}, enable_cdi=${CDI_ON}, has_nvidia_runtime=${HAS_NVIDIA_RT}"
  if [[ "$CDI_ON" != "true" && "$DEFAULT_RT" != "nvidia" ]]; then
    error "containerd 既无 CDI 也未将 nvidia 设为默认运行时，GPU 容器将无法启动"
    error "修复: sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default --cdi.enabled=true"
    error "       sudo systemctl restart containerd"
    exit 1
  fi
  info "containerd 配置满足 GPU 调度要求 ✓"
else
  warn "未找到 containerd 配置文件，跳过检查 (依赖 device-plugin 自检)"
fi
# 复核: nvidia.com/gpu 实际 allocatable
ALLOC_GPU=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | head -1)
if [[ -z "$ALLOC_GPU" || "$ALLOC_GPU" == "0" ]]; then
  if [[ "$DEPLOY_MODE" != "mocker" ]]; then
    error "节点未上报可分配 nvidia.com/gpu，device-plugin 异常"
    exit 1
  fi
fi
info "节点可分配 GPU: ${ALLOC_GPU} ✓"

info "预飞检查通过 ✓"

# ════════════════════════════════════════════════════════════════
# 阶段 1: 清理旧版本 (可选)
# ════════════════════════════════════════════════════════════════
step "阶段 1: 清理旧版本检测"

# 检查是否存在旧的 dynamo-platform (0.7.1 遗留)
OLD_RELEASES=()
for ns in default "$NAMESPACE" "$(kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | tr '\n' ' ')"; do
  if helm status dynamo-platform -n "$ns" &>/dev/null 2>&1; then
    OLD_RELEASES+=("dynamo-platform@${ns}")
  fi
  if helm status dynamo-crds -n "$ns" &>/dev/null 2>&1; then
    OLD_RELEASES+=("dynamo-crds@${ns}")
  fi
done

if [[ ${#OLD_RELEASES[@]} -gt 0 ]]; then
  warn "发现旧版本 Helm release: ${OLD_RELEASES[*]}"
  warn "需要先清理旧版本才能安装 1.0.1"
  read -r -p "确认清理旧版本? [y/N] " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    # 删除 DGD (先删业务，再删平台)
    kubectl delete dgd --all -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete dgdsa --all -n "$NAMESPACE" 2>/dev/null || true
    # 等待 Worker Pod 完全终止（GPU 释放）
    info "等待 Worker Pod 终止 (最多 120s)..."
    kubectl wait --for=delete pods -l dynamo.nvidia.com/component=worker \
      -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

    for release_ns in "${OLD_RELEASES[@]}"; do
      release="${release_ns%@*}"
      ns="${release_ns#*@}"
      helm uninstall "$release" -n "$ns" --wait 2>/dev/null || true
      info "已卸载: ${release} (ns: ${ns})"
    done

    # 删除旧 CRDs (如果从 dynamo-crds chart 安装的)
    kubectl get crd | grep dynamo | awk '{print $1}' | xargs -r kubectl delete crd 2>/dev/null || true

    # 等待 Namespace 清空后删除
    kubectl delete namespace "$NAMESPACE" --wait --timeout=60s 2>/dev/null || true
    info "旧版本清理完成 ✓"
  else
    error "取消部署。请手动清理后重试"
    exit 1
  fi
else
  info "未发现旧版本，继续 ✓"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 2: 创建 Namespace 和 Secrets
# ════════════════════════════════════════════════════════════════
step "阶段 2: 创建 Namespace 和 Secrets"

kubectl create namespace "${NAMESPACE}" 2>/dev/null || info "Namespace ${NAMESPACE} 已存在"

# NGC 镜像拉取 Secret (nvcr.io 身份验证)
if ! kubectl get secret nvcr-imagepullsecret -n "${NAMESPACE}" &>/dev/null; then
  kubectl create secret docker-registry nvcr-imagepullsecret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="${NGC_API_KEY}" \
    --namespace="${NAMESPACE}"
  info "nvcr-imagepullsecret 创建完成 ✓"
else
  info "nvcr-imagepullsecret 已存在，跳过"
fi

# HuggingFace Token Secret (模型下载)
if ! kubectl get secret hf-token-secret -n "${NAMESPACE}" &>/dev/null; then
  kubectl create secret generic hf-token-secret \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    --namespace="${NAMESPACE}"
  info "hf-token-secret 创建完成 ✓"
else
  info "hf-token-secret 已存在，跳过"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 3: 安装 Dynamo Platform (Operator + NATS)
# ════════════════════════════════════════════════════════════════
step "阶段 3: 安装 Dynamo Platform 1.0.1"
# 1.0.1 变化:
#   - 无独立 dynamo-crds chart，CRDs 由 dynamo-operator subchart 管理
#   - 无 etcd (默认禁用，使用 K8s 原生 Discovery)
#   - NATS 仍然保留 (Event Plane)
#   - Webhook 现在是强制项，由 built-in cert-controller 自动处理 TLS

mkdir -p "${CHART_DIR}"
cd "${CHART_DIR}"

if ! helm status dynamo-platform -n "${NAMESPACE}" &>/dev/null 2>&1; then
  if [[ ! -f "dynamo-platform-${RELEASE_VERSION}.tgz" ]]; then
    info "下载 dynamo-platform chart ${RELEASE_VERSION}..."
    helm fetch "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${RELEASE_VERSION}.tgz" \
      --username='$oauthtoken' \
      --password="${NGC_API_KEY}"
  fi

  PLATFORM_VALUES=$(render_to_tmpfile "${MANIFEST_DIR}/dynamo-platform-values.yaml")

  helm install dynamo-platform "${CHART_DIR}/dynamo-platform-${RELEASE_VERSION}.tgz" \
    --namespace "${NAMESPACE}" \
    --values "${PLATFORM_VALUES}" \
    --timeout 15m \
    --wait
  info "Dynamo Platform 安装完成 ✓"
else
  info "dynamo-platform 已安装，执行 upgrade..."
  PLATFORM_VALUES=$(render_to_tmpfile "${MANIFEST_DIR}/dynamo-platform-values.yaml")
  helm upgrade dynamo-platform "${CHART_DIR}/dynamo-platform-${RELEASE_VERSION}.tgz" \
    --namespace "${NAMESPACE}" \
    --values "${PLATFORM_VALUES}" \
    --timeout 15m \
    --wait
  info "Dynamo Platform upgrade 完成 ✓"
fi

# 验证 Operator 和 NATS 就绪
info "等待 Dynamo Operator 就绪..."
kubectl rollout status deployment \
  -l app.kubernetes.io/name=dynamo-operator \
  -n "${NAMESPACE}" --timeout=120s
info "验证 NATS 就绪..."
kubectl rollout status statefulset \
  -l app.kubernetes.io/name=nats \
  -n "${NAMESPACE}" --timeout=120s 2>/dev/null || \
kubectl wait pods -l app.kubernetes.io/name=nats \
  -n "${NAMESPACE}" --for=condition=Ready --timeout=120s 2>/dev/null || \
  warn "NATS 等待超时，继续..."

# 验证 CRDs 就绪 (1.0.1 包含 dgd + dgdsa + dgdr + dynamocheckpoint)
info "验证 CRDs..."
for crd in dynamographdeployments.nvidia.com dynamographdeploymentscalingadapters.nvidia.com; do
  if kubectl get crd "$crd" &>/dev/null; then
    info "  CRD ${crd} ✓"
  else
    warn "  CRD ${crd} 未就绪 (等待 Operator 初始化...)"
    sleep 10
    kubectl get crd "$crd" &>/dev/null || warn "  CRD ${crd} 仍未就绪"
  fi
done

kubectl get pods -n "${NAMESPACE}"

# ════════════════════════════════════════════════════════════════
# 阶段 3.5: 部署监控 + 官方 Grafana Dashboards (复用 dynamo 仓库)
# ════════════════════════════════════════════════════════════════
if [[ "$SKIP_MONITORING" -eq 0 ]]; then
  step "阶段 3.5: 部署监控栈 + 官方 Grafana 仪表盘"

  DYNAMO_REPO_DIR="${DYNAMO_REPO_DIR:-/opt/dynamo}"
  MONITORING_SETUP="${DYNAMO_REPO_DIR}/deploy/observability/k8s/setup-monitoring.sh"
  DASHBOARDS_DIR="${DYNAMO_REPO_DIR}/deploy/observability/k8s"

  # 复用 dynamo 官方 setup-monitoring.sh (kube-prometheus-stack + 4 个 dashboard ConfigMap)
  if [[ -x "$MONITORING_SETUP" ]]; then
    info "复用官方监控脚本: $MONITORING_SETUP"
    NAMESPACE_MON="${MONITORING_NS}" bash "$MONITORING_SETUP" || \
      warn "setup-monitoring.sh 退出非零，继续 (可能监控已部署)"
  else
    warn "未找到 ${MONITORING_SETUP}"
    warn "请克隆 dynamo 仓库: git clone -b v${RELEASE_VERSION} https://github.com/ai-dynamo/dynamo.git ${DYNAMO_REPO_DIR}"
    warn "或预先执行 ../k8s/deploy-Prometheus-Grafana.sh"

    # Fallback: 仅安装 kube-prometheus-stack (不含 dynamo dashboards)
    if ! helm status kube-prometheus-stack -n "$MONITORING_NS" &>/dev/null; then
      kubectl create namespace "$MONITORING_NS" 2>/dev/null || true
      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
      helm repo update
      helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        -n "$MONITORING_NS" \
        --set grafana.adminPassword=admin \
        --wait --timeout 10m
      info "kube-prometheus-stack (fallback) 安装完成"
    fi
  fi

  # 部署官方 Grafana Dashboard ConfigMaps (4 个: disagg / planner / dynamo / operator)
  for cm in grafana-disagg-dashboard \
            grafana-planner-dashboard \
            grafana-dynamo-dashboard \
            grafana-operator-dashboard; do
    CM_FILE="${DASHBOARDS_DIR}/${cm}-configmap.yaml"
    if [[ -f "$CM_FILE" ]]; then
      kubectl apply -f "$CM_FILE" -n "$MONITORING_NS"
      info "  Dashboard ConfigMap: $cm ✓"
    else
      warn "  Dashboard 文件缺失: $CM_FILE"
    fi
  done

  info "Grafana 访问: kubectl -n ${MONITORING_NS} port-forward svc/kube-prometheus-stack-grafana 3000:80"
  info "  默认账户: admin / admin (or kube-prometheus-stack 的 grafana.adminPassword)"
else
  warn "--skip-monitoring 指定: 跳过 Prometheus/Grafana 部署"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 4: 部署推理服务 (DGD)  — 按 DEPLOY_MODE 分支
# ════════════════════════════════════════════════════════════════
case "$DEPLOY_MODE" in
  router)
    step "阶段 4: 部署 DGD (router 模式) — vllm-disagg-router"
    DGD_TEMPLATE="${MANIFEST_DIR}/dgd-vllm-disagg-router.yaml"
    DGD_NAME="vllm-v1-disagg-router"
    export FRONTEND_SVC="vllm-v1-disagg-router-frontend"
    NEED_DGDSA=true
    NEED_GPU_WORKER_WAIT=true
    ;;
  planner)
    step "阶段 4: 部署 DGD (planner 模式) — vllm-disagg-planner"
    DGD_TEMPLATE="${MANIFEST_DIR}/dgd-vllm-disagg-planner.yaml"
    DGD_NAME="vllm-disagg-planner"
    export FRONTEND_SVC="vllm-disagg-planner-frontend"
    NEED_DGDSA=false   # Planner 自己驱动 scale, 不再需要外部 DGDSA
    NEED_GPU_WORKER_WAIT=true
    ;;
  mocker)
    step "阶段 4: 部署 DGD (mocker 模式) — mocker-disagg"
    DGD_TEMPLATE="${MANIFEST_DIR}/dgd-mocker-disagg.yaml"
    DGD_NAME="mocker-disagg"
    export FRONTEND_SVC="mocker-disagg-frontend"
    NEED_DGDSA=false
    NEED_GPU_WORKER_WAIT=false
    ;;
esac

render_template "${DGD_TEMPLATE}" | kubectl apply -f -
info "DGD 已提交，等待 Operator 创建推理 Pod..."

# 等待 Operator 开始创建 Pod (给 Operator 30s 处理 DGD)
sleep 30

# 等待 Frontend 就绪 (CPU Only, 较快)
info "等待 Frontend Pod 就绪..."
kubectl wait pods \
  -l nvidia.com/dynamo-component-type=frontend \
  -n "${NAMESPACE}" \
  --for=condition=Ready --timeout=180s 2>/dev/null || warn "Frontend 等待超时，继续..."

if [[ "$NEED_GPU_WORKER_WAIT" == "true" ]]; then
  info "等待 Worker Pod 就绪 (模型加载中，最多等待 10 分钟)..."
  WORKERS_TOTAL=$((PREFILL_REPLICAS + DECODE_REPLICAS))
  DEADLINE=$((SECONDS + 600))
  while [[ $SECONDS -lt $DEADLINE ]]; do
    READY=$(kubectl get pods -n "${NAMESPACE}" \
      -l nvidia.com/dynamo-component-type=worker \
      --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
    READY=${READY:-0}
    if (( READY >= WORKERS_TOTAL )); then
      info "所有 Worker Pod 就绪: ${READY}/${WORKERS_TOTAL} ✓"
      break
    fi
    info "等待 Worker... ${READY}/${WORKERS_TOTAL} Running"
    sleep 15
  done
else
  info "Mocker 模式: 等待 60s 让 mocker pod 启动..."
  sleep 60
fi

kubectl get pods -n "${NAMESPACE}"

# ════════════════════════════════════════════════════════════════
# 阶段 5: 部署 DGDSA (RL 扩缩容接口)
# ════════════════════════════════════════════════════════════════
if [[ "$NEED_DGDSA" == "true" ]]; then
  step "阶段 5: 部署 DynamoGraphDeploymentScalingAdapter (DGDSA)"
  # DGDSA 是 1.0.1 新增的 CRD，为每个 DGD service 提供 scale subresource
  # RL Scaling Controller 通过 PATCH DGDSA.spec.replicas 驱动扩缩容
  # HPA 也可以通过 DGDSA 作为 scale target

  render_template "${MANIFEST_DIR}/dgdsa-decode.yaml"   | kubectl apply -f -
  render_template "${MANIFEST_DIR}/dgdsa-prefill.yaml"  | kubectl apply -f -
  info "DGDSA 创建完成 ✓"
  kubectl get dgdsa -n "${NAMESPACE}"
else
  info "阶段 5: 跳过 DGDSA (DEPLOY_MODE=${DEPLOY_MODE})"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 6: 部署 ingress-nginx
# ════════════════════════════════════════════════════════════════
step "阶段 6: 部署 ingress-nginx"

if ! helm status ingress-nginx -n ingress-nginx &>/dev/null 2>&1; then
  kubectl create namespace ingress-nginx 2>/dev/null || true
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update

  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --values "${MANIFEST_DIR}/ingress-nginx-values.yaml" \
    --timeout 5m \
    --wait
  info "ingress-nginx 安装完成 ✓"
else
  info "ingress-nginx 已安装，跳过"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 7: 部署 Ingress 规则
# ════════════════════════════════════════════════════════════════
step "阶段 7: 部署 Ingress 规则"

render_template "${MANIFEST_DIR}/ingress-frontend.yaml" | kubectl apply -f -
info "Ingress 规则已应用 ✓"

# ════════════════════════════════════════════════════════════════
# 阶段 8: 验收检查 + 冒烟测试
# ════════════════════════════════════════════════════════════════
step "阶段 8: 验收检查 + 冒烟测试"

# 8.1 基础健康检查
info "--- Pod 状态 ---"
kubectl get pods -n "${NAMESPACE}" -o wide

info "--- DGD 状态 ---"
kubectl get dgd -n "${NAMESPACE}"

info "--- DGDSA 状态 ---"
kubectl get dgdsa -n "${NAMESPACE}"

info "--- Service 状态 ---"
kubectl get svc -n "${NAMESPACE}"

info "--- Ingress 状态 ---"
kubectl get ingress -n "${NAMESPACE}"

# 8.2 等待所有 Pod Running
NOT_READY=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | grep -v "Running\|Completed" | wc -l || echo "0")
if [[ "$NOT_READY" -gt 0 ]]; then
  warn "${NOT_READY} 个 Pod 未就绪，等待 60s..."
  sleep 60
fi

# 8.3 API 冒烟测试
info "等待 API 就绪 (30s)..."
sleep 30

SMOKE_URL="http://${NODE_IP}/v1/models"
info "冒烟测试: GET ${SMOKE_URL}"
if curl -sf --max-time 10 "${SMOKE_URL}" 2>/dev/null | python3 -c "
import json,sys
data = json.load(sys.stdin)
models = [m['id'] for m in data.get('data',[])]
print('Models:', models)
sys.exit(0 if models else 1)
" 2>/dev/null; then
  info "API 冒烟测试通过 ✓"
else
  warn "API 冒烟测试失败（Worker 可能仍在初始化）"
  warn "手动验证: curl http://${NODE_IP}/v1/models"
fi

# 8.4 推理测试
INFER_URL="http://${NODE_IP}/v1/completions"
info "推理冒烟测试: POST ${INFER_URL}"
INFER_RESP=$(curl -sf --max-time 60 -X POST "${INFER_URL}" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"Hello\",\"max_tokens\":5}" 2>/dev/null || echo "")
if [[ -n "$INFER_RESP" ]]; then
  info "推理冒烟测试通过 ✓"
  echo "$INFER_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print('Generated:', r.get('choices',[{}])[0].get('text','?'))" 2>/dev/null || true
else
  warn "推理冒烟测试失败（可能需要等待模型完全就绪）"
fi

# 8.5 输出 Prometheus metrics 检查
info "检查 Dynamo metrics..."
kubectl exec -it \
  "$(kubectl get pods -n "${NAMESPACE}" -l nvidia.com/dynamo-component-type=frontend --no-headers | head -1 | awk '{print $1}')" \
  -n "${NAMESPACE}" -- \
  curl -sf http://localhost:9090/metrics 2>/dev/null | grep -E "dynamo_frontend|dynamo_worker" | head -5 || \
  warn "无法直接获取 metrics，通过 Prometheus 查询"

# ── 完成汇总 ─────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Dynamo ${RELEASE_VERSION} 部署完成!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  推理 API:"
echo "    http://${NODE_IP}/v1/chat/completions"
echo "    http://${NODE_IP}/v1/completions"
echo "    http://${NODE_IP}/v1/models"
echo ""
echo "  调试命令:"
echo "    kubectl get pods -n ${NAMESPACE}"
echo "    kubectl get dgd -n ${NAMESPACE}"
echo "    kubectl get dgdsa -n ${NAMESPACE}"
echo "    kubectl logs -l nvidia.com/dynamo-component-type=frontend -n ${NAMESPACE} --tail=20"
echo "    kubectl logs -l nvidia.com/dynamo-component-type=worker -n ${NAMESPACE} --tail=20"
echo ""
echo "  扩缩容 (DGDSA):"
echo "    kubectl patch dgdsa vllm-v1-disagg-router-decode -n ${NAMESPACE}"
echo "      --type=merge -p '{\"spec\":{\"replicas\":2}}'"
echo ""
echo "  快速推理测试:"
echo "    curl -X POST http://${NODE_IP}/v1/completions \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"model\":\"${MODEL_NAME}\",\"prompt\":\"Hello, world!\",\"max_tokens\":20}'"
echo ""
