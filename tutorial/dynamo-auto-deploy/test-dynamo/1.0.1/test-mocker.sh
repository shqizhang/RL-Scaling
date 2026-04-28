#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# test-mocker.sh — 用 mocker-runtime 验证 Dynamo 控制平面 (无 GPU)
#
# 流程:
#   1. 检查 mocker DGD 已部署且所有 mocker pod Running (无 GPU 检查)
#   2. 检测 Frontend endpoint (Ingress 或 port-forward)
#   3. 冒烟: GET /v1/models 应返回 ${MODEL_NAME}
#   4. 冒烟: POST /v1/completions 应返回模拟 token (mocker 不会真生成)
#   5. 启动负载: 异步 ${CONCURRENCY} 并发 × ${TOTAL_REQUESTS} 请求
#   6. 启动 Prometheus port-forward 并采样关键 metrics:
#        - dynamo_frontend_requests_total
#        - dynamo_worker_active_requests
#        - dynamo_kvbm_*
#   7. 启动 Grafana port-forward, 提示用户去看 disagg + planner dashboard
#
# 全程不需要 GPU。失败/异常都计入 _FAIL。
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
trap cleanup_portforwards EXIT

require_cmds kubectl curl python3

# 使用 mocker DGD 的 frontend
DGD_NAME="$DGD_MOCKER_NAME"

section "Mocker 测试 — DGD: ${DGD_NAME} (no GPU)"

# ── 1. mocker pods Running ─────────────────────────────────────
section "1 — Mocker Pod Running"
MOCKER_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -iE 'mocker' | awk '{print $1, $3}' || true)
if [[ -z "$MOCKER_PODS" ]]; then
  fail "未找到 mocker pod  → 先运行: bash 01-deploy-dynamo-1.0.1.sh --mocker"
  print_summary; exit 1
fi
echo "$MOCKER_PODS" | sed 's/^/    /'
NOT_RUNNING=$(echo "$MOCKER_PODS" | awk '$2 != "Running"' | wc -l)
[[ "$NOT_RUNNING" -eq 0 ]] && pass "所有 mocker Pod Running" || fail "${NOT_RUNNING} 个 pod 未 Running"

# ── 2. endpoint ───────────────────────────────────────────────
section "2 — Endpoint 探测"
setup_endpoint "${DGD_NAME}-frontend"

# ── 3. /v1/models ─────────────────────────────────────────────
section "3 — GET /v1/models"
sleep 5
MODELS=$(curl -sf --max-time 10 "${ENDPOINT}/models" 2>/dev/null \
  | python3 -c 'import json,sys; print(",".join(m["id"] for m in json.load(sys.stdin).get("data",[])))' 2>/dev/null || echo "")
if [[ -n "$MODELS" ]]; then
  pass "/v1/models = ${MODELS}"
else
  fail "/v1/models 失败"
fi

# ── 4. /v1/completions 冒烟 ────────────────────────────────────
section "4 — POST /v1/completions 冒烟"
RESP=$(curl -sf --max-time 30 -X POST "${ENDPOINT}/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"test\",\"max_tokens\":${MAX_TOKENS}}" 2>/dev/null || echo "")
if [[ -n "$RESP" ]] && echo "$RESP" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("choices") else 1)' 2>/dev/null; then
  pass "推理调用成功 (mocker 模拟 token)"
else
  fail "推理调用失败"
  echo "$RESP" | head -3
fi

# ── 5. 异步负载 ────────────────────────────────────────────────
section "5 — 启动 ${CONCURRENCY} 并发负载 × ${TOTAL_REQUESTS} 请求"
LOAD_LOG=$(mktemp)
python3 - <<EOF > "$LOAD_LOG" &
import asyncio, aiohttp, time, json, sys
URL="${ENDPOINT}/completions"
MODEL="${MODEL_NAME}"
N=${TOTAL_REQUESTS}
C=${CONCURRENCY}
sem=asyncio.Semaphore(C)
ok=fail=0
async def one(s,i):
    global ok,fail
    async with sem:
        try:
            async with s.post(URL, json={"model":MODEL,"prompt":f"test {i}","max_tokens":${MAX_TOKENS}}, timeout=60) as r:
                await r.json()
                ok+=1
        except Exception as e:
            fail+=1
async def main():
    async with aiohttp.ClientSession() as s:
        await asyncio.gather(*[one(s,i) for i in range(N)])
t0=time.time()
asyncio.run(main())
print(f"requests={N} ok={ok} fail={fail} elapsed={time.time()-t0:.1f}s")
EOF
LOAD_PID=$!

# ── 6. Prometheus metrics ─────────────────────────────────────
section "6 — Prometheus 关键指标采样"
port_forward_prometheus
sleep 5

for metric in \
  'sum(dynamo_frontend_requests_total)' \
  'sum(dynamo_worker_active_requests)' \
  'sum by (worker_id) (rate(dynamo_worker_requests_total[1m]))' ; do
  V=$(query_prom_value "$metric")
  if [[ -n "$V" ]]; then
    pass "${metric} = ${V}"
  else
    warn "${metric} 无数据"
  fi
done

wait "$LOAD_PID" 2>/dev/null || true
echo ""
info "负载测试结果:"
cat "$LOAD_LOG" | sed 's/^/    /'
rm -f "$LOAD_LOG"

# ── 7. Grafana 提示 ───────────────────────────────────────────
section "7 — Grafana 验证"
port_forward_grafana
echo "    打开 http://localhost:3000 (admin/admin)"
echo "    Dashboards → Browse →"
echo "      - Dynamo Disaggregation     (期望: requests/decode/prefill 有数据)"
echo "      - Dynamo Planner            (mocker 模式无 Planner, 应为空)"
echo "      - Dynamo Operator           (期望: DGD count = 1)"
echo ""
echo "  [按 Ctrl+C 停止 port-forward]"

print_summary
