# RL-Scaling on Dynamo — 技术深度解析

> 本文档面向开发者，系统梳理 RL-Scaling 在 NVIDIA Dynamo 分离式推理架构上的完整技术实现。
> 按「需求场景 → 架构原理 → 代码实现 → 配置项」的脉络展开，每个方案均以实际代码改动为锚点解释架构知识。

---

## 目录

1. [总览：RL-Scaling 三阶段需求](#1-总览rl-scaling-三阶段需求)
2. [Dynamo 核心架构基础](#2-dynamo-核心架构基础)
   - 2.1 [请求路由（KvRouter / PrefillRouter）](#21-请求路由kvrouter--prefillrouter)
   - 2.2 [前缀树（RadixTree）命中规律](#22-前缀树radixtree命中规律)
   - 2.3 [KV 事件机制（Worker → Router）](#23-kv-事件机制worker--router)
   - 2.4 [KVBM：KV Block 生命周期管理](#24-kvbmkv-block-生命周期管理)
   - 2.5 [NIXL Connector：D2D KV 传输](#25-nixl-connectord2d-kv-传输)
   - 2.6 [服务发现 / MDC（Model Deployment Card）](#26-服务发现--mdcmodel-deployment-card)
   - 2.7 [vLLM 定制化集成层](#27-vllm-定制化集成层)
3. [S1：RL 信号驱动弹性伸缩](#3-s1rl-信号驱动弹性伸缩)
4. [S2：Elastic PD Role Switch](#4-s2elastic-pd-role-switch)
5. [S3：Decoder Consolidation（请求合并迁移）](#5-s3decoder-consolidation请求合并迁移)
6. [RL-Scaling Controller 核心逻辑](#6-rl-scaling-controller-核心逻辑)
7. [RL Signal SDK](#7-rl-signal-sdk)
8. [部署架构与 K8s 集成](#8-部署架构与-k8s-集成)
9. [配置项总参考](#9-配置项总参考)
10. [Git Diff 要点清单](#10-git-diff-要点清单)

---

## 1. 总览：RL-Scaling 三阶段需求

| 阶段 | 需求描述 | 核心能力 |
|------|---------|---------|
| **S1** | RL 训练 sampling 阶段提前预热推理集群，sampling 完毕后缩容至零 | Signal SDK → Controller 状态机 → DGDSA patch replicas |
| **S2** | 根据实时负载在 prefill/decode 角色之间弹性切换同一 GPU 工作节点 | Controller 决策 → Sidecar `/switch_role` → DualModeWorker 9 步切换 |
| **S3** | 批次尾部低负载时，将低占用 decode worker 的在途请求迁移到高负载 worker，腾空节点后缩容 | Controller 决策 → Sidecar `/migrate` → MigrationHandler 2 阶段协议 |

三个阶段的代码改动分布：

```
RL-Scaling/
├── rl-signal-sdk/          ← S1：信号发射 SDK
├── rl-scaling-controller/  ← S1/S2/S3：中枢控制器
├── deploy/                 ← K8s 部署清单
└── test-scripts/           ← E2E 测试

dynamo/components/src/dynamo/vllm/
├── rl_scaling_sidecar.py   ← S2+S3：HTTP sidecar 桥接
├── dual_mode.py            ← S2：角色切换编排器
├── migration.py            ← S3：请求迁移处理器
├── handlers.py             ← S2：sleep/wake_up + disaggregation_mode
└── main.py                 ← S2+S3：sidecar 接线、dual-mode 端点注册
```

---

## 2. Dynamo 核心架构基础

### 2.1 请求路由（KvRouter / PrefillRouter）

#### 架构位置

```
Client → Frontend(HTTP) → PrefillRouter → Prefill Worker(s)
                                              ↓ (kv_transfer_params)
                        KvRouter → Decode Worker(s) ← KV Events
```

#### KvRouter 路由流程

`KvRouter::find_best_match()` 是核心入口（`lib/llm/src/kv_router.rs`）：

```
1. compute_block_hash_for_seq(tokens, block_size)
   - 将 token 序列按 block_size 切片
   - 每个 block 用 XXH3_64(seed=1337) 计算哈希
   - LoRA 场景: seed = 1337 XOR xxh3_64(lora_name)

2. indexer.find_matches(block_hashes) → OverlapScores
   - 遍历 RadixTree，返回每个 worker 的匹配 block 数

3. scheduler.schedule(overlaps, isl_tokens, seq_hashes, ...)
   - 综合 KV 命中率 + 负载均衡计算最优 worker
   - 返回 (WorkerWithDpRank, overlap_blocks)
```

#### KvScheduler 负载感知选择

`DefaultWorkerSelector::select_worker()` 的打分公式：

$$\text{logit}(w) = \alpha \cdot \frac{\text{overlap\_blocks}(w)}{\text{total\_blocks}} + \beta \cdot \text{queue\_load}(w) + \gamma \cdot \text{capacity\_terms}$$

其中：
- $\alpha$ = `overlap_score_weight`（默认权重较高，偏好 KV 命中）
- $\beta$ = `queue_weight`（负载惩罚，queue 越满 logit 越低）
- $\gamma$ = 容量相关项（`isl_tokens`, `decode_blocks`）

最终通过 `softmax_sample(logits, router_temperature)` 选择。当 `temperature=0.0` 时退化为确定性 argmin（最高命中+最低负载的 worker）。

#### PrefillRouter

`PrefillRouter`（`lib/llm/src/kv_router/prefill_router.rs`）是一个一次性激活的代理：
- 当发现 `ModelType::Prefill` 的 MDC 时，通过 `oneshot::Receiver<Endpoint>` 激活
- 激活后创建 `KvPushRouter` 指向 prefill 组件端点
- **关键限制**：激活是一次性的，运行时 metadata 变更不会重新触发

#### Indexer 三种模式

| 模式 | 条件 | 特点 |
|------|------|------|
| `KvIndexer` | `use_kv_events=true && router_event_threads==1` | 单线程 RadixTree + TTL 过期 + 大小裁剪 |
| `Concurrent` (ThreadPoolIndexer) | `use_kv_events=true && router_event_threads>1` (默认 4) | 多线程 DashMap，sticky-worker 路由，无 TTL |
| `None` | `overlap_score_weight==0.0` | 不使用 KV 命中信息，纯负载路由 |

---

### 2.2 前缀树（RadixTree）命中规律

#### 数据结构

```rust
// lib/kv-router/src/radix_tree.rs
struct RadixBlock {
    children: FxHashMap<LocalBlockHash, SharedRadixBlock>,
    workers: FxHashSet<WorkerWithDpRank>,  // 持有该 block 的 workers
    block_hash: Option<ExternalSequenceBlockHash>,
    recent_uses: VecDeque<Instant>,         // 频率追踪
}
```

树结构：
```
root (SharedRadixBlock)
  └── children[hash_0] → RadixBlock
       ├── workers: {W1, W2}
       └── children[hash_1] → RadixBlock
            ├── workers: {W1}
            └── children[hash_2] → ...
```

#### 匹配算法

`find_matches(sequence: Vec<LocalBlockHash>) → OverlapScores`：

1. 在 `root.children` 中查找 `sequence[0]`
2. 初始化 `active = first_child.workers`（拥有第一个 block 的所有 worker）
3. 逐层深入：每个后续 hash 跟随 children，workers 逐步淘汰
4. 存活到深度 N 的 worker 得分为 N（匹配 N 个 blocks）
5. **早退优化**：当只剩 1 个 worker 时提前返回
6. **陈旧条目检测**：若 `child.workers.len() > active.len()`，说明有 Remove 事件未传播到子节点 → 回退到全量成员检查

#### 命中规律总结

| 场景 | 命中模式 | 路由效果 |
|------|---------|---------|
| 相同 system prompt | 前 N 个 blocks 全命中 | 同 system prompt 的请求倾向同一 worker |
| 多轮对话 | prefix(历史) 命中 → 新轮 miss | 对话倾向粘性到同一 worker |
| 首次请求 | 无命中 | 退化为纯负载均衡 |
| 高 temperature 多样性采样 | generated tokens 不命中 | 仅 prompt 部分有效 |
| LoRA 切换 | hash seed 变化，完全不命中 | LoRA 天然隔离到不同 worker |

#### 事件驱动更新

`apply_event(RouterEvent)` 处理三种事件：
- `Stored`：从 parent 插入新链（新 KV blocks 被缓存）
- `Removed`：从 parent 移除（block 被驱逐），**不级联删除**子节点（故有陈旧条目）
- `Cleared`：清除整个 worker 子树（worker 重启/角色切换时触发）

---

### 2.3 KV 事件机制（Worker → Router）

#### 完整事件路径

```
vLLM Engine (Python)
    ↓ ZMQ PUB (tcp://127.0.0.1:{port + dp_rank})
ZMQ Listener (Rust, SUB socket)
    ↓ deserialize msgpack → KvCacheEvent
KvEventPublisher.tx (unbounded mpsc channel)
    ↓
Event Processor
    ├─ LocalKvIndexer.apply_event_with_buffer() [环形缓冲区, size=1024]
    └─ EventPublisher.publish_event(RouterEvent) [NATS Core 或 ZMQ 事件面]
         ↓
Router Process (EventSubscriber)
    ├─ Gap Detection: tracks last_event_ids per (worker, dp_rank)
    │   如果 event_id > last_id + 1 → recover_from_worker(gap_start, gap_end)
    │   从 worker 的 LocalKvIndexer 环形缓冲区拉取缺失事件
    └─ Indexer.apply_event(RouterEvent)
         └─ RadixTree / ConcurrentRadixTree 更新
```

#### 事件线格式

```rust
pub struct RouterEvent {
    pub worker_id: WorkerId,   // u64, from component connection_id
    pub event: KvCacheEvent {
        event_id: u64,         // 单调递增计数器 per (worker, dp_rank)
        data: KvCacheEventData,
        dp_rank: DpRank,
    }
}

pub enum KvCacheEventData {
    Stored(KvCacheStoreData {
        parent_hash: Option<ExternalSequenceBlockHash>,
        blocks: Vec<KvCacheStoredBlockData>,
    }),
    Removed(KvCacheRemoveData { block_hashes: Vec<...> }),
    Cleared,
}
```

#### 关键设计决策

| 决策 | 原因 |
|------|------|
| ZMQ 而非 gRPC | vLLM 内部已使用 ZMQ；零拷贝、低延迟 |
| 环形缓冲区 (1024) | 允许短暂网络中断后的 gap recovery 而不丢失所有状态 |
| 事件不级联删除 | 避免大范围树重建，通过陈旧条目检测保证正确性 |
| NATS Core 事件面 | 轻量广播到多个 router 实例，无需持久化 |
| 单调 event_id | 检测 gap；顺序保证每个 (worker, dp_rank) |

#### 配置项

| 参数 | 默认 | 说明 |
|------|------|------|
| `use_kv_events` | `true` | 是否启用实时 KV 事件（关闭则用近似模式） |
| `router_event_threads` | `4` | 事件处理线程数（1=单线程带 TTL，>1=多线程无 TTL） |
| `router_ttl_secs` | `120` | 树节点 TTL（仅单线程模式） |
| `router_max_tree_size` | `2^20` | 树最大节点数 |
| `router_prune_target_ratio` | `0.8` | 裁剪时保留比例 |

---

### 2.4 KVBM：KV Block 生命周期管理

#### Block 状态机

```
Reset ──(allocate_blocks)──► MutableBlock ──(stage/complete)──► CompleteBlock
  ▲                                                                     │
  │                                                        (register_block)
  │ drop                                                         ↓
  └────────────────────────────────────── ImmutableBlock ←──────┘
                                               │
                                           (downgrade)
                                               ↓
                                           WeakBlock ──(upgrade)──► ImmutableBlock
```

所有状态转换通过 RAII guard 强制执行 — 任何 guard 的 drop 自动将 block 归还到正确的池。

#### 三级池架构

```rust
// lib/kvbm-logical/src/manager/mod.rs
pub struct BlockManager<T: BlockMetadata> {
    reset_pool: ResetPool<T>,      // 空闲 blocks
    active_pool: ActivePool<T>,    // 正在使用（pinned，不可驱逐）
    inactive_pool: InactivePool<T>,// 已缓存（可被 LRU 驱逐）
    block_registry: BlockRegistry, // sequence_hash → ImmutableBlock
    allocate_mutex: Mutex<()>,     // 序列化分配
}
```

#### 何时写入 Blocks

1. **Prefill/Decode 步骤完成一个 token block 时**：
   - `MutableBlock::complete()` 创建 `CompleteBlock`
   - `register_block()` 将其转为 `ImmutableBlock` 并放入 inactive pool
   - 同时触发 `KvCacheEvent::Create` 广播到 router

2. **register_block 去重策略**：
   - GPU 层 (`G1`): `BlockDuplicationPolicy::Allow` — 返回 `DuplicateBlock`
   - Host/Disk 层 (`G2+`): `BlockDuplicationPolicy::Reject` — 返回已有的 primary

#### 何时清理/驱逐 Blocks

1. **分配时驱逐** (`allocate_blocks`)：
   - 首先从 `reset_pool` 取空闲 block
   - 不足时从 `inactive_pool` LRU 驱逐
   - 驱逐策略：TinyLFU 频率追踪（`FrequencyTrackingCapacity`），优先驱逐冷/低频 blocks
   - 驱逐触发 `EventReleaseHandle::drop()` → 广播 `KvCacheEvent::Remove`

2. **显式重置** (`reset_inactive_pool`)：
   - 将所有 inactive blocks 回收到 reset pool
   - 在 `engine.reset_prefix_cache()` 时调用
   - **角色切换 (S2) 关键调用点**：`DualModeWorker._reconfig_kv_pool()` → `reset_prefix_cache()`

3. **请求完成/中止**：
   - `ImmutableBlock` 引用计数归零 → block 从 active pool 转入 inactive pool（不立即释放）
   - 只有当 inactive pool 需要为新请求腾空间时才真正驱逐

#### 迁移策略 (S3)

```python
# migration.py
class RequestBlockIndex:
    """Adapter over KvbmCacheManager.get_block_ids()"""
    def get_block_ids(self, request_id: str) -> Optional[list[int]]:
        # 调用 Rust KVBM CacheManager 获取该请求持有的 GPU block IDs
        # 将 list[list[int]] 展平为 flat list[int]
        # 用于 kv_transfer_params 中的 remote_block_ids
```

Block-Hold 协议保证一致性：
1. `migrate_out()` 时将请求加入 `_pending_migrations`（**不立即 abort**）
2. 源节点的 blocks 持续被 pin 在 active pool（请求仍在 in-flight）
3. 目标节点通过 NIXL 拉取 blocks 内容
4. `migration_complete()` 才 abort 源请求，释放 blocks
5. 失败时 `migration_rollback()` 恢复正常执行

**一致性保证**：
- 无分布式锁 — 每个 worker 独立管理自己的 block pool
- Router 的 RadixTree 是最终一致的（事件可能乱序/gap，通过 recovery 补偿）
- Block-Hold 保证迁移期间 source blocks 不被驱逐

---

### 2.5 NIXL Connector：D2D KV 传输

#### 什么是 NIXL

NIXL (NVIDIA Inference eXchange Library) 是 NVIDIA 提供的高性能数据传输库，支持 RDMA/NVLink 直接 GPU-to-GPU 内存传输，绕过 CPU。

#### 配置

vLLM 启动时通过 `--kv-transfer-config` 配置：
```json
{"kv_connector": "NixlConnector", "kv_role": "kv_both"}
```

关键环境变量：
| 变量 | 说明 |
|------|------|
| `VLLM_NIXL_SIDE_CHANNEL_HOST` | NIXL side channel 监听 IP |
| Side channel port | 从 `kv_transfer_config` 读取 |

**重要约束**：`kv_connector` 必须在引擎构建时指定，不能对运行中的引擎动态添加。这是 `DYNAMO_RL_DUAL_MODE=1` 时要求预配置 connector 的原因。

#### NIXL Meta Provider

```python
# rl_scaling_sidecar.py
def make_nixl_meta_provider(vllm_config) -> Callable[[], Optional[dict]]:
    """延迟读取 NIXL 元数据，使角色切换后的 connector 变更被反映"""
    def provider():
        return {
            "engine_id": vllm_config.kv_transfer_config.engine_id,
            "host": vllm_config.kv_transfer_config.nixl_side_channel_host,
            "port": vllm_config.kv_transfer_config.nixl_side_channel_port,
        }
    return provider
```

#### D2D KV 传输流程

```
Source Worker                          Destination Worker
     │                                       │
     │← migrate_out() ──────────────────────│
     │  1. 获取 request blocks (KVBM)        │
     │  2. 获取 NIXL coords                  │
     │  3. 构建 kv_transfer_params:          │
     │     {do_remote_prefill: True,         │
     │      remote_engine_id,                │
     │      remote_block_ids,                │
     │      remote_host, remote_port}        │
     │                                       │
     │──── kv_transfer_params ──────────────→│
     │                                       │← migrate_in()
     │                                       │  提交给 vLLM engine
     │                                       │  NixlConnectorScheduler.add_new_req_to_recv()
     │                                       │  触发 RDMA pull
     │     ←─── NIXL RDMA Pull ────────────→│
     │     (GPU memory 直传, 绕过 CPU)       │
     │                                       │
     │← migration_complete() ────────────────│
     │  abort source request                 │
     │  释放 held blocks                     │
```

`kv_transfer_params` 的字典结构完全匹配 vLLM 0.16 的 `NixlConnectorScheduler.add_new_req_to_recv()` 接口。

#### Side Channel

- NIXL 使用 **TCP side channel** 交换元数据（block 描述符、远程内存地址）
- 实际 KV 数据通过 RDMA/NVLink primitive 高带宽传输
- Side channel 是轻量控制面，不承载数据面流量

#### 当 NIXL 不可用时的降级

如果 KVBM block IDs 未获取到或 NIXL coordinates 不可用（例如 NIXL 未初始化完成），migration 降级为 **Phase-2.A: Recompute-Prefill**：
- 新 prompt = `source_prompt_tokens + source_generated_tokens`
- 目标节点重新做一次完整 prefill
- 代价较高但保证可用性

---

### 2.6 服务发现 / MDC（Model Deployment Card）

#### 注册流程

```python
# main.py: register_vllm_model()
runtime_config = ModelRuntimeConfig(
    total_kv_blocks=...,
    max_num_seqs=...,
    max_num_batched_tokens=...,
    enable_local_indexer=...,
    data_parallel_start_rank=...,
    data_parallel_size=...,
)

await register_model(
    model_type=ModelType.Chat | ModelType.Prefill,
    generate_endpoint=endpoint,
    model_name=config.model,
    kv_cache_block_size=...,
    runtime_config=runtime_config,
)
```

MDC 存入 etcd 路径：
```
v1/mdc/{namespace}/{component}/{endpoint}/{instance_id}
```

#### MDC 结构

```rust
pub struct ModelDeploymentCard {
    name: String,
    model_type: ModelType,          // Chat | Prefill | Completions | Embedding
    model_input: ModelInput,        // Tokens | Text | Tensor
    runtime_config: Option<ModelRuntimeConfig>,
    kv_cache_block_size: u32,
    mdcsum: String,                 // 校验和：同模型所有 worker 必须一致
}
```

#### Router 侧发现

`ModelWatcher::watch()`：
- 订阅 etcd `DiscoveryQuery::AllModels` 的变更流
- `DiscoveryEvent::Added` → 反序列化 MDC → `handle_put()`
  - 如果 `model_type.supports_prefill()` → 激活 `PrefillRouter`
  - 如果 `model_type.supports_chat()` → 建立 `PushRouter`
- `DiscoveryEvent::Removed` → `handle_delete()`
  - 零实例则移除 WorkerSet

**Worker 集合键**：
- Prefill workers: `"{namespace}:prefill"`
- Decode workers: `"{namespace}"`
- 确保 prefill 和 decode 不混入同一 WorkerSet

#### RuntimeConfigWatch

`KvScheduler` 通过 `tokio::sync::watch::Receiver<HashMap<WorkerId, ModelRuntimeConfig>>` 监听 worker 变更：
- worker 加入/离开时更新 `ActiveSequencesMulti` 的追踪集合
- 保证路由决策使用最新的 worker 集合

#### S2 角色切换对发现的影响

`VllmReregistrar`（RL-Scaling 新增）：
```python
class VllmReregistrar:
    """映射 role → (endpoint, ModelType, ModelInput)"""
    async def register(self, role: str):
        await register_vllm_model(model_type=role_to_model_type[role], ...)
    async def unregister(self, role: str):
        await unregister_model(...)
```

角色切换时 MDC 变更序列：
1. `unregister(old_role)` → etcd 删除旧 MDC → Router 收到 `Removed` 事件
2. `register(new_role)` → etcd 写入新 MDC → Router 收到 `Added` 事件
3. Router 自动将 worker 从旧 WorkerSet 移到新 WorkerSet

---

### 2.7 vLLM 定制化集成层

#### 为什么要定制化？

Dynamo 不替换 vLLM，而是在以下 gap 处增加集成层：

| Gap | 定制化内容 | 原因 |
|-----|-----------|------|
| **生命周期管理** | `sleep()`/`wake_up()` in handlers.py | vLLM 没有 discovery 注销/注册 + 优雅排干的原生机制 |
| **路由集成** | KvRouter/PrefillRouter | vLLM 单机不需要跨 worker KV-aware 路由 |
| **disaggregated 流式 bug** | `_partner_prefill_generate` wrapper | vLLM NixlConnector 仅在最后一个 chunk 设置 `kv_transfer_params`，而 Rust PrefillRouter 从第一个 chunk 读取 `disaggregated_params` |
| **角色切换** | DualModeWorker + sidecar | vLLM 不支持运行时 prefill↔decode 切换 |
| **请求迁移** | MigrationHandler | vLLM 没有跨 worker 请求迁移原语 |
| **KV 事件** | ZMQ listener + EventPublisher | vLLM 的 ZMQ 输出需要转为 Dynamo 的事件面格式 |

#### 关键集成点

**AsyncLLM 包装**：
```python
# handlers.py
class BaseWorkerHandler:
    def __init__(self, engine_client: AsyncLLM, ...):
        self.engine_client = engine_client  # vLLM 的异步引擎
```

直接调用的 vLLM API：
- `engine_client.generate()` — 提交推理请求
- `engine_client.abort()` — 中止请求
- `engine_client.reset_prefix_cache()` — 清除前缀缓存
- `engine_client.sleep(level)` — GPU 内存释放
- `engine_client.wake_up()` — GPU 内存恢复

**sleep/wake_up 完整语义**（handlers.py）：
```python
async def sleep(self, level: int = 1):
    """
    level=1: 释放 GPU 内存但保留引擎
    level=2: 同上 + 排干在途请求 + 注销发现端点
    """
    self._unregister_generate_endpoint()
    await drain_in_flight_requests()
    await self.engine_client.sleep(level)

async def wake_up(self):
    await self.engine_client.wake_up()
    self._register_generate_endpoint()
```

**Partner-Prefill Wrapper**（修复 disaggregated 流式 bug）：
```python
# main.py
async def _partner_prefill_generate(request):
    """缓冲所有 chunk，捕获最后一个的 kv_transfer_params，
    合并为一个 chunk 输出 — 使 Rust PrefillRouter 能正确读取"""
    chunks = []
    async for chunk in partner_prefill_handler.generate(request):
        chunks.append(chunk)
    last_kv_params = chunks[-1].kv_transfer_params
    consolidated = merge_chunks(chunks)
    consolidated.kv_transfer_params = last_kv_params
    yield consolidated
```

---

## 3. S1：RL 信号驱动弹性伸缩

### 架构图

```
┌─────────────────┐         ┌──────────────────────┐         ┌───────────────┐
│  RL Training    │  HTTP   │  RL-Scaling Controller│  K8s    │   DGDSA CR    │
│  (sampling loop)│────────→│  State Machine        │────────→│  patch replicas│
│  + Signal SDK   │         │  + Capacity Planner   │         │               │
└─────────────────┘         └──────────────────────┘         └───────────────┘
```

### 状态机

```
States: IDLE → WARM_UP → ACTIVE → COOL_DOWN → IDLE
```

| 状态 | 含义 | 进入条件 |
|------|------|---------|
| `IDLE` | 无 GPU 分配 | 初始状态 / `COOL_DOWN` 排干完成 |
| `WARM_UP` | 已下发扩容，等待 pods Ready | `sampling_progress >= pre_warm_threshold` |
| `ACTIVE` | Workers 就绪，正在服务推理 | `ready_pods >= target_pods` |
| `COOL_DOWN` | 批次完成，正在排干 | `batch_complete` 信号 |

### Capacity Planner 算法

$$N_\text{prefill} = \left\lceil \frac{\text{total\_tokens}}{\text{single\_prefill\_tps} \times \text{target\_prefill\_seconds}} \right\rceil$$

$$N_\text{decode} = \left\lceil \frac{\text{batch\_size}}{\text{max\_concurrent\_per\_decode}} \right\rceil$$

约束：
- $N_\text{prefill} \geq \text{min\_prefill\_replicas}$（≥1）
- $N_\text{decode} \geq \text{min\_decode\_replicas}$（≥1）
- $N_\text{prefill} + N_\text{decode} \leq \text{max\_gpus}$
- 当超出上限时，Prefill 优先，Decode 用剩余

### 控制循环

每 `control_loop_interval`（默认 5s）执行一次 `control_loop_tick()`：

- **WARM_UP 阶段**：轮询 Prometheus `kube_pod_status_ready`，当 `ready >= target` 时转 ACTIVE
- **COOL_DOWN 阶段**：等待 `cooldown_seconds` + in-flight=0；超过 `drain_timeout_seconds` 强制缩容

---

## 4. S2：Elastic PD Role Switch

### 问题域

在 RL 训练场景下，sampling 阶段初期 prefill 负载高、decode 低；后期反转。需要动态调整 P/D 比例而不重启 engine。

### Controller 侧决策

`ElasticRoleSwitchController`（每 tick 评估，受 `min_switch_interval_seconds` 保护）：

**Decode → Prefill 条件**：
```
prefill_queue_depth >= prefill_queue_threshold (10)
AND decode_utilization <= decode_idle_threshold (0.2)
AND decode_worker_count > min_decode_replicas
```

**Prefill → Decode 条件**：
```
decode_queue_depth >= decode_queue_threshold (10)
AND prefill_utilization <= prefill_idle_threshold (0.2)
AND prefill_worker_count > min_prefill_replicas
```

**Worker 选择**：`find_most_idle_worker()` — 选中 `in_flight_requests` 最小的 worker。

### DualModeWorker 9 步切换序列

```python
# dual_mode.py: DualModeWorker.switch_role(target_role)
async def switch_role(self, target_role: str):
    async with self._lock:  # 并发保护
        # 1. handler.sleep(level=2) — 排干 in-flight，注销发现端点
        # 2. 注销额外角色端点（如 partner prefill endpoint）
        # 3. reregistrar.unregister(previous_role) — 从 etcd 移除旧 MDC
        # 4. _reconfig_nixl(target_role) — 销毁旧 NIXL connector
        # 5. _reconfig_kv_pool(target_role) — reset_prefix_cache 清理 GPU blocks
        # 6. handler.set_disaggregation_mode(target_role) — 持久化新角色
        # 7. reregistrar.register(target_role) — 向 etcd 发布新 MDC
        # 8. handler.wake_up() — 恢复 GPU 内存，重新注册 generate 端点
        # 9. 注册新的额外角色端点
        # 10. _emit_role_changed() — pod label 更新 + 事件发布
```

**失败恢复**：任何步骤异常 → 重新注册旧角色 MDC + wake_up + 恢复 `_disaggregation_mode`，保证 worker 永远不会无声卡死。

### 关键子操作

**`_reconfig_nixl(target_role)`**：
- 设置 `handler._nixl_connector = None`
- 对旧 handle 调用 `shutdown()/close()`
- 新角色首次请求时 connector 自动重建（lazy init）

**`_reconfig_kv_pool(target_role)`**：
- 调用 `engine.reset_prefix_cache()` 清空所有 inactive blocks → 释放 GPU 内存
- 不进行真正的 KV cache 大小调整（需要 `_initialize_kv_caches` 重新执行）
- 当前设计：prefill 和 decode 共享同一 KV cache 总量

**Pod Label 更新**：
```python
_patch_self_pod_label("nvidia.com/dynamo-current-role", target_role)
```
- 调用 K8s API patch pod labels
- Best-effort：K8s 外无副作用

### K8s 关键能力支持

| K8s 能力 | 如何支持 PD Switch |
|---------|-------------------|
| **etcd (Discovery)** | MDC 注册/注销实现服务发现的热更新 |
| **DGDSA CR** | Controller patch replicas 控制伸缩 |
| **Pod Labels** | 标记当前角色，观测性 + 潜在调度亲和 |
| **Readiness Probe** | wake_up 后通过 probe 重新进入 Ready 才接收流量 |
| **EndpointSlices** | Dynamo runtime 自动从新端点注册获得路由条目 |

---

## 5. S3：Decoder Consolidation（请求合并迁移）

### 问题域

RL 批次尾部，大部分请求已完成，少量请求散布在多个 decode workers 上。需要将请求合并到少数 workers，腾出空 worker 用于缩容。

### Controller 侧决策

`ConsolidationDecisionEngine.evaluate()`：

**资格门控**：
```
batch_completion_pct >= min_batch_completion_pct (0.6)
AND len(decode_workers) > min_decode_replicas
```

**Two-Pointer 配对算法**：
1. 按 `in_flight_requests` 升序排列 workers
2. 低负载端（i 指针）为 source，高容量端（j 指针）为 target
3. Source 条件：`in_flight_requests <= consolidation_threshold (3)`
4. 迁移仅在 `migration_time < 50% × source.estimated_remaining_time` 时执行

### Sidecar `/migrate` 协调端点

`POST /migrate` 是完整迁移的编排入口（`rl_scaling_sidecar.py`）：

```
1. POST {source}/migrate_out {"request_id": "*"}
   - "*" 表示选择最 progressed 的活跃请求
   - 返回: prompt_tokens, generated_tokens, sampling_params, kv_transfer_params

2. POST {target}/migrate_in {state}
   - 如果有 kv_transfer_params → NIXL pull path
   - 否则 → recompute-prefill path

3a. 成功 → POST {source}/migration_complete
3b. 失败 → POST {source}/migration_rollback
```

### MigrationHandler 实现

#### migrate_out（`migration.py`）

```python
async def migrate_out(self, body: dict) -> dict:
    request_id = body.get("request_id", "*")
    
    # "*" 解析为最 progressed 的活跃请求
    if request_id == "*":
        request_id = self._pick_most_progressed()
    
    # 获取请求状态
    state = self.tracker.get_request_state(request_id)
    
    # KVBM block IDs（用于 NIXL 路径）
    src_block_ids = self.block_index.get_block_ids(request_id)
    
    # NIXL 元数据
    nixl_coords = self.nixl_meta_provider()
    
    # 构建 kv_transfer_params（当 connector_enabled + blocks + NIXL 都就绪）
    use_kv_transfer = (
        self.connector_enabled
        and src_block_ids is not None
        and nixl_coords is not None
    )
    
    if use_kv_transfer:
        response["kv_transfer_params"] = {
            "do_remote_prefill": True,
            "do_remote_decode": False,
            "remote_engine_id": nixl_coords["engine_id"],
            "remote_block_ids": list(src_block_ids),
            "remote_host": nixl_coords["host"],
            "remote_port": int(nixl_coords["port"]),
            "remote_request_id": request_id,
        }
    
    # Block-Hold: 不立即 abort，加入 pending
    self._pending_migrations[request_id] = PendingMigration(...)
    return response
```

#### migrate_in（`migration.py`）

```python
async def migrate_in(self, body: dict) -> dict:
    # 成本收益门控
    if not self._should_migrate(body):
        return {"status": "rejected", "reason": "cost exceeds benefit"}
    
    kv_transfer_params = body.get("kv_transfer_params")
    
    if self.connector_enabled and kv_transfer_params:
        # Phase-2.B: NIXL pull path
        await self.tracker.submit_request(
            prompt_tokens=body["prompt_tokens"],
            sampling_params=body["sampling_params"],
            request_id=new_request_id,
            kv_transfer_params=kv_transfer_params,
        )
        return {"status": "ok", "path": "connector"}
    else:
        # Phase-2.A: Recompute-prefill
        new_prompt = body["prompt_tokens"] + body["generated_tokens"]
        await self.tracker.submit_request(
            prompt_tokens=new_prompt,
            sampling_params=body["sampling_params"],
            request_id=new_request_id,
        )
        return {"status": "ok", "path": "recompute"}
```

#### 成本收益门控（MigrationPolicy）

```python
@dataclass
class MigrationPolicy:
    max_replay_tokens: int = 8192    # 超过此数不值得 recompute
    min_generated_tokens: int = 16   # 太少的 generated 不值得迁移
    min_remaining_tokens: int = 32   # 预计剩余太少不值得
```

#### Stale Migration Sweeper

每 2 秒运行一次，强制 abort 超过 `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT`（默认 10s）的 pending migrations，防止 block leak。

---

## 6. RL-Scaling Controller 核心逻辑

### 目录结构

```
rl-scaling-controller/src/rl_scaling_controller/
├── main.py              # 入口：FastAPI + control loop
├── config.py            # 全部配置从环境变量加载
├── state_machine.py     # S1 核心状态机
├── capacity_planner.py  # 容量规划算法
├── signal_receiver.py   # HTTP 信号接收 API
├── dgdsa_client.py      # K8s DGDSA CR 操作
├── metrics_collector.py # Prometheus 指标查询
├── role_switch/
│   ├── controller.py    # S2 决策引擎
│   ├── dual_mode_client.py  # HTTP → sidecar /switch_role
│   └── strategy.py     # Worker 选择策略
└── consolidation/
    ├── controller.py    # S3 决策引擎
    ├── decision_engine.py   # Two-pointer 配对
    └── migration_client.py  # HTTP → sidecar /migrate
```

### 启动流程

```python
# main.py: build()
app = FastAPI()
capacity_planner = CapacityPlanner(config)
dgdsa_client = K8sDGDSAClient(config) or InMemoryDGDSAClient()
metrics = PrometheusMetricsCollector(config)
state_machine = ScalingStateMachine(capacity_planner, dgdsa_client, metrics, config)

# 如果启用 S2
if config.role_switch_enabled:
    role_switch_ctrl = ElasticRoleSwitchController(DualModeClient(), metrics, config)

# 如果启用 S3  
if config.consolidation_enabled:
    consolidation_ctrl = ConsolidationController(MigrationClient(), metrics, config)

# 控制循环
async def _control_loop():
    while True:
        await state_machine.control_loop_tick()
        if role_switch_ctrl: await role_switch_ctrl.tick()
        if consolidation_ctrl: await consolidation_ctrl.tick()
        await asyncio.sleep(config.control_loop_interval)
```

### 与 Worker Sidecar 的通信

| Controller 动作 | HTTP 调用 | Sidecar 端点 |
|----------------|-----------|-------------|
| 角色切换 | `POST {worker_ip}:9091/switch_role` | → DualModeWorker |
| 迁移 | `POST {source_ip}:9091/migrate` | → 编排完整迁移 |
| 获取角色 | `GET {worker_ip}:9091/v1/role` | → 读取当前角色 |
| 健康检查 | `GET {worker_ip}:9091/healthz` | → 确认 sidecar 存活 |

---

## 7. RL Signal SDK

### 设计理念

SDK 是一个极简的同步 HTTP 信号发射器，**不拥有训练循环**。RL 训练框架（如 veRL）在关键时机调用 SDK 方法。

### API

```python
from rl_signal import RLSignalEmitter, BatchMeta

emitter = RLSignalEmitter(controller_url="http://rl-scaling-controller:8080")

# 训练循环中
for step in training_steps:
    # Sampling 进度上报（触发预热）
    emitter.sampling_progress(progress=0.85, batch_meta=BatchMeta(
        batch_size=64,
        avg_isl=512,
        total_tokens=64*512,  # 可选，不传则自动计算
    ))
    
    # Sampling 完毕（触发完整扩容）
    emitter.sampling_done(batch_meta=BatchMeta(batch_size=64, avg_isl=512))
    
    # 批次完成（触发缩容）
    emitter.batch_complete()

emitter.close()
```

### BatchMeta 验证

```python
@dataclass
class BatchMeta:
    batch_size: int      # 必须 > 0
    avg_isl: int         # 必须 > 0
    total_tokens: Optional[int] = None  # 未提供时 = batch_size × avg_isl
```

### Transport 层

默认 `HttpxTransport`：同步 HTTP POST，timeout 可配置。协议只用 `Transport.post(endpoint, payload)` 接口。

---

## 8. 部署架构与 K8s 集成

### 部署组件

```
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (namespace: dynamo-system)                    │
│                                                                   │
│  ┌───────────────────┐  ┌────────────────────────────────────┐  │
│  │ RL-Scaling        │  │  DynamoGraphDeployment (DGD)        │  │
│  │ Controller        │  │                                      │  │
│  │ (Deployment×1)    │  │  Frontend ── PrefillRouter          │  │
│  │                   │  │       ↓              ↓               │  │
│  │ - state_machine   │  │  PrefillWorker   DecodeWorker(s)    │  │
│  │ - role_switch     │  │    (NIXL)         (NIXL + Sidecar)  │  │
│  │ - consolidation   │  │                                      │  │
│  └───────┬───────────┘  └──────────────────────────────────────┘  │
│          │                                                         │
│          │ patch replicas                                          │
│          ↓                                                         │
│  ┌───────────────────┐                                            │
│  │ DGDSA CR          │  DynamoGraphDeploymentScalingAdapter       │
│  │ - prefill replicas │  (nvidia.com/dynamo, v1alpha1)            │
│  │ - decode replicas  │                                            │
│  └───────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
```

### K8s 清单结构

```
deploy/manifests/
├── 01-rbac.yaml       # ServiceAccount + ClusterRole + Binding
├── 02-configmap.yaml  # 运行时配置
└── 03-deployment.yaml # Controller Deployment + Service
```

#### RBAC 权限

```yaml
rules:
- apiGroups: ["dynamo.nvidia.com"]
  resources: ["dynamographdeploymentscalingadapters/scale"]
  verbs: ["get", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "patch"]  # 用于 pod label 更新
```

#### ConfigMap 关键配置

```yaml
data:
  DYNAMO_NAMESPACE: "dynamo-system"
  DGD_NAME: "vllm-v1-disagg-router"
  PRE_WARM_THRESHOLD: "0.8"
  COOLDOWN_SECONDS: "30"
  CONTROL_LOOP_INTERVAL: "5"
  ROLE_SWITCH_ENABLED: "true"
  CONSOLIDATION_ENABLED: "true"
```

### Auto-Rollout 机制

`deploy/auto-rollout/` 提供 systemd service：
- `watch-and-rollout.sh`：轮询 GHCR image digest 变更
- `rollout-once.sh`：检测到新 digest → rebuild → apply
- 实现 CI/CD 的最后一公里自动部署

---

## 9. 配置项总参考

### Controller 配置（环境变量）

| 变量 | 默认 | 说明 |
|------|------|------|
| `DYNAMO_NAMESPACE` | `dynamo-system` | K8s namespace |
| `DGD_NAME` | `vllm-v1-disagg-router` | DGDSA 资源名前缀 |
| `PROMETHEUS_URL` | `http://prometheus-...:9090` | Prometheus 地址 |
| `PRE_WARM_THRESHOLD` | `0.8` | sampling 进度阈值触发预热 |
| `COOLDOWN_SECONDS` | `30` | 缩容前冷却等待 |
| `DRAIN_TIMEOUT_SECONDS` | `60` | 排干超时强制缩容 |
| `CONTROL_LOOP_INTERVAL` | `5.0` | 控制循环间隔 (秒) |
| `SINGLE_PREFILL_TPS` | `50000` | 单 prefill worker 吞吐 (tokens/s) |
| `MAX_CONCURRENT_PER_DECODE` | `64` | 单 decode worker 最大并发 |
| `TARGET_PREFILL_SECONDS` | `5.0` | 目标 prefill 延迟 |
| `MAX_GPUS` | `8` | GPU 上限 |
| `MIN_PREFILL_REPLICAS` | `1` | prefill 最小副本数 |
| `MIN_DECODE_REPLICAS` | `1` | decode 最小副本数 |
| `ROLE_SWITCH_ENABLED` | `false` | 启用 S2 |
| `PREFILL_QUEUE_THRESHOLD` | `10` | prefill 队列深度阈值 |
| `DECODE_QUEUE_THRESHOLD` | `10` | decode 队列深度阈值 |
| `DECODE_IDLE_THRESHOLD` | `0.2` | decode 空闲 GPU 利用率阈值 |
| `PREFILL_IDLE_THRESHOLD` | `0.2` | prefill 空闲 GPU 利用率阈值 |
| `MIN_SWITCH_INTERVAL` | `30.0` | 最小切换间隔 (秒) |
| `CONSOLIDATION_ENABLED` | `false` | 启用 S3 |
| `CONSOLIDATION_THRESHOLD` | `3` | source 最大 in-flight 数 |
| `MIN_BATCH_COMPLETION` | `0.6` | 开始合并的最小批次完成比 |
| `PER_REQUEST_MIGRATION_OVERHEAD` | `0.5` | 每请求迁移开销 (秒) |

### Worker Sidecar 配置（环境变量）

| 变量 | 默认 | 说明 |
|------|------|------|
| `DYNAMO_RL_SIDECAR_PORT` | `9091` | Sidecar HTTP 端口 |
| `DYNAMO_RL_SIDECAR_DISABLED` | 未设置 | 设为 `1` 完全禁用 sidecar |
| `DYNAMO_RL_DUAL_MODE` | 未设置 | 设为 `1` 启用双模式 (S2) |
| `DYNAMO_RL_DUAL_PARTNER_PREFILL` | 未设置 | 设为 `1` 切换后真实服务 prefill |
| `DYNAMO_RL_CONNECTOR_ENABLED` | 未设置 | 设为 `1` 启用 NIXL KV 传输 (Phase-2.B) |
| `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` | `10.0` | 迁移 block-hold 超时 (秒) |

### Dynamo Router 配置

| 参数 | 默认 | 说明 |
|------|------|------|
| `use_kv_events` | `true` | 启用实时 KV 事件 |
| `router_event_threads` | `4` | 事件处理线程数 |
| `router_ttl_secs` | `120` | 树节点 TTL (仅单线程模式) |
| `router_max_tree_size` | `1048576` | 树最大节点数 |
| `router_prune_target_ratio` | `0.8` | 裁剪保留比例 |
| `overlap_score_weight` | 高 | KV 命中权重 |
| `queue_weight` | - | 负载惩罚权重 |
| `router_temperature` | `0.0` | 路由决策温度 (0=确定性) |
| `router_queue_threshold` | - | 请求排队阈值 |

---

## 10. Git Diff 要点清单

### 新增文件（Dynamo 侧）

| 文件 | 行数 | 角色 |
|------|------|------|
| `components/src/dynamo/vllm/rl_scaling_sidecar.py` | ~600 | S2+S3 HTTP sidecar |
| `components/src/dynamo/vllm/migration.py` | ~515 | S3 迁移协议实现 |
| `components/src/dynamo/vllm/dual_mode.py` | ~420 | S2 角色切换编排 |

### 修改文件（Dynamo 侧）

| 文件 | 修改点 | 说明 |
|------|--------|------|
| `handlers.py` | 新增 `_disaggregation_mode` 字段 | S2 角色状态持久化 |
| `handlers.py` | 新增 `request_registry` 字段 | S3 请求追踪 |
| `handlers.py` | 新增 `set_disaggregation_mode()` / `get_disaggregation_mode()` | S2 角色读写 |
| `main.py` | 新增 `VllmReregistrar` 类 (~85行) | S2 角色注册/注销映射 |
| `main.py` | `init_decode()` 扩展 (~230行) | 双模式端点 + sidecar 接线 |
| `main.py` | `_partner_prefill_generate` wrapper (~40行) | 修复 disaggregated 流式 bug |
| `main.py` | `_generate_dispatch` (~15行) | 多态 generate 分发 |

### 新增文件（RL-Scaling 侧）

| 路径 | 说明 |
|------|------|
| `rl-scaling-controller/src/rl_scaling_controller/main.py` | 入口 + 控制循环 |
| `rl-scaling-controller/src/rl_scaling_controller/state_machine.py` | S1 状态机 |
| `rl-scaling-controller/src/rl_scaling_controller/capacity_planner.py` | 容量规划 |
| `rl-scaling-controller/src/rl_scaling_controller/signal_receiver.py` | HTTP API |
| `rl-scaling-controller/src/rl_scaling_controller/dgdsa_client.py` | K8s CR 操作 |
| `rl-scaling-controller/src/rl_scaling_controller/metrics_collector.py` | Prometheus 查询 |
| `rl-scaling-controller/src/rl_scaling_controller/config.py` | 配置加载 |
| `rl-scaling-controller/src/rl_scaling_controller/role_switch/controller.py` | S2 决策 |
| `rl-scaling-controller/src/rl_scaling_controller/role_switch/dual_mode_client.py` | S2 HTTP client |
| `rl-scaling-controller/src/rl_scaling_controller/role_switch/strategy.py` | Worker 选择 |
| `rl-scaling-controller/src/rl_scaling_controller/consolidation/controller.py` | S3 决策 |
| `rl-scaling-controller/src/rl_scaling_controller/consolidation/decision_engine.py` | 配对算法 |
| `rl-scaling-controller/src/rl_scaling_controller/consolidation/migration_client.py` | S3 HTTP client |
| `rl-signal-sdk/src/rl_signal/emitter.py` | 信号发射器 |
| `rl-signal-sdk/src/rl_signal/events.py` | BatchMeta 定义 |
| `rl-signal-sdk/src/rl_signal/transport.py` | HTTP 传输层 |

### 关键设计决策总结

| 决策 | 理由 |
|------|------|
| Sidecar 而非直接 RPC | Controller 说 HTTP，Dynamo runtime 说 NATS-RPC；sidecar 做协议桥接 |
| Block-Hold 而非立即 abort | 保证 NIXL pull 期间源 blocks 不被驱逐 |
| Recompute-Prefill 作为降级 | NIXL 未就绪时保证可用性，代价是重算 |
| reset_prefix_cache 而非 resize KV | 避免 `_initialize_kv_caches` 重执行的复杂度 |
| `_partner_prefill_generate` 缓冲 | 修复 vLLM 最后 chunk 才设 params vs Rust router 读第一个 chunk 的不匹配 |
| Pod label best-effort | K8s 外运行时（开发/测试）不 panic |
| 单调 event_id + gap recovery | 允许短暂中断但保证最终一致 |
| TinyLFU 驱逐 | 比纯 LRU 对突发扫描更健壮 |
| Two-pointer 配对 | O(n log n) 复杂度，避免组合爆炸 |

---

*文档版本: 2025-05-13 | 基于 commit hash: 2ec0978618*
