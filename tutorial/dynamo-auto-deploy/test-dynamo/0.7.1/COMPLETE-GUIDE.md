# Dynamo 0.7.1 — 完整部署、测试策略与操作指南

> **环境**: gpu14 (192.168.1.246) · 8× RTX 3090 · K8s 1.34.5 · containerd 1.7.28+CDI  
> **模型**: Qwen/Qwen3-0.6B · Dynamo 0.7.1 · Disaggregated Serving (PD 分离)  
> **Namespace**: `dynamo-system`

---

## 目录

1. [系统架构](#1-系统架构)
2. [请求路径：Ingress vs Port-forward](#2-请求路径ingress-vs-port-forward)
3. [HPA 策略与阈值设计](#3-hpa-策略与阈值设计)
4. [各组件扩容特性分析](#4-各组件扩容特性分析)
5. [KV Cache 与路由策略](#5-kv-cache-与路由策略)
6. [已知问题与修复](#6-已知问题与修复)
7. [测试脚本说明](#7-测试脚本说明)
8. [Grafana Dashboard](#8-grafana-dashboard)
9. [Prometheus 查询参考](#9-prometheus-查询参考)
10. [操作手册](#10-操作手册)
11. [故障排查](#11-故障排查)

---

## 1. 系统架构

### 1.1 组件拓扑

```
用户请求 (curl / client)
    │
    ▼
┌──────────────────────┐
│  Ingress (NGINX)     │    hostPort 80/443, DaemonSet
│  /v1 → Frontend Svc  │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│      Frontend        │─── Prometheus scrape ──→ dynamo_frontend_* 指标
│   (Router, 无 GPU)   │
└──┬───────────────┬───┘
   │               │          NATS (KV Transfer)
   ▼               ▼
┌──────────┐  ┌──────────┐
│ Prefill  │  │  Decode  │─── Prometheus scrape ──→ dynamo_component_* 指标
│ Worker   │  │  Worker  │
│ (GPU ×1) │  │ (GPU ×1) │
└──────────┘  └──────────┘

Prometheus ──→ prometheus-adapter ──→ Custom Metrics API ──→ HPA
```

### 1.2 组件职责

| 组件 | 角色 | GPU | 特点 |
|------|------|-----|------|
| **Frontend** | API 网关 + Router | ❌ | 接收请求，查询 KV Cache 状态，路由到 Prefill/Decode |
| **PrefillWorker** | 预填充 (Prompt→KV) | ✅ ×1 | 处理输入 token，计算 KV Cache，耗时与 input length 成正比 |
| **DecodeWorker** | 解码 (KV→Token) | ✅ ×1 | 逐 token 自回归生成，耗时与 max_tokens 成正比（主要瓶颈） |

### 1.3 请求生命周期

```
1. 用户 → Ingress (NGINX) → Frontend
2. Frontend 查询各 Worker 的 KV Cache 状态
3. Frontend → PrefillWorker: 发送 prompt，计算 KV Cache（~20-200ms for 0.6B）
4. PrefillWorker → DecodeWorker: 通过 NATS 传输 KV Cache
5. DecodeWorker: 逐 token 生成（~15-40s for max_tokens=500）
6. DecodeWorker → Frontend → 用户: 流式返回 tokens
```

### 1.4 GPU 资源约束

8× RTX 3090（24GB VRAM/卡），Platform Pod (etcd/NATS/operator) 不占 GPU。

| 组件 | min | max | GPU 占用 |
|------|-----|-----|---------|
| Decode | 1 | 3 | 1-3 GPU |
| Prefill | 1 | 2 | 1-2 GPU |
| Frontend | 1 | 3 | 0 GPU |
| **总计** | **2** | **5** | **2-5 GPU，留 3 GPU 余量** |

---

## 2. 请求路径：Ingress vs Port-forward

### 2.1 两种请求路径对比

| 特性 | Ingress (NGINX) | Port-forward (kubectl) |
|------|-----------------|----------------------|
| **路径** | curl → NGINX (hostPort:80) → K8s Service → Frontend Pod | curl → kubectl → Service/Pod |
| **Frontend 负载均衡** | NGINX 按配置 (round-robin) 分发到多个 Frontend Pod | Service 的 kube-proxy 负载均衡 |
| **生产就绪** | ✅ 是 | ❌ 仅用于调试 |
| **超时控制** | NGINX 配置 (proxy-read-timeout) | 受限于 kubectl |
| **对后端影响** | 无差别 — Prefill/Decode 收到的请求完全相同 | 无差别 |
| **当前测试使用** | ✅ 是（自动检测） | 仅作为 fallback |

### 2.2 请求路径对 HPA 测试的影响

**结论：使用哪种路径对 HPA 测试几乎没有影响。**

HPA 基于 Prometheus 指标触发扩容：
- Decode/Prefill HPA 基于 `dynamo_inflight_requests`（Custom Metrics）
- Frontend HPA 基于 CPU utilization

无论请求通过 Ingress 还是 port-forward 到达 Frontend，后端 Worker 收到的请求完全相同，Prometheus 采集到的指标也完全相同。

**唯一区别**：当 Frontend 有多个 Pod 时：
- **Ingress**: NGINX 在多个 Frontend Pod 间负载均衡 → 每个 Frontend CPU 使用更低
- **Port-forward (to service)**: kube-proxy 也会负载均衡 → 效果类似
- **Port-forward (to pod)**: 所有流量打到单个 Pod → 该 Pod CPU 最高，但其他 Frontend Pod 空闲

当前 `test.sh` 和 `complete-test.sh` 自动检测 Ingress（`http://localhost/v1/models` 返回 200），**这是正确的生产级路径**。

---

## 3. HPA 策略与阈值设计

### 3.1 HPA 配置一览

| HPA | Deployment | 指标类型 | 标准阈值 | 小模型测试阈值 | min→max |
|-----|-----------|---------|---------|-------------|---------|
| hpa-frontend | frontend | CPU Utilization | 60% | 30% | 1→3 |
| hpa-decode-worker | vllmdecodeworker | dynamo_inflight_requests | 5 (AverageValue) | 5 | 1→3 |
| hpa-prefill-worker | vllmprefillworker | dynamo_inflight_requests | 2 (AverageValue) | 300m (0.3) | 1→2 |

### 3.2 指标链路

```
Worker Pod 暴露 metrics
    ↓
Prometheus 每 15s 抓取
    ↓
prometheus-adapter 桥接 Prometheus → Custom Metrics API
    metricsQuery: avg_over_time(<<.Series>>{<<.LabelMatchers>>}[1m])
    ↓
HPA Controller 每 15s 查询 Custom Metrics API
    GET /apis/custom.metrics.k8s.io/v1beta1/namespaces/.../pods/*/dynamo_inflight_requests
    ↓
HPA 计算: 当前值 / 目标值 → 决定是否扩缩容
```

### 3.3 为什么需要"小模型测试阈值"？

以 Qwen3-0.6B 为例，并发 40 + max_tokens 500 时的**实测数据**：

| 组件 | 实测 inflight (avg_over_time[1m]) | 标准阈值 | 触发？ |
|------|----------------------------------|---------|--------|
| Decode | 19458m (≈19.5) | 5 | ✅ **是** |
| Prefill | 416m (≈0.42) | 2 | ❌ 否 (0.42 << 2) |
| Frontend | cpu: `<unknown>` | 60% | ❌ 无法计算 |

**Decode 轻松触发**：每个请求在 Decode 停留 15-40s，并发 40 → inflight ~20-40。

**Prefill 几乎不可能触发**：
- 0.6B 模型 Prefill 极快 (~20ms/request)
- 并发 40 时 steady-state Prefill throughput ~4 req/s
- 瞬时 Prefill inflight ≈ 4 × 0.02s = 0.08
- avg_over_time[1m] ≈ 0.42（包含 burst 峰值的平均）
- 即使阈值降到 2，仍不够（0.42 < 2）

**Frontend CPU 无法读取**：
- Deployment 没有设置 `resources.requests.cpu`
- CPU-based HPA 需要 requests 才能计算百分比
- 没有 requests → 显示 `<unknown>` → 永远不扩容

### 3.4 小模型测试阈值的数学依据

`complete-test.sh` 使用的调整值：

**Prefill: 300m (0.3)**
- 超长 Prompt (~1000 tokens) 使 Prefill 耗时增加到 ~100-200ms
- 并发 80 时初始 burst：80 请求同时进入 Prefill 队列
- 峰值 inflight ~40-80（burst 期间），avg_over_time[1m] ≈ 5-10
- 5-10 >> 0.3 → 轻松触发

**Frontend: CPU 30%**
- `setup.sh` patch 后 requests.cpu=100m
- 30% = 30m 实际 CPU
- 并发 80 的 Python HTTP 路由 → CPU 容易超过 30m
- 实际 CPU 可能达到 50-100m → 50-100% → 远超 30%

---

## 4. 各组件扩容特性分析

### 4.1 不同模型规模的扩容预期

| 模型规模 | Prefill 耗时/req | Decode 耗时/req | 预期扩容组件 |
|----------|-----------------|-----------------|-------------|
| **0.6B** | <100ms | 10-40s | ✅ Decode only（标准阈值） |
| 7B | 200-500ms | 30-120s | ✅ Decode + 可能 Prefill |
| 70B+ | 2-10s | 60-300s | ✅ Decode + Prefill + Frontend |

**关键结论**：用 0.6B 模型只观察到 Decode 扩容是**正常行为**，不代表部署有问题。
生产环境使用 7B/70B+ 模型时，Prefill 成为真正瓶颈，三个组件自然都会扩容。

### 4.2 Inflight 时间对比（0.6B，并发 40）

```
请求生命周期：
  Frontend: ~1ms     │▎│                          ← CPU 几乎无压力
  Prefill:  ~20ms    │██│                          ← 极快完成
  Decode:   ~20000ms │████████████████████████████│  ← 主要瓶颈

各组件瞬时 inflight：
  Frontend:  ~0.04  （请求秒过）
  Prefill:   ~0.08  （20ms × 4 req/s arrival）
  Decode:    ~20    （20s × 1 req/s per worker）
```

### 4.3 GPU Pod 冷启动瓶颈

新 Pod 从调度到 Ready 的时间线（0.6B 模型）：

```
0s    5s    15s   40s   55s   60s   90s   120s
│─────│─────│─────│─────│─────│─────│─────│
│ Schedule  │ Start │  Load Model  │ CUDA │ Ready
│ + Pull    │ Ctnr  │  (0.6B)      │ Init │ ✓
```

- **总计约 60-120s**（第一次测试中新 Decode Pod 在 120s 后仍为 0/1 READY）
- 对于 70B 模型：模型加载可能需要 5-10 分钟

**优化方向**：

| 方案 | 节省时间 | 适用场景 |
|------|---------|---------|
| minReplicas > 1 | 消除冷启动 | 可预测最小负载 |
| 模型缓存到本地 SSD | ~20s | 大模型 |
| 预拉取镜像（DaemonSet） | ~30s | 多节点 |
| 调低 readiness probe | ~10s | 通用 |

---

## 5. KV Cache 与路由策略

### 5.1 前缀感知路由 (Prefix-Aware Routing)

Dynamo 的 Router 实现了 KV Cache 亲和性路由：

1. 请求到达 Frontend → Router 查询各 Worker 的 KV Cache 状态
2. 如果某 Worker GPU 已缓存该 prompt 的前缀 KV 数据 → **优先路由到该 Worker**
3. 未命中时 → 按负载均衡策略分发

**测试影响**：
- 相同 prompt → 全部路由到同一个 Worker（Cache 亲和性）
- 不同 prompt → 无缓存优势 → Router 按负载均衡分发

### 5.2 Cache Busting 策略

`test.sh` 和 `complete-test.sh` 都使用 **唯一 ID 前缀**：

```
[rid123t1712736000r28451] Explain in great detail how ...

  rid123      → 请求序号
  t1712736000 → UNIX 时间戳
  r28451      → $RANDOM
```

每个请求的 prompt 前缀都不同 → KV Cache 无亲和性 → Router 使用负载均衡。

### 5.3 验证 KV Cache 工作

如需验证 KV Cache 命中（非测试扩容时）：
```bash
# 发送相同 prompt 多次，观察 Grafana 中 Cache Hit Rate 上升
for i in $(seq 1 10); do
  curl -s http://localhost/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"What is machine learning?"}],"max_tokens":50}'
done
```

**Grafana 观察**：`KV Prefix Cache Hit Rate` 应从 0 逐渐上升。

---

## 6. 已知问题与修复

### 6.1 Frontend HPA 显示 `cpu: <unknown>/60%`

| | |
|---|---|
| **根因** | Dynamo operator 不设置 Frontend Deployment 的 `resources.requests.cpu` |
| **影响** | CPU 百分比型 HPA 无法计算比例 → 永远不扩容 |
| **修复** | `setup.sh` Stage 4 自动 patch: `kubectl set resources --requests=cpu=100m` |
| **检查** | `kubectl get deployment ${DGD_NAME}-frontend -o jsonpath='{.spec.template.spec.containers[0].resources}'` |

### 6.2 test.sh HPA 显示列偏移

| | |
|---|---|
| **根因** | `kubectl get hpa` 的 TARGETS 列含空格(`cpu: <unknown>/60%`)时 awk 列偏移 |
| **影响** | 显示的 REPLICAS 实际是 MAXPODS |
| **修复** | 使用 `sed 's/^/    /'` 保留原始格式，不再使用 awk 解析 |

### 6.3 新扩容 Pod 未处理流量

| | |
|---|---|
| **根因** | 模型加载需 60-120s，测试在此前结束 |
| **影响** | 新 Pod 0/1 READY，无法接收请求 |
| **修复** | 多波次测试：Wave 1 触发扩容 → 等待 Ready → Wave 2 验证分流 |

### 6.4 prometheus-adapter DNS 解析失败

| | |
|---|---|
| **根因** | `lib/common.sh` 未 `export` 环境变量 → `envsubst` 输出空值 → URL 双 dot |
| **影响** | adapter 日志: `lookup prometheus..svc.cluster.local: no such host` |
| **修复** | `common.sh` 所有 env var 改为 `export` |

---

## 7. 测试脚本说明

### 7.1 文件结构

```
test-dynamo/0.7.1/
  setup.sh              # 一键部署基础设施（Ingress/Adapter/HPA/Grafana）
  test.sh               # 标准负载测试（Decode 扩容）
  complete-test.sh      # 全组件 HPA 验证（Frontend+Prefill+Decode）
  lib/common.sh         # 共享环境变量和函数
  grafana/dynamo-dashboard.json   # Grafana Dashboard 模板
```

### 7.2 test.sh vs complete-test.sh

| 特性 | test.sh | complete-test.sh |
|------|---------|-----------------|
| **验证范围** | Decode 扩容 | Frontend + Prefill + Decode 全部 |
| **运行时间** | ~5 min | ~15 min |
| **并发** | 40 | 40 → 80 |
| **请求数** | Wave 1: 800 + Wave 2: 200 | P1: 500 + P3: 1500 + P5: 300 |
| **Prompt 长度** | 标准 (~200 tokens) | 标准 + 超长 (~1000 tokens) |
| **HPA 阈值修改** | 不修改，使用 setup.sh 部署的值 | 临时 patch 为小模型友好值 |
| **适用场景** | 日常快速验证 | 完整演示 / 论文数据收集 |
| **恢复** | 无 | `--restore` 恢复原始阈值 |

### 7.3 complete-test.sh 六阶段流程

```
时间轴（~15 min）：

Phase 0          Phase 1             Phase 2     Phase 3                    Phase 4     Phase 5    Phase 6
Prereqs          Decode Scaling      Wait Pod    All-Component Burst        Wait Pod    Verify     Results
+ HPA Patch      500 req @40         Ready       1500 req @80 (long)        Ready       300 req
                                                                                        @50
0       1min     2min    4min        5min  7min  8min         13min        14min 15min  16min  17min
|───────|────────|───────|───────────|─────|─────|────────────|────────────|─────|──────|──────|
        HPA      Decode               New        Prefill                    New
        Patch    scaled!               Pod        + Frontend                Pods
                                       Ready      scaled!                   Ready
```

### 7.4 使用方法

```bash
# 在 gpu14 上：

# 1. 首次部署（如果尚未运行）
bash setup.sh --background

# 2. 快速验证 Decode 扩容
bash test.sh

# 3. 完整验证全组件扩容（论文数据）
bash complete-test.sh --reset --restore
# --reset:   先缩回 1 副本（干净的初始状态）
# --restore: 测试后恢复原始 HPA 阈值
```

---

## 8. Grafana Dashboard

### 8.1 Dashboard 信息

- **名称**: Dynamo — HPA & Router Monitor
- **UID**: `dynamo-hpa-router-v1`
- **自动导入**: `setup.sh` Stage 6 通过 HTTP API 导入

### 8.2 面板一览

| Row | 面板 | 类型 | 说明 |
|-----|------|------|------|
| HPA | HPA Replicas — Current vs Desired | 时序图 | 实线=当前, 虚线=期望 |
| HPA | Deployment Available Replicas | Stat | 每个 Deployment 可用副本数 |
| Load | Inflight Requests per Pod | 堆叠面积 | **核心面板** — 按 Pod 显示负载 |
| Load | Frontend Inflight & Queued | 时序图 | 橙色 queued 持续增长 = 下游瓶颈 |
| Latency | TTFT P50/P90/P99 | 时序图 | 首 token 延迟百分位 |
| Latency | Output Tokens/s | 时序图 | 系统吞吐量 |
| Cache | GPU Cache Usage % | 时序图 | 接近 100% 需扩容 |
| Cache | KV Prefix Cache Hit Rate | 时序图 | 重复请求时应上升 |
| Router | Request Rate per Pod | 堆叠面积 | 确认多 Pod 均有流量 |
| Router | NATS Connection State | Stat | 绿=Connected |

### 8.3 如何判读测试结果

**HPA 扩容成功**:
- "HPA Replicas" 面板：desired 先跳变 → current 跟随
- "Deployment Available Replicas" 数字增加
- "Inflight per Pod" 出现新 Pod 曲线

**Router 分发正常**:
- "Inflight per Pod"：多个 Pod 同时有负载（Phase 5/Wave 2 期间最明显）
- "Request Rate per Pod"：所有 Worker Pod 都有请求速率

**KV Cache 工作正常**:
- "KV Prefix Cache Hit Rate"：使用重复 prompt 时 > 0
- "TTFT"：缓存命中后首次应答延迟降低

---

## 9. Prometheus 查询参考

```promql
# ─── Inflight 负载 ─────────────────────────────────────────
# 每 Pod 当前 inflight 请求数
dynamo_component_inflight_requests{namespace="dynamo-system"}

# 最近 15 分钟每 Pod 峰值 inflight（测试结果分析用）
max_over_time(dynamo_component_inflight_requests{namespace="dynamo-system"}[15m])

# Frontend 排队请求数（>0 说明下游瓶颈）
dynamo_frontend_queued_requests{namespace="dynamo-system"}

# ─── 请求速率 ─────────────────────────────────────────────
sum by (pod) (rate(dynamo_component_requests_total{namespace="dynamo-system"}[5m]))

# ─── 延迟 ─────────────────────────────────────────────────
# TTFT P99
histogram_quantile(0.99, rate(dynamo_frontend_time_to_first_token_seconds_bucket{namespace="dynamo-system"}[2m]))

# ─── KV Cache ─────────────────────────────────────────────
dynamo_component_kvstats_gpu_cache_usage_percent{namespace="dynamo-system"}
dynamo_component_kvstats_gpu_prefix_cache_hit_rate{namespace="dynamo-system"}

# ─── HPA ──────────────────────────────────────────────────
kube_horizontalpodautoscaler_status_current_replicas{namespace="dynamo-system"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="dynamo-system"}
```

---

## 10. 操作手册

### 10.1 首次部署

```bash
cd ~/test-dynamo/0.7.1

# 部署全部基础设施（Ingress + Adapter + HPA + Grafana）
bash setup.sh --background
# → Prometheus: http://localhost:9090
# → Grafana:    http://localhost:3000 (admin / <密码会打印>)
```

### 10.2 日常测试

```bash
bash test.sh                           # 标准 Decode 扩容测试
bash complete-test.sh --reset --restore  # 全组件验证
```

### 10.3 修改 HPA 阈值后重新部署

```bash
# setup.sh 是幂等的，直接重新执行
bash setup.sh --background

# 验证
kubectl get hpa -n dynamo-system
kubectl describe hpa hpa-prefill-worker -n dynamo-system
```

### 10.4 手动缩容（测试后清理）

```bash
kubectl scale deployment/vllm-v1-disagg-router-vllmdecodeworker --replicas=1 -n dynamo-system
kubectl scale deployment/vllm-v1-disagg-router-vllmprefillworker --replicas=1 -n dynamo-system
kubectl scale deployment/vllm-v1-disagg-router-frontend --replicas=1 -n dynamo-system
```

---

## 11. 故障排查

### 11.1 HPA 不扩容

| 症状 | 原因 | 排查 |
|------|------|------|
| TARGETS = `<unknown>` (inflight) | prometheus-adapter 未采集到指标 | `kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1"` |
| TARGETS = `<unknown>` (CPU) | deployment 无 cpu requests | `kubectl get deploy ${DGD}-frontend -o jsonpath='{..resources}'` |
| TARGETS 有值但不扩容 | 值未超过阈值 | `kubectl describe hpa -n ${NS}` 看 Conditions |
| desired 增加但 Pod Pending | GPU 不足 | `kubectl describe pod <pending> -n ${NS}` |
| adapter 报 DNS 错误 | common.sh 未 export 变量 | 检查 adapter logs + 重新 `bash setup.sh` |

### 11.2 Router 不分发

| 症状 | 原因 | 排查 |
|------|------|------|
| 只有一个 Worker 有流量 | KV Cache 亲和性（正常行为） | 使用 cache-busting prompt |
| 新 Worker Pod 有流量=0 | Pod 未 Ready | `kubectl get pods` 检查 READY 列 |
| NATS Disconnected | Worker 未连接 NATS | `kubectl logs <worker-pod> \| grep NATS` |

### 11.3 Grafana Dashboard 无数据

| 面板 | 排查 |
|------|------|
| 全部无数据 | port-forward 断开 → `bash setup.sh --background` |
| HPA 面板无数据 | kube-state-metrics 未部署 |
| Dynamo 指标无数据 | Prometheus Targets: `http://localhost:9090/targets` |
| DCGM 面板无数据 | 可选组件，不影响其他面板 |

### 11.4 常用诊断命令

```bash
# prometheus-adapter 日志
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter --tail=20

# Custom Metrics API
kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/dynamo-system/pods/*/dynamo_inflight_requests'

# HPA 详细状态
kubectl describe hpa -n dynamo-system

# Prometheus 原始指标
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=dynamo_component_inflight_requests' | python3 -m json.tool

# Pod 事件
kubectl get events -n dynamo-system --sort-by='.lastTimestamp' | tail -20
```
