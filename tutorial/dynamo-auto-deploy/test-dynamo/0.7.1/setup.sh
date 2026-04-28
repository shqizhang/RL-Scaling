#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# setup.sh — Dynamo 测试环境一键搭建
#
# 从零搭建 Dynamo 推理测试所需的全部基础设施（幂等，可重复执行）：
#   Stage 1: 部署 ingress-nginx（Helm, DaemonSet + hostPort）
#   Stage 2: 部署 prometheus-adapter（Helm, 自定义指标 → Custom Metrics API）
#   Stage 3: 创建 Ingress 资源（/v1 → Frontend Service）
#   Stage 4: 创建 HPA 资源（CPU / inflight-requests based）
#   Stage 5: 启动 port-forward（Prometheus :9090, Grafana :3000）
#   Stage 6: 自动创建 Grafana Dashboard（通过 HTTP API 导入）
#
# 前置条件：
#   - Dynamo Platform + Worker 已部署且 Running
#   - Prometheus & Grafana 已部署（kube-prometheus-stack）
#
# 用法：
#   bash setup.sh              # 部署全部 + 前台运行 port-forward
#   bash setup.sh --background # 部署全部 + 后台运行 port-forward
#
# 参数覆盖（可选）：
#   NAMESPACE=my-ns MONITORING_NS=my-monitoring bash setup.sh
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_cmds kubectl helm envsubst curl

BACKGROUND="${1:-}"

# ─── port-forward 进程管理 ────────────────────────────────────
PF_PIDS=()
cleanup() {
  info "正在清理 port-forward 进程..."
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  pkill -f "kubectl port-forward.*9090:9090" 2>/dev/null || true
  pkill -f "kubectl port-forward.*3000:80"  2>/dev/null || true
  info "清理完成"
}
trap cleanup EXIT

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  setup.sh — Dynamo 测试环境一键搭建                         ║"
echo "║  Ingress + Adapter + HPA + Grafana Dashboard                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
printf "  %-16s %s\n" "NAMESPACE:"     "${NAMESPACE}"
printf "  %-16s %s\n" "MONITORING_NS:" "${MONITORING_NS}"
printf "  %-16s %s\n" "MANIFESTS_DIR:" "${MANIFESTS_DIR}"
echo ""

[[ -d "$MANIFESTS_DIR" ]] || fatal "manifests 目录不存在：${MANIFESTS_DIR}"

# ─── 前置检查 ──────────────────────────────────────────────────
info "检查 Dynamo Pod 状态..."
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || true
echo ""
check_dynamo_ready || warn "存在异常 Pod，继续执行"

info "检查 Prometheus..."
PROM_READY=$(kubectl get pods -n "${MONITORING_NS}" \
  -l "app.kubernetes.io/name=prometheus" \
  --no-headers 2>/dev/null | grep -c "Running" || echo "0")
[[ "${PROM_READY}" -ge 1 ]] \
  || fatal "Prometheus 未就绪（namespace: ${MONITORING_NS}）"
ok "Prometheus 就绪 ✓"

# ═══════════════════════════════════════════════════════════════════
# Stage 1：部署 ingress-nginx
#
# NGINX Ingress Controller（DaemonSet + hostPort 80/443），
# 作为推理 API 统一入口。
# ═══════════════════════════════════════════════════════════════════
section "Stage 1：部署 ingress-nginx"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx

INGRESS_VALUES="${MANIFESTS_DIR}/ingress-nginx-values.yaml"
[[ -f "$INGRESS_VALUES" ]] || fatal "缺少 manifests/ingress-nginx-values.yaml"

if helm status ingress-nginx -n "${INGRESS_NS}" &>/dev/null; then
  info "ingress-nginx 已安装，执行 upgrade..."
  helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NS}" \
    --values "${INGRESS_VALUES}" \
    --wait --timeout 120s
else
  info "安装 ingress-nginx..."
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NS}" \
    --create-namespace \
    --values "${INGRESS_VALUES}" \
    --wait --timeout 120s
fi

kubectl rollout status daemonset/ingress-nginx-controller \
  -n "${INGRESS_NS}" --timeout=120s
ok "ingress-nginx 就绪 ✓"

# ═══════════════════════════════════════════════════════════════════
# Stage 2：部署 prometheus-adapter
#
# 将 Prometheus 指标桥接为 K8s Custom Metrics API，供 HPA 使用：
#   dynamo_component_inflight_requests → dynamo_inflight_requests
#   dynamo_component_kvstats_gpu_cache_usage_percent → dynamo_gpu_cache_usage
#
# 重要：MONITORING_NS 已在 common.sh 中 export，envsubst 可正确替换。
# ═══════════════════════════════════════════════════════════════════
section "Stage 2：部署 prometheus-adapter"

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

PROM_ADAPTER_TEMPLATE="${MANIFESTS_DIR}/prometheus-adapter-values.yaml"
[[ -f "$PROM_ADAPTER_TEMPLATE" ]] || fatal "缺少 manifests/prometheus-adapter-values.yaml"

# 渲染模板（替换 ${MONITORING_NS}）
TMPFILE_ADAPTER=$(mktemp /tmp/prom-adapter-values-XXXXXX.yaml)
envsubst '${MONITORING_NS}' < "${PROM_ADAPTER_TEMPLATE}" > "${TMPFILE_ADAPTER}"

if helm status prometheus-adapter -n "${MONITORING_NS}" &>/dev/null; then
  info "prometheus-adapter 已安装，执行 upgrade..."
  helm upgrade prometheus-adapter \
    prometheus-community/prometheus-adapter \
    --namespace "${MONITORING_NS}" \
    --values "${TMPFILE_ADAPTER}" \
    --wait --timeout 120s
else
  info "安装 prometheus-adapter..."
  helm install prometheus-adapter \
    prometheus-community/prometheus-adapter \
    --namespace "${MONITORING_NS}" \
    --values "${TMPFILE_ADAPTER}" \
    --wait --timeout 120s
fi
rm -f "${TMPFILE_ADAPTER}"
ok "prometheus-adapter 就绪 ✓"

# 验证 Custom Metrics APIService
sleep 5
if kubectl get apiservice v1beta1.custom.metrics.k8s.io &>/dev/null; then
  AVAILABLE=$(kubectl get apiservice v1beta1.custom.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$AVAILABLE" == "True" ]]; then
    ok "Custom Metrics APIService Available=True ✓"
  else
    warn "Custom Metrics APIService Available=${AVAILABLE}（adapter 可能仍在启动）"
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# Stage 3：创建 Ingress 资源
#
# 路由 /v1 → Frontend Service:8000，长超时支持 SSE 流式响应。
# ═══════════════════════════════════════════════════════════════════
section "Stage 3：创建 Ingress 资源"

render_template "${MANIFESTS_DIR}/ingress-frontend.yaml" | kubectl apply -f -
ok "Ingress 已创建"
kubectl get ingress -n "${NAMESPACE}"

# 等待 Ingress 可达
info "验证 Ingress 连通性..."
WAIT_SECS=0
while true; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://localhost/v1/models" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "Ingress 可达（HTTP 200）✓"
    break
  fi
  sleep 5; WAIT_SECS=$((WAIT_SECS+5))
  printf "\r  等待中... %ds（HTTP %s）" "$WAIT_SECS" "$HTTP_CODE"
  if [[ $WAIT_SECS -ge 120 ]]; then
    echo ""
    warn "Ingress 120s 内未返回 200"
    break
  fi
done
echo ""

# ═══════════════════════════════════════════════════════════════════
# Stage 4：创建 HPA 资源
#
# - hpa-frontend:       CPU 60%, min=1 max=3
# - hpa-decode-worker:  dynamo_inflight_requests AverageValue=5, min=1 max=2
# - hpa-prefill-worker: dynamo_inflight_requests AverageValue=5, min=1 max=2
#
# 扩容冷却 30s / 缩容冷却 300s（避免 GPU Pod 频繁调度）
# ═══════════════════════════════════════════════════════════════════
section "Stage 4：创建 HPA 资源"

# Fix: Frontend Deployment 需要 CPU resource requests 才能让 CPU-based HPA 正常工作
# Dynamo operator 默认不设置 requests → HPA 无法计算 CPU 百分比 → 显示 <unknown>
info "为 Frontend Deployment 设置 CPU resource requests..."
kubectl set resources deployment "${DGD_NAME}-frontend" -n "${NAMESPACE}" \
  --requests=cpu=100m --limits=cpu=2000m 2>/dev/null \
  && ok "Frontend CPU requests 已设置 ✓" \
  || warn "无法设置 Frontend CPU requests（HPA CPU 将显示 <unknown>）"

# 等待 Frontend rollout 完成（patch 会触发 Pod 重建）
kubectl rollout status "deployment/${DGD_NAME}-frontend" \
  -n "${NAMESPACE}" --timeout=120s 2>/dev/null || warn "Frontend rollout 超时"

for hpa_template in hpa-frontend.yaml hpa-decode-worker.yaml hpa-prefill-worker.yaml; do
  tmpl="${MANIFESTS_DIR}/${hpa_template}"
  [[ -f "$tmpl" ]] || fatal "缺少 manifests/${hpa_template}"
  render_template "$tmpl" | kubectl apply -f -
  ok "HPA 已创建：${hpa_template%.yaml}"
done

echo ""
kubectl get hpa -n "${NAMESPACE}"

# ═══════════════════════════════════════════════════════════════════
# Stage 5：启动 port-forward（Prometheus :9090, Grafana :3000）
# ═══════════════════════════════════════════════════════════════════
section "Stage 5：启动 port-forward"

# 清理旧 port-forward
pkill -f "kubectl port-forward.*9090:9090" 2>/dev/null || true
pkill -f "kubectl port-forward.*3000:80"  2>/dev/null || true
sleep 1

# Prometheus :9090
kubectl port-forward svc/prometheus-kube-prometheus-prometheus \
  9090:9090 -n "${MONITORING_NS}" --address 127.0.0.1 >/dev/null 2>&1 &
PF_PIDS+=($!)

# Grafana :3000
kubectl port-forward svc/prometheus-grafana \
  3000:80 -n "${MONITORING_NS}" --address 127.0.0.1 >/dev/null 2>&1 &
PF_PIDS+=($!)

sleep 4

# 验证
PROM_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  "http://localhost:9090/-/ready" 2>/dev/null || echo "000")
GRAFANA_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  "http://localhost:3000/api/health" 2>/dev/null || echo "000")

[[ "$PROM_HTTP" =~ ^(200|204)$ ]] && ok "Prometheus :9090 ✓" \
  || warn "Prometheus HTTP ${PROM_HTTP}"
[[ "$GRAFANA_HTTP" == "200" ]] && ok "Grafana :3000 ✓" \
  || warn "Grafana HTTP ${GRAFANA_HTTP}"

# 获取 Grafana 密码
GRAFANA_PASS=$(kubectl get secret prometheus-grafana \
  -n "${MONITORING_NS}" \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<获取失败>")

echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│${NC}  Prometheus:   ${CYAN}http://localhost:9090${NC}"
echo -e "${BOLD}│${NC}  Grafana:      ${CYAN}http://localhost:3000${NC}"
echo -e "${BOLD}│${NC}  Grafana 账号: ${GREEN}admin${NC}"
echo -e "${BOLD}│${NC}  Grafana 密码: ${GREEN}${GRAFANA_PASS}${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────┘${NC}"

# ═══════════════════════════════════════════════════════════════════
# Stage 6：自动创建 Grafana Dashboard
#
# 通过 Grafana HTTP API 导入预定义的 Dashboard JSON。
# 包含 HPA 副本数、Inflight/Pod、Latency、KV Cache、Router 分布等面板。
# ═══════════════════════════════════════════════════════════════════
section "Stage 6：创建 Grafana Dashboard"

GRAFANA_URL="http://localhost:3000"
GRAFANA_USER="admin"
DASHBOARD_TEMPLATE="${SCRIPT_DIR}/grafana/dynamo-dashboard.json"

if [[ ! -f "$DASHBOARD_TEMPLATE" ]]; then
  warn "Dashboard 模板不存在：${DASHBOARD_TEMPLATE}，跳过"
else
  info "导入 Dashboard（namespace=${NAMESPACE}）..."
  IMPORT_RESP=$(mktemp /tmp/grafana-import-XXXXXX.json)

  IMPORT_HTTP=$(sed "s/__NAMESPACE__/${NAMESPACE}/g" "$DASHBOARD_TEMPLATE" \
    | curl -s -o "$IMPORT_RESP" -w "%{http_code}" \
        -X POST "${GRAFANA_URL}/api/dashboards/db" \
        -H "Content-Type: application/json" \
        -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
        -d @- 2>/dev/null || echo "000")

  if [[ "$IMPORT_HTTP" == "200" ]]; then
    DASH_URL=$(python3 -c "
import json
with open('${IMPORT_RESP}') as f:
    d = json.load(f)
print(d.get('url',''))
" 2>/dev/null || echo "")
    ok "Dashboard 导入成功 ✓"
    [[ -n "$DASH_URL" ]] && echo -e "  打开：${CYAN}${GRAFANA_URL}${DASH_URL}${NC}"
  else
    ERRMSG=$(python3 -c "
import json
with open('${IMPORT_RESP}') as f:
    d = json.load(f)
print(d.get('message',''))
" 2>/dev/null || echo "")
    warn "Dashboard 导入 HTTP ${IMPORT_HTTP}：${ERRMSG}"
    warn "可手动导入：Grafana → Dashboards → Import → 上传 grafana/dynamo-dashboard.json"
  fi
  rm -f "$IMPORT_RESP"
fi

# ═══════════════════════════════════════════════════════════════════
# 完成汇总
# ═══════════════════════════════════════════════════════════════════
section "部署完成"

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo -e "${BOLD}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│${NC}  推理 API:  ${CYAN}http://${HOST_IP}/v1/chat/completions${NC}"
echo -e "${BOLD}│${NC}  Prometheus: ${CYAN}http://localhost:9090${NC}"
echo -e "${BOLD}│${NC}  Grafana:    ${CYAN}http://localhost:3000${NC}  (admin / ${GRAFANA_PASS})"
echo -e "${BOLD}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo "  下一步："
echo "    bash test.sh                  # 负载测试（触发 HPA + 观察路由分发）"
echo ""
echo "  观察命令（另开终端）："
echo "    watch -n 5 'kubectl get hpa,pods -n ${NAMESPACE}'"
echo "    kubectl get events -n ${NAMESPACE} --watch --field-selector reason=SuccessfulRescale"
echo ""

if [[ "$BACKGROUND" == "--background" ]]; then
  info "后台模式：port-forward PID=${PF_PIDS[*]}"
  info "停止：kill ${PF_PIDS[*]}"
  trap - EXIT
else
  echo -e "${GREEN}${BOLD}port-forward 正在运行，按 Ctrl+C 停止。${NC}"
  echo ""
  while true; do
    sleep 30
    for pid in "${PF_PIDS[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        warn "port-forward ${pid} 已停止，重新启动..."
        kubectl port-forward svc/prometheus-kube-prometheus-prometheus \
          9090:9090 -n "${MONITORING_NS}" --address 127.0.0.1 >/dev/null 2>&1 &
        PF_PIDS+=($!)
        kubectl port-forward svc/prometheus-grafana \
          3000:80 -n "${MONITORING_NS}" --address 127.0.0.1 >/dev/null 2>&1 &
        PF_PIDS+=($!)
        break
      fi
    done
  done
fi
