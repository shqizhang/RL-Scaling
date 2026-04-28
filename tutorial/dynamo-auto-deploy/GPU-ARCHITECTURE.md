# K8s + Dynamo 系统部署架构：GPU 资源与调度深度解析

> 目标读者：已部署 Dynamo 0.7.1 的实验者，计划深入阅读 Dynamo 源码、实现自定义调度策略。  
> 环境参考：单节点 gpu14，8× RTX 3090（各 24 GiB），K8s 1.x，Dynamo 0.7.1，Qwen3-0.6B。

---

## 1. 系统整体架构概览

```
┌─────────────────────────────────────────────────────────────────────┐
│  K8s 节点 gpu14（8× RTX 3090）                                       │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────┐       │
│  │  Namespace: dynamo-system                   │       │
│  │                                                          │       │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │       │
│  │  │  Frontend    │  │PrefillWorker │  │DecodeWorker  │  │       │
│  │  │  (CPU Pod)   │  │  (GPU Pod)   │  │  (GPU Pod)   │  │       │
│  │  │  :8000/v1    │  │  GPU 0       │  │  GPU 1       │  │       │
│  │  │  KV Router   │  │  vLLM Engine │  │  vLLM Engine │  │       │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │       │
│  │         │                 │                 │           │       │
│  │         └─────────────────┴─────────────────┘           │       │
│  │              NATS (消息总线)  etcd (服务发现)             │       │
│  └──────────────────────────────────────────────────────────┘       │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐     │
│  │  Namespace: gpu-operator                                   │     │
│  │  NVIDIA Device Plugin DaemonSet — 管理 GPU 分配            │     │
│  │  NVIDIA Container Toolkit DaemonSet — 配置 containerd     │     │
│  └────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. GPU 资源分配机制

### 2.1 NVIDIA Device Plugin 工作原理

K8s 本身不感知 GPU。GPU 调度能力由 NVIDIA Device Plugin 提供，它以 DaemonSet 形式在每个 GPU 节点上运行。

```
kubectl 请求                   device plugin                  CUDA 驱动层
─────────────────────────────────────────────────────────────────────────
Pod spec:                      ListAndWatch:                  /dev/nvidia0
  resources:                     注册可分配资源:               /dev/nvidia1
    limits:                        nvidia.com/gpu: 8           ...
      nvidia.com/gpu: "1"          (每块 GPU 独立计数)
         │
         ▼
   kubelet Allocate()           ─────────────────────────────────────────
   → 调用 device plugin         Allocate():
     的 Allocate gRPC            1. 从空闲池取 GPU 0
                                 2. 向 kubelet 返回:
                                    - NVIDIA_VISIBLE_DEVICES=0
                                    - /dev/nvidia0 device mount
                                    - /dev/nvidiactl device mount
                                    - 驱动库路径挂载
                                    （不在容器 env/spec 中显示！）
                                 3. 将 GPU 0 标记为已分配
```

**关键点**：`NVIDIA_VISIBLE_DEVICES` 是由 device plugin 在 **kubelet 层** 注入的，不会出现在 `kubectl describe pod` 的 env 列表里。容器启动时（containerd 调用 `nvidia-container-runtime`），该环境变量被读取，runtime 将对应的物理 GPU expose 到容器内。

### 2.2 容器内的 GPU 视图

每个 Worker Pod 内的 vLLM 进程看到的是一个 **虚拟化的独立 GPU 环境**：

```bash
# 在 Prefill Pod 内执行
$ nvidia-smi
+----------------------------------------------------+
| GPU 0  NVIDIA GeForce RTX 3090   23.57 GiB        |   ← 总是 "GPU 0"
+----------------------------------------------------+
| Process: python3 (vLLM)          ~21 GiB           |
+----------------------------------------------------+

# 在 Decode Pod 内执行
$ nvidia-smi
+----------------------------------------------------+
| GPU 0  NVIDIA GeForce RTX 3090   23.57 GiB        |   ← 也是 "GPU 0"，但是物理 GPU 1
+----------------------------------------------------+
```

容器内永远看到 "GPU 0"，物理 GPU 索引的映射由 device plugin 和 container runtime 完成，对 vLLM 代码完全透明。

### 2.3 GPU 内存预分配

vLLM 启动时会立刻预分配 KV Cache 空间：

```python
# vllm/v1/worker/gpu_worker.py
free_memory = torch.cuda.mem_get_info()[0]   # 查询当前空闲 VRAM
total_memory = torch.cuda.mem_get_info()[1]  # 总 VRAM（24 GiB）

# gpu_memory_utilization = 0.90
desired_bytes = total_memory * gpu_memory_utilization   # 0.90 × 24 GiB ≈ 21.6 GiB

if free_memory < desired_bytes:
    raise ValueError(
        f"Free memory on device ({free_memory/GiB:.2f}/{total_memory/GiB:.2f} GiB) "
        f"is less than desired GPU memory utilization ..."
    )

# 实际预分配 KV Cache blocks，每个 block = num_layers × num_heads × head_dim × 2 × dtype_size
```

**这正是本次崩溃的原因**：Prefill Worker 已占用 GPU 0 的 21.2 GiB，Decode Worker 也被分配到 GPU 0（竞态），启动时发现 free 仅 2.55 GiB < 21.21 GiB，抛出 `ValueError`。

---

## 3. Disaggregated Prefill / Decode 架构

### 3.1 为什么要 Prefill / Decode 分离？

在传统（coupled）推理中，同一进程先做 Prefill（计算所有 input tokens 的 attention，O(n²) 复杂度），再做 Decode（逐 token 生成，O(n) 复杂度）。二者特征差异很大：

| 维度 | Prefill | Decode |
|------|---------|--------|
| 计算强度 | 高（矩阵乘法） | 低（单 token 计算） |
| 内存带宽需求 | 中 | 极高（每步都要读取全部 KV） |
| 批处理效率 | 可以 batch 许多 token | 每 step 只生成 1 token |
| GPU 利用率瓶颈 | Compute bound | Memory bandwidth bound |

分离后，可以对两类负载独立扩缩，选择最优的 GPU 配置。

### 3.2 完整请求生命周期

```
用户请求（HTTP POST /v1/chat/completions）
           │
           ▼
    ┌─────────────────┐
    │   Frontend Pod  │
    │  (KV Router)    │
    │                 │
    │  1. 查询 etcd:  │
    │     哪个 Prefill│
    │     KV 命中率高 │
    │  2. 路由决策    │
    └────────┬────────┘
             │ NATS publish
             ▼
    ┌─────────────────┐
    │  PrefillWorker  │
    │  (GPU 0)        │
    │                 │
    │  3. 计算 input  │
    │     tokens 的   │
    │     全部 KV     │
    │  4. KV Cache 写 │
    │     入 GPU HBM  │
    └────────┬────────┘
             │ NIXL/UCX KV Transfer
             │ (GPU-to-GPU via PCIe/NVLink)
             ▼
    ┌─────────────────┐
    │  DecodeWorker   │
    │  (GPU 1)        │
    │                 │
    │  5. 接收 KV     │
    │  6. Autoregressive│
    │     decoding    │
    │  7. 每生成1 token│
    │     通过 NATS   │
    │     回传到      │
    │     Frontend    │
    └─────────────────┘
             │ SSE stream response
             ▼
         客户端
```

### 3.3 KV Cache Transfer（NIXL）

Prefill 计算完的 KV Cache 需要传输到 Decode Worker，这是 disaggregated 架构的关键。

```
Dynamo 使用 NIXL（NVIDIA Inference Xfer Library）：

PrefillWorker GPU 0            DecodeWorker GPU 1
─────────────────              ──────────────────
KV blocks in HBM               等待 KV block 到达

NIXL agent (UCX backend):      NIXL agent (UCX backend):
  register memory regions        register memory regions
  ↓
  cudaIpcMemHandle / UCX rkey
  ↓ (PCIe P2P 或 via system memory)
                            →   cudaMemcpyPeer / UCX RDMA put
                                ↑
                            接收完成，开始 decode

延迟约 1~5ms（RTX 3090 PCIe，无 NVLink）
```

日志中的关键行：
```
2026-04-09T05:15:26.540782Z  INFO nixl_connector: NIXL is available
2026-04-09T05:15:26.542079Z  INFO factory: Creating v1 connector with name: NixlConnector
(EngineCore_DP0) 2026-04-09 05:15:26 NIXL INFO _api.py:361 Backend UCX was instantiated
```

说明 NIXL 已初始化 UCX 后端（用于 P2P GPU 内存传输），在你的 RTX 3090 环境中走 PCIe 总线。

---

## 4. 扩容（Scale）的 GPU 调度逻辑

### 4.1 每个 Pod 独享 1 GPU（no sharing）

当前配置中，每个 Prefill/Decode Worker 副本独占 1 块物理 GPU：

```yaml
resources:
  requests:
    nvidia.com/gpu: "1"
  limits:
    nvidia.com/gpu: "1"
```

这意味着：

```
副本数配置                  GPU 占用
──────────────────────────────────────
PREFILL_REPLICAS=1         → GPU 0（1 块）
DECODE_REPLICAS=1          → GPU 1（1 块）
共计                         2 块

PREFILL_REPLICAS=2         → GPU 0, GPU 2（2 块）
DECODE_REPLICAS=4          → GPU 1, GPU 3, GPU 4, GPU 5（4 块）
共计                         6 块（需要 6 块空闲 GPU）
```

K8s Scheduler 保证：请求相同数量 `nvidia.com/gpu` 的 Pod，device plugin 从空闲 GPU 池中各选 1 块（在单节点上整体见分晓）。

### 4.2 HPA 触发扩容的完整链路

```
1. vLLM 暴露 Prometheus 指标（/metrics）:
   dynamo_component_inflight_requests{component="VllmDecodeWorker"} = 8

2. Prometheus 采集指标（30s 间隔）

3. prometheus-adapter 转换格式:
   /apis/custom.metrics.k8s.io/v1beta1/.../pods/*/dynamo_inflight_requests
   → value: 8    当前所有 Decode Pod 上的平均 inflight

4. HPA 控制器计算:
   desiredReplicas = ceil(currentReplicas × (currentMetric / targetMetric))
                   = ceil(1 × (8 / 5))    ← targetAverageValue=5
                   = 2

5. HPA 将 Decode Deployment.spec.replicas 从 1 → 2

6. ReplicaSet 创建新 Pod

7. kubelet → device plugin Allocate(gpu=1)
   → 从空闲池取 GPU 2（GPU 0 被 Prefill 占，GPU 1 被现有 Decode 占）

8. 新 Decode Pod 在 GPU 2 上启动 vLLM，加载模型权重

9. 模型加载完（Qwen3-0.6B ≈ 1.2 GiB，约 30~60s），Pod Ready

10. Frontend Router 通过 etcd 发现新 Decode Worker，开始分配流量
```

**关键延迟来源**：
- Prometheus 采集延迟：~30s
- HPA 控制器轮询：~15s
- Pod 调度 + 容器启动：~10s
- vLLM 模型加载：30~300s（取决于模型大小和缓存状态）
- **总体扩容延迟**：约 1~6 分钟

### 4.3 多 GPU 场景下的资源利用效率

**单 GPU 利用率分析（Qwen3-0.6B 场景）**：

```
GPU 0（Prefill Worker）
├── 模型权重: 0.6B × 2 bytes (BF16) ≈ 1.2 GiB
├── KV Cache 预留: 21.6 GiB × 0.90 - 权重 ≈ 20 GiB
│   KV Cache blocks: ~20 GiB / (32 layers × 16 heads × 128 dim × 2 × 2 bytes)
│                   ≈ 数千个 block（每 block = 16 or 32 tokens）
└── CUDA OP: ~1 GiB
    → GPU 利用率高，但 compute GPU 对 0.6B 模型是 overkill

GPU 1（Decode Worker）
├── 相同权重: 1.2 GiB
├── KV Cache: 20 GiB
└── Decode 阶段 GPU compute 利用率很低（memory bandwidth bound）
    → 对于小模型，RTX 3090 compute 浪费严重
```

**提高效率的思路**（研究方向）：

| 策略 | 原理 | Dynamo 支持情况 |
|------|------|----------------|
| 较小 gpu_memory_util | 降低 KV Cache 预分配，2 个 Worker 共享 1 GPU | ⚠ 可行但会降低最大并发 |
| 多模型共享 GPU（MPS） | NVIDIA MPS 允许多进程共享 GPU Compute | Dynamo 目前不支持 |
| TP（Tensor Parallel） | 1 个模型跨多 GPU parallelism | 需在 args 指定 --tensor-parallel-size |
| 异步 Prefill 流水线 | Chunked Prefill 与 Decode 交错执行 | vLLM v1 默认开启 chunked_prefill |

---

## 5. Dynamo Operator 如何管理 Pod

### 5.1 DynamoGraphDeployment → Pod 的转换链

```
用户 apply DGD YAML
       │
       ▼
Dynamo Operator（Deployment in K8s）
  watch DynamoGraphDeployment CRD
       │
       ▼ 为每个 service 创建:
  Deployment（spec，含 extraPodSpec）
  Service（ClusterIP，用于 Frontend 8000 等访问）
  ServiceAccount（dynamo-platform-dynamo-operator-component）
       │
       ▼
K8s Scheduler 调度 Pod
  → 评估 nodeAffinity、GPU 资源配额
  → 单节点环境：所有 Pod 落在同一节点
       │
       ▼
kubelet + containerd（defaultRuntimeName=nvidia）+ CDI
  → containerd 默认使用 nvidia runtime（不通过 runtimeClassName）
  → device plugin 通过 CDI 分配 GPU，确保每个 Pod 只看到 1 张
  → 容器启动时 nvidia runtime 挂载驱动
```

### 5.2 Operator 传递 extraPodSpec 的代码路径

Dynamo Operator 源码（参考路径）：

```
dynamo/
  lib/runtime/                 ← Rust 运行时核心
  deploy/dynamo/operator/      ← Go K8s Operator
    controllers/
      dynamographdeployment_controller.go   ← 主控制器
      ↓ reconcile loop
      deployment.go                          ← 创建 Deployment 的逻辑
        buildPodTemplateSpec()
          → 读取 service.extraPodSpec.runtimeClassName
          → 设置到 PodSpec.RuntimeClassName
```

如果你想自定义调度策略（如 GPU affinity、topology），修改 `buildPodTemplateSpec()` 或添加 `nodeSelector` / `affinity` 到 DGD spec 是切入点。

### 5.3 etcd 服务发现机制

Frontend 通过 etcd 发现 Worker 的方式：

```
# Prefill Worker 启动时注册：
etcd key: /dynamo-discovery/{namespace}/VllmPrefillWorker/{pod-uuid}
value: {
  "endpoint": "10.244.0.135:50051",   # NATS endpoint
  "kv_stats": {
    "gpu_prefix_cache_hit_rate": 0.72,
    "gpu_cache_usage_percent": 0.68,
    "inflight_requests": 3
  }
}

# Frontend 定期查询 etcd，获取所有 Worker 的实时 KV 状态
# KV Router 的路由决策：
#   - 选择 prefix cache hit rate 最高的 Prefill Worker（减少重复计算）
#   - 选择 cache_usage_percent 最低的 Decode Worker（避免 OOM）
#   - 通过 NATS 向选定的 Worker 发送请求
```

---

## 6. 当前部署的已知问题和优化建议

### 6.1 已修复：CrashLoopBackOff（containerd 配置覆写）

**根因**：containerd 重启后 GPU Operator toolkit daemonset 覆写配置，导致 3 个问题：
- `defaultRuntimeName` 回退为 `runc`（容器内无 GPU 驱动 → libcuda.so.1 缺失）
- `enable_cdi` 被重置为 `false`（CDI 设备隔离失效 → 每个容器看到全部 8 张 GPU）
- `device-plugin` 未重启（CDI annotation 未注入）

**修复**：3 步修复 containerd 配置（toolkit env + CDI + device plugin），DGD manifest 不设 `runtimeClassName`。
**文档**：`recover-script/MIGRATION-GUIDE.md` Section 7，`recover-script/DIAGNOSIS-AND-REPAIR.md` 第五节。

### 6.2 已修复：GPU OOM（Pod 调度竞态）

**根因**：删除 DGD → K8s 对象消失 → 立刻重建 → 新 Decode Pod 与旧 Prefill 共享 GPU 0  
（旧 Prefill 进程还活着，DGD 对象消失不代表 Pod 终止）。  
**修复**：添加 GPU 释放等待（等待 Pod 全部消失 + 30s buffer）。  
**代码**：`recover-script/04-fix-worker-crashloop.sh` 阶段 4.5，`deploy-dynamo-0.7.1/00-deploy-inference.sh`。

### 6.3 当前限制：Qwen3-0.6B 对 RTX 3090 过小

0.6B 模型 + 24 GiB 显存，compute 严重浪费。两个问题：
1. 每个 Worker 浪费约 20 GiB 显存在 KV Cache，但实际推理的 batch size 和 context 远达不到上限。
2. Decode 阶段 GPU compute 利用率极低（memory bandwidth bound，RTX 3090 memory BW 936 GB/s 对小模型也绰绰有余）。

**建议实验**：
```bash
# 测试用较大模型（充分利用 KV Cache 空间）
MODEL_NAME=Qwen/Qwen3-8B PREFILL_REPLICAS=1 DECODE_REPLICAS=1 \
  bash 00-deploy-inference.sh
# Qwen3-8B ≈ 16 GiB BF16，在 24 GiB 显存上基本满额

# 或测试负载峰值 + 扩容效果
bash ../test-dynamo/04-test-load.sh --mode python --concurrency 20 --total 200
bash ../test-dynamo/02-test-hpa.sh --trigger
```

### 6.4 研究切入点：自定义路由策略

Dynamo 的 KV Router 当前使用基于 prefix hash 的贪心策略。可以研究/修改的维度：

```
dynamo/lib/llm/src/kv_router/
  mod.rs              ← Router trait 定义
  policies/
    prefix.rs         ← 当前策略：按 KV prefix hash 路由
    round_robin.rs    ← 简单轮询（对比基准）
  
自定义策略示例：
  1. Load-aware routing：综合 inflight_requests + cache_usage
  2. Deadline-aware routing：对 latency-sensitive 请求优先分配低 inflight 的 Worker
  3. Speculative prefill：提前预热高概率 prefix 的 KV Cache
```

Dynamo 的 Router 通过 etcd 获取 Worker 状态，通过 NATS 发送路由决策，接口是 Rust trait，适合在 Rust 层实现新策略，或通过 Python binding 快速原型。

---

## 7. 参考命令速查

```bash
# 查看 GPU 分配（物理层）
nvidia-smi

# 查看 K8s 层 GPU 分配
kubectl describe node gpu14 | grep -A5 "Allocated resources"

# 查看 device plugin 分配的 GPU（容器内）
kubectl exec -n dynamo-system <pod> -- nvidia-smi

# 查看 etcd 中注册的 Worker
kubectl exec -n dynamo-system dynamo-platform-etcd-0 -- \
  etcdctl --endpoints=http://localhost:2379 get / --prefix --keys-only | grep dynamo

# 查看 Prometheus KV 指标
curl -s "http://localhost:9090/api/v1/query?query=dynamo_component_kvstats_gpu_prefix_cache_hit_rate"

# 端到端推理延迟分析
bash ../test-dynamo/04-test-load.sh --mode python --concurrency 5 --total 50 --stream
```
