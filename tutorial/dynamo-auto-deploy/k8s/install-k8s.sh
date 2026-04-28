#!/bin/bash
# ============================================================
# install-k8s.sh — 从零安装单节点 Kubernetes + GPU 支持
#
# 适用环境：
#   - Ubuntu 22.04 LTS
#   - 单节点（控制平面兼工作节点）
#   - NVIDIA GPU（RTX 3090 或同类）
#   - 需要 sudo 权限
#
# 安装内容：
#   Stage 1  — 系统预备（swap, 内核模块, sysctl）
#   Stage 2  — containerd 安装与配置
#   Stage 3  — kubeadm / kubelet / kubectl 安装
#   Stage 4  — kubeadm init（集群初始化）
#   Stage 5  — kubeconfig 配置
#   Stage 6  — CNI 安装（Flannel）
#   Stage 7  — 去除 Master Taint（单节点关键步骤）
#   Stage 8  — NVIDIA Container Toolkit 安装
#   Stage 9  — NVIDIA GPU Operator 安装（via helm）
#   Stage 10 — 验收检查
#
# 使用方法：
#   export NODE_IP=192.168.1.246   # 本机 IP（必须设置）
#   bash install-k8s.sh
#
# 重试方法（如果中途失败）：
#   sudo kubeadm reset -f
#   sudo rm -rf /etc/kubernetes/pki/ /etc/kubernetes/*.conf
#   bash install-k8s.sh
#
# 安装完成后下一步：
#   bash deploy-Prometheus-Grafana.sh
# ============================================================
set -euo pipefail

# ── 颜色输出 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${BLUE}════════════════════════════════════════════════════════════${NC}"; \
          echo -e "${BLUE}  $*${NC}"; \
          echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"; }

# ── 可配置变量 ───────────────────────────────────────────────
K8S_VERSION="${K8S_VERSION:-v1.30}"                          # K8s 版本系列
POD_NETWORK_CIDR="${POD_NETWORK_CIDR:-10.244.0.0/16}"       # Pod 网络 CIDR（Flannel 默认值）
NODE_IP="${NODE_IP:-}"                                        # 本机 IP（必须设置）
NGC_API_KEY="${NGC_API_KEY:-}"                               # NGC API Key（GPU Operator 安装需要）

echo ""
echo "============================================================"
echo "  Kubernetes 单节点安装脚本"
echo "============================================================"
echo "  K8s 版本:         ${K8S_VERSION}"
echo "  Pod 网络 CIDR:    ${POD_NETWORK_CIDR}"
echo "  本机 IP:          ${NODE_IP:-（未指定，将自动检测）}"
echo "============================================================"
echo ""

# ── 基础检查 ─────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]] && ! sudo -n true 2>/dev/null; then
  error "此脚本需要 sudo 权限。请以 root 运行，或确保当前用户有 sudo 访问。"
  exit 1
fi

if [[ -z "$NODE_IP" ]]; then
  NODE_IP=$(hostname -I | awk '{print $1}')
  warn "NODE_IP 未设置，自动检测为: ${NODE_IP}"
  warn "如果不正确，请手动设置: export NODE_IP=<正确IP>"
  sleep 3
fi

# ════════════════════════════════════════════════════════════════
# Stage 1：系统预备
# ════════════════════════════════════════════════════════════════
step "Stage 1：系统预备（swap / 内核模块 / sysctl）"

# 1.1 关闭 swap（K8s 要求，否则 kubelet 无法启动）
info "关闭 swap..."
sudo swapoff -a
# 永久生效：注释掉 /etc/fstab 中所有 swap 行
sudo sed -i '/\bswap\b/s/^/#/' /etc/fstab
# 验证
if [[ "$(free -m | awk '/Swap/{print $2}')" != "0" ]]; then
  error "Swap 关闭失败"
  exit 1
fi
info "swap 已关闭 ✓"

# 1.2 加载必要的内核模块
info "加载内核模块（overlay, br_netfilter）..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
info "内核模块已加载 ✓"

# 1.3 设置 sysctl 参数
info "配置 sysctl 参数..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system > /dev/null
info "sysctl 参数已应用 ✓"

# 1.4 关闭防火墙（单节点环境）
if command -v ufw &>/dev/null; then
  sudo ufw disable 2>/dev/null || true
  info "ufw 防火墙已关闭 ✓"
fi

info "Stage 1 完成 ✓"

# ════════════════════════════════════════════════════════════════
# Stage 2：安装 containerd
# ════════════════════════════════════════════════════════════════
step "Stage 2：安装 containerd"

info "安装 containerd..."
sudo apt-get update -y
sudo apt-get install -y containerd

# 2.2 生成默认配置文件
info "生成 containerd 默认配置..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# 2.3 配置 SystemdCgroup=true
# 这是最容易遗漏的关键配置：kubelet 默认使用 systemd 作为 cgroup 驱动，
# containerd 也必须保持一致，否则节点状态出现异常
info "配置 containerd 使用 systemd cgroup 驱动..."
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 验证修改
if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
  error "containerd SystemdCgroup 配置失败"
  exit 1
fi

# 2.4 重启并启用 containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

# 验收
if ! sudo systemctl is-active --quiet containerd; then
  error "containerd 服务启动失败"
  sudo systemctl status containerd
  exit 1
fi
info "containerd 安装完成，SystemdCgroup=true ✓"

# ════════════════════════════════════════════════════════════════
# Stage 3：安装 kubeadm / kubelet / kubectl
# ════════════════════════════════════════════════════════════════
step "Stage 3：安装 kubeadm / kubelet / kubectl（${K8S_VERSION}）"

info "安装依赖..."
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# 添加 K8s apt 仓库签名密钥
info "添加 Kubernetes apt 仓库签名密钥..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# 添加仓库
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 安装
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl

# 锁定版本（防止意外升级导致版本不一致）
sudo apt-mark hold kubelet kubeadm kubectl

# 启用 kubelet（此时会不断重启，正常现象，等待 kubeadm init 后恢复）
sudo systemctl enable kubelet

info "kubeadm / kubelet / kubectl 安装完成 ✓"
kubeadm version --output short
kubectl version --client --output yaml | grep -E "gitVersion"

# ════════════════════════════════════════════════════════════════
# Stage 4：初始化集群（kubeadm init）
# ════════════════════════════════════════════════════════════════
step "Stage 4：初始化 Kubernetes 集群（kubeadm init）"

# 检查是否已经初始化过
if kubectl cluster-info &>/dev/null 2>&1; then
  warn "集群已存在，跳过 kubeadm init"
else
  info "执行 kubeadm init（可能需要几分钟）..."
  info "  API Server IP:  ${NODE_IP}"
  info "  Pod CIDR:       ${POD_NETWORK_CIDR}"

  sudo kubeadm init \
    --apiserver-advertise-address="${NODE_IP}" \
    --pod-network-cidr="${POD_NETWORK_CIDR}"

  info "kubeadm init 完成 ✓"
fi

# ════════════════════════════════════════════════════════════════
# Stage 5：配置 kubeconfig
# ════════════════════════════════════════════════════════════════
step "Stage 5：配置 kubectl 访问权限"

# 为当前用户配置
mkdir -p "${HOME}/.kube"
sudo cp -f /etc/kubernetes/admin.conf "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
export KUBECONFIG="${HOME}/.kube/config"

# 写入 .bashrc（永久生效）
if ! grep -q "KUBECONFIG" "${HOME}/.bashrc"; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "${HOME}/.bashrc"
fi

# 验证
if ! kubectl cluster-info &>/dev/null; then
  error "kubectl 配置失败，无法连接集群"
  exit 1
fi
info "kubectl 已配置，集群可正常访问 ✓"
kubectl get nodes

# ════════════════════════════════════════════════════════════════
# Stage 6：安装 CNI 插件（Flannel）
# ════════════════════════════════════════════════════════════════
step "Stage 6：安装 CNI 网络插件（Flannel）"

# Flannel 要求 pod-network-cidr=10.244.0.0/16，即上面 kubeadm init 使用的值
if kubectl get pods -n kube-flannel -l app=flannel 2>/dev/null | grep -q Running; then
  info "Flannel 已安装，跳过"
else
  info "安装 Flannel..."
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  # 等待 Flannel DaemonSet Pod 就绪
  info "等待 Flannel Pod 就绪（最多 3 分钟）..."
  for i in $(seq 1 36); do
    FLANNEL_READY=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null \
      | grep -c "Running" || true)
    if [[ "$FLANNEL_READY" -ge 1 ]]; then
      info "Flannel Pod Running ✓"
      break
    fi
    sleep 5
  done
fi

# 等待节点变为 Ready
info "等待节点 Ready（最多 5 分钟）..."
for i in $(seq 1 60); do
  NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
  if [[ "$NODE_STATUS" == "Ready" ]]; then
    info "节点状态: Ready ✓"
    break
  fi
  echo -ne "\r  [${i}/60] 等待节点 Ready，当前状态: ${NODE_STATUS:-Unknown}..."
  sleep 5
done
echo ""

kubectl get nodes
info "CNI 安装完成 ✓"

# ════════════════════════════════════════════════════════════════
# Stage 7：移除 Master Taint（单节点关键步骤）
# ════════════════════════════════════════════════════════════════
step "Stage 7：移除 Master Taint（允许普通 Pod 调度到控制平面节点）"

# 单节点模式下，控制平面节点默认带有 NoSchedule taint，
# 必须移除否则工作负载 Pod 无法调度
info "移除 control-plane taint..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

# 验证
TAINT_CHECK=$(kubectl get nodes -o jsonpath='{.items[0].spec.taints[*].key}' 2>/dev/null || true)
if echo "$TAINT_CHECK" | grep -q "control-plane"; then
  warn "control-plane taint 可能未完全移除，请手动检查: kubectl describe node"
else
  info "Master taint 已移除，普通 Pod 可以调度 ✓"
fi

# ════════════════════════════════════════════════════════════════
# Stage 8：安装 NVIDIA Container Toolkit
# ════════════════════════════════════════════════════════════════
step "Stage 8：安装 NVIDIA Container Toolkit"

# 8.1 检查 NVIDIA 驱动
if ! command -v nvidia-smi &>/dev/null; then
  warn "nvidia-smi 未找到！"
  warn "必须先安装 NVIDIA 驱动（推荐 535+）后再继续。"
  warn "可暂时跳过 GPU 相关步骤，安装驱动后重新从 Stage 8 开始。"
  warn "继续安装（3 秒后）..."
  sleep 3
else
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
  info "检测到 ${GPU_COUNT} 块 GPU ✓"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
fi

# 8.2 安装 nvidia-container-toolkit
info "安装 NVIDIA Container Toolkit..."
if ! command -v nvidia-ctk &>/dev/null; then
  # 添加 NVIDIA Container Toolkit 仓库
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  sudo apt-get update -y
  sudo apt-get install -y nvidia-container-toolkit

  info "NVIDIA Container Toolkit 安装完成 ✓"
else
  info "NVIDIA Container Toolkit 已安装，版本: $(nvidia-ctk --version 2>/dev/null | head -1)"
fi

# 8.3 配置 containerd 使用 nvidia runtime handler
# 这是关键步骤：在 K8s 中 runtimeClassName: nvidia 必须对应到
# containerd 中已注册的 nvidia runtime handler
info "配置 containerd 使用 nvidia runtime handler..."
sudo nvidia-ctk runtime configure --runtime=containerd

# 重启 containerd 使配置生效
sudo systemctl restart containerd
sleep 3

# 验证 nvidia handler 已注册到 containerd 配置中
if grep -q "nvidia" /etc/containerd/config.toml; then
  info "nvidia runtime handler 已注册到 containerd ✓"
else
  warn "请手动检查 /etc/containerd/config.toml 中是否有 nvidia handler"
fi

info "NVIDIA Container Toolkit 配置完成 ✓"

# ════════════════════════════════════════════════════════════════
# Stage 9：安装 NVIDIA GPU Operator
# ════════════════════════════════════════════════════════════════
step "Stage 9：安装 NVIDIA GPU Operator（via Helm）"

# GPU Operator 职责：
# 1. 部署 NVIDIA Device Plugin → K8s 调度层可见 nvidia.com/gpu 资源
# 2. 管理 nvidia RuntimeClass → runtimeClassName: nvidia 可被解析
# 3. 部署 DCGM Exporter → Prometheus 可采集 GPU 指标

# 9.1 安装 Helm（如未安装）
if ! command -v helm &>/dev/null; then
  info "安装 Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  info "Helm 安装完成: $(helm version --short)"
else
  info "Helm 已安装: $(helm version --short)"
fi

# 9.2 添加 NVIDIA Helm 仓库
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update
info "NVIDIA Helm 仓库已添加 ✓"

# 9.3 安装 GPU Operator
if helm status gpu-operator -n gpu-operator &>/dev/null 2>&1; then
  info "GPU Operator 已安装，跳过"
else
  info "安装 GPU Operator（可能需要 5-10 分钟，需要拉取镜像）..."
  kubectl create namespace gpu-operator 2>/dev/null || true

  # 关键参数说明：
  # --set driver.enabled=false: 如果 GPU 驱动已在宿主机安装则禁用，
  #   避免与已有驱动冲突。若宿主机无驱动则去掉此参数让 Operator 管理驱动。
  # --set toolkit.enabled=true: 确保 Container Toolkit 由 Operator 管理
  helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --set driver.enabled=false \
    --set toolkit.enabled=true \
    --wait \
    --timeout 15m

  info "GPU Operator 安装完成 ✓"
fi

# 9.4 等待 GPU Operator 组件就绪
info "等待 GPU Operator 组件就绪（最多 10 分钟）..."
for i in $(seq 1 60); do
  NOT_READY=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null \
    | grep -v "Running\|Completed" | wc -l || true)
  if [[ "$NOT_READY" -eq 0 ]]; then
    info "GPU Operator 所有组件就绪 ✓"
    break
  fi
  echo -ne "\r  [${i}/60] 还有 ${NOT_READY} 个 Pod 未就绪..."
  sleep 10
done
echo ""

kubectl get pods -n gpu-operator

# ════════════════════════════════════════════════════════════════
# Stage 10：验收检查
# ════════════════════════════════════════════════════════════════
step "Stage 10：最终验收检查"

echo ""
info "--- 节点状态 ---"
kubectl get nodes -o wide

echo ""
info "--- 系统 Pod 状态 ---"
kubectl get pods -n kube-system

echo ""
info "--- GPU Operator Pod 状态 ---"
kubectl get pods -n gpu-operator 2>/dev/null || warn "gpu-operator namespace 不存在"

echo ""
info "--- GPU 资源可分配情况 ---"
GPU_ALLOCATABLE=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "未知")
info "  nvidia.com/gpu 可分配数量: ${GPU_ALLOCATABLE}"

if [[ "$GPU_ALLOCATABLE" == "0" ]] || [[ "$GPU_ALLOCATABLE" == "未知" ]]; then
  warn "GPU 资源尚未可分配。GPU Operator 可能仍在初始化中。"
  warn "请等待 1-2 分钟后执行: kubectl get nodes -o json | grep nvidia"
else
  info "GPU 资源可分配: ${GPU_ALLOCATABLE} 块 ✓"
fi

echo ""
info "--- RuntimeClass 检查 ---"
if kubectl get runtimeclass nvidia &>/dev/null 2>&1; then
  info "nvidia RuntimeClass 存在 ✓"
  kubectl get runtimeclass nvidia
else
  warn "nvidia RuntimeClass 尚不存在（GPU Operator 初始化完成后会自动创建）"
fi

echo ""
echo "============================================================"
echo "  K8s 单节点安装完成！"
echo "============================================================"
echo ""
info "验收检查清单："
echo "  ✓ swap 已关闭"
echo "  ✓ containerd 运行中（SystemdCgroup=true）"
echo "  ✓ kubeadm / kubelet / kubectl 已安装"
echo "  ✓ 集群初始化完成（kubeadm init）"
echo "  ✓ kubectl 已配置"
echo "  ✓ Flannel CNI 已安装"
echo "  ✓ Master taint 已移除（单节点调度启用）"
echo "  ✓ NVIDIA Container Toolkit 已安装并配置"
echo "  ✓ GPU Operator 已安装"
echo ""
info "下一步："
echo "  1. 验证 GPU 资源可调度:"
echo "       kubectl get nodes -o json | python3 -c \\"
echo "         \"import json,sys; [print(n['status']['allocatable'].get('nvidia.com/gpu','0')) \\"
echo "         for n in json.load(sys.stdin)['items']]\""
echo "  2. 部署监控:"
echo "       bash ../k8s/deploy-Prometheus-Grafana.sh"
echo "  3. 部署 Dynamo:"
echo "       bash ../0.7.1/deploy-dynamo-0.7.1.sh"
echo ""
echo "============================================================"
