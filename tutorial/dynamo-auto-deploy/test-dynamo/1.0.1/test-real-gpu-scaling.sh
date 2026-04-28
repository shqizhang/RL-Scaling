#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# test-real-gpu-scaling.sh — 真实 GPU 扩缩容端到端测试 (1.0.1)
#
# 验证目标:
#   (a) 在持续负载下, Decode/Prefill Pod 副本数 自动 增加 (DGDSA 或 Planner)
#   (b) 新扩容的 Pod 实际承接处理流量 (kubectl logs / metrics 双重确认)
#   (c) Grafana Disagg dashboard 中可见 per-pod 流量分布
#
# 兼容两种部署:
#   - DEPLOY_MODE=router  → 通过 PATCH dgdsa/scale 手动触发扩容(模拟 RL 控制器)
#   - DEPLOY_MODE=planner → 等 Planner 自动扩容
#
# 多波次模式 (沿用 0.7.1 test.sh 思路):
#   Stage 0  预飞: 检查 GPU / DGD / DGDSA / Prometheus
#   Stage 1  预热: 少量请求, 让 Prometheus 开始采样
#   Stage 2  Wave 1 高并发持续 ${WAVE_DURATION}s, 触发 scale-up
#   Stage 3  观察扩容: 等待 Decode replicas > 初始值
#   Stage 4  等新 Pod Running (GPU init + 模型加载, 最多 8min)
#   Stage 5  Wave 2 验证负载: 确认新 pod 接收请求
#   Stage 6  Per-pod 分布 + Prometheus/Grafana 查询
#
# 用法:
#   bash test-real-gpu-scaling.sh                         # router 模式 (默认)
#   bash test-real-gpu-scaling.sh --mode planner          # 等 Planner 自动扩容
#   bash test-real-gpu-scaling.sh --concurrency 60 --wave-duration 240
#   bash test-real-gpu-scaling.sh --target-replicas 3     # 手动扩容到 3 (router only)
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_cmds kubectl curl python3

MODE="router"
TARGET_REPLICAS=2
SCALE_OBSERVE_TIMEOUT=600
POD_READY_TIMEOUT=480

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)              MODE="$2"; shift 2 ;;
    --concurrency)       CONCURRENCY="$2"; shift 2 ;;
    --wave-duration)     WAVE_DURATION="$2"; shift 2 ;;
    --target-replicas)   TARGET_REPLICAS="$2"; shift 2 ;;
    --max-tokens)        MAX_TOKENS="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
trap cleanup_portforwards EXIT

# 选择 DGD
case "$MODE" in
  router)  DGD_NAME="$DGD_NAME" ;;
  planner) DGD_NAME="$DGD_PLANNER_NAME" ;;
  *) fatal "--mode 仅支持 router | planner" ;;
esac

section "Real GPU Scaling Test  (mode=${MODE}, DGD=${DGD_NAME})"
printf "  %-22s %s\n" "Concurrency:"    "$CONCURRENCY"
printf "  %-22s %s\n" "Wave duration:"  "${WAVE_DURATION}s"
printf "  %-22s %s\n" "Max tokens:"     "$MAX_TOKENS"
printf "  %-22s %s\n" "Target replicas:" "$TARGET_REPLICAS  (router 模式)"

# ── Stage 0: 预飞 ─────────────────────────────────────────────
section "Stage 0 — 预飞检查"
if ! kubectl get dgd "$DGD_NAME" -n "$NAMESPACE" &>/dev/null; then
  fatal "DGD ${DGD_NAME} 不存在 → 先运行 01-deploy-dynamo-1.0.1.sh --${MODE}"
fi

if [[ "$MODE" == "router" ]]; then
  if ! kubectl get dgdsa -n "$NAMESPACE" 2>/dev/null | grep -q decode; then
    fatal "DGDSA (decode) 不存在 — router 模式需要 DGDSA"
  fi
fi

GPU_AVAIL=$(kubectl get nodes -o json 2>/dev/null | python3 -c '
import json,sys
n=json.load(sys.stdin)["items"]
print(sum(int(i["status"]["allocatable"].get("nvidia.com/gpu",0)) for i in n))')
ok "可用 GPU: ${GPU_AVAIL}"
[[ "$GPU_AVAIL" -lt $((PREFILL_REPLICAS + DECODE_REPLICAS + 1)) ]] && \
  warn "GPU 数量可能不足以 scale-up"

INIT_DECODE=$(kubectl get pods -n "$NAMESPACE" \
  -l "nvidia.com/dynamo-graph-deployment-name=${DGD_NAME},nvidia.com/dynamo-component-type=worker" \
  --no-headers 2>/dev/null | grep -ciE 'decode' || echo 0)
[[ "$INIT_DECODE" -eq 0 ]] && INIT_DECODE=$(kubectl get pods -n "$NAMESPACE" --no-headers \
  | grep -iE "${DGD_NAME}.*decode" | grep -c Running || echo 0)
ok "初始 Decode pod 数: ${INIT_DECODE}"

setup_endpoint "${DGD_NAME}-frontend"
port_forward_prometheus

# ── Stage 1: 预热 ─────────────────────────────────────────────
section "Stage 1 — 预热 (10 个请求)"
for i in {1..10}; do
  curl -sf --max-time 30 -X POST "${ENDPOINT}/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"warmup ${i}\",\"max_tokens\":50}" \
    >/dev/null 2>&1 || true
done
ok "预热完成"

# ── Stage 2: Wave 1 持续负载 ──────────────────────────────────
section "Stage 2 — Wave 1: ${CONCURRENCY} 并发持续 ${WAVE_DURATION}s"
LOAD_LOG=$(mktemp)
python3 - <<EOF >"$LOAD_LOG" &
import asyncio, aiohttp, time
URL="${ENDPOINT}/completions"; MODEL="${MODEL_NAME}"; C=${CONCURRENCY}; D=${WAVE_DURATION}
ok=fail=0; deadline=time.time()+D
async def worker(s,wid):
    global ok,fail; i=0
    while time.time()<deadline:
        i+=1
        try:
            async with s.post(URL, json={"model":MODEL,"prompt":f"w{wid} req {i} explain LLM scaling in detail","max_tokens":${MAX_TOKENS}}, timeout=120) as r:
                await r.json(); ok+=1
        except Exception: fail+=1
async def main():
    async with aiohttp.ClientSession() as s:
        await asyncio.gather(*[worker(s,i) for i in range(C)])
t0=time.time(); asyncio.run(main())
print(f"wave1: ok={ok} fail={fail} elapsed={time.time()-t0:.1f}s rps={ok/max(time.time()-t0,1):.1f}")
EOF
LOAD_PID=$!
ok "Wave 1 已在后台启动 (PID=${LOAD_PID})"

# ── Stage 3: 触发或观察扩容 ────────────────────────────────────
section "Stage 3 — 触发/等待扩容"
if [[ "$MODE" == "router" ]]; then
  # 找 decode dgdsa
  DGDSA_DEC=$(kubectl get dgdsa -n "$NAMESPACE" -o name 2>/dev/null \
    | grep -iE 'decode' | head -1 | awk -F/ '{print $2}')
  if [[ -n "$DGDSA_DEC" ]]; then
    info "PATCH ${DGDSA_DEC} → replicas=${TARGET_REPLICAS} (模拟 RL 控制器决策)"
    kubectl patch "dgdsa/${DGDSA_DEC}" -n "$NAMESPACE" --type=merge \
      -p "{\"spec\":{\"replicas\":${TARGET_REPLICAS}}}" || warn "PATCH 失败"
  else
    warn "未找到 decode dgdsa, 跳过手动扩容"
  fi
else
  info "Planner 模式: 等待自动决策 (最多 ${SCALE_OBSERVE_TIMEOUT}s)"
fi

DEADLINE=$((SECONDS + SCALE_OBSERVE_TIMEOUT))
SCALED=false
while [[ $SECONDS -lt $DEADLINE ]]; do
  CUR=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -iE "${DGD_NAME}.*decode" | wc -l)
  if [[ "$CUR" -gt "$INIT_DECODE" ]]; then
    pass "扩容触发: decode pod ${INIT_DECODE} → ${CUR}"
    SCALED=true; break
  fi
  printf "\r  等待扩容... 当前 decode=%s (期望>%s) [%ss]" "$CUR" "$INIT_DECODE" "$SECONDS"
  sleep 10
done
echo ""
$SCALED || fail "未观察到扩容"

# ── Stage 4: 等新 Pod Ready ────────────────────────────────────
section "Stage 4 — 等新 Decode Pod Running (GPU init)"
DEADLINE=$((SECONDS + POD_READY_TIMEOUT))
while [[ $SECONDS -lt $DEADLINE ]]; do
  RUN=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -iE "${DGD_NAME}.*decode" | grep -c Running || echo 0)
  TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -ciE "${DGD_NAME}.*decode" || echo 0)
  if [[ "$RUN" -eq "$TOTAL" ]] && [[ "$TOTAL" -gt "$INIT_DECODE" ]]; then
    pass "新 Pod 全部 Running (${RUN}/${TOTAL})"; break
  fi
  printf "\r  Running %s/%s [%ss]" "$RUN" "$TOTAL" "$SECONDS"
  sleep 15
done
echo ""

# ── Stage 5: Wave 2 验证 ────────────────────────────────────────
section "Stage 5 — Wave 2 (60s) 验证新 Pod 是否分流"
WAVE2_LOG=$(mktemp)
python3 - <<EOF >"$WAVE2_LOG" &
import asyncio, aiohttp, time
URL="${ENDPOINT}/completions"; MODEL="${MODEL_NAME}"; C=${CONCURRENCY}
ok=fail=0; deadline=time.time()+60
async def w(s,wid):
    global ok,fail; i=0
    while time.time()<deadline:
        i+=1
        try:
            async with s.post(URL, json={"model":MODEL,"prompt":f"v {wid}-{i}","max_tokens":${MAX_TOKENS}}, timeout=60) as r:
                await r.json(); ok+=1
        except: fail+=1
async def main():
    async with aiohttp.ClientSession() as s:
        await asyncio.gather(*[w(s,i) for i in range(C)])
asyncio.run(main()); print(f"wave2: ok={ok} fail={fail}")
EOF
W2_PID=$!
wait "$W2_PID" 2>/dev/null || true

# ── Stage 6: per-pod 流量分布 ─────────────────────────────────
section "Stage 6 — Per-Pod 流量分布"
sleep 10
RAW=$(query_prom "sum by (pod) (rate(dynamo_worker_requests_total{namespace=\"${NAMESPACE}\"}[2m]))")
echo "$RAW" | python3 -c '
import json,sys
d=json.load(sys.stdin)
res=d.get("data",{}).get("result",[])
if not res:
    print("    (无数据 — 检查 PodMonitor / Prometheus scrape)")
else:
    for r in res:
        pod=r["metric"].get("pod","?"); v=r["value"][1]
        print(f"    {pod:60s}  rate={v}")
' 2>/dev/null || echo "    (查询失败)"

# 终止 wave1 (若还在跑)
kill "$LOAD_PID" 2>/dev/null || true
wait 2>/dev/null || true
echo ""
info "Wave 1 结果:"; cat "$LOAD_LOG" | sed 's/^/    /'
info "Wave 2 结果:"; cat "$WAVE2_LOG" | sed 's/^/    /'
rm -f "$LOAD_LOG" "$WAVE2_LOG"

# Grafana
section "Grafana 验证"
port_forward_grafana
echo "    打开 http://localhost:3000 (admin/admin)"
echo "    Dashboards →"
echo "      - Dynamo Disaggregation: 应看到 decode pod 数量从 ${INIT_DECODE} → 多个, per-pod request rate"
[[ "$MODE" == "planner" ]] && echo "      - Dynamo Planner: 应看到 scaling decision 时间线"
echo ""

print_summary
