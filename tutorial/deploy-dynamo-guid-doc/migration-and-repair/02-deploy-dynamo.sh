#!/bin/bash
# ============================================================
# 02-deploy-dynamo.sh — Dynamo 0.7.1 推理服务一键部署
#
# 职责：在已有 K8s 集群 + Prometheus 基础上，部署完整的 Dynamo
#       推理服务栈（Operator + etcd + NATS + Disaggregated Workers
#       + Ingress + HPA）。
#
# 前置条件：
#   - kubectl / helm v3.8+ / envsubst 可用
#   - K8s 集群正常，GPU 可调度
#   - NVIDIA Container Toolkit 已安装且 containerd 已配置 nvidia handler
#   - Prometheus 已部署（01 脚本已执行）
#   - HF_TOKEN / NGC_API_KEY 环境变量已设置
#
# 关联文件：
#   manifests/                           ← 所有 K8s YAML 模板
#   01-deploy-prometheus-grafana.sh      ← 前置脚本
#   03-test-dynamo.sh                    ← 验证脚本
#
# 设计原则：
#   - YAML 模板与执行逻辑分离（manifests/ 目录）
#   - 每个阶段幂等可重入
#   - 适合直接集成到 CI/CD pipeline
# ============================================================
set -euo pipefail

# ── 脚本目录定位 ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

# ── 颜色输出 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 临时文件管理 ─────────────────────────────────────────────
TMPFILES=()
cleanup_tmpfiles() {
  for f in "${TMPFILES[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_tmpfiles EXIT

# ── 模板渲染函数 ─────────────────────────────────────────────
# 使用 envsubst 将 YAML 模板中的 ${VAR} 替换为环境变量值
# 仅替换显式列出的变量，避免破坏 YAML 中的其他 $ 引用
TEMPLATE_VARS='${NAMESPACE} ${RELEASE_VERSION} ${MODEL_NAME} ${DECODE_REPLICAS} ${PREFILL_REPLICAS} ${PROM_ENDPOINT} ${MONITORING_NS}'

render_template() {
  local template="$1"
  if [[ ! -f "$template" ]]; then
    error "模板文件不存在: $template"
    exit 1
  fi
  envsubst "${TEMPLATE_VARS}" < "$template"
}

# 渲染模板到临时文件（用于 helm --values），自动注册清理
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
export RELEASE_VERSION="${RELEASE_VERSION:-0.7.1}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
export HF_TOKEN="${HF_TOKEN:-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}"
export NGC_API_KEY="${NGC_API_KEY:-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}"
export MONITORING_NS="${MONITORING_NS:-monitoring}"
export PREFILL_REPLICAS="${PREFILL_REPLICAS:-1}"
export DECODE_REPLICAS="${DECODE_REPLICAS:-1}"

echo "============================================================"
echo "  Dynamo ${RELEASE_VERSION} 一键部署脚本"
echo "============================================================"
echo "  Namespace:         ${NAMESPACE}"
echo "  Dynamo Version:    ${RELEASE_VERSION}"
echo "  Model:             ${MODEL_NAME}"
echo "  Prefill Replicas:  ${PREFILL_REPLICAS}"
echo "  Decode Replicas:   ${DECODE_REPLICAS}"
echo "  GPU Required:      $((PREFILL_REPLICAS + DECODE_REPLICAS))"
echo "  Manifests Dir:     ${MANIFEST_DIR}"
echo "============================================================"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 0：预飞检查
# 目的：在执行任何变更前，验证所有前置条件均满足，
#       避免执行到中间步骤才发现环境不满足而留下脏状态。
# ════════════════════════════════════════════════════════════════
info "阶段 0：预飞检查..."

# 0.1 凭证检查
if [[ -z "$HF_TOKEN" ]]; then
  error "HF_TOKEN 未设置！请执行: export HF_TOKEN=hf_your_token"
  exit 1
fi
if [[ -z "$NGC_API_KEY" ]]; then
  error "NGC_API_KEY 未设置！请执行: export NGC_API_KEY=nvapi-your_key"
  exit 1
fi

# 0.2 工具链检查
for cmd in kubectl helm envsubst; do
  if ! command -v "$cmd" &>/dev/null; then
    if [[ "$cmd" == "envsubst" ]]; then
      error "$cmd 未安装！请执行: apt-get install -y gettext-base"
    else
      error "$cmd 未安装"
    fi
    exit 1
  fi
done

# 0.3 Manifests 目录检查
if [[ ! -d "$MANIFEST_DIR" ]]; then
  error "YAML 模板目录不存在: $MANIFEST_DIR"
  exit 1
fi

# 0.4 KUBECONFIG 自动检测
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    warn "使用 /etc/kubernetes/admin.conf 作为 KUBECONFIG"
  fi
fi

# 0.5 K8s 连接检查
if ! kubectl cluster-info &>/dev/null; then
  error "无法连接 K8s 集群"
  echo "  请检查 KUBECONFIG 是否正确："
  echo "    export KUBECONFIG=/etc/kubernetes/admin.conf"
  exit 1
fi

# 0.6 GPU 资源检查
GPU_COUNT=$(kubectl get nodes -o json | python3 -c "
import json, sys
nodes = json.load(sys.stdin)['items']
total = sum(int(n['status']['allocatable'].get('nvidia.com/gpu', 0)) for n in nodes)
print(total)
" 2>/dev/null || echo "0")

REQUIRED_GPU=$((PREFILL_REPLICAS + DECODE_REPLICAS))
if [[ "$GPU_COUNT" -lt "$REQUIRED_GPU" ]]; then
  error "GPU 不足！可用: ${GPU_COUNT}, 需要: ${REQUIRED_GPU} (Prefill=${PREFILL_REPLICAS} + Decode=${DECODE_REPLICAS})"
  exit 1
fi
info "GPU 检查通过：可用 ${GPU_COUNT}，需要 ${REQUIRED_GPU}"

# ── 0.7 NVIDIA Container Runtime & CDI 检查 ─────────────────
#
# 背景（2026-04-10 更新）：
#   Dynamo DGD 的 manifest 不设 runtimeClassName，依赖 containerd 的
#   默认 nvidia runtime + CDI（Container Device Interface）实现每个
#   Worker 只看到 1 张 GPU。需要同时满足 3 个条件：
#     ① defaultRuntimeName = nvidia
#     ② enable_cdi = true
#     ③ nvidia-device-plugin-daemonset 已感知当前配置
#
#   SSD 迁移后 containerd 重启会触发 toolkit daemonset 覆写配置，
#   可能导致 default 回退为 runc、CDI 关闭。
#
#   ⚠️ 不要用 runtimeClassName: nvidia 作为解决方案：
#      它绕过 CDI → 每个容器看到全部 8 张 GPU → OOM
#
info "检查 NVIDIA Container Runtime & CDI 配置..."

# 0.7.1 用 crictl info 检查 containerd 实际配置
RUNTIME_OK=true
RUNTIME_INFO=$(sudo crictl info 2>/dev/null || true)
if [[ -z "$RUNTIME_INFO" ]]; then
  error "无法获取 containerd 配置（crictl info 失败）"
  echo "  请确认 containerd 正在运行: systemctl status containerd"
  exit 1
fi

DEFAULT_RT=$(echo "$RUNTIME_INFO" | python3 -c "
import json, sys
try:
    info = json.load(sys.stdin)
    print(info.get('config',{}).get('containerd',{}).get('defaultRuntimeName','unknown'))
except: print('error')" 2>/dev/null)

CDI_ENABLED=$(echo "$RUNTIME_INFO" | python3 -c "
import json, sys
try:
    info = json.load(sys.stdin)
    print(str(info.get('config',{}).get('enableCDI', False)))
except: print('error')" 2>/dev/null)

echo "  containerd 实际配置（crictl info）："
echo "    defaultRuntimeName: ${DEFAULT_RT}"
echo "    enableCDI: ${CDI_ENABLED}"

if [[ "$DEFAULT_RT" != "nvidia" ]]; then
  RUNTIME_OK=false
  error "defaultRuntimeName = ${DEFAULT_RT}（应为 nvidia）"
fi
if [[ "$CDI_ENABLED" != "True" ]]; then
  RUNTIME_OK=false
  error "enableCDI = ${CDI_ENABLED}（应为 True）"
fi

if [[ "$RUNTIME_OK" != "true" ]]; then
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │ containerd GPU 配置不正确，Worker 将无法正常启动！       │"
  echo "  │                                                         │"
  echo "  │ 请执行以下 3 步修复（缺一不可）：                        │"
  echo "  │                                                         │"
  echo "  │ ① 让 toolkit 设 nvidia 为默认 runtime:                  │"
  echo "  │   kubectl set env ds/nvidia-container-toolkit-daemonset  │"
  echo "  │     -n gpu-operator NVIDIA_RUNTIME_SET_AS_DEFAULT=true  │"
  echo "  │   kubectl rollout status ds/nvidia-container-toolkit-   │"
  echo "  │     daemonset -n gpu-operator --timeout=120s            │"
  echo "  │                                                         │"
  echo "  │ ② 启用 CDI:                                             │"
  echo "  │   sudo sed -i 's/enable_cdi = false/enable_cdi = true/' │"
  echo "  │     /etc/containerd/config.toml                         │"
  echo "  │   sudo systemctl restart containerd                     │"
  echo "  │                                                         │"
  echo "  │ ③ 重启 device plugin:                                   │"
  echo "  │   kubectl rollout restart ds/nvidia-device-plugin-      │"
  echo "  │     daemonset -n gpu-operator                           │"
  echo "  │                                                         │"
  echo "  │ 或直接执行: bash 04-fix-worker-crashloop.sh             │"
  echo "  └─────────────────────────────────────────────────────────┘"
  echo ""
  exit 1
fi
info "NVIDIA Runtime & CDI 配置正确 ✓"

# 0.8 Prometheus 检查
if ! kubectl get svc prometheus-kube-prometheus-prometheus -n "${MONITORING_NS}" &>/dev/null; then
  warn "Prometheus 未检测到 (namespace: ${MONITORING_NS})"
  warn "Dynamo Operator 的 metrics 功能可能不可用，但不影响推理部署。"
fi
export PROM_ENDPOINT="http://prometheus-kube-prometheus-prometheus.${MONITORING_NS}.svc.cluster.local:9090"
info "Prometheus endpoint: ${PROM_ENDPOINT}"

info "预飞检查完成 ✓"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 1：清理旧安装（如果存在）
# 目的：确保干净的起点。按 DGD → HPA/Ingress → Platform → PVC → NS
#       顺序删除，让 Operator 先清理推理 Pod，再卸载 Operator 自身。
# 后果：namespace 下所有资源（包括 Secrets、PVC）将被删除。
#       Dynamo CRDs 为集群级资源，不受影响。
# ════════════════════════════════════════════════════════════════
info "阶段 1：清理旧安装..."

# 1.1 删除 DGD（触发 Operator 清理推理 Pod 及关联 Service）
if kubectl get dynamographdeployment vllm-v1-disagg-router -n "${NAMESPACE}" &>/dev/null; then
  warn "删除旧的 DGD: vllm-v1-disagg-router..."
  kubectl delete dynamographdeployment vllm-v1-disagg-router -n "${NAMESPACE}" --wait --timeout=120s || true
  info "等待推理 Pod 清理..."
  sleep 10
fi

# 1.2 删除 HPA / Ingress
kubectl delete hpa --all -n "${NAMESPACE}" 2>/dev/null || true
kubectl delete ingress --all -n "${NAMESPACE}" 2>/dev/null || true

# 1.3 卸载 Helm release（必须在删 NS 之前，否则 Helm 元数据丢失）
if helm status dynamo-platform -n "${NAMESPACE}" &>/dev/null; then
  warn "卸载旧的 dynamo-platform..."
  helm uninstall dynamo-platform -n "${NAMESPACE}" --wait || true
fi

# 1.4 清理残留 PVC
PVCS=$(kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null || true)
if [[ -n "$PVCS" ]]; then
  warn "清理残留 PVC..."
  kubectl delete pvc --all -n "${NAMESPACE}" --wait=false || true
fi

# 1.5 删除 namespace
if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  warn "删除旧 namespace: ${NAMESPACE}..."

  for res in pods deployments statefulsets replicasets jobs daemonsets services; do
    kubectl delete "$res" --all -n "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
  done

  kubectl delete namespace "${NAMESPACE}" --wait --timeout=180s || true

  # 等待 namespace 消失
  NS_GONE=false
  for i in $(seq 1 60); do
    if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
      NS_GONE=true; break
    fi
    sleep 3
  done

  # namespace 卡在 Terminating 时强制清除 finalizers
  if [[ "$NS_GONE" == "false" ]]; then
    NS_STATUS=$(kubectl get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$NS_STATUS" == "Terminating" ]]; then
      warn "Namespace 卡在 Terminating 状态，强制清除 finalizers..."
      kubectl get namespace "${NAMESPACE}" -o json \
        | python3 -c "
import json, sys
ns = json.load(sys.stdin)
ns['spec']['finalizers'] = []
json.dump(ns, sys.stdout)
" | kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - 2>/dev/null || true
      for i in $(seq 1 20); do
        if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then break; fi
        sleep 2
      done
    fi
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
      error "Namespace ${NAMESPACE} 无法删除，请手动检查: kubectl get ns ${NAMESPACE} -o yaml"
      exit 1
    fi
  fi
fi

info "清理完成 ✓"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 2：安装 Dynamo CRDs（集群级，幂等）
# 目的：注册 DynamoGraphDeployment 等自定义资源类型。
# 后果：集群级资源，多用户共享，已存在则跳过。
# ════════════════════════════════════════════════════════════════
info "阶段 2：安装 Dynamo CRDs..."

CHART_DIR="${HOME}/dynamo-charts"
mkdir -p "${CHART_DIR}"
cd "${CHART_DIR}"

if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null; then
  info "Dynamo CRDs 已存在，跳过安装"
else
  info "下载 dynamo-crds chart..."
  helm fetch "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-${RELEASE_VERSION}.tgz" \
    --username='$oauthtoken' \
    --password="${NGC_API_KEY}"

  helm install dynamo-crds "dynamo-crds-${RELEASE_VERSION}.tgz" \
    --namespace default \
    --wait
  info "Dynamo CRDs 安装完成"
fi

kubectl get crd | grep dynamo
info "CRDs 就绪 ✓"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 3：创建 Namespace 和 Secrets
# 目的：建立资源隔离边界，预置 NGC 镜像拉取凭证和 HF Token。
# 后果：创建全新 namespace 和两个 Secret。
# ════════════════════════════════════════════════════════════════
info "阶段 3：创建 Namespace 和 Secrets..."

kubectl create namespace "${NAMESPACE}"

kubectl create secret docker-registry nvcr-imagepullsecret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="${NGC_API_KEY}" \
  --namespace="${NAMESPACE}"

kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --namespace="${NAMESPACE}"

info "Namespace 和 Secrets 创建完成 ✓"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 4：安装 Dynamo Platform（Operator + etcd + NATS）
# 目的：部署推理服务的三个基础设施组件。
#   - Operator：监听 DGD 对象，自动创建/管理推理 Pod
#   - etcd：服务发现键值存储，Frontend 通过它定位 Worker
#   - NATS：组件间异步消息传递总线
# 后果：创建 3~4 个 Pod（Operator、etcd-0、nats-0、nats-box 可选）。
#       消耗约 512MB 内存，不占用 GPU。
# ════════════════════════════════════════════════════════════════
info "阶段 4：安装 Dynamo Platform（Operator + etcd + NATS）..."

cd "${CHART_DIR}"

if [[ ! -f "dynamo-platform-${RELEASE_VERSION}.tgz" ]]; then
  info "下载 dynamo-platform chart..."
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
echo ""

# 验证 Platform Pod
info "验证 Platform Pod 状态..."
kubectl get pods -n "${NAMESPACE}"
echo ""

# etcd 健康检查
info "etcd 健康检查..."
kubectl exec -n "${NAMESPACE}" dynamo-platform-etcd-0 -- \
  etcdctl --endpoints=http://localhost:2379 endpoint health || warn "etcd 健康检查失败"

# Operator 日志检查
ERRORS=$(kubectl logs -l app.kubernetes.io/name=dynamo-operator \
  -n "${NAMESPACE}" --tail=20 2>/dev/null | grep -ci error || true)
if [[ "$ERRORS" -gt 0 ]]; then
  warn "Operator 日志中发现 ${ERRORS} 条 error，请检查: kubectl logs -l app.kubernetes.io/name=dynamo-operator -n ${NAMESPACE} --tail=50"
else
  info "Operator 无错误日志 ✓"
fi
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 5：部署推理服务（DGD）
# 目的：提交 DynamoGraphDeployment 到集群，触发 Operator 创建
#       Frontend + PrefillWorker + DecodeWorker 的 Deployment/Service。
# 后果：Operator 为每个 Worker 创建 Deployment（各占 1 GPU），
#       Frontend 创建 1 个 CPU Pod + ClusterIP Service。
# 关键：DGD 模板不设 runtimeClassName，依赖 containerd 默认 nvidia
#       runtime + CDI 实现 GPU 设备隔离（每 Worker 只看到 1 张 GPU）。
#       Stage 0.7 已验证 containerd 配置正确。
# ════════════════════════════════════════════════════════════════
info "阶段 5：部署推理服务（manifests/dgd-vllm-disagg-router.yaml）..."

render_template "${MANIFEST_DIR}/dgd-vllm-disagg-router.yaml" | kubectl apply -f -

info "DGD 已提交，等待 Operator 创建推理 Pod..."
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 6：等待推理服务就绪
# 目的：轮询 DGD 状态直到 Ready=True 或超时。
#       Worker 首次启动需从 HuggingFace 下载模型权重，可能耗时较长。
# ════════════════════════════════════════════════════════════════
info "阶段 6：等待推理服务就绪（最多 15 分钟）..."

TIMEOUT=900
ELAPSED=0
INTERVAL=15

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  DGD_READY=$(kubectl get dynamographdeployment vllm-v1-disagg-router -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

  if [[ "$DGD_READY" == "True" ]]; then
    info "DGD Ready=True ✓"
    break
  fi

  RUNNING=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -c "Running" || true)
  TOTAL=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | wc -l || true)

  echo -ne "\r  [${ELAPSED}s/${TIMEOUT}s] DGD Ready=${DGD_READY}  Pods: ${RUNNING}/${TOTAL} Running    "
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
echo ""

# 最终 Pod 状态
info "最终 Pod 状态："
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""

# GPU 分配检查
info "GPU 分配情况："
kubectl get pods -n "${NAMESPACE}" -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,GPU:.spec.containers[0].resources.limits.nvidia\.com/gpu'
echo ""

# DGD 状态
info "DGD 状态："
kubectl get dynamographdeployment -n "${NAMESPACE}"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 7：部署 Ingress
# 目的：通过 ingress-nginx 将 /v1 路径代理到 Frontend Service，
#       使推理 API 可通过宿主机 80 端口直接访问。
# 后果：安装 ingress-nginx DaemonSet（占用 80/443 端口），
#       创建 Ingress 路由规则。如果安装失败可通过 port-forward 替代。
# ════════════════════════════════════════════════════════════════
info "阶段 7：部署 Ingress Controller 和 Ingress 规则..."

if ! helm status ingress-nginx -n ingress-nginx &>/dev/null; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update

  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --values "${MANIFEST_DIR}/ingress-nginx-values.yaml" \
    --wait || warn "Ingress Controller 安装失败，可通过 port-forward 替代访问"
else
  info "Ingress Controller 已存在，跳过"
fi

render_template "${MANIFEST_DIR}/ingress-frontend.yaml" | kubectl apply -f -

info "Ingress 部署完成 ✓"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 8：安装 Prometheus Adapter（HPA 自定义指标依赖）
# 目的：将 Dynamo 的 Prometheus 指标暴露为 K8s custom metrics API，
#       使 HPA 能基于推理队列深度（inflight requests）自动扩缩容。
# 后果：在 monitoring namespace 创建 prometheus-adapter Deployment。
#       集群级共享组件，已存在则跳过。
# ════════════════════════════════════════════════════════════════
info "阶段 8：安装 Prometheus Adapter..."

if helm status prometheus-adapter -n "${MONITORING_NS}" &>/dev/null; then
  info "prometheus-adapter 已存在，跳过"
else
  ADAPTER_VALUES=$(render_to_tmpfile "${MANIFEST_DIR}/prometheus-adapter-values.yaml")

  helm install prometheus-adapter \
    prometheus-community/prometheus-adapter \
    --namespace "${MONITORING_NS}" \
    --values "${ADAPTER_VALUES}" \
    --wait || warn "prometheus-adapter 安装失败，HPA 将无法基于推理指标扩容"

  info "Prometheus Adapter 安装完成 ✓"
fi
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 9：配置 HPA 自动扩容
# 目的：为 Frontend/Decode/Prefill 配置水平扩缩策略。
#   - Frontend：基于 CPU 利用率（60%）
#   - Workers：基于 inflight requests（平均 5 个/Pod）
# 后果：创建 3 个 HPA 对象。maxReplicas 受可用 GPU 数量限制。
# ════════════════════════════════════════════════════════════════
info "阶段 9：配置 HPA 自动扩容..."

render_template "${MANIFEST_DIR}/hpa-frontend.yaml"       | kubectl apply -f -
render_template "${MANIFEST_DIR}/hpa-decode-worker.yaml"   | kubectl apply -f -
render_template "${MANIFEST_DIR}/hpa-prefill-worker.yaml"  | kubectl apply -f -

info "HPA 配置完成 ✓"
kubectl get hpa -n "${NAMESPACE}"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 10：端到端验证
# 目的：通过 HTTP 请求验证推理链路完整可用。
# ════════════════════════════════════════════════════════════════
info "阶段 10：端到端验证..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost/v1/models 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  info "Ingress 端到端验证成功 ✓"
  echo ""
  info "模型列表："
  curl -s http://localhost/v1/models | python3 -m json.tool 2>/dev/null || true
else
  warn "Ingress 暂不可用 (HTTP ${HTTP_CODE})，尝试 port-forward..."
  kubectl port-forward svc/vllm-v1-disagg-router-frontend 8000:8000 -n "${NAMESPACE}" &
  PF_PID=$!
  sleep 5

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:8000/v1/models 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    info "Port-forward 端到端验证成功 ✓"
    curl -s http://localhost:8000/v1/models | python3 -m json.tool 2>/dev/null || true
  else
    warn "推理 API 尚未就绪 (HTTP ${HTTP_CODE})，Worker 可能仍在下载模型..."
    warn "请稍后手动验证: curl http://localhost:8000/v1/models"
  fi
  kill $PF_PID 2>/dev/null || true
fi

echo ""
echo "============================================================"
echo "  Dynamo ${RELEASE_VERSION} 部署完成！"
echo "============================================================"
echo ""
info "关键信息："
echo "  Namespace:     ${NAMESPACE}"
echo "  Model:         ${MODEL_NAME}"
echo "  Frontend:      http://localhost/v1/ (Ingress)"
echo "                 或 kubectl port-forward svc/vllm-v1-disagg-router-frontend 8000:8000 -n ${NAMESPACE}"
echo ""
info "常用命令："
echo "  查看 Pod:       kubectl get pods -n ${NAMESPACE}"
echo "  查看 DGD:       kubectl get dynamographdeployment -n ${NAMESPACE}"
echo "  查看 HPA:       kubectl get hpa -n ${NAMESPACE}"
echo "  查看日志:       kubectl logs -l nvidia.com/dynamo-component-type=worker -n ${NAMESPACE} --prefix --tail=50"
echo "  运行测试:       bash 03-test-dynamo.sh"
echo ""
echo "============================================================"
