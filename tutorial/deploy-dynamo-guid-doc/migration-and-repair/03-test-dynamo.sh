#!/bin/bash
# ============================================================
# Dynamo 推理服务 + HPA 自动扩容 + Router 路由 测试脚本
# 适用于：验证 Dynamo 部署后的完整功能链路
# 前提：脚本 01（Prometheus）和 02（Dynamo）已执行完毕
# ============================================================
set -euo pipefail

# ── 颜色输出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}\n"; }

# ── 可配置变量 ──────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-dynamo-system}"
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-0.6B}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
# 推理 API endpoint（优先使用 Ingress，fallback 到 port-forward）
ENDPOINT="${ENDPOINT:-}"

# 负载测试参数
CONCURRENCY="${CONCURRENCY:-10}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-100}"
MAX_TOKENS="${MAX_TOKENS:-100}"

# ── 测试模式选择 ────────────────────────────────────────────
MODE="${1:-all}"

usage() {
  echo "用法: $0 [mode]"
  echo ""
  echo "可选模式："
  echo "  health     - 仅健康检查（快速验证环境）"
  echo "  api        - API 功能测试（验证推理能力）"
  echo "  router     - Router 路由验证（验证 Disaggregated 模式）"
  echo "  metrics    - Prometheus 指标验证"
  echo "  load       - 负载测试（触发 HPA 扩容）"
  echo "  hpa        - HPA 扩容验证（需配合 load 测试）"
  echo "  all        - 执行所有测试（默认）"
  echo ""
  echo "环境变量："
  echo "  NAMESPACE       - Dynamo namespace (默认: dynamo-system)"
  echo "  MODEL_NAME      - 模型名称 (默认: Qwen/Qwen3-0.6B)"
  echo "  ENDPOINT        - 推理 API 地址 (默认: 自动检测)"
  echo "  CONCURRENCY     - 负载测试并发数 (默认: 10)"
  echo "  TOTAL_REQUESTS  - 负载测试总请求数 (默认: 100)"
  echo "  MAX_TOKENS      - 每个请求最大 token 数 (默认: 100)"
}

if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  usage
  exit 0
fi

# ── KUBECONFIG 自动检测（sudo -i 切换到 root 时 ~/.kube/config 可能不存在）
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
    warn "使用 /etc/kubernetes/admin.conf 作为 KUBECONFIG"
  fi
fi

# ── 辅助函数：获取推理 API endpoint ─────────────────────────
PF_PID=""
setup_endpoint() {
  if [[ -n "$ENDPOINT" ]]; then
    info "使用指定 endpoint: ${ENDPOINT}"
    return
  fi

  # 尝试 Ingress
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/v1/models 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    ENDPOINT="http://localhost/v1"
    info "使用 Ingress endpoint: ${ENDPOINT}"
    return
  fi

  # Fallback: port-forward
  info "Ingress 不可用，启动 port-forward..."
  # 清理可能存在的旧 port-forward
  pkill -f "kubectl port-forward.*vllm-v1-disagg-router-frontend.*8000" 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/vllm-v1-disagg-router-frontend 8000:8000 -n "${NAMESPACE}" &
  PF_PID=$!
  sleep 4
  ENDPOINT="http://localhost:8000/v1"
  info "使用 port-forward endpoint: ${ENDPOINT}"
}

cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill $PF_PID 2>/dev/null || true
  fi
  # 清理所有后台 port-forward
  pkill -f "kubectl port-forward.*9090:9090" 2>/dev/null || true
  pkill -f "kubectl port-forward.*3000:80" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# 测试 1：健康检查
# ============================================================
test_health() {
  section "测试 1：集群健康检查"

  local PASS=0
  local FAIL=0

  # 1.1 K8s 节点
  echo "── 1.1 K8s 节点状态 ──"
  kubectl get nodes -o wide
  echo ""
  ((PASS++))

  # 1.2 Dynamo Pod 状态
  echo "── 1.2 Dynamo Pod 状态 ──"
  kubectl get pods -n "${NAMESPACE}" -o wide
  echo ""

  NOT_READY=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v "Running\|Completed" | wc -l)
  if [[ "$NOT_READY" -eq 0 ]]; then
    info "所有 Dynamo Pod 正常 ✓"; ((PASS++))
  else
    error "有 ${NOT_READY} 个 Pod 异常 ✗"; ((FAIL++))
    kubectl get pods -n "${NAMESPACE}" --no-headers | grep -v "Running\|Completed"
  fi
  echo ""

  # 1.3 Monitoring Pod 状态
  echo "── 1.3 Monitoring Pod 状态 ──"
  kubectl get pods -n "${MONITORING_NS}" -o wide
  echo ""

  NOT_READY_MON=$(kubectl get pods -n "${MONITORING_NS}" --no-headers 2>/dev/null \
    | grep -v "Running\|Completed" | wc -l)
  if [[ "$NOT_READY_MON" -eq 0 ]]; then
    info "所有 Monitoring Pod 正常 ✓"; ((PASS++))
  else
    warn "Monitoring 有 ${NOT_READY_MON} 个 Pod 异常"; ((FAIL++))
  fi
  echo ""

  # 1.4 DGD 状态
  echo "── 1.4 DGD 状态 ──"
  kubectl get dynamographdeployment -n "${NAMESPACE}"
  DGD_READY=$(kubectl get dynamographdeployment vllm-v1-disagg-router -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$DGD_READY" == "True" ]]; then
    info "DGD Ready=True ✓"; ((PASS++))
  else
    error "DGD Ready=${DGD_READY} ✗"; ((FAIL++))
  fi
  echo ""

  # 1.5 GPU 分配
  echo "── 1.5 GPU 分配 ──"
  kubectl get pods -n "${NAMESPACE}" -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,GPU:.spec.containers[0].resources.limits.nvidia\.com/gpu'
  echo ""
  ((PASS++))

  # 1.6 HPA 状态
  echo "── 1.6 HPA 状态 ──"
  kubectl get hpa -n "${NAMESPACE}" 2>/dev/null || info "未配置 HPA"
  echo ""

  # 1.7 Services
  echo "── 1.7 Services ──"
  kubectl get svc -n "${NAMESPACE}"
  echo ""

  echo "健康检查结果：${PASS} 通过, ${FAIL} 失败"
}

# ============================================================
# 测试 2：API 功能测试
# ============================================================
test_api() {
  section "测试 2：API 功能测试"
  setup_endpoint

  local PASS=0
  local FAIL=0

  # 2.1 模型列表
  echo "── 2.1 查询模型列表 ──"
  MODELS=$(curl -s --max-time 15 "${ENDPOINT}/models" 2>/dev/null)
  if echo "$MODELS" | python3 -c "import sys,json; d=json.load(sys.stdin); assert len(d['data'])>0" 2>/dev/null; then
    info "模型列表正常 ✓"
    echo "$MODELS" | python3 -m json.tool 2>/dev/null
    ((PASS++))
  else
    error "模型列表异常 ✗"
    echo "$MODELS"
    ((FAIL++))
  fi
  echo ""

  # 2.2 Chat Completions（非流式）
  echo "── 2.2 Chat Completions（非流式） ──"
  RESPONSE=$(curl -s --max-time 60 "${ENDPOINT}/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "What is 2+3? Answer with just the number."}],
      "max_tokens": 20
    }' 2>/dev/null)

  if echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['choices'][0]['message']['content']" 2>/dev/null; then
    info "非流式推理正常 ✓"
    CONTENT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null)
    echo "  Response: ${CONTENT}"
    ((PASS++))
  else
    error "非流式推理失败 ✗"
    echo "$RESPONSE"
    ((FAIL++))
  fi
  echo ""

  # 2.3 Chat Completions（流式）
  echo "── 2.3 Chat Completions（流式） ──"
  STREAM_OUTPUT=$(curl -s --max-time 60 "${ENDPOINT}/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "Say hello in one word."}],
      "max_tokens": 10,
      "stream": true
    }' 2>/dev/null)

  if echo "$STREAM_OUTPUT" | grep -q "data:"; then
    info "流式推理正常 ✓"
    # 提取流式内容
    echo "$STREAM_OUTPUT" | grep "^data: " | head -5
    ((PASS++))
  else
    error "流式推理失败 ✗"
    echo "$STREAM_OUTPUT" | head -5
    ((FAIL++))
  fi
  echo ""

  # 2.4 多轮对话
  echo "── 2.4 多轮对话 ──"
  MULTI_RESPONSE=$(curl -s --max-time 60 "${ENDPOINT}/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [
        {"role": "user", "content": "My name is Alice."},
        {"role": "assistant", "content": "Hello Alice! Nice to meet you."},
        {"role": "user", "content": "What is my name?"}
      ],
      "max_tokens": 30
    }' 2>/dev/null)

  if echo "$MULTI_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['choices'][0]['message']['content']" 2>/dev/null; then
    info "多轮对话正常 ✓"
    CONTENT=$(echo "$MULTI_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null)
    echo "  Response: ${CONTENT}"
    ((PASS++))
  else
    error "多轮对话失败 ✗"
    ((FAIL++))
  fi
  echo ""

  echo "API 测试结果：${PASS} 通过, ${FAIL} 失败"
}

# ============================================================
# 测试 3：Router 路由验证
# ============================================================
test_router() {
  section "测试 3：Disaggregated Router 路由验证"
  setup_endpoint

  echo "── 3.1 发送测试请求并观察 Worker 日志 ──"
  info "发送 5 个请求，验证 Prefill 和 Decode 都参与处理..."
  echo ""

  for i in $(seq 1 5); do
    echo -n "  Request #${i}: "
    RESP=$(curl -s --max-time 60 "${ENDPOINT}/chat/completions" \
      -H "Content-Type: application/json" \
      -d '{
        "model": "'"${MODEL_NAME}"'",
        "messages": [{"role": "user", "content": "Count from 1 to '"$i"'."}],
        "max_tokens": 30
      }' 2>/dev/null)

    CONTENT=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'][:80])" 2>/dev/null || echo "ERROR")
    echo "${CONTENT}"
  done
  echo ""

  echo "── 3.2 检查 Worker Pod 活跃状态 ──"
  echo ""
  echo "PrefillWorker 最新日志："
  kubectl logs -l nvidia.com/dynamo-component-type=worker -n "${NAMESPACE}" \
    --prefix=true --tail=5 2>/dev/null | grep -i "prefill" | tail -3 || info "（无 prefill 关键字日志，可能使用不同格式）"
  echo ""
  echo "DecodeWorker 最新日志："
  kubectl logs -l nvidia.com/dynamo-component-type=worker -n "${NAMESPACE}" \
    --prefix=true --tail=5 2>/dev/null | grep -i "decode" | tail -3 || info "（无 decode 关键字日志，可能使用不同格式）"
  echo ""

  echo "── 3.3 KV Cache 命中率测试（发送重复 prompt） ──"
  info "发送 10 个相同 prompt，触发 KV Cache 命中..."
  for i in $(seq 1 10); do
    curl -s --max-time 60 "${ENDPOINT}/chat/completions" \
      -H "Content-Type: application/json" \
      -d '{
        "model": "'"${MODEL_NAME}"'",
        "messages": [{"role": "user", "content": "What is Kubernetes?"}],
        "max_tokens": 20
      }' > /dev/null 2>&1
    echo -n "."
  done
  echo ""
  info "KV Cache 命中率测试完成，请在 Prometheus/Grafana 中查看 dynamo_component_kvstats_gpu_prefix_cache_hit_rate"
  echo ""
}

# ============================================================
# 测试 4：Prometheus 指标验证
# ============================================================
test_metrics() {
  section "测试 4：Prometheus 指标验证"

  # 启动 Prometheus port-forward
  pkill -f "kubectl port-forward.*9090:9090" 2>/dev/null || true
  sleep 1
  kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n "${MONITORING_NS}" &
  PROM_PF_PID=$!
  sleep 4

  local PASS=0
  local FAIL=0

  # 4.1 PodMonitor
  echo "── 4.1 PodMonitor 检查 ──"
  kubectl get podmonitor -n "${NAMESPACE}" 2>/dev/null || warn "未发现 PodMonitor"
  echo ""

  # 4.2 Scrape Targets
  echo "── 4.2 Prometheus Targets 中的 Dynamo endpoint ──"
  TARGETS=$(curl -s --max-time 10 "http://localhost:9090/api/v1/targets" 2>/dev/null)
  DYNAMO_TARGETS=$(echo "$TARGETS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
active = data.get('data', {}).get('activeTargets', [])
dynamo_t = [t for t in active if '${NAMESPACE}' in json.dumps(t.get('labels', {}))]
for t in dynamo_t:
    health = t.get('health', 'unknown')
    url = t.get('scrapeUrl', 'unknown')
    print(f'  [{health}] {url}')
if not dynamo_t:
    print('  (none)')
" 2>/dev/null || echo "  (查询失败)")
  echo "$DYNAMO_TARGETS"
  echo ""

  # 4.3 Dynamo 指标列表
  echo "── 4.3 已采集的 Dynamo 指标 ──"
  METRIC_NAMES=$(curl -s --max-time 10 'http://localhost:9090/api/v1/label/__name__/values' 2>/dev/null \
    | python3 -c "import sys,json; names=json.load(sys.stdin).get('data',[]); [print(f'  {n}') for n in names if 'dynamo' in n.lower()]" 2>/dev/null || echo "  (查询失败)")
  if [[ -n "$METRIC_NAMES" ]]; then
    echo "$METRIC_NAMES"
    ((PASS++))
  else
    warn "未发现 dynamo 相关指标，请先发送推理请求"
    ((FAIL++))
  fi
  echo ""

  # 4.4 关键指标查询
  echo "── 4.4 关键指标当前值 ──"
  for metric in "dynamo_component_inflight_requests" \
                "dynamo_component_kvstats_gpu_cache_usage_percent" \
                "dynamo_component_kvstats_active_blocks" \
                "dynamo_frontend_requests_total"; do
    VALUE=$(curl -s --max-time 5 "http://localhost:9090/api/v1/query?query=${metric}" 2>/dev/null \
      | python3 -c "import sys,json; r=json.load(sys.stdin).get('data',{}).get('result',[]); print(len(r),'个序列' if r else '(无数据)')" 2>/dev/null || echo "(查询失败)")
    echo "  ${metric}: ${VALUE}"
  done
  echo ""

  # 4.5 GPU 指标（DCGM）
  echo "── 4.5 GPU 指标（DCGM Exporter） ──"
  GPU_METRICS=$(curl -s --max-time 5 'http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL' 2>/dev/null \
    | python3 -c "
import sys,json
r = json.load(sys.stdin).get('data',{}).get('result',[])
for item in r:
    gpu = item['metric'].get('gpu','?')
    val = item['value'][1]
    print(f'  GPU {gpu}: {val}% 利用率')
if not r: print('  (无数据)')
" 2>/dev/null || echo "  (查询失败)")
  echo "$GPU_METRICS"
  echo ""

  kill $PROM_PF_PID 2>/dev/null || true

  echo "指标测试结果：${PASS} 通过, ${FAIL} 失败"
}

# ============================================================
# 测试 5：负载测试
# ============================================================
test_load() {
  section "测试 5：负载测试（并发=${CONCURRENCY}, 总请求=${TOTAL_REQUESTS}）"
  setup_endpoint

  CHAT_ENDPOINT="${ENDPOINT}/chat/completions"

  # 不同的 prompt
  PROMPTS=(
    "Explain the theory of relativity in detail"
    "Write a Python function to sort a list"
    "What is Kubernetes and how does it work"
    "Describe the architecture of a neural network"
    "Tell me about the history of computing"
    "How does HTTP/2 differ from HTTP/1.1"
    "Explain quantum computing in simple terms"
    "Write a REST API design for a todo app"
    "What are the benefits of microservices"
    "Describe the MapReduce programming model"
  )

  # 重复 prompt（测试 KV Cache 命中）
  REPEATED_PROMPTS=(
    "Explain the theory of relativity in detail"
    "Write a Python function to sort a list"
    "What is Kubernetes and how does it work"
  )

  SUCCESS=0
  FAIL_COUNT=0
  START_TIME=$(date +%s)

  send_request() {
    local req_id=$1

    # 70% 重复 prompt，30% 随机
    if (( RANDOM % 10 < 7 )); then
      local prompt="${REPEATED_PROMPTS[$((RANDOM % ${#REPEATED_PROMPTS[@]}))]}"
    else
      local prompt="${PROMPTS[$((RANDOM % ${#PROMPTS[@]}))]}"
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" --max-time 120 "${CHAT_ENDPOINT}" \
      -H "Content-Type: application/json" \
      -d '{
        "model": "'"${MODEL_NAME}"'",
        "messages": [{"role": "user", "content": "'"${prompt}"'"}],
        "max_tokens": '"${MAX_TOKENS}"'
      }' 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" == "200" ]]; then
      echo "[$(date +%H:%M:%S)] Request #${req_id} ✅ (HTTP ${http_code})"
      return 0
    else
      echo "[$(date +%H:%M:%S)] Request #${req_id} ❌ (HTTP ${http_code})"
      return 1
    fi
  }

  info "开始发送请求..."
  echo ""

  PIDS=()
  for ((i=1; i<=TOTAL_REQUESTS; i++)); do
    send_request $i &
    PIDS+=($!)

    # 控制并发数
    while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do
      sleep 0.1
    done
  done

  # 等待所有请求完成
  for pid in "${PIDS[@]}"; do
    wait $pid && ((SUCCESS++)) || ((FAIL_COUNT++))
  done

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  echo ""
  echo "============================================"
  echo "  负载测试结果"
  echo "============================================"
  echo "  总请求数:  ${TOTAL_REQUESTS}"
  echo "  成功:      ${SUCCESS}"
  echo "  失败:      ${FAIL_COUNT}"
  echo "  总耗时:    ${DURATION}s"
  if [[ $DURATION -gt 0 ]]; then
    echo "  QPS:       $(echo "scale=2; ${TOTAL_REQUESTS}/${DURATION}" | bc 2>/dev/null || echo "N/A")"
  fi
  echo "============================================"
}

# ============================================================
# 测试 6：HPA 扩容验证（实时监控）
# ============================================================
test_hpa() {
  section "测试 6：HPA 扩容验证"

  echo "── 6.1 当前 HPA 状态 ──"
  kubectl get hpa -n "${NAMESPACE}" 2>/dev/null || { warn "未配置 HPA"; return; }
  echo ""

  echo "── 6.2 HPA 详细信息 ──"
  kubectl describe hpa -n "${NAMESPACE}" 2>/dev/null | grep -A5 "Metrics:\|Events:\|Conditions:" || true
  echo ""

  echo "── 6.3 当前 Deployment 副本数 ──"
  kubectl get deployment -n "${NAMESPACE}" 2>/dev/null
  echo ""

  echo "── 6.4 HPA 相关事件 ──"
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null \
    | grep -iE "hpa|scale|replica|autoscal" | tail -10 || info "（无 HPA 相关事件）"
  echo ""

  echo "── 6.5 Custom Metrics API 状态 ──"
  kubectl get apiservice v1beta1.custom.metrics.k8s.io 2>/dev/null || warn "custom.metrics API 未注册"
  echo ""

  # 查询自定义指标值
  echo "── 6.6 自定义指标当前值 ──"
  CUSTOM_METRICS=$(kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/pods/*/dynamo_inflight_requests" 2>/dev/null)
  if [[ -n "$CUSTOM_METRICS" ]]; then
    echo "$CUSTOM_METRICS" | python3 -m json.tool 2>/dev/null || echo "$CUSTOM_METRICS"
  else
    warn "dynamo_inflight_requests 指标暂无数据（需要先发送推理请求）"
  fi
  echo ""

  info "提示：要验证 HPA 扩容，请在另一个终端运行："
  echo "  CONCURRENCY=20 TOTAL_REQUESTS=300 MAX_TOKENS=200 bash $0 load"
  echo ""
  info "同时在第三个终端观察："
  echo "  watch -n 5 'kubectl get hpa -n ${NAMESPACE} && echo --- && kubectl get pods -n ${NAMESPACE}'"
}

# ============================================================
# 主入口
# ============================================================
echo "============================================================"
echo "  Dynamo 测试脚本 | 模式: ${MODE}"
echo "============================================================"
echo "  Namespace:     ${NAMESPACE}"
echo "  Model:         ${MODEL_NAME}"
echo "  Monitoring:    ${MONITORING_NS}"
echo "============================================================"

case "$MODE" in
  health)  test_health ;;
  api)     test_api ;;
  router)  test_router ;;
  metrics) test_metrics ;;
  load)    test_load ;;
  hpa)     test_hpa ;;
  all)
    test_health
    test_api
    test_router
    test_metrics
    test_hpa
    echo ""
    section "所有测试完成"
    info "如需执行负载测试（会产生持续流量），请单独运行："
    echo "  CONCURRENCY=20 TOTAL_REQUESTS=300 bash $0 load"
    ;;
  *)
    error "未知模式: ${MODE}"
    usage
    exit 1
    ;;
esac
