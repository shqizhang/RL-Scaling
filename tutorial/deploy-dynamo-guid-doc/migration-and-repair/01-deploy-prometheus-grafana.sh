#!/bin/bash
# ============================================================
# 一键部署 Prometheus & Grafana（kube-prometheus-stack）
# 适用于：单节点 K8s 集群，全新安装或灾后恢复
# 前提：kubectl / helm v3.8+ 可用，K8s 集群正常，
#       已完成 StorageClass / GPU / control-plane taint 配置
# ============================================================
set -euo pipefail

# ── 颜色输出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 可配置变量（按需修改） ──────────────────────────────────
MONITORING_NS="${MONITORING_NS:-monitoring}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-placeholder}"  # 请修改为实际密码
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-20Gi}"
GRAFANA_STORAGE_SIZE="${GRAFANA_STORAGE_SIZE:-5Gi}"

echo "============================================================"
echo "  Prometheus & Grafana 一键部署脚本"
echo "============================================================"
echo "  Namespace:           ${MONITORING_NS}"
echo "  Grafana Password:    ${GRAFANA_ADMIN_PASSWORD}"
echo "  Prometheus Retention:${PROMETHEUS_RETENTION}"
echo "============================================================"
echo ""

# ── 阶段 0：预飞检查 ────────────────────────────────────────
info "阶段 0：预飞检查..."

# 检查 kubectl
if ! command -v kubectl &>/dev/null; then
  error "kubectl 未安装"; exit 1
fi

# 检查 helm
if ! command -v helm &>/dev/null; then
  error "helm 未安装，请先执行："
  echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

# 自动检测 KUBECONFIG（sudo -i 切换到 root 时 ~/.kube/config 可能不存在）
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    warn "使用 /etc/kubernetes/admin.conf 作为 KUBECONFIG"
  fi
fi

# 检查 K8s 连接
if ! kubectl cluster-info &>/dev/null; then
  error "无法连接 K8s 集群"
  echo "  请检查 KUBECONFIG 是否正确："
  echo "    export KUBECONFIG=/etc/kubernetes/admin.conf"
  echo "  或者将 admin.conf 复制到 ~/.kube/config："
  echo "    mkdir -p ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config"
  exit 1
fi

# 检查默认 StorageClass
DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)
if [[ -z "$DEFAULT_SC" ]]; then
  warn "未检测到默认 StorageClass，尝试安装 local-path-provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  info "local-path StorageClass 已设置为默认"
else
  info "默认 StorageClass: ${DEFAULT_SC}"
fi

info "预飞检查完成 ✓"
echo ""

# ── 阶段 1：清理旧安装（如果存在） ──────────────────────────
info "阶段 1：清理旧安装..."

# 卸载 prometheus-adapter（如果存在）
if helm status prometheus-adapter -n "${MONITORING_NS}" &>/dev/null; then
  warn "发现旧的 prometheus-adapter，卸载中..."
  helm uninstall prometheus-adapter -n "${MONITORING_NS}" --wait || true
fi

# 卸载 kube-prometheus-stack（如果存在）
if helm status prometheus -n "${MONITORING_NS}" &>/dev/null; then
  warn "发现旧的 kube-prometheus-stack，卸载中..."
  helm uninstall prometheus -n "${MONITORING_NS}" --wait || true
fi

# 清理残留 PVC
PVCS=$(kubectl get pvc -n "${MONITORING_NS}" -o name 2>/dev/null || true)
if [[ -n "$PVCS" ]]; then
  warn "清理残留 PVC..."
  kubectl delete pvc --all -n "${MONITORING_NS}" --wait=false || true
fi

# 清理残留 CRDs（prometheus-operator 的 CRDs）
# 注意：这些 CRD 是集群级的，如果其他 namespace 也在用 prometheus，不要删
# 这里假设只有我们在用
for crd in alertmanagerconfigs.monitoring.coreos.com \
           alertmanagers.monitoring.coreos.com \
           podmonitors.monitoring.coreos.com \
           probes.monitoring.coreos.com \
           prometheusagents.monitoring.coreos.com \
           prometheuses.monitoring.coreos.com \
           prometheusrules.monitoring.coreos.com \
           scrapeconfigs.monitoring.coreos.com \
           servicemonitors.monitoring.coreos.com \
           thanosrulers.monitoring.coreos.com; do
  if kubectl get crd "$crd" &>/dev/null; then
    warn "删除残留 CRD: $crd"
    kubectl delete crd "$crd" --wait=false || true
  fi
done

# 删除 namespace（等待完全清除）
if kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
  warn "删除旧 namespace: ${MONITORING_NS}..."
  kubectl delete namespace "${MONITORING_NS}" --wait --timeout=120s || true
  # 等待 namespace 完全消失
  for i in $(seq 1 60); do
    if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
      break
    fi
    sleep 2
  done
fi

info "清理完成 ✓"
echo ""

# ── 阶段 2：创建 namespace 并配置 Helm repo ─────────────────
info "阶段 2：创建 namespace 并配置 Helm repo..."

kubectl create namespace "${MONITORING_NS}"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

info "Helm repo 已就绪 ✓"
echo ""

# ── 阶段 3：生成 values 并安装 kube-prometheus-stack ────────
info "阶段 3：安装 kube-prometheus-stack..."

VALUES_FILE=$(mktemp /tmp/prometheus-values-XXXXXX.yaml)
cat > "${VALUES_FILE}" << EOF
# ============================================================
# kube-prometheus-stack 单节点优化配置
# ============================================================

# Grafana 配置
grafana:
  enabled: true
  replicas: 1
  persistence:
    enabled: true
    size: ${GRAFANA_STORAGE_SIZE}
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"

# Prometheus 配置
prometheus:
  prometheusSpec:
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorNamespaceSelector: {}
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorNamespaceSelector: {}
    probeNamespaceSelector: {}
    retention: ${PROMETHEUS_RETENTION}
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${PROMETHEUS_STORAGE_SIZE}
    replicas: 1

# Alertmanager 单副本
alertmanager:
  alertmanagerSpec:
    replicas: 1

# node-exporter
nodeExporter:
  enabled: true

# kube-state-metrics
kubeStateMetrics:
  enabled: true
EOF

helm install prometheus \
  prometheus-community/kube-prometheus-stack \
  --namespace "${MONITORING_NS}" \
  --values "${VALUES_FILE}" \
  --timeout 10m \
  --wait

rm -f "${VALUES_FILE}"

info "kube-prometheus-stack 安装完成 ✓"
echo ""

# ── 阶段 4：验证 Pod 状态 ───────────────────────────────────
info "阶段 4：验证 Pod 状态..."

echo ""
kubectl get pods -n "${MONITORING_NS}" -o wide
echo ""

# 等待所有 Pod Ready（最多 5 分钟）
info "等待所有 Pod Ready（最多 5 分钟）..."
READY=false
for i in $(seq 1 60); do
  NOT_READY=$(kubectl get pods -n "${MONITORING_NS}" --no-headers 2>/dev/null \
    | grep -v "Running\|Completed" | wc -l)
  if [[ "$NOT_READY" -eq 0 ]]; then
    READY=true
    break
  fi
  sleep 5
done

if $READY; then
  info "所有 Pod 状态正常 ✓"
else
  warn "部分 Pod 尚未就绪，请手动检查：kubectl get pods -n ${MONITORING_NS}"
fi

# ── 阶段 5：输出关键信息 ────────────────────────────────────
echo ""
echo "============================================================"
echo "  部署完成！关键信息汇总"
echo "============================================================"

# Prometheus 集群内地址
PROM_SVC=$(kubectl get svc -n "${MONITORING_NS}" -l app=kube-prometheus-stack-prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "prometheus-kube-prometheus-prometheus")
echo ""
info "Prometheus 集群内地址（Dynamo 安装时需要）："
echo "  http://${PROM_SVC}.${MONITORING_NS}.svc.cluster.local:9090"

echo ""
info "Services 列表："
kubectl get svc -n "${MONITORING_NS}"

echo ""
info "Grafana 访问方法（从本地电脑通过 SSH 隧道）："
echo "  1. 本地终端执行: ssh -L 3000:localhost:3000 gpu14"
echo "  2. 在 SSH 会话中: kubectl port-forward svc/prometheus-grafana 3000:80 -n ${MONITORING_NS}"
echo "  3. 浏览器访问: http://localhost:3000"
echo "  4. 登录: admin / ${GRAFANA_ADMIN_PASSWORD}"

echo ""
info "Prometheus 访问方法："
echo "  1. 本地终端执行: ssh -L 9090:localhost:9090 gpu14"
echo "  2. 在 SSH 会话中: kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n ${MONITORING_NS}"
echo "  3. 浏览器访问: http://localhost:9090"

echo ""
echo "============================================================"
info "Prometheus & Grafana 部署完成！"
echo "============================================================"
