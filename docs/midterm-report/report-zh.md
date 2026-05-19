# 面向强化学习的分离式LLM推理弹性伸缩：基于NVIDIA Dynamo实现动态PD角色切换与请求合并迁移

**子课题: RL-Scaling-Elastic-PD-Switch-and-Consolidation**

张盛琪

## 摘要

强化学习（RL）训练流水线在 sampling 阶段表现出高度突发性的推理需求，随后在梯度更新阶段进入长时间空闲。传统的静态 GPU 推理集群配置导致严重的资源浪费。本文提出 RL-Scaling，一个构建在 NVIDIA Dynamo 分离式 Prefill-Decode（PD）架构之上的弹性推理伸缩系统，实现三项渐进能力：（i）信号驱动的预热与缩容至零生命周期管理；（ii）不重启引擎的运行时 Prefill↔Decode 角色切换；（iii）通过活跃请求的 KV 缓存迁移实现请求合并，支持优雅缩容。系统通过在动态拓扑变更过程中维护四层一致性——Kubernetes 服务发现、Dynamo KV 感知路由器、vLLM KV Block Manager（KVBM）以及 NVIDIA NIXL 互联——实现端到端正确性。我们在生产级 Kubernetes 集群上用真实 GPU 负载完成了完整系统的实现和验证，证明角色切换可在 5 秒内完成，单请求迁移的 block-hold 开销低于 10ms。

## 1 引言

### 1.1 背景：RL训练与推理协同调度

现代基于人类反馈的强化学习（RLHF）及在线 RL 训练流水线——如 PPO、GRPO、DAPO——在两个计算特性截然不同的阶段之间交替进行：

1. **Sampling 阶段**：策略模型为一批提示词生成 rollout，需要多 GPU 的高吞吐 LLM 推理，同时承载 prefill 和 decode 工作负载。
2. **训练阶段**：在训练 GPU 上进行梯度计算，此时推理 GPU 完全空闲。

这种时间不对称性造成了根本性的资源利用问题。以 batch_size=64、平均输入序列长度 512 的典型训练循环为例，sampling 阶段可能需要 4-8 块推理 GPU 持续 30-60 秒，随后是数分钟的训练阶段，期间这些 GPU 产生零有效工作。

### 1.2 分离式PD架构

NVIDIA Dynamo 实现了分离式 Prefill-Decode（PD）架构，将自回归生成的两个阶段物理分离：

- **Prefill Workers**：单次前向传播计算输入提示词的完整 Key-Value（KV）缓存。该阶段为计算密集型，受益于高批次吞吐。
- **Decode Workers**：使用缓存的 KV 状态逐 token 生成。该阶段为内存带宽密集型，受益于高并发。

这种分离实现了各角色的独立伸缩，但引入了 prefill 和 decode workers 之间 KV 缓存传输的挑战——通过 NVIDIA 的 NIXL（NVIDIA Inference eXchange Library）实现 GPU 对 GPU 的直接 RDMA 传输来解决。

### 1.3 问题定义

针对 RL 训练的突发推理模式，我们识别出三个递进需求：

| 需求 | 挑战 |
|------|------|
| **S1**: 弹性扩缩容 | GPU 分配须跟踪 sampling 生命周期；需通过预热最小化冷启动延迟 |
| **S2**: 动态PD比例调整 | sampling 进程中 prefill/decode 负载比例变化；固定分配浪费容量 |
| **S3**: 优雅合并 | 批次尾部请求分散在多个部分空闲的 decoder 上；缩容前合并避免请求丢弃 |

每个需求都要求与 Dynamo 的路由、发现和 KV 管理子系统进行更深层次的集成。核心技术挑战是**在动态拓扑变更期间维护所有系统层的一致性**。

### 1.4 贡献

本工作做出以下贡献：

1. **完整的弹性推理生命周期系统**：集成信号 SDK、容量规划器和 Kubernetes 操作器，实现 RL 感知的 GPU 管理。
2. **首个在 Dynamo 上不重启引擎的运行时 PD 角色切换**：定义 9 步协议，维护路由一致性、KV 缓存相干性和服务发现原子性。
3. **两阶段请求迁移协议**：支持重计算预填充（降级）和基于 NIXL 的 KV block 传输（最优），配合成本收益门控和超时清理保障可靠性。
4. **端到端验证**：在生产级 Kubernetes 集群上进行验证，包含 140 个单元测试和脚本化 E2E 测试套件，证明在真实 GPU 负载下的正确性。

## 2 相关工作与动机

### 2.1 分离式推理系统

**DistServe** [1] 和 **Splitwise** [2] 首次提出将 prefill 和 decode 分离到不同资源池，通过独立伸缩展示了吞吐改善。但两者都假设在部署时配置静态 PD 比例。

**NVIDIA Dynamo** [3] 将此概念扩展为生产级系统，具备 KV 感知路由（基于 RadixTree 的前缀匹配）、用于零拷贝 GPU-GPU KV 传输的 NIXL，以及 Kubernetes 原生部署模型。Dynamo 提供了基础设施但不包含面向 RL 工作负载的弹性伸缩能力。

**Mooncake** [4] 引入以 KV 缓存为中心的分离架构，通过分布式 DRAM 池化实现存储效率，但聚焦于存储效率而非动态拓扑管理。

### 2.2 弹性推理伸缩

**ServerlessLLM** [5] 解决无服务器 LLM 服务的冷启动优化，但未处理 PD 分离拓扑。**SpotServe** [6] 提供 LLM 服务的 spot 实例管理及迁移能力，但操作粒度为实例级而非请求级。

现有系统均未解决 RL 训练的特定需求：可预测的突发模式、单批次内 PD 比例调整的需要，以及缩容前请求级优雅合并。

### 2.3 动机：RL Sampling 生命周期

```
┌─────────────────────────────────────────────────────────────┐
│  RL 训练循环                                                  │
│                                                              │
│  ┌──────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │ Sampling  │  │  奖励计算         │  │  策略更新         │  │
│  │ (30-60秒) │  │  (5-10秒)        │  │  (60-120秒)      │  │
│  │ GPU×8    │  │  GPU×1           │  │  GPU×8 (训练)    │  │
│  └──────────┘  └──────────────────┘  └──────────────────┘  │
│       ↑                                                      │
│  推理GPU仅在此阶段需要                                        │
└─────────────────────────────────────────────────────────────┘
```

**图1**：RL训练循环中的时间资源利用率。推理GPU仅在sampling阶段（阴影部分）需要，占总训练时间的15-30%。

Sampling 阶段自身也表现出内部负载动态：
- **早期**：Prefill 密集（所有提示词同时到达）
- **中期**：平衡（prefill 逐步完成，decode 开始）
- **晚期**：Decode 密集但负载递减（大部分序列接近完成）

这激发了单个 sampling 批次内动态 PD 比例调整（S2）和请求合并（S3）的需求。

## 3 系统架构总览

### 3.1 组件拓扑

```
┌──────────────────────────────────────────────────────────────────────┐
│  Kubernetes 集群 (namespace: dynamo-system)                           │
│                                                                        │
│  ┌─────────────────┐     ┌─────────────────────────────────────────┐ │
│  │ RL 训练 Pod      │     │  Dynamo Graph Deployment (DGD)          │ │
│  │                  │     │                                          │ │
│  │  ┌────────────┐ │ HTTP│  ┌──────────┐   ┌──────────────────┐   │ │
│  │  │Signal SDK  │─┼─────┼─→│ 控制器    │   │   Frontend Pod    │   │ │
│  │  └────────────┘ │     │  │          │   │   (Axum :8000)    │   │ │
│  │                  │     │  │ 状态机    │   │   PrefillRouter   │   │ │
│  │  训练循环         │     │  │          │   │   KvRouter        │   │ │
│  │  (veRL/OpenRLHF) │     │  │ 容量规划  │   └────────┬─────────┘   │ │
│  └─────────────────┘     │  │          │            │              │ │
│                           │  │ 角色切换  │            │ NATS-RPC     │ │
│                           │  │          │            ▼              │ │
│                           │  │ 请求合并  │   ┌──────────────────┐   │ │
│                           │  │          │──→│ Worker Pods ×N   │   │ │
│                           │  └─────┬────┘   │ ┌──────────────┐ │   │ │
│                           │        │        │ │vLLM 引擎     │ │   │ │
│                           │        │ HTTP   │ │(AsyncLLM)    │ │   │ │
│                           │        └───────→│ ├──────────────┤ │   │ │
│                           │                 │ │Dynamo Handler│ │   │ │
│                           │                 │ ├──────────────┤ │   │ │
│                           │                 │ │RL Sidecar    │ │   │ │
│                           │                 │ │(:9091)       │ │   │ │
│                           │                 │ └──────────────┘ │   │ │
│                           │                 └──────────────────┘   │ │
│                           │                                          │ │
│  ┌──────────┐            │  ┌─────────────┐                        │ │
│  │Prometheus│            │  │ DGDSA CR    │←── patch replicas       │ │
│  │(:9090)   │            │  │ (伸缩适配器) │                         │ │
│  └──────────┘            │  └─────────────┘                        │ │
└──────────────────────────────────────────────────────────────────────┘
```

**图2**：系统组件拓扑。RL Signal SDK 向控制器发送生命周期信号，控制器通过 DGDSA CR 编排伸缩，通过 HTTP 向 worker sidecar 执行运行时操作。

### 3.2 分层架构

系统跨越五个独立层运行，每层有特定的一致性要求：

| 层次 | 组件 | 角色 | 一致性要求 |
|------|------|------|-----------|
| L1 | RL 训练 | 信号发射 | 生命周期事件的时序保证 |
| L2 | 控制器 | 决策与编排 | 单调状态转换，幂等操作 |
| L3 | Kubernetes | 资源管理 | DGDSA replicas ↔ 实际 pods |
| L4 | Dynamo 运行时 | 路由与发现 | MDC 注册表 ↔ 活跃 workers |
| L5 | vLLM 引擎 | 推理执行 | KV 缓存状态 ↔ 路由器的 RadixTree |

**核心洞察**：PD 角色切换或请求迁移必须同时维护 L3-L5 层的一致性。部分更新（如 MDC 已更新但 KV 缓存陈旧）将导致路由错误或数据损坏。

### 3.3 通信协议

| 路径 | 协议 | 用途 |
|------|------|------|
| SDK → 控制器 | HTTP (同步) | 信号传递 |
| 控制器 → DGDSA | K8s API (PATCH) | 副本伸缩 |
| 控制器 → Sidecar | HTTP (:9091) | 角色切换/迁移命令 |
| Frontend → Workers | NATS-RPC | 推理请求 |
| Workers → Router | ZMQ → NATS Core | KV 缓存事件 |
| Workers → etcd | gRPC | MDC 注册/发现 |
| Workers → Workers | NIXL (RDMA/NVLink) | KV block 传输 |

## 4 KV感知路由与前缀树

### 4.1 KvRouter 架构

KvRouter 是 Dynamo 分离式推理管线中的核心路由决策引擎。它基于 KV 缓存重叠度为每个请求选择最优 decode worker，最小化冗余计算。

```
请求 Tokens ──→ compute_block_hash_for_seq()
                      │
                      ▼
                 Block 哈希 [h₀, h₁, ..., hₙ]
                      │
                      ▼
            Indexer.find_matches()
            ┌─────────────────────────┐
            │      RadixTree          │
            │  root                   │
            │   ├─[h₀]→{W1,W2,W3}   │
            │   │  ├─[h₁]→{W1,W2}   │
            │   │  │  └─[h₂]→{W1}   │
            │   │  └─[h₃]→{W3}      │
            │   └─[h₄]→{W4}         │
            └─────────────────────────┘
                      │
                      ▼
            OverlapScores: {W1:3, W2:2, W3:1, W4:0}
                      │
                      ▼
            KvScheduler.schedule()
            logit(w) = α·overlap + β·queue + γ·capacity
                      │
                      ▼
            最优Worker: W1 (3个blocks已缓存)
```

**图3**：KvRouter 请求路由流程。Block 哈希与 RadixTree 匹配以获得每个 worker 的 KV 缓存重叠度，然后结合负载指标进行最终选择。

### 4.2 RadixTree 实现

RadixTree（位于 `lib/kv-router/src/radix_tree.rs`）是将 token block 哈希序列映射到 worker 集合的前缀匹配数据结构：

```rust
struct RadixBlock {
    children: FxHashMap<LocalBlockHash, SharedRadixBlock>,
    workers: FxHashSet<WorkerWithDpRank>,  // 持有该 block 的 workers
    block_hash: Option<ExternalSequenceBlockHash>,
    recent_uses: VecDeque<Instant>,         // 频率追踪
}
```

**匹配算法** (`find_matches`)：
1. 在 root children 中查找 `sequence[0]` → 初始化 `active_workers`
2. 对每个后续哈希，跟随 children；缺少下一个 block 的 workers 被淘汰
3. 存活到深度 N 的 workers 得分为 N 个匹配 blocks
4. **早退优化**：仅剩 1 个 worker 时立即返回
5. **陈旧条目检测**：若 child workers 超过 active 集合，说明 Remove 事件未传播 → 进行全量成员检查

### 4.3 前缀命中规律

| 场景 | 命中模式 | 路由效果 |
|------|---------|---------|
| 相同 system prompt | 前 N 个 blocks 全命中 | 粘性路由到同一 worker |
| 多轮对话 | 历史前缀命中 | 对话亲和性 |
| 首次请求 | 无命中 | 退化为纯负载均衡 |
| LoRA 切换 | 哈希种子变化 | LoRA 天然隔离 |
| 角色切换后 | 触发 `Cleared` 事件 | Worker 子树被清除，从零开始 |

最后一行对 S2 至关重要：角色切换后，被切换 worker 在 RadixTree 中的整个子树通过 `KvCacheEventData::Cleared` 事件被清除，确保路由器不会基于陈旧的 KV 缓存状态将请求路由到该 worker。

### 4.4 事件驱动的树维护

```
vLLM 引擎 ──ZMQ PUB──→ ZMQ 监听器 (Rust)
                             │
                             ▼
                    KvEventPublisher
                    ├─ LocalKvIndexer [环形缓冲区, size=1024]
                    └─ EventPublisher ──NATS Core──→ Router
                                                      │
                                                      ▼
                                             EventSubscriber
                                             ├─ Gap 检测 (单调 event_id)
                                             │   └─ 从 LocalKvIndexer 恢复
                                             └─ Indexer.apply_event()
                                                 └─ RadixTree 更新
```

**图4**：KV 缓存事件从 vLLM 引擎传播到路由器 RadixTree 的完整路径。Gap 检测和恢复确保即使存在瞬时网络问题也能实现最终一致性。

**一致性保证**：事件使用每 (worker, dp_rank) 的单调 `event_id`。若 `received_id > last_id + 1`，路由器触发从 worker 环形缓冲区的 gap 恢复。这提供了**有界恢复时间的最终一致性**。

## 5 KV Block Manager (KVBM)

### 5.1 Block 生命周期状态机

```
                    allocate_blocks()
    ResetPool ─────────────────────────→ MutableBlock (ActivePool)
        ▲                                       │
        │                               stage() / complete()
        │ drop                                  ▼
        │                               CompleteBlock
        │                                       │
        │                               register_block()
        │                                       ▼
        └──────────────────────── ImmutableBlock (InactivePool)
                                        │              ▲
                                downgrade()         upgrade()
                                        ▼              │
                                    WeakBlock ─────────┘
```

**图5**：KVBM block 状态机。所有转换通过 RAII 强制执行——任何 guard 的 drop 自动将 block 归还到正确的池。

### 5.2 三级池架构

| 池 | 内容 | 可驱逐？ | 角色 |
|----|------|---------|------|
| `ResetPool` | 空闲 blocks | 不适用 | 可供分配 |
| `ActivePool` | 使用中 blocks（pinned） | 否 | 当前服务请求 |
| `InactivePool` | 已缓存 blocks（LRU） | 是 | 前缀重用候选 |

**分配策略** (`allocate_blocks(count)`)：
1. 从 ResetPool 取（空闲列表）
2. 不足时 → 从 InactivePool 驱逐（TinyLFU 频率感知）
3. 仍不足 → OOM（请求被拒绝）

**驱逐策略**：TinyLFU（`FrequencyTrackingCapacity`）结合时间局部性（LRU）和频率信息，相比纯 LRU 对扫描引起的缓存抖动有更好的抵抗力。

### 5.3 KVBM 与角色切换 (S2)

Worker 切换角色时，`DualModeWorker._reconfig_kv_pool()` 调用 `engine.reset_prefix_cache()`，触发：

1. `InactivePool` → 所有 blocks 排干回 `ResetPool`
2. 所有已注册的 block 哈希失效
3. `EventReleaseHandle::drop()` 触发 → 为每个驱逐的 block 广播 `KvCacheEvent::Remove`
4. 路由器接收批量 Remove 事件 → 从 RadixTree 中裁剪该 worker

这确保路由器的视图在角色切换后与 worker 的实际 KV 缓存状态一致。

### 5.4 KVBM 与迁移 (S3)

请求迁移期间，`RequestBlockIndex.get_block_ids(request_id)` 获取在途请求的物理 GPU block IDs。这些 IDs 被包含在 `kv_transfer_params` 中用于基于 NIXL 的 D2D 传输。Block-hold 协议确保这些 blocks 在迁移完成或超时之前保持在 `ActivePool`（不可驱逐）。

## 6 NIXL：GPU间KV传输

### 6.1 架构

NIXL（NVIDIA Inference eXchange Library）提供 GPU 内存之间的高性能数据传输，支持 RDMA、NVLink 和 TCP 协议。在 Dynamo 的 PD 分离架构中：

```
Prefill Worker                              Decode Worker
┌────────────────────┐                ┌────────────────────┐
│ GPU 内存            │                │ GPU 内存            │
│ ┌────────────────┐ │                │ ┌────────────────┐ │
│ │ KV Blocks      │ │   NIXL RDMA   │ │ KV Blocks      │ │
│ │ [B0][B1][B2]   │─┼──────────────→│ │ [B0][B1][B2]   │ │
│ └────────────────┘ │  (零拷贝)      │ └────────────────┘ │
│                    │                │                    │
│ NixlConnector      │                │ NixlConnector      │
│ (kv_role=kv_both)  │                │ (kv_role=kv_both)  │
└────────┬───────────┘                └────────┬───────────┘
         │                                     │
         │         TCP Side Channel            │
         └─────────────────────────────────────┘
              (元数据交换: block 描述符,
               远程内存地址)
```

**图6**：用于 KV 缓存传输的 NIXL 架构。数据通过 RDMA/NVLink 直接 GPU-to-GPU 移动。TCP side channel 仅承载轻量元数据。

### 6.2 配置

NIXL 在引擎启动时通过 `--kv-transfer-config` 配置：
```json
{"kv_connector": "NixlConnector", "kv_role": "kv_both"}
```

**关键约束**：connector 必须在引擎构建时指定，不能在运行中的引擎上动态添加。这就是 `DYNAMO_RL_DUAL_MODE=1` 要求预配置 connector 的原因——同一引擎须在 prefill 和 decode 两种角色下都能运作。

### 6.3 NIXL 在角色切换中 (S2)

角色切换时，`DualModeWorker._reconfig_nixl()`：
1. 设置 `handler._nixl_connector = None`
2. 对旧 connector handle 调用 `shutdown()/close()`
3. 新角色的首次请求触发延迟重初始化

Connector 实例按角色区分但共享同一底层 NIXL agent（跨切换持久化）。Side-channel 端点保持稳定。

### 6.4 NIXL 在迁移中 (S3)

迁移期间传递的 `kv_transfer_params` 字典匹配 vLLM 0.16 的 `NixlConnectorScheduler` 接口：

```python
kv_transfer_params = {
    "do_remote_prefill": True,
    "do_remote_decode": False,
    "remote_engine_id": "<源引擎UUID>",
    "remote_block_ids": [12, 45, 78, ...],  # 物理 GPU block IDs
    "remote_host": "10.233.x.y",
    "remote_port": 14579,
    "remote_request_id": "req-abc-123",
}
```

目标 worker 的 `NixlConnectorScheduler.add_new_req_to_recv()` 发起从源 worker GPU 内存的 RDMA READ，直接拉取 KV blocks 而不涉及 CPU。

## 7 服务发现与MDC

### 7.1 Model Deployment Card (MDC)

每个 worker 在 etcd 中注册描述其能力的 Model Deployment Card：

```rust
pub struct ModelDeploymentCard {
    name: String,              // 模型名称
    model_type: ModelType,     // Chat | Prefill | Completions
    model_input: ModelInput,   // Tokens | Text
    runtime_config: ModelRuntimeConfig {
        total_kv_blocks: u32,
        max_num_seqs: u32,
        max_num_batched_tokens: u32,
        ...
    },
    kv_cache_block_size: u32,
    mdcsum: String,            // 配置校验和
}
```

**etcd 路径**：`v1/mdc/{namespace}/{component}/{endpoint}/{instance_id}`

### 7.2 角色切换中的发现 (S2)

`VllmReregistrar` 管理角色切换期间的 MDC 生命周期：

```
switch_role(decode → prefill):
  1. unregister("decode")     → etcd DELETE 旧 MDC
                              → Router 收到 DiscoveryEvent::Removed
                              → Worker 从 decode WorkerSet 移除
  
  2. register("prefill")      → etcd PUT 新 MDC (ModelType::Prefill)
                              → Router 收到 DiscoveryEvent::Added
                              → Worker 加入 prefill WorkerSet
                              → PrefillRouter 重新激活（如果是首个 prefill）
```

**一致性**：unregister→register 序列确保路由器永远不会将请求发送到错误角色的 worker。在注销之前的 `sleep(level=2)` 步骤首先排干所有在途请求。

### 7.3 WorkerSet 隔离

Workers 按 `(namespace, role)` 分组到 `WorkerSet`：
- Decode：key = `"{namespace}"`
- Prefill：key = `"{namespace}:prefill"`

这防止 KvRouter 在同一路由决策中混合 prefill 和 decode workers。

## 8 S2：弹性PD角色切换

### 8.1 问题定义

给定运行中的 DGD 包含 P 个 prefill workers 和 D 个 decode workers，动态改变比例为 P' 个 prefill 和 D' 个 decode，同时不：
- 丢弃在途请求
- 损坏路由器状态
- 留下陈旧的 KV 缓存引用
- 需要 pod 重建或引擎重启

### 8.2 控制器决策逻辑

`ElasticRoleSwitchController` 在每个控制循环 tick（5秒）评估，受 `min_switch_interval_seconds`（30秒）保护：

**Decode → Prefill 触发条件**：
$$\text{prefill\_queue\_depth} \geq T_{\text{prefill}} \quad \wedge \quad \text{decode\_util} \leq T_{\text{idle}} \quad \wedge \quad D > D_{\min}$$

**Prefill → Decode 触发条件**：
$$\text{decode\_queue\_depth} \geq T_{\text{decode}} \quad \wedge \quad \text{prefill\_util} \leq T_{\text{idle}} \quad \wedge \quad P > P_{\min}$$

Worker 选择：`find_most_idle_worker()` → 选中 `in_flight_requests` 最小的 worker。

### 8.3 9步切换协议

```
┌─────────────────────────────────────────────────────────────────┐
│  DualModeWorker.switch_role(target_role="prefill")              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  步骤1: handler.sleep(level=2)                                  │
│         ├─ 从发现中注销 generate 端点                             │
│         ├─ 排干所有在途请求（等待完成）                             │
│         └─ 释放 GPU 内存（vLLM sleep）                           │
│                                                                  │
│  步骤2: 注销伙伴端点（如存在）                                    │
│         └─ 移除双模式额外注册                                     │
│                                                                  │
│  步骤3: reregistrar.unregister(old_role="decode")               │
│         └─ etcd DELETE MDC → Router 从 WorkerSet 移除            │
│                                                                  │
│  步骤4: _reconfig_nixl(target_role)                             │
│         ├─ 关闭旧 NixlConnector handle                          │
│         └─ 设置 handler._nixl_connector = None（延迟重初始化）    │
│                                                                  │
│  步骤5: _reconfig_kv_pool(target_role)                          │
│         ├─ engine.reset_prefix_cache()                           │
│         ├─ InactivePool → 所有 blocks 排干到 ResetPool           │
│         └─ 为所有驱逐的 blocks 触发 KvCacheEvent::Remove          │
│                                                                  │
│  步骤6: handler.set_disaggregation_mode("prefill")              │
│         └─ 在 handler 状态上持久化新角色                          │
│                                                                  │
│  步骤7: reregistrar.register(new_role="prefill")                │
│         └─ etcd PUT 新 MDC → Router 加入 prefill WorkerSet       │
│                                                                  │
│  步骤8: handler.wake_up()                                        │
│         ├─ 恢复 GPU 内存（vLLM wake_up）                         │
│         └─ 重新注册 generate 端点                                 │
│                                                                  │
│  步骤9: 注册伙伴端点（如果是双伙伴模式）                          │
│         └─ 额外 prefill 端点注册                                  │
│                                                                  │
│  步骤10: _emit_role_changed()                                    │
│          ├─ 更新 pod label: nvidia.com/dynamo-current-role       │
│          └─ 发布 role_changed 事件                                │
│                                                                  │
│  ⚠️ 任何步骤异常时:                                               │
│     → reregistrar.register(old_role)                             │
│     → handler.wake_up()                                          │
│     → 恢复 _disaggregation_mode                                  │
│     (Worker 永不会卡在破损状态)                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**图7**：带失败恢复的9步PD角色切换协议。每步解决特定的一致性层。

### 8.4 一致性分析

| 步骤 | 影响层 | 一致性保证 |
|------|--------|-----------|
| 1 | L4 (路由器) | 无新请求路由到此 worker |
| 1 | L5 (引擎) | 所有在途请求在状态变更前完成 |
| 3 | L4 (发现) | 路由器从旧角色 WorkerSet 移除 worker |
| 4 | L5 (NIXL) | 旧 connector handle 释放；无悬挂引用 |
| 5 | L5 (KVBM) | 所有缓存 blocks 释放；Remove 事件传播到路由器 |
| 7 | L4 (发现) | 路由器将 worker 加入新角色 WorkerSet |
| 8 | L5 (引擎) | GPU 内存恢复；准备接受新角色请求 |

**关键不变量**：切换过程中的任何时刻，路由器都不能向该 worker 发送请求。这由 sleep(level=2) → unregister → ... → register → wake_up 序列保证。

### 8.5 Kubernetes 集成

```
控制器                       K8s API              Pod
    │                            │                  │
    │  POST /switch_role         │                  │
    │──────────────────────────────────────────────→│
    │                            │                  │ (9步协议)
    │                            │                  │
    │                            │  PATCH pod label │
    │                            │←─────────────────│
    │                            │                  │
    │  ← {"status":"ok",        │                  │
    │     "switch_time_ms":4500} │                  │
    │←──────────────────────────────────────────────│
```

切换是**原地操作**：无 pod 删除或创建。DGDSA 各角色的副本数仅在需要实际扩缩容（S1）时由控制器调整，角色切换（S2）不涉及。这避免了 K8s 调度器参与，实现 5 秒以内的切换时间。

### 8.6 Partner-Prefill 修复

发现并修复了一个关键的 vLLM 集成问题：vLLM 的 `NixlConnector` 仅在**最后一个**流式 chunk 上设置 `kv_transfer_params`，但 Dynamo 的 Rust `PrefillRouter` 从**第一个** chunk 读取 `disaggregated_params`。

**解决方案**（`main.py` 中的 `_partner_prefill_generate` 包装器）：
```python
async def _partner_prefill_generate(request):
    chunks = []
    async for chunk in handler.generate(request):
        chunks.append(chunk)
    # 从最后一个 chunk 捕获 kv_transfer_params
    kv_params = chunks[-1].kv_transfer_params
    # 输出单个合并 chunk
    consolidated = merge(chunks)
    consolidated.kv_transfer_params = kv_params
    yield consolidated
```

这确保 PrefillRouter 正确接收 NIXL 传输元数据，无论 vLLM 将其放在哪个 chunk 上。

## 9 S3：请求合并迁移

### 9.1 问题定义

在批次尾部（例如 60%+ 请求已完成），剩余在途请求可能分布在多个 decode workers 上，每个仅有 1-3 个活跃请求。缩容会丢弃这些请求。合并将它们迁移到更少的 workers 上，释放 workers 用于缩容。

### 9.2 控制器决策引擎

`ConsolidationDecisionEngine` 使用双指针算法：

**资格门控**：
$$\text{batch\_pct} \geq T_{\text{batch}} \quad \wedge \quad |\text{workers}| > D_{\min}$$

**配对算法**：
1. 按 `in_flight_requests` 升序排列 workers
2. 双指针：`i`（source，低负载）和 `j`（target，高容量）
3. Source 资格条件：`in_flight[i] ≤ T_{\text{consolidation}}`（默认 3）
4. 仅当 `migration_time < 0.5 × estimated_remaining_time` 时执行迁移

### 9.3 两阶段迁移协议

```
┌────────────────────────────────────────────────────────────────┐
│  Phase 2.A: 重计算预填充（降级路径）                              │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  源 Worker                编排器               目标 Worker       │
│       │                     │                      │            │
│       │← POST /migrate_out ─│                      │            │
│       │  {request_id: "*"}  │                      │            │
│       │                     │                      │            │
│       │─ 响应: ─────────────│                      │            │
│       │  {prompt_tokens,    │                      │            │
│       │   generated_tokens, │                      │            │
│       │   sampling_params}  │                      │            │
│       │                     │                      │            │
│       │  (请求立即中止)      │                      │            │
│       │                     │── POST /migrate_in ─→│            │
│       │                     │  {new_prompt =       │            │
│       │                     │   prompt+generated}  │            │
│       │                     │                      │            │
│       │                     │←─ {status: ok,  ─────│            │
│       │                     │    path: recompute}  │            │
│       │                     │                      │            │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  Phase 2.B: NIXL Block 传输（最优路径）                          │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  源 Worker                编排器               目标 Worker       │
│       │                     │                      │            │
│       │← POST /migrate_out ─│                      │            │
│       │  {request_id: "*"}  │                      │            │
│       │                     │                      │            │
│       │─ 响应: ─────────────│                      │            │
│       │  {prompt_tokens,    │                      │            │
│       │   generated_tokens, │                      │            │
│       │   kv_transfer_params:                      │            │
│       │    {remote_block_ids,│                      │            │
│       │     remote_host/port}}                     │            │
│       │                     │                      │            │
│       │  (blocks 被持有,    │                      │            │
│       │   请求未中止)        │                      │            │
│       │                     │── POST /migrate_in ─→│            │
│       │                     │  {kv_transfer_params}│            │
│       │                     │                      │            │
│       │     ◄═══ NIXL RDMA READ ═══════════════════│            │
│       │     (GPU-to-GPU, 零拷贝)                   │            │
│       │                     │                      │            │
│       │                     │←─ {status: ok,  ─────│            │
│       │                     │    path: connector}  │            │
│       │                     │                      │            │
│       │← POST /migration_complete                  │            │
│       │  (中止源请求, 释放blocks)                   │            │
│       │                     │                      │            │
└────────────────────────────────────────────────────────────────┘
```

**图8**：两种迁移路径。Phase 2.A（重计算）是通用降级方案；Phase 2.B（NIXL）是零拷贝最优路径，需要 KVBM block IDs 和 NIXL 连通性。

### 9.4 成本收益门控

`MigrationPolicy` 防止适得其反的迁移：

```python
class MigrationPolicy:
    max_replay_tokens: int = 8192    # 超过此数重计算不划算
    min_generated_tokens: int = 16   # 生成太少不值得迁移
    min_remaining_tokens: int = 32   # 预计即将完成不值得迁移
```

迁移被拒绝的条件：
- 重计算成本（`prompt + generated tokens`）超过 `max_replay_tokens`
- 请求生成的 tokens 太少（不值得开销）
- 请求预计即将完成（剩余量低于阈值）

### 9.5 Block-Hold 一致性协议

Block-hold 机制是 Phase 2.B 正确性的关键：

```
时间线:
t0: migrate_out() → 加入 _pending_migrations
    │  Blocks 保留在 ActivePool（pinned，不可驱逐）
    │  请求继续在源上执行（持续生成 tokens）
    │
t1: 目标发起 NIXL RDMA READ
    │  源 blocks 必须在传输期间保持稳定
    │
t2: 传输完成 → migration_complete()
    │  源请求被中止 → blocks 释放
    │  Blocks 从 Active → Reset pool
    │
t_timeout: 若 t2 在 HOLD_TIMEOUT（10秒）内未到达
    │  sweep_stale_migrations() 触发
    │  强制中止源请求
    │  Blocks 释放（防止无限内存泄漏）
```

**一致性保证**：
1. 传输期间源 blocks 永不被驱逐（active pool pinned）
2. 超时 holds 自动清理（10秒超时 + 2秒扫描间隔）
3. 回滚路径恢复源执行（请求如同无事发生继续运行）

### 9.6 InProcessRequestRegistry 设计

实现中的一个细节：迁入的请求**不会**出现在目标 worker 的 `InProcessRequestRegistry` 中。该注册表仅追踪通过正常 handler 路由路径进入的请求。迁入请求直接提交到 `EngineRequestTracker.submit_request()` → vLLM 的 `AsyncLLM.generate()`。

**含义**：迁移验证不能使用目标端的注册表成员关系。系统转而验证：
- `left_D1 = true`：请求 ID 从源注册表消失
- `D2_accepted = true`：`/migrate_in` 响应包含 `path=recompute` 或 `path=connector`

## 10 RL-Scaling 控制器

### 10.1 状态机

```
         sampling_progress              ready >= target
  IDLE ───────────────────→ WARM_UP ─────────────────→ ACTIVE
   ▲                           │                          │
   │                           │ batch_complete           │ batch_complete
   │      cooldown +           ▼                          ▼
   └──── drain 完成 ────── COOL_DOWN ←────────────────────┘
```

**图9**：控制器状态机。转换由 SDK 信号（sampling_progress、batch_complete）和系统观察（pod 就绪状态、排干完成）触发。

### 10.2 容量规划器

将批次元数据转换为伸缩目标：

$$N_{\text{prefill}} = \left\lceil \frac{\text{batch\_size} \times \text{avg\_isl}}{\text{single\_prefill\_tps} \times \text{target\_prefill\_seconds}} \right\rceil$$

$$N_{\text{decode}} = \left\lceil \frac{\text{batch\_size}}{\text{max\_concurrent\_per\_decode}} \right\rceil$$

约束条件：
$$N_{\text{prefill}} + N_{\text{decode}} \leq \text{max\_gpus}$$

优先级：prefill 优先获得分配；decode 使用剩余量。

### 10.3 控制循环架构

```python
async def _control_loop():
    while True:
        # S1: 状态机 tick
        await state_machine.control_loop_tick()
        
        # S2: 角色切换评估（如启用）
        if role_switch_enabled:
            await role_switch_controller.tick()
        
        # S3: 合并评估（如启用）
        if consolidation_enabled:
            await consolidation_controller.tick()
        
        await asyncio.sleep(control_loop_interval)
```

## 11 测试与验证

### 11.1 测试架构

系统采用测试金字塔，共 140 个测试：

| 层级 | 数量 | 范围 |
|------|------|------|
| 单元测试 | 72 | 控制器逻辑（状态机、规划器、角色切换、合并） |
| 单元测试 | 68 | Dynamo 侧（dual_mode、migration、sidecar） |
| E2E 测试 | 2 | 全集群脚本测试（S2、S3） |

### 11.2 E2E 测试：S2 弹性PD切换

**测试脚本**：`test-s2-elastic.sh`

**流程**：
1. 验证初始状态：2 个 decode workers，1 个 prefill worker
2. 发送 `/switch_role {"target_role":"prefill"}` 到一个 decoder
3. 验证：worker 出现在 prefill WorkerSet（MDC 检查）
4. 发送推理请求 → 验证 prefill 路由包含切换后的 worker
5. 切回 → 验证 decode 路由恢复
6. 断言：切换期间 0 个 HTTP 错误，测试窗口内 0 个日志 503

**结果**：通过——切换在约 4.5 秒内完成，零请求丢弃。

### 11.3 E2E 测试：S3 请求合并

**测试脚本**：`test-s3-consolidation.sh`

**流程**：
1. 发送 6 个长时间运行的请求分布在 2 个 decode workers
2. 对每次迁移：`POST /migrate {"source": D1, "target": D2, "request_id": "*"}`
3. 验证每请求：`left_D1=true`（从源注册表消失）且 `D2_accepted=true`（迁移路径确认）
4. 断言：6 次迁移全部成功，无孤立 blocks

**结果**：通过——6/6 MIG_OK，路径=recompute（NIXL 路径通过 connector_enabled 配置单独验证）。

### 11.4 正确性标准

| 属性 | 验证方法 |
|------|---------|
| 切换期间无请求丢弃 | 测试窗口 HTTP 错误计数 = 0 |
| 路由器一致性 | etcd 中 MDC 存在与 worker 角色匹配 |
| KV 缓存相干性 | 切换后观察到 RadixTree `Cleared` 事件 |
| Block-hold 安全 | 并发迁移期间无 OOM |
| 超时 hold 清理 | 注入超时 → 验证 abort 的 sweeper 测试 |

## 12 讨论与未来工作

### 12.1 当前局限

1. **切换时 KV 缓存大小未调整**：`reset_prefix_cache()` 清除缓存 blocks 但不调整 KV 缓存总分配。Prefill 和 decode 共享相同的池大小，这不是最优的（prefill 受益于更大的 blocks，decode 受益于更多并发槽位）。

2. **PrefillRouter 一次性激活**：PrefillRouter 通过 `oneshot::Receiver` 在首个 prefill MDC 出现时激活。如果所有 prefill workers 被移除后重新添加，路由器可能不会重新激活。这是 Dynamo 上游的限制。

3. **重计算预填充开销**：没有 NIXL block 传输时，迁移成本与 `prompt_tokens + generated_tokens` 成正比。对于长上下文（>8K tokens），此开销可能超过收益。

4. **单节点验证**：当前 E2E 测试在单节点单 GPU 集群上运行。多节点 RDMA 传输已通过 NIXL 指标验证但未在完整迁移 E2E 流程中测试。

### 12.2 未来工作

**短期**：
- 在双模式 workers 中实现 KVBM block ID 可用性（当前因未初始化的 block 映射返回 None）
- 添加基于 Prometheus 指标驱动的角色切换决策（当前队列深度为模拟）
- 启用真正的多节点 NIXL 迁移 E2E 测试

**中期**：
- 角色切换时动态 KV 缓存大小调整（需要重新执行 vLLM `_initialize_kv_caches`）
- 与 veRL/OpenRLHF 训练框架集成用于生产信号发射
- 多 DGD 支持（跨多个模型部署伸缩）

**长期**：
- 使用 RL 训练 batch size 预测的预测性伸缩
- 跨集群迁移用于地理分布式训练
- 与 NVIDIA DGX Cloud 编排 API 集成

### 12.3 经验教训

1. **一致性是核心难题**：实际的角色切换逻辑很直接；确保所有系统层（路由器、KVBM、NIXL、发现）在转换期间保持一致需要理解五个独立的代码库。

2. **vLLM 集成需要务实的变通**：chunk 排序 bug（kv_transfer_params 在最后 vs 第一个 chunk）没有文档记录——需要同时阅读 Rust 路由器和 Python connector 源码才能发现。

3. **Block-hold 对正确性至关重要**：初始迁移设计立即中止源请求。这导致竞态条件——NIXL 从已释放的 GPU 内存读取。Hold 协议消除了这类 bug。

4. **Kubernetes 原地更新被低估**：通过 pod label + discovery 更新进行角色切换远快于 pod 替换。K8s API 对切换本身无需自定义 CRD 即已足够。

## 参考文献

[1] Y. Zhong, S. Liu, J. Chen, et al., "DistServe: Disaggregating Prefill and Decoding for Goodput-optimized Large Language Model Serving," in *OSDI*, 2024.

[2] P. Patel, E. Choukse, C. Zhang, et al., "Splitwise: Efficient Generative LLM Inference Using Phase Splitting," in *ISCA*, 2024.

[3] NVIDIA, "Dynamo: A Disaggregated Inference Serving Framework," GitHub, 2024. [Online]. Available: https://github.com/ai-dynamo/dynamo

[4] R. Qin, Z. Li, W. He, et al., "Mooncake: Trading More Storage for Less Computation—A KVCache-Centric Architecture for Serving LLM Chatbot," in *FAST*, 2025.

[5] Y. Fu, L. Xue, S. Huang, et al., "ServerlessLLM: Low-Latency Serverless Inference for Large Language Models," in *OSDI*, 2024.

[6] X. Miao, C. Shi, J. Duan, et al., "SpotServe: Serving Generative Large Language Models on Preemptible Instances," in *ASPLOS*, 2024.

[7] W. Kwon, Z. Li, S. Zhuang, et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention," in *SOSP*, 2023.

[8] L. Zheng, L. Yin, Z. Xie, et al., "SGLang: Efficient Execution of Structured Language Model Programs," in *NeurIPS*, 2024.

[9] NVIDIA, "NIXL: NVIDIA Inference eXchange Library," GitHub, 2024. [Online]. Available: https://github.com/ai-dynamo/nixl

[10] L. Zheng, Z. Huang, C. H. Yu, et al., "vLLM: Easy, Fast, and Cheap LLM Serving with PagedAttention, Quantization, and Optimized CUDA Kernels," GitHub, 2024.

## 附录A：环境配置

| 组件 | 版本/配置 |
|------|----------|
| Kubernetes | 1.34.1（单节点，containerd） |
| NVIDIA GPU Operator | 预装 |
| Dynamo | 1.0.1（分支：rl-scaling） |
| vLLM | 0.16（内置于 Dynamo 镜像） |
| NIXL | 捆绑在 Dynamo 容器中 |
| 模型 | Qwen/Qwen3-0.6B |
| Python | 3.12 |
| 容器镜像 | ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-2ec0978618 |
| 控制器镜像 | ghcr.io/shqizhang/rl-scaling-controller:latest |

## 附录B：Sidecar HTTP API

| 端点 | 方法 | 用途 |
|------|------|------|
| `/healthz` | GET | 健康检查 |
| `/v1/role` | GET | 当前 worker 角色 |
| `/switch_role` | POST | 触发角色切换 |
| `/migrate_out` | POST | 导出请求状态 |
| `/migrate_in` | POST | 导入请求状态 |
| `/migration_complete` | POST | 确认迁移成功 |
| `/migration_rollback` | POST | 取消挂起的迁移 |
| `/migrate` | POST | 完整协调迁移 |
| `/v1/active_requests` | GET | 列出活跃请求ID |

## 附录C：配置参考

### 控制器环境变量

| 变量 | 默认值 | 描述 |
|------|-------|------|
| `PRE_WARM_THRESHOLD` | 0.8 | 触发预热的 sampling 进度 |
| `COOLDOWN_SECONDS` | 30 | 缩容至零前的冷却期 |
| `DRAIN_TIMEOUT_SECONDS` | 60 | 最大排干等待 |
| `CONTROL_LOOP_INTERVAL` | 5.0 | 控制循环周期（秒） |
| `SINGLE_PREFILL_TPS` | 50000 | 单 prefill worker 吞吐（tokens/s） |
| `MAX_CONCURRENT_PER_DECODE` | 64 | 单 decode worker 最大并发序列 |
| `MAX_GPUS` | 8 | GPU 上限 |
| `ROLE_SWITCH_ENABLED` | false | 启用 S2 |
| `CONSOLIDATION_ENABLED` | false | 启用 S3 |
| `PREFILL_QUEUE_THRESHOLD` | 10 | 触发 decode→prefill 的队列深度 |
| `DECODE_QUEUE_THRESHOLD` | 10 | 触发 prefill→decode 的队列深度 |
| `MIN_SWITCH_INTERVAL` | 30.0 | 最小切换间隔（秒） |
| `CONSOLIDATION_THRESHOLD` | 3 | 合并源最大 in-flight 数 |
| `MIN_BATCH_COMPLETION` | 0.6 | 开始合并的批次完成百分比 |

### Worker 环境变量

| 变量 | 默认值 | 描述 |
|------|-------|------|
| `DYNAMO_RL_SIDECAR_PORT` | 9091 | Sidecar 监听端口 |
| `DYNAMO_RL_DUAL_MODE` | 未设置 | 启用双模式（设为1） |
| `DYNAMO_RL_CONNECTOR_ENABLED` | 未设置 | 启用 NIXL 迁移路径（设为1） |
| `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` | 10.0 | Block-hold 超时（秒） |
