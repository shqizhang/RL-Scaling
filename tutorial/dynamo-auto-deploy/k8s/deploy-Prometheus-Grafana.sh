#!/bin/bash
# ============================================================
# deploy-Prometheus-Grafana.sh — 部署 Prometheus + Grafana 监控栈
#
# 使用 kube-prometheus-stack（包含 Prometheus, Grafana,
# Alertmanager, node-exporter, kube-state-metrics）
#
# 前置条件：
#   - K8s 集群正常运行（install-k8s.sh 已完成）
#   - kubectl / helm v3.8+ 可用
#   - 默认 StorageClass 已配置（否则自动安装 local-path-provisioner）
#
# 使用方法：
#   export GRAFANA_ADMIN_PASSWORD=your_password
#   bash deploy-Prometheus-Grafana.sh
#
# 安装完成后下一步：
#   bash ../0.7.1/deploy-dynamo-0.7.1.sh
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
MONITORING_NS="${MONITORING_NS:-monitoring}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-placeholder}"  # 建议通过环境变量传入
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-20Gi}"
GRAFANA_STORAGE_SIZE="${GRAFANA_STORAGE_SIZE:-5Gi}"

echo ""
echo "============================================================"
echo "  Prometheus & Grafana 部署脚本"
echo "============================================================"
echo "  Namespace:             ${MONITORING_NS}"
echo "  Grafana Admin 密码:    ${GRAFANA_ADMIN_PASSWORD}"
echo "  Prometheus 保留时间:   ${PROMETHEUS_RETENTION}"
echo "  Prometheus 存储大小:   ${PROMETHEUS_STORAGE_SIZE}"
echo "  Grafana 存储大小:      ${GRAFANA_STORAGE_SIZE}"
echo "============================================================"
echo ""

# ════════════════════════════════════════════════════════════════
# 阶段 0：预飞检查
# ════════════════════════════════════════════════════════════════
step "阶段 0：预飞检查"

if ! command -v kubectl &>/dev/null; then
  error "kubectl 未安装"
  exit 1
fi

if ! command -v helm &>/dev/null; then
  error "helm 未安装，请先执行："
  echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

# 自动检测 KUBECONFIG
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    warn "使用 /etc/kubernetes/admin.conf 作为 KUBECONFIG"
  fi
fi

if ! kubectl cluster-info &>/dev/null; then
  error "无法连接 K8s 集群"
  echo "  请检查: export KUBECONFIG=/etc/kubernetes/admin.conf"
  exit 1
fi

# 检查默认 StorageClass
DEFAULT_SC=$(kubectl get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
  2>/dev/null || true)
if [[ -z "$DEFAULT_SC" ]]; then
  warn "未检测到默认 StorageClass，安装 local-path-provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  info "local-path StorageClass 已设置为默认 ✓"
else
  info "默认 StorageClass: ${DEFAULT_SC} ✓"
fi

info "预飞检查完成 ✓"

# ════════════════════════════════════════════════════════════════
# 阶段 1：清理旧安装（如果存在）
# ════════════════════════════════════════════════════════════════
step "阶段 1：清理旧安装（如果存在）"

if helm status prometheus-adapter -n "${MONITORING_NS}" &>/dev/null; then
  warn "卸载旧的 prometheus-adapter..."
  helm uninstall prometheus-adapter -n "${MONITORING_NS}" --wait || true
fi

if helm status prometheus -n "${MONITORING_NS}" &>/dev/null; then
  warn "卸载旧的 kube-prometheus-stack..."
  helm uninstall prometheus -n "${MONITORING_NS}" --wait || true
fi

# 清理残留 PVC
PVCS=$(kubectl get pvc -n "${MONITORING_NS}" -o name 2>/dev/null || true)
if [[ -n "$PVCS" ]]; then
  warn "清理残留 PVC..."
  kubectl delete pvc --all -n "${MONITORING_NS}" --wait=false || true
fi

# 清理残留 prometheus-operator CRDs
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

# 删除 namespace，等待完全清除
if kubectl get namespace "${MONITORING_NS}" &>/dev/null; then
  warn "删除旧 namespace: ${MONITORING_NS}..."
  kubectl delete namespace "${MONITORING_NS}" --wait --timeout=120s || true
  for i in $(seq 1 60); do
    if ! kubectl get namespace "${MONITORING_NS}" &>/dev/null; then break; fi
    sleep 2
  done
fi

info "清理完成 ✓"

# ════════════════════════════════════════════════════════════════
# 阶段 2：创建 namespace 并配置 Helm repo
# ════════════════════════════════════════════════════════════════
step "阶段 2：创建 namespace 并配置 Helm repo"

kubectl create namespace "${MONITORING_NS}"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

info "Helm repo 就绪 ✓"

# ════════════════════════════════════════════════════════════════
# 阶段 3：安装 kube-prometheus-stack
# ════════════════════════════════════════════════════════════════
step "阶段 3：安装 kube-prometheus-stack"

VALUES_FILE=$(mktemp /tmp/prometheus-values-XXXXXX.yaml)
trap "rm -f ${VALUES_FILE}" EXIT

cat > "${VALUES_FILE}" << VALEOF
# kube-prometheus-stack 单节点优化配置

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

alertmanager:
  alertmanagerSpec:
    replicas: 1

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
VALEOF

helm install prometheus \
  prometheus-community/kube-prometheus-stack \
  --namespace "${MONITORING_NS}" \
  --values "${VALUES_FILE}" \
  --timeout 10m \
  --wait

info "kube-prometheus-stack 安装完成 ✓"

# ════════════════════════════════════════════════════════════════
# 阶段 4：验证 Pod 状态
# ════════════════════════════════════════════════════════════════
step "阶段 4：验证 Pod 状态"

kubectl get pods -n "${MONITORING_NS}" -o wide

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
  echo -ne "\r  [${i}/60] 还有 ${NOT_READY} 个 Pod 未就绪..."
  sleep 5
done
echo ""

if $READY; then
  info "所有 Pod 状态正常 ✓"
else
  warn "部分 Pod 尚未就绪，请手动检查: kubectl get pods -n ${MONITORING_NS}"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 4.5：应用 Dynamo 官方 Grafana Dashboards
# ════════════════════════════════════════════════════════════════
step "阶段 4.5：应用 Dynamo 官方 Grafana Dashboards"

DYNAMO_REPO_DIR="${DYNAMO_REPO_DIR:-$HOME/dynamo-v1.0.1}"
DYNAMO_REPO_URL="${DYNAMO_REPO_URL:-https://github.com/ai-dynamo/dynamo.git}"
DYNAMO_REPO_TAG="${DYNAMO_REPO_TAG:-v1.0.1}"

if [[ ! -d "${DYNAMO_REPO_DIR}/deploy/observability/k8s" ]]; then
  warn "未找到 ${DYNAMO_REPO_DIR}, 克隆 ${DYNAMO_REPO_URL}@${DYNAMO_REPO_TAG}..."
  rm -rf "${DYNAMO_REPO_DIR}"
  git clone --depth 1 -b "${DYNAMO_REPO_TAG}" "${DYNAMO_REPO_URL}" "${DYNAMO_REPO_DIR}"
fi

DASH_DIR="${DYNAMO_REPO_DIR}/deploy/observability/k8s"
for f in grafana-disagg-dashboard-configmap.yaml \
         grafana-dynamo-dashboard-configmap.yaml \
         grafana-operator-dashboard-configmap.yaml \
         grafana-planner-dashboard-configmap.yaml; do
  if [[ -f "${DASH_DIR}/${f}" ]]; then
    kubectl apply -f "${DASH_DIR}/${f}"
  else
    warn "缺失 dashboard: ${f}"
  fi
done

info "已加载 Dashboard ConfigMap (sidecar label grafana_dashboard=1)："
kubectl get cm -n "${MONITORING_NS}" -l grafana_dashboard=1

# ════════════════════════════════════════════════════════════════
# 阶段 4.6：将 Grafana svc 暴露为 NodePort 30030 (外网访问)
# ════════════════════════════════════════════════════════════════
step "阶段 4.6：暴露 Grafana 为 NodePort 30030"

GRAFANA_NODEPORT="${GRAFANA_NODEPORT:-30030}"
kubectl patch svc prometheus-grafana -n "${MONITORING_NS}" --type=merge -p \
  "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"http-web\",\"port\":80,\"targetPort\":3000,\"nodePort\":${GRAFANA_NODEPORT}}]}}"

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
info "Grafana 外网地址: http://${NODE_IP}:${GRAFANA_NODEPORT}  (admin / ${GRAFANA_ADMIN_PASSWORD})"

# ════════════════════════════════════════════════════════════════
# 阶段 4.7：触发 Dynamo Operator 重新生成 PodMonitor (如果已部署)
# ════════════════════════════════════════════════════════════════
step "阶段 4.7：检查 Dynamo Platform 是否需要 helm upgrade 以创建 PodMonitor"

DYN_NS="${DYNAMO_NS:-dynamo-system}"
if helm status dynamo-platform -n "${DYN_NS}" &>/dev/null; then
  info "检测到 dynamo-platform 已安装于 ns/${DYN_NS}"
  PM_COUNT=$(kubectl get podmonitors -n "${DYN_NS}" --no-headers 2>/dev/null | wc -l)
  if [[ "${PM_COUNT}" -lt 4 ]]; then
    CHART_TGZ="${DYNAMO_PLATFORM_CHART:-$HOME/dynamo-charts-1.0.1/dynamo-platform-1.0.1.tgz}"
    if [[ -f "${CHART_TGZ}" ]]; then
      info "helm upgrade dynamo-platform 以触发 PodMonitor 创建 (现有 ${PM_COUNT}/4)..."
      helm upgrade dynamo-platform "${CHART_TGZ}" -n "${DYN_NS}" --reuse-values 2>&1 | tail -3
    else
      warn "未找到 chart ${CHART_TGZ}, 请手动执行: helm upgrade dynamo-platform <chart> -n ${DYN_NS} --reuse-values"
    fi
  else
    info "PodMonitor 已存在 (${PM_COUNT}) ✓"
  fi
else
  info "dynamo-platform 尚未安装, 跳过 PodMonitor 触发 (部署 Dynamo 后会自动创建)"
fi

# ════════════════════════════════════════════════════════════════
# 阶段 5：输出关键信息
# ════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  监控栈部署完成！关键信息汇总"
echo "============================================================"

PROM_SVC=$(kubectl get svc -n "${MONITORING_NS}" \
  -l app=kube-prometheus-stack-prometheus \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || echo "prometheus-kube-prometheus-prometheus")

echo ""
info "Prometheus 集群内地址（Dynamo 安装时需要）："
echo "  http://${PROM_SVC}.${MONITORING_NS}.svc.cluster.local:9090"
echo "  （可用于 deploy-dynamo-0.7.1.sh 的 MONITORING_NS=${MONITORING_NS}）"

echo ""
info "Services 列表："
kubectl get svc -n "${MONITORING_NS}"

echo ""
info "Grafana 外网访问 (NodePort)："
echo "  浏览器: http://${NODE_IP:-<NODE_IP>}:${GRAFANA_NODEPORT:-30030}"
echo "  登录:   admin / ${GRAFANA_ADMIN_PASSWORD}"
echo ""
info "Grafana 访问 (备用 — SSH 隧道)："
echo "  1. 本地终端: ssh -L 3000:localhost:3000 <服务器>"
echo "  2. 服务器上: kubectl port-forward svc/prometheus-grafana 3000:80 -n ${MONITORING_NS}"
echo "  3. 浏览器:   http://localhost:3000"
echo "  4. 登录:     admin / ${GRAFANA_ADMIN_PASSWORD}"

echo ""
info "Prometheus 访问方法："
echo "  1. 本地终端: ssh -L 9090:localhost:9090 <服务器>"
echo "  2. 服务器上: kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n ${MONITORING_NS}"
echo "  3. 浏览器:   http://localhost:9090"

echo ""
info "下一步："
echo "  bash ../1.0.1/01-deploy-dynamo-1.0.1.sh --planner --skip-monitoring"
echo ""
echo "============================================================"
