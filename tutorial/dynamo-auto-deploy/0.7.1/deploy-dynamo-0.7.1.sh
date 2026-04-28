#!/bin/bash
# ============================================================
# deploy-dynamo-0.7.1.sh — Dynamo 0.7.1 推理服务一键部署
#
# 职责：在已有 K8s 集群 + Prometheus 基础上，部署完整的 Dynamo
#       推理服务栈：
#         Dynamo CRDs → Namespace/Secrets → Platform（Operator +
#         etcd + NATS） → DGD（Disaggregated Prefill/Decode） →
#         Ingress → Prometheus Adapter → HPA
#
# 前置条件：
#   - kubectl / helm v3.8+ / envsubst 可用
#   - K8s 集群正常，GPU 可调度，nvidia RuntimeClass 存在
#   - Prometheus 已部署（deploy-Prometheus-Grafana.sh 已执行）
#   - HF_TOKEN / NGC_API_KEY 已设置
#
# 使用方法：
#   export HF_TOKEN=hf_your_token
#   export NGC_API_KEY=nvapi-your_key
#   bash deploy-dynamo-0.7.1.sh
#
# 关联文件：
#   manifests/                    ← 所有 K8s YAML 模板（此目录）
#   ../k8s/deploy-Prometheus-Grafana.sh  ← 前置脚本
#   ../../test-dynamo/0.7.1/     ← 测试脚本
#
# 设计原则：
#   - YAML 模板与执行逻辑分离（YAMLs 在 manifests/ 目录）
#   - 每个阶段幂等可重入
#   - GPU 竞态保护：完全等待旧 Worker Pod 终止后再部署新 DGD
# ============================================================
set -euo pipefail

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
  for f in "${TMPFILES[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_tmpfiles EXIT

# ── 模板渲染函数 ─────────────────────────────────────────────
# 使用 envsubst 将 YAML 模板中的 ${VAR} 替换为环境变量值
# 仅替换显式列出的变量，避免破坏 YAML 中的其他 $ 引用
TEMPLATE_VARS='${NAMESPACE} ${RELEASE_VERSION} ${MODEL_NAME} ${DECODE_REPLICAS} ${PREFILL_REPLICAS} ${PROM_ENDPOINT} ${MONITORING_NS} ${GPU_MEMORY_UTIL}'

render_template() {
  local template="$1"
  if [[ ! -f "$template" ]]; then
    error "模板文件不存在: $template"
    exit 1
  fi
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
export RELEASE_VERSION="${RELEASE_VERSION:-0.7.1}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
export HF_TOKEN="${HF_TOKEN:-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}"
export NGC_API_KEY="${NGC_API_KEY:-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}"
export MONITORING_NS="${MONITORING_NS:-monitoring}"
export PREFILL_REPLICAS="${PREFILL_REPLICAS:-1}"
export DECODE_REPLICAS="${DECODE_REPLICAS:-1}"
export GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.90}"

echo ""
echo "============================================================"
echo "  Dynamo ${RELEASE_VERSION} 一键部署脚本"
echo "============================================================"
echo "  Namespace:           ${NAMESPACE}"
echo "  Dynamo Version:      ${RELEASE_VERSION}"
echo "  Model:               ${MODEL_NAME}"
echo "  Prefill Replicas:    ${PREFILL_REPLICAS}"
echo "  Decode Replicas:     ${DECODE_REPLICAS}"
echo "  GPU Required:        $((PREFILL_REPLICAS + DECODE_REPLICAS))"
echo "  GPU Memory Util:     ${GPU_MEMORY_UTIL}"
echo "  Monitoring NS:       ${MONITORING_NS}"
echo "  Manifests Dir:       ${MANIFEST_DIR}"
echo "============================================================"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 0：预飞检查
# ════════════════════════════════════════════════════════════════
step "阶段 0：预飞检查"

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
  error "无法连接 K8s 集群，请检查 KUBECONFIG"
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
info "GPU 检查通过：可用 ${GPU_COUNT}，需要 ${REQUIRED_GPU} ✓"

# 0.7 NVIDIA Container Runtime + CDI 隔离检查
#
# Dynamo DGD 正确运行需要满足以下 3 个条件：
#   ① containerd defaultRuntimeName = "nvidia"
#   ② containerd enableCDI = true
#   ③ DGD manifest 中不设 runtimeClassName
#
# 三者缺一不可，否则：
#   - 缺①：containerd 用 runc → 容器无 GPU 驱动 → libcuda.so.1 缺失
#   - 缺②：CDI 设备隔离不生效 → 容器看到全部 GPU → 多 Worker 竞争同一 GPU → OOM
#   - 加 runtimeClassName: nvidia → 绕过 CDI，走 legacy 路径 → 同②
#
# SSD 迁移 / containerd 重启可能导致这些配置丢失。
# GPU Operator 的 nvidia-container-toolkit-daemonset 控制 containerd 配置：
#   NVIDIA_RUNTIME_SET_AS_DEFAULT=true → ①
#   CDI_ENABLED=true                   → ② (toolkit 已设，但主 config.toml 可能遗漏)

info "检查 NVIDIA Container Runtime + CDI 配置..."

# 使用 crictl info 获取 containerd 实际生效的配置（比 grep config.toml 更可靠）
CRICTL_JSON=$(sudo crictl info 2>/dev/null || true)
PREFLIGHT_FAIL=false

if [[ -n "$CRICTL_JSON" ]]; then
  ACTUAL_DEFAULT_RT=$(echo "$CRICTL_JSON" | python3 -c "
import json, sys
info = json.load(sys.stdin)
print(info.get('config', {}).get('containerd', {}).get('defaultRuntimeName', 'UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

  ACTUAL_CDI=$(echo "$CRICTL_JSON" | python3 -c "
import json, sys
info = json.load(sys.stdin)
print(info.get('config', {}).get('enableCDI', 'UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
else
  warn "无法通过 crictl info 获取配置，回退到 config.toml 检查"
  ACTUAL_DEFAULT_RT="UNKNOWN"
  ACTUAL_CDI="UNKNOWN"
  if grep -q 'default_runtime_name.*nvidia' /etc/containerd/config.toml 2>/dev/null; then
    ACTUAL_DEFAULT_RT="nvidia"
  fi
  if grep -q 'enable_cdi = true' /etc/containerd/config.toml 2>/dev/null; then
    ACTUAL_CDI="True"
  fi
fi

# 检查 ① defaultRuntimeName
if [[ "$ACTUAL_DEFAULT_RT" == "nvidia" ]]; then
  info "containerd defaultRuntimeName = nvidia ✓"
else
  error "containerd 默认 runtime = \"${ACTUAL_DEFAULT_RT}\"（需要 nvidia）"
  PREFLIGHT_FAIL=true
fi

# 检查 ② enableCDI
if [[ "$ACTUAL_CDI" == "True" || "$ACTUAL_CDI" == "true" ]]; then
  info "containerd enableCDI = true ✓"
else
  error "containerd CDI 未启用（enableCDI = ${ACTUAL_CDI}）"
  PREFLIGHT_FAIL=true
fi

if [[ "$PREFLIGHT_FAIL" == "true" ]]; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║  GPU 运行环境配置不正确，Dynamo Worker 将无法正常启动       ║"
  echo "  ╠══════════════════════════════════════════════════════════════╣"
  echo "  ║                                                            ║"
  echo "  ║  修复步骤（在 GPU 节点上执行）：                            ║"
  echo "  ║                                                            ║"
  echo "  ║  Step 1: 让 toolkit 将 nvidia 设为默认 runtime              ║"
  echo "  ║    kubectl set env daemonset/nvidia-container-toolkit-daemonset \\ ║"
  echo "  ║      -n gpu-operator NVIDIA_RUNTIME_SET_AS_DEFAULT=true     ║"
  echo "  ║    kubectl rollout status ds/nvidia-container-toolkit-daemonset \\ ║"
  echo "  ║      -n gpu-operator --timeout=120s                         ║"
  echo "  ║                                                            ║"
  echo "  ║  Step 2: 启用 CDI                                          ║"
  echo "  ║    sudo sed -i 's/enable_cdi = false/enable_cdi = true/' \\ ║"
  echo "  ║      /etc/containerd/config.toml                            ║"
  echo "  ║    sudo systemctl restart containerd                        ║"
  echo "  ║                                                            ║"
  echo "  ║  Step 3: 重启 device plugin                                ║"
  echo "  ║    kubectl rollout restart ds/nvidia-device-plugin-daemonset \\ ║"
  echo "  ║      -n gpu-operator                                        ║"
  echo "  ║                                                            ║"
  echo "  ║  然后重新运行本脚本。                                      ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo ""
  exit 1
fi

# 0.8 Prometheus 检查
if kubectl get svc prometheus-kube-prometheus-prometheus -n "${MONITORING_NS}" &>/dev/null; then
  info "Prometheus 已检测到 ✓"
else
  warn "Prometheus 未检测到（namespace: ${MONITORING_NS}）"
  warn "Dynamo Operator 的 metrics 功能可能不可用，但不影响推理部署。"
fi
export PROM_ENDPOINT="http://prometheus-kube-prometheus-prometheus.${MONITORING_NS}.svc.cluster.local:9090"
info "Prometheus endpoint: ${PROM_ENDPOINT}"

info "预飞检查完成 ✓"

# ════════════════════════════════════════════════════════════════
# 阶段 1：清理旧安装（如果存在）
# 按 DGD → HPA/Ingress → Platform → PVC → NS 顺序删除，
# 让 Operator 先清理推理 Pod，再卸载 Operator 自身。
# ════════════════════════════════════════════════════════════════
step "阶段 1：清理旧安装（如果存在）"

# 1.1 删除 DGD（触发 Operator 清理推理 Pod 及关联 Service）
if kubectl get dynamographdeployment vllm-v1-disagg-router -n "${NAMESPACE}" &>/dev/null; then
  warn "删除旧的 DGD: vllm-v1-disagg-router..."
  kubectl delete dynamographdeployment vllm-v1-disagg-router -n "${NAMESPACE}" --wait --timeout=120s || true

  # ── GPU 竞态保护：等待所有 Worker Pod 完全终止 ──────────────
  # 原因：DGD K8s 对象删除后，Worker Pod 可能继续短暂运行。
  # 如果此时立即创建新 DGD，NVIDIA Device Plugin 可能仍将旧 Pod
  # 的 GPU 视为"已分配"，导致新 Decode Pod 被分配到同一 GPU：
  #   旧 Prefill（GPU 0） + 新 Decode（GPU 0）→ OOM CrashLoopBackOff
  # 解决：等待所有 *Worker* Pods 完全消失，再等 30s 确保 GPU 内存释放。
  info "等待旧 Worker Pod 完全终止（GPU 竞态保护）..."
  for i in $(seq 1 60); do
    WORKER_PODS=$(kubectl get pods -n "${NAMESPACE}" \
      -l nvidia.com/dynamo-component-type=worker \
      --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$WORKER_PODS" -eq 0 ]]; then
      info "所有 Worker Pod 已终止 ✓"
      break
    fi
    echo -ne "\r  [${i}/60] 还有 ${WORKER_PODS} 个 Worker Pod 运行中，等待..."
    sleep 5
  done
  echo ""
  # vLLM CUDA context 析构后，GPU VRAM 并非立即回收：
  #   Pod 消失（K8s）→ SIGKILL → 进程死亡 → CUDA driver 释放显存
  # 整个链路可能需要 30-60s。若等待不足，Device Plugin 会将同一 GPU
  # 重新分配给新 Decode Worker，而旧进程尚未释放显存 → OOM
  info "等待 60s 确保 GPU 内存完全释放（vLLM CUDA context 析构需要额外时间）..."
  sleep 60
fi

# 1.2 删除 HPA / Ingress
kubectl delete hpa --all -n "${NAMESPACE}" 2>/dev/null || true
kubectl delete ingress --all -n "${NAMESPACE}" 2>/dev/null || true

# 1.3 卸载 Helm release
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

  NS_GONE=false
  for i in $(seq 1 60); do
    if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
      NS_GONE=true; break
    fi
    sleep 3
  done

  # Namespace 卡在 Terminating 时强制清除 finalizers
  if [[ "$NS_GONE" == "false" ]]; then
    NS_STATUS=$(kubectl get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$NS_STATUS" == "Terminating" ]]; then
      warn "Namespace 卡在 Terminating，强制清除 finalizers..."
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

# ════════════════════════════════════════════════════════════════
# 阶段 2：安装 Dynamo CRDs（集群级，幂等）
# ════════════════════════════════════════════════════════════════
step "阶段 2：安装 Dynamo CRDs"

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

# ════════════════════════════════════════════════════════════════
# 阶段 3：创建 Namespace 和 Secrets
# ════════════════════════════════════════════════════════════════
step "阶段 3：创建 Namespace 和 Secrets"

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

# ════════════════════════════════════════════════════════════════
# 阶段 4：安装 Dynamo Platform（Operator + etcd + NATS）
# ════════════════════════════════════════════════════════════════
step "阶段 4：安装 Dynamo Platform（Operator + etcd + NATS）"

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
kubectl get pods -n "${NAMESPACE}"

# etcd 健康检查
info "etcd 健康检查..."
kubectl exec -n "${NAMESPACE}" dynamo-platform-etcd-0 -- \
  etcdctl --endpoints=http://localhost:2379 endpoint health || warn "etcd 健康检查失败"

# Operator 日志检查
ERRORS=$(kubectl logs -l app.kubernetes.io/name=dynamo-operator \
  -n "${NAMESPACE}" --tail=20 2>/dev/null | grep -ci error || true)
if [[ "$ERRORS" -gt 0 ]]; then
  warn "Operator 日志中发现 ${ERRORS} 条 error，请检查: kubectl logs -l app.kubernetes.io/name=dynamo-operator -n ${NAMESPACE}"
else
  info "Operator 无错误日志 ✓"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 5：部署推理服务（DGD）
# ════════════════════════════════════════════════════════════════
step "阶段 5：部署推理服务（DGD）"

render_template "${MANIFEST_DIR}/dgd-vllm-disagg-router.yaml" | kubectl apply -f -

info "DGD 已提交，等待 Operator 创建推理 Pod..."

# ════════════════════════════════════════════════════════════════
# 阶段 6：等待推理服务就绪（最多 15 分钟）
# ════════════════════════════════════════════════════════════════
step "阶段 6：等待推理服务就绪"
info "Worker 首次启动需从 HuggingFace 下载模型权重，可能耗时较长..."

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

  # ── GPU 冲突检测（诊断提示，不自动修复）─────────────────────
  # 如果 Worker CrashLoopBackOff 且日志含 "Free memory on device"，
  # 说明 GPU 设备隔离失败（通常是 runtimeClassName 配置问题）。
  # 此时自动删 Pod 无法修复，需要检查 DGD manifest 和 containerd 配置。
  if [[ $ELAPSED -ge 120 && $((ELAPSED % 120)) -eq 0 ]]; then
    CRASH_WORKER=$(kubectl get pods -n "${NAMESPACE}" \
      -l "nvidia.com/dynamo-component-type=worker" --no-headers 2>/dev/null \
      | awk '$3 == "CrashLoopBackOff" || $3 == "Error" {print $1}' | head -1)
    if [[ -n "$CRASH_WORKER" ]]; then
      CRASH_LOG=$(kubectl logs "$CRASH_WORKER" -n "${NAMESPACE}" --previous 2>/dev/null || true)
      if echo "$CRASH_LOG" | grep -q "Free memory on device" 2>/dev/null; then
        echo ""
        error "[GPU 冲突] ${CRASH_WORKER} 启动时发现 GPU 显存已被占用"
        error "多个 Worker 被分配到同一物理 GPU → OOM。"
        error "可能原因："
        error "  1. DGD manifest 中设了 runtimeClassName: nvidia（绕过 CDI 隔离）"
        error "  2. 旧 Worker Pod 未完全终止，Device Plugin 分配状态竞态"
        error "修复：确认 manifest 无 runtimeClassName，且 containerd 默认 runtime = nvidia"
      elif echo "$CRASH_LOG" | grep -q "libcuda.so" 2>/dev/null; then
        echo ""
        error "[无 GPU 驱动] ${CRASH_WORKER} 容器内找不到 libcuda.so.1"
        error "containerd 默认 runtime 不是 nvidia，容器使用 runc 启动，无 GPU 驱动注入。"
        error "修复："
        error "  sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default"
        error "  sudo systemctl restart containerd"
      fi
    fi
  fi

  RUNNING=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -c "Running" || true)
  TOTAL=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l || true)
  echo -ne "\r  [${ELAPSED}s/${TIMEOUT}s] DGD Ready=${DGD_READY}  Pods: ${RUNNING}/${TOTAL} Running    "
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

info "最终 Pod 状态："
kubectl get pods -n "${NAMESPACE}" -o wide

info "GPU 分配情况："
kubectl get pods -n "${NAMESPACE}" \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,GPU:.spec.containers[0].resources.limits.nvidia\.com/gpu'

kubectl get dynamographdeployment -n "${NAMESPACE}"

# ════════════════════════════════════════════════════════════════
# 阶段 7：部署 Ingress Controller 和规则
# ════════════════════════════════════════════════════════════════
step "阶段 7：部署 Ingress Controller 和规则"

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

# ════════════════════════════════════════════════════════════════
# 阶段 8：安装 Prometheus Adapter（HPA 自定义指标依赖）
# ════════════════════════════════════════════════════════════════
step "阶段 8：安装 Prometheus Adapter"

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

# ════════════════════════════════════════════════════════════════
# 阶段 9：配置 HPA 自动扩容
# ════════════════════════════════════════════════════════════════
step "阶段 9：配置 HPA 自动扩容"

render_template "${MANIFEST_DIR}/hpa-frontend.yaml"       | kubectl apply -f -
render_template "${MANIFEST_DIR}/hpa-decode-worker.yaml"   | kubectl apply -f -
render_template "${MANIFEST_DIR}/hpa-prefill-worker.yaml"  | kubectl apply -f -

info "HPA 配置完成 ✓"
kubectl get hpa -n "${NAMESPACE}"

# ════════════════════════════════════════════════════════════════
# 阶段 10：端到端验证
# ════════════════════════════════════════════════════════════════
step "阶段 10：端到端验证"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost/v1/models 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  info "Ingress 端到端验证成功 ✓"
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
    warn "推理 API 尚未就绪 (HTTP ${HTTP_CODE})，Worker 可能仍在初始化..."
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
echo "  Frontend:      http://localhost/v1/  (Ingress，80 端口)"
echo "  或通过 port-forward: kubectl port-forward svc/vllm-v1-disagg-router-frontend 8000:8000 -n ${NAMESPACE}"
echo ""
info "常用命令："
echo "  查看 Pod:    kubectl get pods -n ${NAMESPACE}"
echo "  查看 DGD:    kubectl get dynamographdeployment -n ${NAMESPACE}"
echo "  查看 HPA:    kubectl get hpa -n ${NAMESPACE}"
echo "  查看日志:    kubectl logs -l nvidia.com/dynamo-component-type=worker -n ${NAMESPACE} --prefix --tail=50"
echo "  运行测试:    bash ../../test-dynamo/0.7.1/00-setup-env.sh"
echo ""
echo "============================================================"
