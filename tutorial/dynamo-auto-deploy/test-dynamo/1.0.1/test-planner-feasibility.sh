#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# test-planner-feasibility.sh — 验证 Planner DGD 可行性
#
# 验证项 (8 项):
#   1. Planner Pod 存在且 Running
#   2. Planner ConfigMap 已挂载且包含 raw_data.json
#   3. Planner ServiceAccount + RBAC 由 Operator 自动创建
#   4. Planner 能成功调用 K8s API (PATCH dgdsa scale)
#   5. Planner 日志中出现 "throughput_adjustment" / scaling decision
#   6. PROMETHEUS_ENDPOINT 已注入 Planner 容器
#   7. Prometheus 能查询到 dynamo_planner_* metrics
#   8. Grafana planner-dashboard ConfigMap 存在 → 已被 Grafana sidecar 加载
#
# 所有断言失败都会被计入 _FAIL，最终 print_summary 决定退出码。
# 测试期间会启动 port-forward (Prometheus 9090, Grafana 3000)。
#
# 用法:
#   bash test-planner-feasibility.sh
#   DGD_PLANNER_NAME=my-planner bash test-planner-feasibility.sh
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
trap cleanup_portforwards EXIT

require_cmds kubectl curl python3

section "Planner 可行性测试 — DGD: ${DGD_PLANNER_NAME}"

# ── 1. Planner Pod ─────────────────────────────────────────────
section "1/8 — Planner Pod 存在且 Running"
PLANNER_POD=$(kubectl get pods -n "$NAMESPACE" \
  -l nvidia.com/dynamo-component-type=planner \
  --no-headers 2>/dev/null | head -1 | awk '{print $1}')

if [[ -z "$PLANNER_POD" ]]; then
  # fallback: 按名字模糊匹配
  PLANNER_POD=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -iE 'planner' | head -1 | awk '{print $1}')
fi

if [[ -z "$PLANNER_POD" ]]; then
  fail "未找到 Planner Pod  (DGD ${DGD_PLANNER_NAME} 是否已部署?)"
  print_summary; exit 1
fi
ok "Planner Pod: ${PLANNER_POD}"

PHASE=$(kubectl get pod "$PLANNER_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
if [[ "$PHASE" == "Running" ]]; then pass "Phase=Running"
else fail "Phase=${PHASE}"; fi

# ── 2. ConfigMap 挂载 ─────────────────────────────────────────
section "2/8 — Planner profile data ConfigMap 已挂载"
if kubectl exec "$PLANNER_POD" -n "$NAMESPACE" -- \
     ls /workspace/profiling_results 2>/dev/null | grep -qE 'raw_data.json|disagg|interpolation'; then
  pass "/workspace/profiling_results 包含 profile 数据"
else
  fail "ConfigMap 未挂载或路径错误"
  kubectl exec "$PLANNER_POD" -n "$NAMESPACE" -- ls -la /workspace/profiling_results 2>&1 | head -10 || true
fi

# ── 3. ServiceAccount + RBAC ──────────────────────────────────
section "3/8 — Planner ServiceAccount + RBAC"
SA=$(kubectl get pod "$PLANNER_POD" -n "$NAMESPACE" -o jsonpath='{.spec.serviceAccountName}')
ok "ServiceAccount: ${SA}"
if kubectl get clusterrolebinding -o name 2>/dev/null | grep -qE "planner|${SA}"; then
  pass "ClusterRoleBinding 存在"
else
  if kubectl get rolebinding -n "$NAMESPACE" -o name 2>/dev/null | grep -qiE "planner"; then
    pass "RoleBinding (namespace-scope) 存在"
  else
    fail "未找到 Planner 相关的 (Cluster)RoleBinding"
  fi
fi

# ── 4. 能否 PATCH dgdsa scale (用 SA 试一次 SelfSubjectAccessReview) ─
section "4/8 — Planner 是否有权限 PATCH dgdsa/scale"
CAN_PATCH=$(kubectl auth can-i patch dynamographdeploymentscalingadapters/scale \
  --as="system:serviceaccount:${NAMESPACE}:${SA}" \
  -n "$NAMESPACE" 2>/dev/null || echo "no")
if [[ "$CAN_PATCH" == "yes" ]]; then
  pass "Planner SA 有权 PATCH dgdsa/scale"
else
  warn "Planner SA 无 PATCH dgdsa/scale 权限 (=${CAN_PATCH}) — 可能 Operator RBAC 模板缺项"
  fail "权限不足"
fi

# ── 5. Planner 日志中的调度决策 ────────────────────────────────
section "5/8 — Planner 日志中的 scaling 决策"
LOG=$(kubectl logs "$PLANNER_POD" -n "$NAMESPACE" --tail=200 2>/dev/null || echo "")
if echo "$LOG" | grep -qiE 'throughput_adjustment|scaling|replicas|interval'; then
  pass "Planner 已开始调度循环"
  echo "$LOG" | grep -iE 'throughput_adjustment|scal|replicas' | tail -5 | sed 's/^/    /'
else
  warn "未在日志中检测到调度循环 (可能刚启动, 等 60s 后重试)"
  fail "无调度日志"
fi

# ── 6. PROMETHEUS_ENDPOINT env ────────────────────────────────
section "6/8 — Planner 容器 PROMETHEUS_ENDPOINT 已注入"
PROM_INJECTED=$(kubectl get pod "$PLANNER_POD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].env[?(@.name=="PROMETHEUS_ENDPOINT")].value}' 2>/dev/null)
if [[ -n "$PROM_INJECTED" ]]; then
  pass "PROMETHEUS_ENDPOINT=${PROM_INJECTED}"
else
  fail "PROMETHEUS_ENDPOINT 未注入 — 检查 dynamo-platform-values.yaml 中 dynamo.metrics.prometheusEndpoint"
fi

# ── 7. Prometheus 中的 planner metrics ────────────────────────
section "7/8 — Prometheus 中的 dynamo_planner_* metrics"
port_forward_prometheus
sleep 3
RAW=$(query_prom 'count by (__name__) ({__name__=~"dynamo_planner.*"})')
COUNT=$(echo "$RAW" | python3 -c '
import json,sys
try: d=json.load(sys.stdin); print(len(d.get("data",{}).get("result",[])))
except: print(0)' 2>/dev/null || echo 0)
if [[ "$COUNT" -gt 0 ]]; then
  pass "Prometheus 中检测到 ${COUNT} 个 dynamo_planner_* metric"
  echo "$RAW" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d.get("data",{}).get("result",[])[:10]:
    print(f"    {r[\"metric\"][\"__name__\"]}")
' 2>/dev/null || true
else
  warn "无 dynamo_planner_* metrics — 检查 PodMonitor / scrape_configs"
  fail "无 planner metrics"
fi

# ── 8. Grafana planner dashboard ──────────────────────────────
section "8/8 — Grafana planner-dashboard ConfigMap 已加载"
if kubectl get cm -n "$MONITORING_NS" grafana-planner-dashboard &>/dev/null; then
  pass "ConfigMap grafana-planner-dashboard 存在"
  port_forward_grafana
  echo "    → 打开浏览器: http://localhost:3000  (admin/admin)"
  echo "    → Dashboards → Browse → 'Dynamo Planner'"
  echo "    → 验证以下面板有数据:"
  echo "      - Replicas (prefill / decode)"
  echo "      - Decision interval / Throughput"
  echo "      - Scaling actions count"
else
  fail "ConfigMap grafana-planner-dashboard 不存在 — 重新运行 01-deploy"
fi

print_summary
