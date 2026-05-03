# RL 场景下 Dynamo Scaling 优化 — 统一技术方案与开发指导

> **项目**: HKUST MSc Thesis — Cloud Native LLM Serving Scale  
> **作者**: Shengqi Zhang  
> **日期**: 2026-07  
> **版本**: v2.0 (整合 Technical Proposal + Requirements Document)  
> **Baseline**: NVIDIA Dynamo v1.0.1 (Latest Stable)

---

## 目录

- **知识库篇**
  - [K1. LLM 推理原理：Prefill 与 Decode](#k1-llm-推理原理prefill-与-decode)
  - [K2. Dynamo 部署架构与 Router 内部状态](#k2-dynamo-部署架构与-router-内部状态)
  - [K3. RL 推理场景特征与优化目标](#k3-rl-推理场景特征与优化目标)
  - [K4. Dynamo 版本对比与 Baseline 选择](#k4-dynamo-版本对比与-baseline-选择)
  - [K5. KV Cache 一致性保障总体方案](#k5-kv-cache-一致性保障总体方案)
  - [K6. KV Cache 深度解析与 KVBM](#k6-kv-cache-深度解析与-kvbm)
- **场景篇**
  - [S1. Rollout-based Scale Up/Down](#s1-rollout-based-scale-updown)
  - [S2. Elastic Role Switch (Prefill ↔ Decode)](#s2-elastic-role-switch-prefill--decode)
  - [S3. Request Consolidation & Redirection](#s3-request-consolidation--redirection)
- **工程篇**
  - [E1. 实现优先级与开发路线图](#e1-实现优先级与开发路线图)
  - [E2. 最小化部署方案](#e2-最小化部署方案)
  - [E3. 部署拓扑与系统集成](#e3-部署拓扑与系统集成)
  - [E4. 验证与测试策略](#e4-验证与测试策略)
  - [E5. 风险评估](#e5-风险评估)
- **附录**
  - [附录 A：关键术语表](#附录-a关键术语表)
  - [附录 B：参考链接](#附录-b参考链接)

---

# 知识库篇

## K1. LLM 推理原理：Prefill 与 Decode

每一个发送到 LLM 的请求，**无论模型架构如何**，都必须经历两个串行阶段：

```
═══════════════════════════════════════════════════════════════════
阶段 1: Prefill（预填充 / Prompt Processing）
═══════════════════════════════════════════════════════════════════

输入: ["Hello", ",", "how", "are", "you", "?"]  (6 个 tokens)

                    ┌──────────────────────────┐
 6 tokens ────────▶ │  ALL Transformer Layers  │ ────▶ KV Cache (6 个位置)
 (并行处理)          │  (Layer 1 → Layer N)     │       + next_token_logits
                    │  自注意力+FFN × N层       │
                    └──────────────────────────┘

特征:
- 所有输入 tokens 同时通过所有层（一次前向传播）
- 产出: 为每个 token 位置计算 Key 和 Value，存入 KV Cache
- 计算特征: 大矩阵乘法 → Compute-Bound（受限于 GPU FLOPS）
- 类比: "阅读理解"——模型一次性读取并理解整个输入

═══════════════════════════════════════════════════════════════════
阶段 2: Decode（自回归生成 / Generation）
═══════════════════════════════════════════════════════════════════

第 1 步: 生成 token "I"
                    ┌──────────────────────────┐
 1 token ─────────▶ │  ALL Transformer Layers  │ ────▶ KV Cache 追加 1 位置
 (只有新 token)      │  新 Q × 所有历史 K,V     │       + next_token_logits
 + KV Cache ───────▶│                          │
 (6 个位置)          └──────────────────────────┘

第 2 步: 生成 token "am" ... 重复直到 EOS 或 max_tokens

特征:
- 每步只处理 1 个新 token，但需读取整个 KV Cache
- 计算特征: 小矩阵乘 + 大量内存读取 → Memory-Bandwidth-Bound
- 类比: "一个字一个字地写回答"——每写一个字都要回顾之前所有内容
```

**要点**：Prefill 和 Decode 使用 **完全相同的模型权重**，区别仅在于计算模式和资源瓶颈类型。这是 PD 分离和 Role Switch 可行性的根本基础。

---

## K2. Dynamo 部署架构与 Router 内部状态

### K2.1 部署全景

```
┌──────────────────────────────────────────────────────────────┐
│ Dynamo 完整组件关系                                            │
│                                                              │
│  Client ──▶ Frontend Pod                                     │
│             ├── HTTP Server :8000 (OpenAI API)               │
│             ├── Pre-processor                                │
│             └── Router ◀── 嵌入在 Frontend 中（非独立部署）     │
│                  │                                           │
│          ┌───────┴───────┐                                   │
│          ▼               ▼                                   │
│  Prefill Worker Pod    Decode Worker Pod                     │
│  (GPU, vLLM Engine)    (GPU, vLLM Engine)                    │
│  NIXL: KV sender       NIXL: KV receiver                    │
│                                                              │
│  可选: Planner Pod (SLA 驱动自动扩缩)                         │
│  基础设施: K8s native + TCP/ZMQ (v1.0+, 不再依赖 etcd/NATS)  │
└──────────────────────────────────────────────────────────────┘
```

### K2.2 Router 是有状态的决策引擎

Router **不是**无状态的 Service 转发器，它在内存中维护大量状态，这对理解 Role Switch 等场景至关重要：

```
┌─────────────────────────────────────────────────────────────┐
│              Router 内存状态（非无状态转发）                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. KVIndexer (Radix Tree)                                  │
│     → 追踪每个 worker 上缓存了哪些 KV blocks                 │
│     → 用于计算 overlap_score（新请求能复用多少 cached KV）     │
│                                                             │
│  2. Active Block Tracker                                    │
│     → 追踪每个 worker 的实时负载（active blocks, in-flight）  │
│     → 用于负载均衡决策                                        │
│                                                             │
│  3. Worker Registry (from Discovery Service)                │
│     → 追踪每个 worker 的角色（prefill/decode）和通信地址       │
│                                                             │
│  4. Cost Model                                              │
│     cost = overlap_score_weight × prefill_blocks             │
│           + decode_blocks                                    │
│     → 每次路由时对每个候选 worker 计算成本                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**关键推论**：任何改变 worker 角色、销毁 worker、迁移请求的操作，都必须同步更新 Router 的这些内存状态，否则会导致路由决策错误。

---

## K3. RL 推理场景特征与优化目标

### K3.1 RL Training Loop 时序

```
  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
  │ Sampling  │──▶│  Batch   │──▶│ Training │──▶│ Sampling │──▶ ...
  │ (slow)   │   │ Inference│   │  Update  │   │ (slow)   │
  │ GPU idle │   │ GPU busy │   │ GPU busy │   │ GPU idle │
  └──────────┘   └──────────┘   └──────────┘   └──────────┘
  │◄─── idle ──▶│◄── burst ──▶│◄── train ──▶│◄─── idle ──▶│
```

### K3.2 与 Online Serving 的差异

| 特征 | Online Serving | RL Batch Inference |
|------|---------------|-------------------|
| 流量模式 | 持续、渐变 | 突发、周期性 |
| 优化目标 | 单请求 TTFT/ITL/SLA | Batch 整体完成时间 |
| 空闲期 | 少 | 多（Sampling + Training） |
| 请求关系 | 独立 | 同一 Batch 有相关性 |
| 扩缩容速度要求 | 分钟级可接受 | 秒级需求 |
| 成本敏感度 | 中 | 高（空闲 = 浪费） |

### K3.3 优化目标

$$\text{Minimize } T_{\text{batch}} = \max_{r \in \text{Batch}} T_{\text{complete}}(r)$$

$$\text{Minimize } \text{GPU}_{\text{hours}} = \sum_{g \in \text{GPUs}} T_{\text{allocated}}(g)$$

$$\text{Maximize } \text{GPU}_{\text{utilization}} = \frac{\sum T_{\text{compute}}}{\sum T_{\text{allocated}}}$$

核心思路：**提高单个 GPU effective hour，尽量 batch，同时优化 batch 的整体时间，减少整体 GPU 的使用**。

### K3.4 三个优化场景概述

| 场景 | 优化层面 | 核心目标 | 优先级 |
|------|---------|---------|-------|
| S1: Rollout Scale Up/Down | Scaling | 减少空闲期 GPU 占用 | P0 |
| S2: Elastic Role Switch | Scaling | 消除 PD 相位空闲，最大化 GPU 利用率 | P1 |
| S3: Request Consolidation | Scaling + Router | 尽早释放 GPU 资源 | P2 |

---

## K4. Dynamo 版本对比与 Baseline 选择

### K4.1 版本时间线

```
v0.7.1 ─────▶ v0.8.x ─────▶ v0.9.x ─────▶ v1.0.0 ─────▶ v1.0.1 ─────▶ v1.1.0-dev.1
2025-12       2026-01       2026-02       2026-03       2026-06       2026-06
  │                                         │                │              │
  我们当前部署                         首个 GA 版本      最新稳定版      pre-release
  基础 PD + NATS/etcd                成熟架构            ★ Baseline     Pluggable Scheduling
```

### K4.2 关键能力对比

| 能力 | v0.7.1 | v1.0.1 | v1.1.0-dev.1 |
|------|--------|--------|-------------|
| **KV-Aware Router** | 基础 KV 事件 | 完整 KV Router + 成本模型 + Softmax | 同 + Pluggable scheduling (#7260) |
| **KVIndexer** | ❌ | ✅ Radix Tree + 多线程 | ✅ 独立进程 + P2P 恢复 |
| **Router 多副本同步** | ❌ | ✅ Inter-Router Communication | ✅ |
| **DGDSA** | ❌ | ✅ K8s Scale 适配器 | ✅ |
| **KEDA Scale-to-Zero** | ❌ | ✅ | ✅ |
| **Load-based Scaling** | ❌ | ✅ FPM + ARIMA/Kalman/Prophet | ✅ |
| **Request Migration** | ❌ | ✅ Token state tracking | ✅ |
| **Dynamo Snapshot** | ❌ | ✅ Preview (CRIU + cuda-checkpoint) | ✅ |
| **Service Discovery** | etcd 依赖 | K8s Native (EndpointSlices) | ✅ |
| **Event Plane** | NATS 依赖 | ZMQ 默认 / NATS 可选 | ✅ + Velo trait-based |
| **GlobalPlanner** | ❌ | ❌ (Preview) | ✅ `--max-total-gpus` |

### K4.3 Baseline 选择: ★ Dynamo v1.0.1

| 评估维度 | v0.7.1 | v1.0.1 | 决策因素 |
|---------|--------|--------|---------|
| S1 可行性 | ❌ 无 KEDA/DGDSA | ✅ KEDA Scale-to-Zero + DGDSA | 核心能力缺失 |
| S2 可行性 | ❌ 无 Snapshot / 基础 xPyD | ✅ Snapshot + 增强 xPyD + Discovery | 基础条件具备 |
| S3 可行性 | ❌ 无 Request Migration | ✅ Migration Operator | 核心能力缺失 |
| 基础设施成熟度 | 低 (etcd + NATS) | 高 (K8s native, TCP) | 运维简化 |

**策略**：以 v1.0.1 为 Baseline 开发，密切关注 v1.1 的 Pluggable Scheduling (#7260)，设计时保持接口兼容。

---

## K5. KV Cache 一致性保障总体方案

KV Cache 一致性是贯穿所有三个优化场景的核心问题。

### K5.1 KV Cache 生命周期

```
  Creation ──▶ Active ──▶ Cached ──▶ Eviction
     │           │          │          │
  (Prefill     (Decode    (请求完成   (LRU/LFU
   computed)   in-progress) available  被新请求
                            for reuse) 替换)

  涉及场景:
  ┌─────────┬──────────┬──────────┬──────────┐
  │ Creation │ Active   │ Cached   │ Eviction │
  ├─────────┼──────────┼──────────┼──────────┤
  │S1:缩放   │          │ ✅ 持久化│ ✅ 清理  │
  │S2:切换   │ ⚠️ Drain │ ⚠️ 清理  │          │
  │S3:合并   │ ⚠️ 迁移  │          │ ✅ 释放  │
  └─────────┴──────────┴──────────┴──────────┘
```

### K5.2 不变量 (Invariant)

**对于任何在 decode 中的请求，其 KV Cache 必须包含从 position 0 到当前 position 的所有 key-value 对。**

### K5.3 保障机制与 Dynamo 组件映射

| 机制 | 功能 | Dynamo 组件 |
|------|------|------------|
| KVPublisher | 发布 block stored/removed 事件 | 各 Worker 内置 |
| KVIndexer | 全局 prefix tree，追踪 block 位于哪个 worker | Router 内置 |
| Inter-Router Sync | 多 Router 副本间同步 active block 信息 | Router 内置 |
| NIXL | GPU-to-GPU KV 数据传输 | 独立库 |
| KVBM | 多层存储管理（GPU → Host → SSD） | Worker 内置 |
| Request Migration | 请求状态迁移（token tracking） | Frontend 内置 |

### K5.4 各场景一致性保障矩阵

| | KVPublisher | KVIndexer | Inter-Router Sync | NIXL Transfer | KVBM Offload | Migration Operator |
|---|---|---|---|---|---|---|
| **S1: Scale Up/Down** | Scale Up 后重建 | 从 worker local 恢复 | - | - | ✅ scale down 前 offload | - |
| **S2: 角色切换** | 切换后清除旧条目 | 切换后重建映射 | 通知角色变更 | - | - | - |
| **S3: 请求合并** | 源删除 + 目标添加 | 原子更新 | 更新 active block 计数 | ✅ KV block 迁移 | - | ✅ 请求重定向 |

### K5.5 操作原则

1. **只在请求暂停时操作其 KV Cache**（S2, S3）
2. **通过 KV Events 保持全局视图一致**（所有场景）
3. **KVBM 负责本地块管理，KVIndexer 负责全局索引**（职责分离）

---

## K6. KV Cache 深度解析与 KVBM

KV Cache 是贯穿所有 4 个优化场景的核心数据结构。本节深入解释其物理本质、管理机制和在 scaling 场景下的行为。

### K6.1 KV Cache 的物理本质

#### 什么是 KV Cache

在 Transformer 的自注意力（Self-Attention）中，每个 token 位置会计算三个向量：Query (Q)、Key (K)、Value (V)。注意力计算公式：

$$\text{Attention}(Q, K, V) = \text{softmax}\left(\frac{QK^T}{\sqrt{d_k}}\right) V$$

在 **Decode 阶段**，每步只生成 1 个新 token，但需要与**所有历史 token** 做注意力计算。如果每次都重新计算历史 token 的 K 和 V，则计算量 $O(n^2)$，极其浪费。

**KV Cache 的作用**：缓存所有历史 token 的 K 和 V 向量，每步 decode 只需计算新 token 的 Q，与缓存的 K、V 做注意力。

```
没有 KV Cache (每步重新计算所有 K, V):
  Step 1: 计算 token 1-6 的 K,V + 新 token 的 Q → Attention → token 7
  Step 2: 计算 token 1-7 的 K,V + 新 token 的 Q → Attention → token 8  ← 重复计算 1-6！
  Step 3: 计算 token 1-8 的 K,V + 新 token 的 Q → Attention → token 9  ← 重复计算 1-7！

有 KV Cache:
  Step 1: 用 cached K,V[1-6] + 新 token 的 Q → Attention → token 7, 缓存 K,V[7]
  Step 2: 用 cached K,V[1-7] + 新 token 的 Q → Attention → token 8, 缓存 K,V[8]
  Step 3: 用 cached K,V[1-8] + 新 token 的 Q → Attention → token 9, 缓存 K,V[9]
  → 每步只计算 1 个新 token 的 K,V，历史的直接从缓存读取
```

#### KV Cache 的大小计算

每个 token 位置在每一层、每个注意力头上都有 K 和 V 两个向量：

$$\text{KV\_size\_per\_token} = 2 \times n_{\text{layers}} \times n_{\text{heads}} \times d_{\text{head}} \times \text{dtype\_bytes}$$

| 模型 | Layers | Heads | Head Dim | dtype | 每 Token KV 大小 | 2048 Tokens 的 KV |
|------|--------|-------|----------|-------|----------------|------------------|
| Qwen3-0.6B | 28 | 16 | 64 | fp16 (2B) | 2×28×16×64×2 = 114 KB | ~228 MB |
| LLaMA-7B | 32 | 32 | 128 | fp16 | 2×32×32×128×2 = 524 KB | ~1.05 GB |
| LLaMA-70B | 80 | 64 | 128 | fp16 | 2×80×64×128×2 = 2.62 MB | ~5.24 GB |

**关键洞察**：KV Cache 占用的 GPU VRAM 与**序列长度 × 并发请求数**成正比。对于 RTX 3090 (24 GiB)，加载模型权重后，剩余显存主要被 KV Cache 占用。这就是为什么 KV Cache 管理对 GPU 利用率至关重要。

### K6.2 PagedAttention 与 Block 机制

#### 传统 KV Cache 的问题

传统实现为每个请求预分配一段连续的 GPU 显存用于 KV Cache。问题：

```
GPU VRAM 布局 (传统连续分配):

|--Request A (max_len=2048)--|--Request B (max_len=2048)--|--- 碎片 ---|
|██████░░░░░░░░░░░░░░░░░░░░░░|████░░░░░░░░░░░░░░░░░░░░░░|            |
 实际用 512    浪费 1536       实际用 256   浪费 1792

问题: 按 max_len 预分配 → 大量内部碎片 → 显存利用率低
```

#### PagedAttention (vLLM)

vLLM 的 PagedAttention 借鉴操作系统虚拟内存的分页机制：

```
GPU VRAM 布局 (PagedAttention Block 分配):

Block Table (每个 block = 16 tokens 的 KV):
┌─────────────────────────────────────────────────────────────┐
│  Block Pool:                                                │
│  [Block 0][Block 1][Block 2][Block 3][Block 4][Block 5]... │
│   Req A    Req A    Req B    Req A    Free     Req B        │
│   tok 0-15 tok16-31 tok 0-15 tok32-47          tok16-31     │
└─────────────────────────────────────────────────────────────┘

Request A 的 Block Table: [0, 1, 3]        ← 非连续，按需分配
Request B 的 Block Table: [2, 5]            ← 非连续，按需分配
Free Blocks: [4, 6, 7, ...]                ← 可随时分配给新请求

优势:
1. 按需分配: 只分配实际使用的 blocks，不按 max_len 预留
2. 无碎片: blocks 固定大小，没有内部碎片
3. 共享: 多个请求可共享相同前缀的 blocks (Prefix Caching)
```

**Block 是 Dynamo 中 KV Cache 管理的最小单位**——KVPublisher 发布的事件、KVIndexer 追踪的索引、KVBM 管理的存储层，都以 block 为粒度。

### K6.3 KVBM (KV Block Manager) 多层存储架构

KVBM 是 Dynamo 中管理 KV Cache blocks 跨多层存储的组件，嵌入在每个 Worker 中：

```
┌────────────────────────────────────────────────────────────────────┐
│  KVBM 多层存储架构 (每个 Worker 内部)                                │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Tier 0: GPU VRAM (HBM)            ← 最快，容量有限                │
│  ┌──────────────────────────┐                                      │
│  │ Active KV Blocks         │  ← 正在 decode 的请求的 KV           │
│  │ (in-flight requests)     │    绝对不能 offload                  │
│  ├──────────────────────────┤                                      │
│  │ Cached KV Blocks         │  ← 已完成请求的 KV，可被复用         │
│  │ (prefix cache)           │    复用 = 新请求的 prefill 可以跳过   │
│  │                          │    这些 token 的计算                  │
│  └───────────┬──────────────┘                                      │
│              │ offload (当 GPU VRAM 压力大时)                       │
│              ▼                                                     │
│  Tier 1: Host RAM (CPU Memory)     ← 较快，容量较大                │
│  ┌──────────────────────────┐                                      │
│  │ Offloaded KV Blocks      │  ← 从 GPU 移出的 blocks              │
│  │ (可 recall 回 GPU)       │    recall 需要 PCIe 传输             │
│  └───────────┬──────────────┘                                      │
│              │ offload (当 Host RAM 也紧张时)                      │
│              ▼                                                     │
│  Tier 2: NVMe SSD                  ← 最慢，容量最大                │
│  ┌──────────────────────────┐                                      │
│  │ Persistent KV Blocks     │  ← 长期存储                          │
│  │                          │    recall 需要 SSD 读取               │
│  └──────────────────────────┘                                      │
│                                                                    │
│  操作:                                                              │
│  - allocate(n_blocks) → 从 Tier 0 free list 分配                   │
│  - offload(block_id, target_tier) → 移动 block 到更低层             │
│  - recall(block_id) → 从低层移回 Tier 0                            │
│  - evict(block_id) → 永久删除 block（释放空间）                     │
│  - free(block_id) → 标记为可重用                                    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

**KVBM 与 KVPublisher/KVIndexer 的关系**：

```
Worker 内部:
  KVBM ─── 管理本地 block 的存储位置（在哪个 tier）
    │
    ├── 当 block 被分配/释放时 ──▶ KVPublisher ──(ZMQ)──▶ Router 的 KVIndexer
    │                                                      (更新全局索引)
    │
    └── 当需要 offload/recall 时 ──▶ 自行管理 tier 间数据搬运

Router 的 KVIndexer:
  只知道 "block X 在 worker Y 上存在" (全局视图)
  不知道 block 在 worker 内部的哪个 tier (那是 KVBM 的事)
```

### K6.4 Scale Down 时 KV Cache 的处理策略

这是 S1 (Rollout Scale) 的关键决策点：Scale down 时，Worker 上的 KV Cache 怎么办？

#### 选项分析

| 策略 | 操作 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| **A: 直接丢弃** | evict 所有 blocks，Pod terminated | 最快，最简单 | 下次 scale up 需重新 prefill | RL Batch：每次 batch 请求独立，前一轮 cache 对下一轮无用 |
| **B: Offload 到 Host/SSD** | KVBM offload 到 Tier 1/2，然后 terminate Pod | 保留 cache，下次 recall | offload 需要时间；Host/SSD 空间占用 | 连续 batch 有共同 system prompt |
| **C: 持久化到外部存储** | 导出 KV 到 PVC/S3 | Pod 销毁后仍可恢复 | 极慢，开发复杂 | 不推荐 |

#### RL 场景推荐：A (直接丢弃) 为主，B (Offload) 为可选优化

**理由**：

```
RL 训练 Batch 1:  [Prompt A1] [Prompt A2] ... [Prompt A128]
                  ↓ prefill → KV Cache A1, A2, ...
                  ↓ decode → 生成 response
                  ↓ batch 完成 → scale down

                  --- Sampling + Training (30 分钟) ---

RL 训练 Batch 2:  [Prompt B1] [Prompt B2] ... [Prompt B128]
                  这些 prompt 与 Batch 1 完全不同！
                  Batch 1 的 KV Cache 对 Batch 2 零复用价值

唯一可能的复用: system prompt (如 "You are a helpful assistant...")
  → 这部分通常很短 (< 100 tokens)
  → 重新 prefill 的代价很小 (< 0.1 秒)
  → 不值得 offload 的开销

结论: 直接丢弃是最优策略
```

**实际 Scale Down 流程**：

```
COOL_DOWN 阶段:
1. RL Scaling Controller 检测到 batch 完成
2. Controller 设置 worker 为 draining 状态
3. 等待所有 in-flight 请求完成 (此时 KV Cache 处于 Active 状态，不可动)
4. 所有请求完成后:
   → Active blocks → 0
   → Cached blocks: 直接 evict (不 offload)
   → KVBM 释放所有 blocks
   → KVPublisher 批量发送 "blocks removed" events
   → Router KVIndexer 清除该 worker 的所有索引
5. Controller patch DGDSA replicas = 0
6. K8s 终止 Pod → GPU 释放
```

### K6.5 Scale Up 时的模型加载延迟问题

Scale Up 的瓶颈不是 KV Cache（新请求从零开始），而是 **模型权重加载**。

#### 模型加载的时间分解

```
Scale Up 时间线 (从 DGDSA replicas 变更到 Worker Ready):

┌──────────────────────────────────────────────────────────────┐
│ 1. Pod Scheduling (K8s)                        ~5-15 秒      │
│    K8s 调度器选择节点，检查 GPU 资源                           │
│    nvidia-device-plugin 分配 GPU                              │
├──────────────────────────────────────────────────────────────┤
│ 2. Container Pull (如果镜像不在本地)           ~0-60 秒       │
│    拉取 Dynamo worker 容器镜像                                │
│    首次拉取可能很大 (5-10 GB)                                  │
├──────────────────────────────────────────────────────────────┤
│ 3. Container Start + CUDA Init                 ~5-10 秒      │
│    Python/Rust 进程启动                                       │
│    CUDA context 初始化                                        │
│    cuBLAS / cuDNN 库加载                                      │
├──────────────────────────────────────────────────────────────┤
│ 4. Model Weight Loading                   ★ 主要瓶颈          │
│    从存储 (PVC/NFS/Host) 读取模型权重到 GPU VRAM              │
│    ┌─────────────────────────────────────────────────────┐   │
│    │ Qwen3-0.6B:  ~1.2 GB → PCIe Gen4 ~2-3 秒           │   │
│    │ LLaMA-7B:    ~14 GB  → PCIe Gen4 ~20-30 秒          │   │
│    │ LLaMA-70B:   ~140 GB → PCIe Gen4 ~3-5 分钟          │   │
│    └─────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────┤
│ 5. vLLM Engine Init                            ~5-15 秒      │
│    KV Cache 内存池预分配                                      │
│    PagedAttention kernel 编译 (如首次)                        │
│    NIXL agent 初始化 + 注册                                   │
├──────────────────────────────────────────────────────────────┤
│ 6. Discovery Registration                     ~1-2 秒        │
│    向 K8s EndpointSlice 注册                                  │
│    Router 感知新 worker                                       │
├──────────────────────────────────────────────────────────────┤
│ 总计: Qwen3-0.6B ~20-45 秒 | LLaMA-7B ~60-90 秒             │
│       LLaMA-70B ~4-6 分钟                                    │
└──────────────────────────────────────────────────────────────┘
```

#### 多层优化策略

Pre-warming 只是其中一层。完整的优化策略是 **4 层叠加**：

```
┌───────────────────────────────────────────────────────────────────┐
│ 层次 1: Pre-warming (信号预知)                                     │
│ ─────────────────────────────────────────                         │
│ 策略: 在 sampling 完成 ~80% 时就开始 scale up                      │
│ 效果: 节省 scale up 时间 × sampling 剩余 20% 的重叠时间            │
│ 实现: RL Signal Emitter 在 sampling_progress ≥ 0.8 时发信号        │
│                                                                   │
│ 适用: 所有模型大小。对大模型效果最好（重叠时间更有价值）              │
│ 限制: 如果模型加载 > sampling 剩余时间，仍会有等待                   │
├───────────────────────────────────────────────────────────────────┤
│ 层次 2: 容器镜像预拉取                                              │
│ ─────────────────────────────────────                              │
│ 策略: 确保所有节点上预先拉取了 worker 容器镜像                       │
│ 效果: 消除容器拉取时间 (~0-60s → 0s)                               │
│ 实现: K8s DaemonSet 或 imagePullPolicy: IfNotPresent               │
│                                                                    │
│ 适用: 所有场景。一次性配置。                                        │
├───────────────────────────────────────────────────────────────────┤
│ 层次 3: 模型权重预缓存到 Host Memory                                │
│ ─────────────────────────────────────                              │
│ 策略: 将模型权重文件挂载为 hostPath 或 emptyDir (tmpfs)              │
│       模型文件 mmap 到 Host RAM，首次加载后常驻 OS page cache       │
│ 效果: 模型加载从"磁盘读取"变为"内存拷贝" (throughput 提高 10-50x)    │
│ 实现: - 模型文件放在 NVMe SSD 上的 PVC，首次加载后 OS 缓存          │
│       - 或用 tmpfs 将模型直接放内存                                 │
│ 数据: Qwen3-0.6B 从 NVMe: ~2s → 从 RAM: ~0.3s                     │
│       LLaMA-7B 从 NVMe: ~20s → 从 RAM: ~3s                        │
│                                                                    │
│ 适用: 有足够 Host RAM 的节点 (gpu14 有 256 GB RAM)                  │
├───────────────────────────────────────────────────────────────────┤
│ 层次 4: Standby Pod (模型预加载，GPU 保持分配)                       │
│ ─────────────────────────────────────                              │
│ 策略: 保持 1-2 个 worker Pod 处于 "standby" 状态                    │
│       模型已加载到 GPU，vLLM engine 已初始化                        │
│       但不注册到 Discovery → 不接收请求 → GPU 显存被占但无计算       │
│ 效果: Scale up 仅需 Discovery 注册 (~1-2s)，接近零延迟              │
│ 代价: 占用 GPU 显存（但不做计算，功耗很低 ~30W vs 满载 350W）       │
│                                                                    │
│ 适用: 对 scale-up 延迟极其敏感的场景                                │
│ 限制: 不适合 scale-to-zero 目标（因为 GPU 显存一直被占）             │
│       可与 Pre-warming 组合：standby 覆盖首批，后续批用 pre-warming  │
└───────────────────────────────────────────────────────────────────┘
```

#### 推荐组合策略

| 模型大小 | 推荐策略 | 预估 Scale-Up 延迟 |
|---------|---------|-------------------|
| 小模型 (< 2B, 如 Qwen3-0.6B) | 层次 1 + 2 + 3 | **5-10 秒** |
| 中模型 (7-13B) | 层次 1 + 2 + 3 | **15-30 秒** |
| 大模型 (70B+) | 层次 1 + 2 + 3 + 4 (1 standby) | **2-5 秒** (standby) 或 **2-4 分钟** (cold) |

**本项目（Qwen3-0.6B on RTX 3090）**：层次 1 + 2 + 3 足够，目标 Scale-Up 延迟 < 15 秒。

---

# 场景篇

---


---

## S1. Rollout-based Scale Up/Down

> ### ✅ 可行性确认 (基于 Dynamo v1.0.1 源码验证)
>
> **结论：高可行性。无需修改 Dynamo 任何代码**。本场景完全部署在 Dynamo 外部，通过现有 K8s API 驱动 DGDSA。
>
> **验证过的关键设施**（路径针对 v1.0.1 tag, commit `5534a9d`）：
> - DGDSA CRD `nvidia.com/v1alpha1` 定义中 `Replicas int32` 字段存在：`deploy/operator/api/v1alpha1/dynamographdeploymentscalingadapter_types.go` L30
> - kubebuilder `+subresource:scale` 在 `dynamographdeploymentscalingadapter_types.go` L78 已启用，意味着 `kubectl scale dgdsa/foo --replicas=N` 可以工作
> - DGDSA Reconciler 会从 `spec.replicas` patch 到底层 DynamoGraphDeployment：`deploy/operator/internal/controller/dynamographdeploymentscalingadapter_controller.go` L116-117
> - KEDA scale-to-zero 已集成为一等公民 (`hpa-decode-worker.yaml` / `hpa-prefill-worker.yaml` 已在 0.7.1 环境验证)
>
> **那些模块需要新建**（均在独立项目 `rl-scaling-controller/`，不动 Dynamo）：
> - `signal_receiver.py` (FastAPI :8080)
> - `state_machine.py` (IDLE / WARM_UP / ACTIVE / COOL_DOWN)
> - `capacity_planner.py` (batch metadata → replicas)
> - `dgdsa_client.py` (kubernetes-asyncio Patch DGDSA spec.replicas)
> - `metrics_collector.py` (Prometheus 查询)
>
> **有响不需部分**：Pre-warming（提前 10s scale up）、最低保留、Capacity Planner ISL/OSL 预估都仅为 Controller 内部逻辑。
>
> **已知限制**：RTX 3090 (Ampere) 不支持 cuda-checkpoint，所以 KV Cache 采用 "丢弃 + scale up 后重新 prefill" 策略（见 K6.4 选项 A）。不使用 Dynamo Snapshot 。

### S1.1 背景与需求

#### 问题

RL 训练循环中 GPU 使用是间歇性的。传统 always-on 部署在 Sampling/Training 阶段浪费大量 GPU 时间。

```
时间线:  ── Sampling (30min) ── Batch Infer (5min) ── Training (10min) ── Sampling ...
GPU:        0 需求                8 需求                0 需求              0 需求
传统:       8 GPU (浪费!)         8 GPU                 8 GPU (浪费!)      8 GPU (浪费!)
理想:       0 GPU (释放!)         8 GPU (scale up)      0 GPU (释放!)      0 GPU (释放!)
```

#### 优化目标

$$\text{Minimize } \text{GPU\_hours} = \sum_{g \in \text{GPUs}} T_{\text{allocated}}(g)$$

### S1.2 技术方案选择

| 方案 | 描述 | 优点 | 缺点 | 推荐 |
|------|------|------|------|------|
| A: 纯 KEDA Reactive | KEDA 监控 Prometheus 指标自动缩放 | 零开发 | 纯 reactive，无法预知 RL 信号 | ❌ |
| B: RL Signal + KEDA | RL 框架发信号 → KEDA External Scaler | 利用 KEDA 生态 | 需要实现 External Scaler gRPC | ⚠️ 备选 |
| C: RL Scaling Controller | 独立 K8s Controller 接收 RL 信号，直接 patch DGDSA | 最灵活，可实现 pre-warming | 需要自己实现 Controller | ✅ **推荐** |

#### 推荐方案：C — RL Scaling Controller

与 Dynamo 技术选型一致——Dynamo 自身也是用独立 Controller（operator）管理 DGD 的 lifecycle。我们的 Controller 通过 patch DGDSA 的 `spec.replicas` 来驱动缩放，与 Dynamo 的 K8s 原生架构保持一致。

#### Scale Up 加速方案：Snapshot vs Cold-Start 的技术决策

**结论先行：我们选择 4 层 Cold-Start 优化策略（K6.5），不使用 Dynamo 的 Checkpoint/Snapshot 功能。**

##### Dynamo v1.0.1 的 Checkpoint/Snapshot 功能（已存在）

Dynamo v1.0.1 实际上已经内建了完整的 **CRIU + cuda-checkpoint** 快照系统，覆盖 Python 层、DaemonSet Agent、K8s Operator CRD 三个层面：

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Dynamo v1.0.1 Checkpoint 系统架构                                           │
│                                                                              │
│  层次 1: Worker 进程内 — Python 生命周期管理                                   │
│  ┌──────────────────────────────────────────────────────────┐                │
│  │ components/src/dynamo/vllm/snapshot.py                     │                │
│  │ • CheckpointConfig: 解析环境变量                           │                │
│  │   DYN_READY_FOR_CHECKPOINT_FILE (默认 /tmp/ready-for-ckpt) │                │
│  │   DYN_CHECKPOINT_STORAGE_TYPE (pvc / s3 / oci)             │                │
│  │   DYN_CHECKPOINT_LOCATION                                  │                │
│  │ • run_lifecycle(engine_client, sleep_level):                │                │
│  │   1. Sleep engine (CRIU-friendly GPU 状态)                  │                │
│  │   2. 写 ready-for-checkpoint 文件 (触发 DaemonSet agent)    │                │
│  │   3. 等待信号:                                              │                │
│  │      SIGUSR1 → checkpoint 完成 → 退出进程 (由 CRIU dump)    │                │
│  │      SIGCONT → restore 完成 → 唤醒模型, 继续正常运行         │                │
│  │      SIGKILL → 失败                                        │                │
│  └──────────────────────────────────────────────────────────┘                │
│                                                                              │
│  层次 2: 节点级 — DaemonSet Snapshot Agent (Go)                               │
│  ┌──────────────────────────────────────────────────────────┐                │
│  │ deploy/snapshot/                                           │                │
│  │ • Watcher: 监控 ready-for-checkpoint 文件出现               │                │
│  │ • Orchestrate: 多阶段 checkpoint 编排                       │                │
│  │   Phase 1 — Inspect: 获取容器状态 (PID, rootfs, mounts)     │                │
│  │   Phase 2 — Configure: 构建 CRIU dump 选项                 │                │
│  │   Phase 3 — Capture: 执行 CRIU dump + cuda-checkpoint       │                │
│  │ • cuda-checkpoint 二进制: /usr/local/sbin/cuda-checkpoint   │                │
│  │   → lock → checkpoint (GPU VRAM 序列化) → unlock             │                │
│  │ • CRIU: 进程级快照 (内存、文件描述符、网络状态)               │                │
│  │ • Restore: CRIU restore + cuda-checkpoint restore           │                │
│  └──────────────────────────────────────────────────────────┘                │
│                                                                              │
│  层次 3: 集群级 — K8s Operator CRD                                           │
│  ┌──────────────────────────────────────────────────────────┐                │
│  │ deploy/operator/api/v1alpha1/dynamocheckpoint_types.go     │                │
│  │ • CRD: DynamoCheckpoint                                    │                │
│  │   Identity: model + backendFramework + TP/PP size + dtype   │                │
│  │   → identity hash 确定 checkpoint 等价性                    │                │
│  │ • Lifecycle phases: Pending → Creating → Ready | Failed     │                │
│  │ • Storage: PVC / S3 / OCI (默认 PVC snapshot-pvc)          │                │
│  │ deploy/operator/internal/controller/                       │                │
│  │   dynamocheckpoint_controller.go                           │                │
│  │ • CheckpointReconciler: 管理 checkpoint Job 的完整生命周期  │                │
│  └──────────────────────────────────────────────────────────┘                │
│                                                                              │
│  Snapshot 热启动流程 (如果硬件支持):                                           │
│  Pod 创建 → 检测到 matching checkpoint (identity hash) →                      │
│  CRIU restore 进程 → cuda-checkpoint restore GPU 状态 →                       │
│  模型权重 + KV Pool + CUDA context 全部从 snapshot 恢复 →                     │
│  Skip 模型加载 + vLLM init → 直接注册到 Discovery → Ready                    │
│  预估恢复时间: ~1-3 秒 (vs cold-start 20-45 秒 for Qwen3-0.6B)              │
└──────────────────────────────────────────────────────────────────────────────┘
```

##### 为何我们的环境不能使用 Snapshot

| 限制因素 | 说明 |
|---------|------|
| **GPU 架构** | `cuda-checkpoint` 依赖 NVIDIA driver 的 CUDA checkpoint API。RTX 3090 (Ampere GA102, compute capability 8.6) 是消费级 GPU，对 CRIU checkpoint 的 CUDA 支持有限。该功能主要面向数据中心级 GPU (H100/H200/B200)，且需要特定 CUDA driver 版本 (535+) 和内核配置 |
| **Linux 内核配置** | CRIU 要求内核编译启用 `CONFIG_CHECKPOINT_RESTORE=y`。标准 Ubuntu 内核通常已启用，但需要验证。此外 CRIU dump GPU 进程需要额外的 kernel namespace 和 seccomp 配置 |
| **容器运行时** | Snapshot Agent 需要以 DaemonSet 部署，拥有对 containerd 的直接访问权限（挂载 containerd socket），需要 privileged 模式运行。我们的单节点 K8s 环境安全配置较为简单，但 DaemonSet 的运维复杂度不低 |
| **RL 场景适用性** | RL 场景的 KV Cache 在 Batch 间**零复用**（每个 Batch 的 prompt 完全不同），Snapshot 保存的 KV Cache 对下一个 Batch 毫无价值。Snapshot 的核心优势——跳过模型加载——在小模型 (Qwen3-0.6B, 1.2GB) 下收益有限 |

##### 什么环境可以使用 Snapshot

| 条件 | 要求 |
|------|------|
| GPU | NVIDIA H100 / H200 / B200 (Hopper/Blackwell 架构), 数据中心级 GPU |
| Driver | CUDA Driver ≥ 535, 且支持 cuda-checkpoint API |
| 内核 | Linux kernel ≥ 5.15, `CONFIG_CHECKPOINT_RESTORE=y` |
| 容器运行时 | containerd ≥ 1.7, 支持 checkpoint API |
| 模型规模 | 大模型 (70B+) 效果最显著——cold-start 需 4-6 分钟, Snapshot 仅需 ~3-5 秒 |
| 使用场景 | 在线推理服务 scale-up (KV Cache 有复用价值), 或需要极低启动延迟的场景 |

##### 两种方案对比

| 维度 | Snapshot 热启动 | 4 层 Cold-Start 优化 (K6.5) |
|------|----------------|---------------------------|
| **Scale-Up 延迟** | ~1-3s (理想情况) | ~5-15s (Qwen3-0.6B) |
| **硬件要求** | H100+ 数据中心 GPU | 任意 NVIDIA GPU (RTX 3090 ✓) |
| **运维复杂度** | 高 (DaemonSet + CRD + CRIU + privileged) | 低 (镜像预拉取 + NVMe + hostPath) |
| **开发成本** | 零 (Dynamo 内建) | 低 (配置层面优化为主) |
| **RL 场景收益** | 有限 (KV Cache 零复用, 小模型加载本身很快) | **匹配** (4 层叠加覆盖所有瓶颈) |
| **适用模型规模** | 70B+ (收益最大) | 所有规模 (小模型: 5-15s, 中模型: 15-30s) |

##### 决策结论

```
本项目环境: RTX 3090 (Ampere) + Qwen3-0.6B + RL Batch Inference
→ Snapshot 不可用 (GPU 架构限制) + 收益有限 (小模型 + KV 零复用)
→ 4 层 Cold-Start 优化 (K6.5) 是正确选择:
   层次 1: Pre-warming (信号预知, 重叠 sampling 尾部与 scale-up)
   层次 2: 容器镜像预拉取 (消除拉取延迟)
   层次 3: NVMe SSD + OS Page Cache (模型加载从磁盘 I/O → 内存拷贝)
   层次 4: Standby Pod (可选, 大模型场景预留)
→ 目标 Scale-Up 延迟: < 15 秒 (Qwen3-0.6B)

未来演进: 如果项目迁移到 H100+ 环境 + 大模型 (70B+),
         Dynamo 的 Checkpoint 功能可直接启用, 无需额外开发。
```

### S1.3 整体实现架构——代码库拆分与部署关系

#### S1.3.1 为什么是独立项目，不是修改 Dynamo

```
问题: RL Scaling Controller 是在 Dynamo 代码里加逻辑，还是独立代码库？

答案: 独立代码库 + 独立 Pod 部署。原因如下:

┌─────────────────────────────────────────────────────────────────────┐
│  Dynamo (NVIDIA 开源项目)                                           │
│  ───────────────────────                                            │
│  - 主要语言: Rust + Python                                          │
│  - 定位: 通用 LLM Serving 基础设施                                   │
│  - 维护者: NVIDIA                                                   │
│  - 我们的关系: 使用者，不是维护者                                     │
│  - 如果在里面加 RL 逻辑 → 需要 fork 整个仓库 → 无法跟随上游更新      │
│                                                                     │
│  RL Scaling Controller (我们的项目)                                  │
│  ─────────────────────────────────                                  │
│  - 主要语言: Python                                                  │
│  - 定位: RL 专用的 Scaling 决策引擎                                   │
│  - 与 Dynamo 交互方式: 全部通过公开 API                              │
│    1. K8s API → patch DGDSA replicas (驱动扩缩容)                    │
│    2. Prometheus → 读取 Dynamo 暴露的指标 (读取集群状态)              │
│    3. Worker HTTP API → 调用 drain/switch 端点 (控制 Worker 行为)     │
│    4. ZMQ Event Plane → 订阅/发布事件 (可选，事件驱动)                │
│                                                                     │
│  类比: Dynamo 就像 Kubernetes 本身                                   │
│       RL Scaling Controller 就像 KEDA 或 Knative                    │
│       → KEDA 不是写在 K8s 源码里的，而是独立项目通过 K8s API 交互    │
│       → 我们的 Controller 同理                                       │
└─────────────────────────────────────────────────────────────────────┘
```

#### S1.3.2 代码库总览——三个代码产出物

本项目涉及 **2 个新建代码库** + **对 Dynamo 的最小化修改**（通过 fork/PR）:

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        代码库拆分全景图                                    │
│                                                                          │
│  代码库 1: rl-scaling-controller/    ★ 核心项目 (独立 Git 仓库)          │
│  ─────────────────────────────────                                       │
│  部署为: K8s Deployment (1 个 Pod, CPU-only)                             │
│  功能: 接收 RL 信号 → 状态机决策 → 驱动 Dynamo 扩缩容                    │
│  包含: S1 状态机, S2 角色切换控制器, S3 合并控制器, 容量规划              │
│                                                                          │
│  代码库 2: rl-signal-sdk/            辅助库 (独立 Git 仓库, pip install) │
│  ─────────────────────────                                               │
│  部署为: 不部署! 是一个 Python 库，被 RL Training Framework import       │
│  功能: 提供 RLSignalEmitter 类，RL 框架调用它发送生命周期事件             │
│                                                                          │
│  Dynamo fork 改动:                   对 Dynamo 代码的最小侵入式修改      │
│  ─────────────────                                                       │
│  范围: 仅在 S2(角色切换) 和 S3(请求合并) 需要修改 Dynamo 内部            │
│  S1 不需要改 Dynamo 任何代码! (纯外部 API 交互)                          │
│  详细改动见 S2.3, S3.3                                                   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

#### S1.3.3 部署拓扑与交互关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  K8s 集群 (gpu14 节点)                                                      │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │  RL Training Framework (用户的训练代码)                          │        │
│  │  ┌─────────────────────────────────────┐                        │        │
│  │  │ import rl_signal                    │  ← 代码库 2 的 pip 包   │        │
│  │  │                                     │                        │        │
│  │  │ emitter = rl_signal.Emitter(        │                        │        │
│  │  │   controller_url="http://rl-scaling │                        │        │
│  │  │     -controller:8080"               │                        │        │
│  │  │ )                                   │                        │        │
│  │  │                                     │                        │        │
│  │  │ # 在 sampling loop 中:              │                        │        │
│  │  │ emitter.sampling_progress(0.8, meta)│───── HTTP POST ────┐   │        │
│  │  │ emitter.sampling_done(batch_meta)   │───── HTTP POST ──┐ │   │        │
│  │  │ emitter.batch_complete()            │───── HTTP POST ─┐│ │   │        │
│  │  └─────────────────────────────────────┘                 ││ │   │        │
│  └──────────────────────────────────────────────────────────┼┼─┘   │        │
│                                                             ││     │        │
│  ┌──────────────────────────────────────────────────────────┼┼─────┤        │
│  │  RL Scaling Controller Pod (代码库 1)                    ││     │        │
│  │  ┌───────────────────────────────────────────────────────┼┼───┐ │        │
│  │  │                                                       ▼▼   │ │        │
│  │  │  Signal Receiver  ──▶  State Machine  ──▶  DGDSA     ─┼───┼─┼──┐     │
│  │  │  (FastAPI :8080)       (IDLE→WARM_UP    Client       │   │ │  │     │
│  │  │                         →ACTIVE→        (K8s API)    │   │ │  │     │
│  │  │                         COOL_DOWN)                    │   │ │  │     │
│  │  │                            │                          │   │ │  │     │
│  │  │                            ▼                          │   │ │  │     │
│  │  │                    Capacity Planner                   │   │ │  │     │
│  │  │                    (计算需要多少                       │   │ │  │     │
│  │  │                     prefill/decode                    │   │ │  │     │
│  │  │                     replicas)                         │   │ │  │     │
│  │  │                            │                          │   │ │  │     │
│  │  │                            ▼                          │   │ │  │     │
│  │  │                    Metrics Collector ─────────────────┼─┐ │ │  │     │
│  │  │                    (Prometheus 查询)                   │ │ │ │  │     │
│  │  └───────────────────────────────────────────────────────┘ │ │ │  │     │
│  └────────────────────────────────────────────────────────────┘ │ │  │     │
│                                                                 │ │  │     │
│  ┌──────────────────────────────────────────────────────────────┘ │  │     │
│  │  Prometheus                                                    │  │     │
│  │  (已部署, 采集 Dynamo 指标)                                    │  │     │
│  └────────────────────────────────────────────────────────────────┘  │     │
│                                                                      │     │
│  ┌───────────────────────────────────────────────────────────────────┘     │
│  │  Dynamo 组件 (已部署)                                                   │
│  │  ┌───────────────┐  ┌──────────────────┐  ┌──────────────────┐         │
│  │  │ Frontend Pod   │  │ Prefill Worker   │  │ Decode Worker    │         │
│  │  │ (含 Router)    │  │ (GPU, DGDSA 管理)│  │ (GPU, DGDSA 管理)│         │
│  │  └───────────────┘  └──────────────────┘  └──────────────────┘         │
│  │                                                                         │
│  │  patch DGDSA replicas = N  ←── 这就是 Controller 驱动 Dynamo 的方式    │
│  │  → Dynamo Operator 自动 reconcile → 创建/删除 Worker Pods              │
│  └─────────────────────────────────────────────────────────────────────────┘
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### S1.4 RL Scaling Controller 详解

#### S1.4.1 项目结构

```
rl-scaling-controller/                    # 独立 Git 仓库
├── Dockerfile                            # 构建镜像
├── pyproject.toml                        # Python 项目配置 (poetry/hatch)
├── README.md
├── src/
│   └── rl_scaling_controller/
│       ├── __init__.py
│       ├── main.py                       # 应用入口: FastAPI server + 后台 control loop
│       ├── config.py                     # 所有配置项（来自环境变量）
│       │
│       ├── # ─── S1: Scale Up/Down 核心逻辑 ───
│       ├── state_machine.py              # 四状态状态机: IDLE → WARM_UP → ACTIVE → COOL_DOWN
│       ├── capacity_planner.py           # 容量规划算法: batch metadata → 需要多少 replicas
│       ├── signal_receiver.py            # FastAPI 路由: 接收 RL Signal SDK 发来的 HTTP 请求
│       ├── dgdsa_client.py              # K8s API 封装: patch DGDSA replicas
│       ├── metrics_collector.py          # Prometheus 查询封装: 读取 Dynamo 指标
│       │
│       ├── # ─── S2: Elastic Role Switch (子模块) ───
│       ├── role_switch/
│       │   ├── __init__.py
│       │   ├── controller.py             # ElasticRoleSwitchController: 切换决策逻辑
│       │   ├── dual_mode_client.py       # HTTP 调用 Worker 的 /switch_role 端点
│       │   └── strategy.py               # 切换策略: 哪个 worker 最适合切换
│       │
│       └── # ─── S3: Request Consolidation (子模块) ───
│           consolidation/
│           ├── __init__.py
│           ├── controller.py             # ConsolidationController: 合并决策循环
│           ├── decision_engine.py        # 合并决策算法: 评估是否值得迁移
│           └── migration_client.py       # 调用 Dynamo Migration Operator API
│
├── deploy/                               # K8s 部署 manifests
│   ├── deployment.yaml                   # Controller Pod 定义
│   ├── service.yaml                      # ClusterIP Service (供 RL Signal SDK 访问)
│   ├── rbac.yaml                         # RBAC: 允许 patch DGDSA, 读取 pods
│   └── keda-scaled-object.yaml           # KEDA 补充配置 (scale-to-zero)
│
└── tests/
    ├── test_state_machine.py             # 状态机单元测试
    ├── test_capacity_planner.py          # 容量规划单元测试
    ├── test_role_switch.py               # 角色切换单元测试
    ├── test_consolidation.py             # 合并决策单元测试
    └── conftest.py                       # pytest fixtures
```

**关键设计决策**：S2 (Role Switch) 和 S3 (Consolidation) 的**决策逻辑**放在这个 Controller 中，因为它们都需要读取 Prometheus 指标、感知集群状态、做出扩缩容决策。但**执行逻辑**（如 Worker 切换自身角色、NIXL 传输 KV）在 Dynamo 侧。

#### S1.4.2 信号流转全路径（从 RL 框架到 GPU 变化）

```
完整信号流转 (一个 RL Cycle 的 Scale Up → Active → Scale Down):

 ┌─RL Training Framework─┐   ┌─RL Scaling Controller─┐   ┌──K8s + Dynamo──┐
 │                        │   │                        │   │                │
 │ 1. sampling 进度 80%   │   │                        │   │                │
 │    emitter.sampling    │──▶│ 2. signal_receiver     │   │                │
 │     _progress(0.8,meta)│   │    解析 HTTP POST body │   │                │
 │                        │   │    提取 batch_size,     │   │                │
 │                        │   │    avg_isl, avg_osl    │   │                │
 │                        │   │         │              │   │                │
 │                        │   │         ▼              │   │                │
 │                        │   │ 3. state_machine:      │   │                │
 │                        │   │    IDLE → WARM_UP      │   │                │
 │                        │   │         │              │   │                │
 │                        │   │         ▼              │   │                │
 │                        │   │ 4. capacity_planner:   │   │                │
 │                        │   │    compute(meta)       │   │                │
 │                        │   │    → prefill=2,decode=4│   │                │
 │                        │   │         │              │   │                │
 │                        │   │         ▼              │   │                │
 │                        │   │ 5. dgdsa_client:       │   │                │
 │                        │   │    patch prefill-dgdsa │──▶│ 6. K8s API     │
 │                        │   │     replicas=2         │   │    更新 DGDSA  │
 │                        │   │    patch decode-dgdsa  │──▶│    spec        │
 │                        │   │     replicas=4         │   │       │        │
 │                        │   │                        │   │       ▼        │
 │                        │   │                        │   │ 7. Dynamo      │
 │                        │   │                        │   │    Operator    │
 │                        │   │                        │   │    reconcile   │
 │                        │   │                        │   │    → 创建 Pods │
 │                        │   │                        │   │    → 分配 GPU  │
 │                        │   │                        │   │    → 加载模型  │
 │                        │   │                        │   │       │        │
 │                        │   │ 8. metrics_collector:  │◀──│ 9. Prometheus  │
 │                        │   │    轮询 worker_ready   │   │    指标更新    │
 │                        │   │    count == target     │   │                │
 │                        │   │         │              │   │                │
 │                        │   │         ▼              │   │                │
 │                        │   │ 10. state_machine:     │   │                │
 │                        │   │     WARM_UP → ACTIVE   │   │                │
 │                        │   │                        │   │                │
 │ 11. sampling_done      │──▶│ 12. 已经 ACTIVE,      │   │                │
 │     发送 batch 到      │   │     无需额外操作       │   │                │
 │     Dynamo Frontend    │   │     (如果还在WARM_UP   │   │                │
 │                        │   │      则等待)           │   │                │
 │ ─── 推理进行中 ───     │   │                        │   │                │
 │                        │   │                        │   │                │
 │ 13. batch_complete     │──▶│ 14. state_machine:     │   │                │
 │     emitter.batch      │   │     ACTIVE → COOL_DOWN │   │                │
 │      _complete()       │   │         │              │   │                │
 │                        │   │         ▼              │   │                │
 │                        │   │ 15. 等待 cooldown_sec  │   │                │
 │                        │   │     (默认 30s, 确保    │   │                │
 │                        │   │      无迟到请求)       │   │                │
 │                        │   │         │              │   │                │
 │                        │   │         ▼              │   │                │
 │                        │   │ 16. dgdsa_client:      │──▶│ 17. K8s:       │
 │                        │   │     patch replicas=0   │   │     terminate  │
 │                        │   │                        │   │     Pods       │
 │                        │   │         │              │   │     释放 GPU   │
 │                        │   │         ▼              │   │                │
 │                        │   │ 18. state_machine:     │   │                │
 │                        │   │     COOL_DOWN → IDLE   │   │                │
 │                        │   │                        │   │                │
 └────────────────────────┘   └────────────────────────┘   └────────────────┘
```

#### S1.4.3 状态机详细实现

```python
# src/rl_scaling_controller/state_machine.py

from enum import Enum
from dataclasses import dataclass
import time
import logging

logger = logging.getLogger(__name__)

class State(Enum):
    IDLE = "idle"           # 无 GPU 分配，等待 RL 信号
    WARM_UP = "warm_up"     # 正在 scale up，等待 workers ready
    ACTIVE = "active"       # workers ready，正在处理推理请求
    COOL_DOWN = "cool_down" # 推理完成，等待 drain + scale down

@dataclass
class ScaleTarget:
    prefill_replicas: int
    decode_replicas: int

class ScalingStateMachine:
    """
    状态机管理 RL Scaling 的完整生命周期。
    
    为什么需要状态机而不是简单的 if-else:
    1. 防止重复操作 (如在 WARM_UP 期间再次收到 signal 不会重复 scale up)
    2. 防止非法状态转换 (如在 ACTIVE 期间不允许直接回到 IDLE)
    3. 记录状态转换历史，方便调试
    """
    
    def __init__(self, config, dgdsa_client, capacity_planner, metrics_collector):
        self.state = State.IDLE
        self.config = config
        self.dgdsa = dgdsa_client
        self.planner = capacity_planner
        self.metrics = metrics_collector
        self.current_target: ScaleTarget | None = None
        self.state_entered_at: float = time.time()
    
    # ─── 合法状态转换 ───
    TRANSITIONS = {
        State.IDLE: [State.WARM_UP],
        State.WARM_UP: [State.ACTIVE, State.COOL_DOWN],  # COOL_DOWN: 如果 pre-warm 后 signal 取消
        State.ACTIVE: [State.COOL_DOWN],
        State.COOL_DOWN: [State.IDLE],
    }
    
    def transition_to(self, new_state: State):
        if new_state not in self.TRANSITIONS[self.state]:
            logger.warning(f"非法转换: {self.state} → {new_state}, 忽略")
            return False
        logger.info(f"状态转换: {self.state} → {new_state}")
        self.state = new_state
        self.state_entered_at = time.time()
        return True
    
    # ─── 事件处理器 (Signal Receiver 调用这些方法) ───
    
    def on_sampling_progress(self, progress: float, batch_meta: dict):
        """RL 框架报告 sampling 进度"""
        if self.state != State.IDLE:
            logger.info(f"当前状态 {self.state}, 忽略 sampling_progress")
            return
        if progress < self.config.pre_warm_threshold:
            return  # 还没到 pre-warm 阈值
        
        # 计算需要多少 replicas
        self.current_target = self.planner.compute(batch_meta)
        logger.info(f"Pre-warming: 需要 P={self.current_target.prefill_replicas}, "
                    f"D={self.current_target.decode_replicas}")
        
        # 状态转换: IDLE → WARM_UP
        self.transition_to(State.WARM_UP)
        
        # 驱动 Dynamo: patch DGDSA replicas
        self.dgdsa.patch("prefill", self.current_target.prefill_replicas)
        self.dgdsa.patch("decode", self.current_target.decode_replicas)
    
    def on_sampling_done(self, batch_meta: dict):
        """Sampling 完成，Batch 即将提交"""
        if self.state == State.IDLE:
            # 没有 pre-warming，直接 cold start
            self.current_target = self.planner.compute(batch_meta)
            self.transition_to(State.WARM_UP)
            self.dgdsa.patch("prefill", self.current_target.prefill_replicas)
            self.dgdsa.patch("decode", self.current_target.decode_replicas)
        elif self.state == State.WARM_UP:
            # 已经在 pre-warming，等待 workers ready
            pass
        elif self.state == State.ACTIVE:
            # 已经 ready，无需操作
            pass
    
    def on_batch_complete(self):
        """Batch 推理完成"""
        if self.state != State.ACTIVE:
            logger.warning(f"batch_complete 但当前状态是 {self.state}")
            return
        self.transition_to(State.COOL_DOWN)
    
    # ─── 后台 Control Loop (每 5 秒运行一次) ───
    
    async def control_loop_tick(self):
        """在 main.py 的后台任务中被周期性调用"""
        
        if self.state == State.WARM_UP:
            # 检查 workers 是否全部 ready
            ready = await self.metrics.get_ready_worker_count()
            target = (self.current_target.prefill_replicas + 
                      self.current_target.decode_replicas)
            if ready >= target:
                logger.info(f"所有 {ready} workers ready, 进入 ACTIVE")
                self.transition_to(State.ACTIVE)
        
        elif self.state == State.COOL_DOWN:
            # 等待 cooldown period 后 scale down
            elapsed = time.time() - self.state_entered_at
            if elapsed >= self.config.cooldown_seconds:
                logger.info("Cooldown 完成, scale down to 0")
                self.dgdsa.patch("prefill", 0)
                self.dgdsa.patch("decode", 0)
                self.transition_to(State.IDLE)
```

#### S1.4.4 容量规划算法详解

```python
# src/rl_scaling_controller/capacity_planner.py

from math import ceil
from dataclasses import dataclass

@dataclass
class ScaleTarget:
    prefill_replicas: int
    decode_replicas: int

class CapacityPlanner:
    """
    根据 Batch metadata 计算需要多少 Prefill 和 Decode workers。
    
    输入: batch_meta — RL Signal SDK 发送的 Batch 元信息
      {
        "batch_size": 128,          # 请求数量
        "avg_isl": 500,             # 平均输入序列长度
        "avg_osl": 200,             # 平均输出序列长度 (或 max_tokens)
        "total_tokens": 64000,      # 总 prefill tokens (batch_size × avg_isl)
      }
    
    配置参数 (来自环境变量，可根据实际 benchmark 调整):
      single_prefill_tps: 单个 Prefill GPU 的 token/s 吞吐量
                          → Qwen3-0.6B on RTX 3090: ~50000 tok/s (prefill)
      max_concurrent_per_decode: 单个 Decode GPU 最大并发请求数
                          → 取决于 KV Cache 大小和 GPU VRAM
                          → Qwen3-0.6B on RTX 3090 (24GB): ~64 concurrent
      target_prefill_seconds: 目标 prefill 完成时间
                          → 越小需要越多 prefill GPU
      max_gpus: 最大可用 GPU 数量 (硬件限制)
    """
    
    def __init__(self, config):
        self.single_prefill_tps = config.single_prefill_tps      # tok/s per GPU
        self.max_concurrent = config.max_concurrent_per_decode    # requests per GPU
        self.target_prefill_sec = config.target_prefill_seconds   # 目标 prefill 时间
        self.max_gpus = config.max_gpus                           # 最大 GPU 数
    
    def compute(self, batch_meta: dict) -> ScaleTarget:
        total_tokens = batch_meta.get("total_tokens",
            batch_meta["batch_size"] * batch_meta["avg_isl"])
        
        # ─── Prefill replicas 计算 ───
        # 公式: 需要多少 GPU 在 target_prefill_sec 内处理完所有 prefill tokens
        # total_tokens / (N_prefill × single_prefill_tps) = target_prefill_sec
        # → N_prefill = total_tokens / (single_prefill_tps × target_prefill_sec)
        prefill_replicas = ceil(
            total_tokens / (self.single_prefill_tps * self.target_prefill_sec)
        )
        
        # ─── Decode replicas 计算 ───
        # 所有请求 prefill 完成后都会进入 decode 阶段 (并发)
        # 每个 decode GPU 能并发处理 max_concurrent 个请求
        # → N_decode = batch_size / max_concurrent
        decode_replicas = ceil(
            batch_meta["batch_size"] / self.max_concurrent
        )
        
        # ─── 限制不超过硬件上限 ───
        prefill_replicas = min(prefill_replicas, self.max_gpus)
        decode_replicas = min(decode_replicas, self.max_gpus - prefill_replicas)
        # 注意: prefill + decode 总数不能超过 max_gpus
        
        return ScaleTarget(
            prefill_replicas=max(1, prefill_replicas),
            decode_replicas=max(1, decode_replicas),
        )
    
    # ─── 使用示例 ───
    # planner = CapacityPlanner(config)
    # target = planner.compute({
    #     "batch_size": 128,
    #     "avg_isl": 500,
    #     "total_tokens": 64000,
    # })
    # → ScaleTarget(prefill_replicas=2, decode_replicas=2)
    # 含义: 需要 2 个 prefill GPU + 2 个 decode GPU = 4 GPU
```

#### S1.4.5 DGDSA Client — 与 Dynamo 的唯一接口

```python
# src/rl_scaling_controller/dgdsa_client.py

from kubernetes import client, config
import logging

logger = logging.getLogger(__name__)

class DGDSAClient:
    """
    封装 K8s API 调用，修改 DGDSA (DynamoGraphDeploymentScalingAdapter) 的 replicas。
    
    工作原理:
    1. 我们 patch DGDSA 的 spec.replicas = N
    2. Dynamo Operator 监控到 DGDSA 变化
    3. Dynamo Operator 修改对应 DGD 的 worker Deployment replicas
    4. K8s 根据 Deployment replicas 创建/删除 Pods
    5. Pod 启动后加载模型、注册到 Discovery → Router 感知
    
    这与 Dynamo 自身的 Planner 组件驱动扩缩容的方式完全一致:
    Planner 也是通过 patch DGDSA replicas 来间接控制 worker 数量。
    我们的 Controller 只是用 RL 信号替代了 Planner 的 load-based 触发。
    """
    
    def __init__(self, namespace: str):
        config.load_incluster_config()  # Pod 内运行时使用 in-cluster config
        self.custom_api = client.CustomObjectsApi()
        self.namespace = namespace
    
    def patch(self, service_name: str, replicas: int):
        """
        修改指定 service 的 DGDSA replicas。
        
        service_name: "prefill" 或 "decode"
        replicas: 目标副本数 (0 = scale to zero)
        
        DGDSA 命名约定: {dgd_name}-{service_name}
        例如: DGD 名为 "rl-serving", service 为 "prefill"
              → DGDSA 名为 "rl-serving-prefill"
        """
        dgdsa_name = f"rl-serving-{service_name}"
        
        try:
            self.custom_api.patch_namespaced_custom_object_scale(
                group="dynamo.nvidia.com",
                version="v1alpha1",
                namespace=self.namespace,
                plural="dynamographdeploymentscalingadapters",
                name=dgdsa_name,
                body={"spec": {"replicas": replicas}}
            )
            logger.info(f"Patched {dgdsa_name} replicas={replicas}")
        except client.ApiException as e:
            logger.error(f"Failed to patch {dgdsa_name}: {e}")
            raise
```

### S1.5 RL Signal Emitter SDK 详解

#### S1.5.1 项目结构

```
rl-signal-sdk/                            # 独立 Git 仓库, 发布到 PyPI
├── pyproject.toml                        # pip install rl-signal
├── README.md
├── src/
│   └── rl_signal/
│       ├── __init__.py                   # 导出 Emitter, Events
│       ├── emitter.py                    # RLSignalEmitter 类
│       ├── events.py                     # 事件数据模型
│       └── transport.py                  # HTTP 传输层
└── tests/
    └── test_emitter.py
```

#### S1.5.2 SDK 做什么？不做什么？

```
SDK 做什么:
──────────
  - 提供 Python API，让 RL 框架在生命周期关键节点发送结构化事件
  - 将 RL 框架的内部状态（sampling 进度、batch 信息）序列化为 JSON
  - 通过 HTTP 发送到 RL Scaling Controller

SDK 不做什么:
──────────
  - 不做任何 scaling 决策 (那是 Controller 的事)
  - 不直接调用 K8s API (那是 Controller 的事)
  - 不读取 Prometheus 指标 (那是 Controller 的事)
  - 不转换指标格式 (发送原始 RL 事件，Controller 负责解析)

SDK 就是一个 "信号发射器"——RL 框架调用 SDK → SDK 发 HTTP → Controller 接收
```

#### S1.5.3 SDK 实现

```python
# src/rl_signal/emitter.py

import httpx
from dataclasses import dataclass, asdict
from typing import Optional

@dataclass
class BatchMeta:
    """Batch 元信息 — RL 框架在 sampling 时就能知道的信息"""
    batch_size: int               # 请求数量
    avg_isl: int                  # 平均输入序列长度 (tokens)
    avg_osl: Optional[int] = None # 平均期望输出长度 (如果可预测)
    total_tokens: Optional[int] = None  # 总 prefill tokens

class RLSignalEmitter:
    """
    RL 训练框架调用此类，在关键生命周期节点发送信号。
    
    使用方式 (在 RL 训练代码中):
    
        from rl_signal import RLSignalEmitter, BatchMeta
        
        emitter = RLSignalEmitter(controller_url="http://rl-scaling-controller:8080")
        
        # === RL Training Loop ===
        for epoch in range(num_epochs):
            
            # --- Sampling 阶段 ---
            prompts = []
            for i, sample in enumerate(dataset):
                prompts.append(sample)
                progress = (i + 1) / len(dataset)
                
                # 报告 sampling 进度 (Controller 会在 ≥0.8 时触发 pre-warm)
                emitter.sampling_progress(progress, BatchMeta(
                    batch_size=len(dataset),
                    avg_isl=estimate_avg_isl(dataset),
                ))
            
            # --- Sampling 完成，即将提交 Batch ---
            emitter.sampling_done(BatchMeta(
                batch_size=len(prompts),
                avg_isl=avg([len(p) for p in prompts]),
                total_tokens=sum(len(p) for p in prompts),
            ))
            
            # --- 发送请求到 Dynamo 并等待结果 ---
            results = send_batch_to_dynamo(prompts)
            
            # --- Batch 推理完成 ---
            emitter.batch_complete()
            
            # --- Training 阶段 (Controller 会在此期间 scale down) ---
            train(results)
    """
    
    def __init__(self, controller_url: str, timeout: float = 5.0):
        self.url = controller_url.rstrip("/")
        self.client = httpx.Client(timeout=timeout)
    
    def sampling_progress(self, progress: float, meta: BatchMeta):
        """报告 sampling 进度。progress ∈ [0, 1]"""
        self.client.post(f"{self.url}/api/v1/signals/sampling_progress", json={
            "progress": progress,
            "batch_meta": asdict(meta),
        })
    
    def sampling_done(self, meta: BatchMeta):
        """Sampling 完成，Batch 即将提交"""
        self.client.post(f"{self.url}/api/v1/signals/sampling_done", json={
            "batch_meta": asdict(meta),
        })
    
    def batch_complete(self):
        """Batch 推理完成，可以 scale down"""
        self.client.post(f"{self.url}/api/v1/signals/batch_complete")
```

#### S1.5.4 Signal Receiver (Controller 侧)

```python
# src/rl_scaling_controller/signal_receiver.py

from fastapi import FastAPI, Request
from .state_machine import ScalingStateMachine

app = FastAPI()
state_machine: ScalingStateMachine = None  # 在 main.py 中注入

@app.post("/api/v1/signals/sampling_progress")
async def on_sampling_progress(request: Request):
    body = await request.json()
    state_machine.on_sampling_progress(
        progress=body["progress"],
        batch_meta=body["batch_meta"],
    )
    return {"status": "ok", "state": state_machine.state.value}

@app.post("/api/v1/signals/sampling_done")
async def on_sampling_done(request: Request):
    body = await request.json()
    state_machine.on_sampling_done(batch_meta=body["batch_meta"])
    return {"status": "ok", "state": state_machine.state.value}

@app.post("/api/v1/signals/batch_complete")
async def on_batch_complete():
    state_machine.on_batch_complete()
    return {"status": "ok", "state": state_machine.state.value}

@app.get("/api/v1/status")
async def get_status():
    """健康检查 + 当前状态查询"""
    return {
        "state": state_machine.state.value,
        "current_target": state_machine.current_target,
    }
```

### S1.6 Scale Up 模型加载优化

模型加载是 Scale Up 的主要延迟瓶颈。详细分析和多层优化策略见 **K6.5**。

本项目推荐策略：**层次 1 (Pre-warming) + 层次 2 (镜像预拉取) + 层次 3 (模型权重 Host 缓存)**。

```python
# Pre-warming 实现 (已集成在 state_machine.on_sampling_progress 中):
# 当 sampling progress ≥ 0.8 时 → patch DGDSA replicas
# → Dynamo Operator 创建 Pod → 模型加载开始
# → 与 sampling 剩余 20% 并行进行
# → 当 sampling_done 时，worker 可能已经 ready (取决于模型大小)

# 镜像预拉取 (一次性配置):
# kubectl apply -f deploy/daemonset-image-puller.yaml
# → 确保所有节点缓存了 worker 镜像

# 模型权重 Host 缓存:
# Worker Pod 使用 hostPath volume 挂载 /data/models/
# 首次启动后模型文件进入 OS page cache
# 后续 Pod 启动读取模型 = 从 RAM 拷贝而非磁盘
```

### S1.7 Scale Down KV Cache 处理策略

详细分析见 **K6.4**。RL 场景推荐**直接丢弃**策略。

```
Scale Down 完整流程 (Controller COOL_DOWN 状态):

1. Controller 检测到 batch_complete 信号
   state: ACTIVE → COOL_DOWN

2. 等待 cooldown_seconds (默认 30s)
   → 确保没有迟到的请求/重试

3. Controller patch DGDSA replicas = 0
   → Dynamo Operator 开始终止 Worker Pods

4. K8s 向 Worker Pod 发送 SIGTERM
   → Worker 的 Graceful Shutdown Handler 启动:
     a. 停止接受新请求 (从 Discovery 注销)
     b. 等待所有 in-flight 请求完成 (最多 terminationGracePeriodSeconds)
     c. in-flight 完成后:
        - Active KV blocks → 0 (请求都完成了)
        - Cached KV blocks → evict all (直接释放，不 offload)
        - KVPublisher 发送 "all blocks removed" event
        - Router KVIndexer 清除该 worker 索引
     d. NIXL agent 断开连接
     e. vLLM engine 释放 CUDA 资源
     f. 进程退出

5. K8s 确认 Pod terminated
   → nvidia-device-plugin 回收 GPU
   → GPU 可被其他 Pod 使用

为什么不 offload KV Cache (见 K6.4):
  RL Batch 1 的 KV ≠ RL Batch 2 的 KV
  → 前一轮 cache 对下一轮无复用价值
  → offload 到 Host/SSD 只是浪费时间和存储空间
```

### S1.8 需要改动的组件总结

| # | 组件 | 所属代码库 | 改动类型 | 语言 | 工作量 | 描述 |
|---|------|----------|---------|------|-------|------|
| 1 | RL Scaling Controller | `rl-scaling-controller/` (新建) | **新项目** | Python | 中 | FastAPI server + 状态机 + CapacityPlanner + DGDSA Client |
| 2 | RL Signal Emitter SDK | `rl-signal-sdk/` (新建) | **新包** | Python | 低 | pip install rl-signal，3 个 API |
| 3 | KEDA ScaledObject | `rl-scaling-controller/deploy/` | YAML | - | 低 | 补充 scale-to-zero |
| 4 | Dynamo 代码 | 无需修改 | — | — | — | S1 不修改 Dynamo 任何代码！ |

**重要**：S1 (Rollout Scale) 不需要修改 Dynamo 的任何代码。完全通过外部 K8s API 交互。这是 S1 与 S2/S3 的关键区别——S2/S3 需要修改 Dynamo 内部。

### S1.9 部署与测试

#### 部署

```yaml
# deploy/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rl-scaling-controller
  namespace: ${NAMESPACE}
spec:
  replicas: 1                             # 只需要 1 个副本 (有状态)
  selector:
    matchLabels:
      app: rl-scaling-controller
  template:
    metadata:
      labels:
        app: rl-scaling-controller
    spec:
      serviceAccountName: rl-scaling-controller
      containers:
      - name: controller
        image: ${REGISTRY}/rl-scaling-controller:latest
        ports:
        - containerPort: 8080
        env:
        - name: DYNAMO_NAMESPACE
          value: ${NAMESPACE}
        - name: PROMETHEUS_URL
          value: http://prometheus-kube-prometheus-prometheus.monitoring:9090
        - name: PRE_WARM_THRESHOLD
          value: "0.8"
        - name: COOLDOWN_SECONDS
          value: "30"
        - name: SINGLE_PREFILL_TPS
          value: "50000"
        - name: MAX_CONCURRENT_PER_DECODE
          value: "64"
        - name: TARGET_PREFILL_SECONDS
          value: "5"
        - name: MAX_GPUS
          value: "8"
        resources:
          requests: { cpu: "500m", memory: "512Mi" }
          limits: { cpu: "1", memory: "1Gi" }
---
# deploy/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: rl-scaling-controller
  namespace: ${NAMESPACE}
spec:
  selector:
    app: rl-scaling-controller
  ports:
  - port: 8080
    targetPort: 8080
---
# deploy/rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rl-scaling-controller
rules:
- apiGroups: ["dynamo.nvidia.com"]
  resources: ["dynamographdeploymentscalingadapters/scale"]
  verbs: ["patch", "get"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["list", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rl-scaling-controller
subjects:
- kind: ServiceAccount
  name: rl-scaling-controller
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: rl-scaling-controller
  apiGroup: rbac.authorization.k8s.io
```

#### 测试用例

| 编号 | 名称 | 方法 | 预期 |
|------|------|------|------|
| S1-T1 | Scale Up 触发 | 发 SAMPLING_DONE 信号 | Controller 触发 scale up |
| S1-T2 | Scale Up 延迟 | 测量 signal → first worker ready | Pre-warming: < 15s (Qwen3-0.6B) |
| S1-T3 | Scale Down 安全 | active batch 期间触发 scale down | 拒绝，等待 batch 完成 |
| S1-T4 | Scale Down GPU 释放 | Batch 完成后观察 | Worker pods terminated |
| S1-T5 | Scale-to-Zero | 全部空闲 30s | DGDSA replicas = 0 |
| S1-T6 | GPU 利用率对比 | 模拟 3 个 RL cycle | GPU hours 减少 40%+ |
| S1-T7 | 状态机正确性 | 快速连续发送 signal | 状态转换正确，不跳过 |
| S1-T8 | Pre-warming 有效性 | 在 80% progress 触发 | Worker 在 sampling_done 前就绪 |
| S1-T9 | CapacityPlanner 正确性 | 不同 batch_size / ISL | replicas 数量符合预期 |

---

## S2. Elastic Role Switch (Prefill ↔ Decode)

> ### ⚠️ 可行性确认 (基于 Dynamo v1.0.1 源码验证)
>
> **结论：中可行性。需要实现三个不存在的内部 API 才能达到设计预期**。同时，部分设计预设的能力（如 sleep/wake_up 、动态原子角色切换）**仅能部分复用**，需同时修改 Python、Rust 两层。
>
> **可复用的现有设施**（验证过）：
> - `BaseWorkerHandler.sleep()` / `wake_up()`：`components/src/dynamo/vllm/handlers.py` L406-472，带 `_sleep_wake_lock` (L364) 串行化
> - `DisaggregationMode` enum (AGGREGATED/PREFILL/DECODE)：`components/src/dynamo/common/constants.py` L7-11
> - NIXL transfer 是角色无关的通用 block copy：`lib/llm/src/block_manager/block/transfer/nixl.rs` L76-140
>
> **必须新增的 API（Dynamo fork 中需实现）**：
> 1. `BaseWorkerHandler.set_disaggregation_mode(new_mode)` — `handlers.py` 中不存在，设计中 `_reconfig_disagg_mode()` 依赖该方法。**需新增 ~20-40 行 Python**，含动态替换 handler 实例逻辑。注意：`main.py` L183 是在启动时选择 handler 类，运行时变更需要重新初始化逻辑。
> 2. `WorkerRoleChanged` 事件类型 — `lib/kv-router/src/protocols.rs` L289-301 仅定义了 `Stored`/`Removed`/`Cleared`。**需在 Rust 侧新增 enum variant + serialization**，~20-40 行 Rust。Router 订阅者也需增加 handler。
> 3. NIXL 重配 API — 设计文档中 `_reconfig_nixl()` 调用 `set_role()` / `start_send_loop()` / `start_recv_loop()` 都是虚构 API。**实际 NIXL agent 结构仅提供 block-level send/recv 调用**。需在 `block_manager/block/transfer/nixl.rs` 附近设计一个“重启会话与反转角色”的 manager API，**预估 80-150 行 Rust**。
> 4. KV Pool 重配 API — `set_allocation_policy()` / `reinit_free_list()` 也不存在。需在 KVBM Block Pool 中设计 `clear_and_resize_for_role()` 类接口，**预估 50-100 行 Rust**。
>
> **调整后的 Dynamo fork 工作量估算**：从原设计 "~300 行" 上调为 **~400-500 行（Python ~150-200 + Rust ~250-350）**。§2.4.2 与§2.8 的 effort 表需同步修正。
>
> **限制与风险**：vLLM 的 `pause_generation()` 会 abort 所有在纯 in-flight 请求（无法单独 pause），因此 sleep 前必须先完成 drain，实际切换延迟 = drain 时间 + ~2s。

### S2.1 背景与需求

#### 问题：PD 分离的"相位空闲"

PD 分离架构下，Prefill 和 Decode 的负载在时间上是错开的。在 RL Batch Inference 中，这种错开尤为极端：

```
Phase 1 (Batch 到达):
  Prefill Workers: ████████████████ (满载，排队)
  Decode Workers:  ░░░░░░░░░░░░░░░░ (空闲，等 Prefill 完成)

Phase 2 (Prefill 完成):
  Prefill Workers: ░░░░░░░░░░░░░░░░ (空闲)
  Decode Workers:  ████████████████ (满载)

→ 固定 PD 比例导致至少一半 GPU 时间被浪费
```

#### 弹性切换的价值

```
              不切换                       有弹性切换
          ─────────────                 ─────────────
          Prefill  Decode              All Workers (弹性角色)
Phase 1:  ████████ ░░░░░               ████████████████ (全做 Prefill)
          100%     0%                  100%
Phase 2:  ░░░░░░░░ ████████            ████████████████ (全做 Decode)
          0%       100%               100%
GPU 利用率: ~50% (平均)                  ~100% (理想情况)
```

#### 触发场景

| 场景 | 触发条件 | 动作 |
|------|---------|------|
| A: D→P | Batch 到达，Prefill 满载，Decode 空闲 | Decode 切 Prefill，加速 Prefill 阶段 |
| B: P→D | Prefill 完成，Decode 满载，Prefill 空闲 | Prefill 切 Decode，加速 Generation 阶段 |
| C: 反复切换 | RL Batch 的 Prefill→Decode→下一个 Batch | 所有 GPU 跟随工作负载相位切换角色 |

### S2.2 技术方案选择

| 方案 | 描述 | 切换时间 | 优点 | 缺点 | 推荐 |
|------|------|---------|------|------|------|
| A: 重启 Pod 切换 | Scale down + scale up 不同角色 Pod | 分钟级 | 简单 | 太慢（模型重载 2-5 min） | ❌ |
| B: Dual-Mode Worker | Worker 始终加载模型，通过 API 切换模式 | **秒级** | 快速，无需重载模型 | 需改 Worker 注册和 NIXL 配置 | ✅ **推荐** |
| C: Aggregated Fallback | 所有 worker 运行 agg 模式 | 即时 | 最灵活 | 资源利用率不如专用 PD | 作为兜底 |
| D: CRIU Snapshot | 利用 Dynamo 内建 cuda-checkpoint 保存/恢复角色状态 | 10-30s | Dynamo v1.0.1 已内建完整实现 | RTX 3090 (Ampere) 不支持 cuda-checkpoint (详见 S1.2 Snapshot 决策) | ❌ |

#### 推荐方案：B (Dual-Mode Worker) + C (Aggregated Fallback)

- **方案 B 为主**：提供秒级角色切换（核心创新）
- **方案 C 为兜底**：切换过程中保持服务可用

**关键设计决策：复用 Dynamo 现有的 `sleep()` / `wake_up()` API**

Dynamo v1.0.1 的 `BaseWorkerHandler` (位于 `components/src/dynamo/vllm/handlers.py`) 已经实现了完整的 sleep/wake_up 生命周期：

```
现有 sleep() 实现 (BaseWorkerHandler):
  Step 1: Unregister from Discovery — 从路由池中移除
  Step 2: pause_generation() — Abort + 排空所有 in-flight 请求
  Step 3: engine.sleep(level) — 释放 GPU 显存 (保留模型权重)
  → 使用 asyncio Lock 保证并发安全

现有 wake_up() 实现 (BaseWorkerHandler):
  Step 1: engine.wake_up() — 恢复 GPU 显存
  Step 2: resume_generation() + register_endpoint_instance() — 重新注册到路由池
```

**这意味着 DualModeWorker 的核心切换流程可以大幅简化**：

```
原始设计 (全部从零构建):              优化设计 (复用现有 API):
─────────────────────────             ─────────────────────────
1. 自行实现 drain                     1. 调用 sleep() ← 已有！
2. 自行实现 deregister                   (自动 drain + deregister + sleep engine)
3. 自行实现 sleep engine              2. 角色重配 (DisaggregationMode + NIXL + KV Pool)
4. 角色重配                              ← 这是唯一需要新写的核心逻辑
5. 自行实现 wake engine               3. 调用 wake_up() ← 已有！
6. 自行实现 register                     (自动 wake engine + register)
7. 自行实现 Router 事件通知            4. 发送 WorkerRoleChanged event
                                         ← 新增 ~20 行
→ 7 个步骤全部自建                    → 2 个步骤复用 + 2 个步骤新建
```

**可行性核心依据**：Prefill 和 Decode 使用**完全相同的模型权重**。同一 GPU 上已加载模型，切换角色只需要变更以下配置（不需要重载模型）：

| 需要切换的部分 | D→P 操作 | P→D 操作 | 复用现有 API | 耗时 |
|--------------|----------|----------|-------------|------|
| Drain + Unregister | sleep() 自动完成 | sleep() 自动完成 | ✅ `BaseWorkerHandler.sleep()` | < 1s |
| GPU 显存释放/恢复 | sleep()/wake_up() | sleep()/wake_up() | ✅ `engine_client.sleep/wake_up` | < 0.5s |
| Discovery 重新注册 | wake_up() 自动完成 | wake_up() 自动完成 | ✅ `BaseWorkerHandler.wake_up()` | < 1s |
| NIXL Transfer 角色 | receiver → sender | sender → receiver | ❌ 需新增 | < 0.5s |
| KV Cache Pool 策略 | 长期 decode → 短期 prefill | 反之 | ❌ 需新增 | < 0.5s |
| DisaggregationMode | DECODE → PREFILL | PREFILL → DECODE | ❌ 需新增 (修改 handler 引用) | < 0.1s |
| Router 通知 | WorkerRoleChanged event | WorkerRoleChanged event | ❌ 需新增 ~20 行 | < 0.5s |

**总切换时间：2-5 秒**（主要是 drain in-flight 请求的等待时间）。

> **工程影响**: 复用 sleep/wake_up 显著降低了 Dynamo fork 的改动量。原本需要从零构建 drain + unregister + sleep + wake + register 五个核心步骤，现在只需在 sleep() 和 wake_up() 之间插入角色重配逻辑。这将 S2 的 Dynamo fork 工作量从"高"降为"中"。

### S2.3 整体实现架构——代码改动边界

S2 与 S1 的关键区别：S1 **不修改 Dynamo 代码**（纯外部 API），而 S2 **需要修改 Dynamo 内部代码**。但通过**复用 Dynamo 现有的 `sleep()` / `wake_up()` API**，Dynamo fork 的改动量大幅降低。

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     S2 代码改动边界图 (优化后)                                 │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────┐          │
│  │  我们的代码库: rl-scaling-controller/                          │          │
│  │  ──────────────────────────────────                           │          │
│  │  ▸ role_switch/controller.py  — 切换决策逻辑 (何时切、切哪个)   │          │
│  │  ▸ role_switch/strategy.py    — 选择最佳候选 worker            │          │
│  │  ▸ role_switch/dual_mode_client.py — 调用 Worker HTTP API     │          │
│  │  这些代码只做"决策 + 发指令"，不碰 Dynamo 内部                  │          │
│  └──────────────┬─────────────────────────────────────────────────┘          │
│                 │                                                            │
│                 │ HTTP: POST /switch_role {"target_role": "prefill"}          │
│                 ▼                                                            │
│  ┌────────────────────────────────────────────────────────────────┐          │
│  │  Dynamo 代码改动 (fork Dynamo 仓库, 提交 PR)                    │          │
│  │  ──────────────────────────────────────                        │          │
│  │                                                                │          │
│  │  ★ 核心优化: 复用 BaseWorkerHandler.sleep()/wake_up()          │          │
│  │  ─────────────────────────────────────────────────             │          │
│  │  sleep() 已实现: unregister + pause_generation + engine.sleep  │          │
│  │  wake_up() 已实现: engine.wake_up + resume_generation +        │          │
│  │                    register_endpoint_instance                  │          │
│  │  → Drain/Unregister/Register 全部复用, 无需重写                 │          │
│  │                                                                │          │
│  │  改动 1: Worker Python — /switch_role endpoint (工作量: 中-低)  │          │
│  │  ┌──────────────────────────────────────────────────┐          │          │
│  │  │ components/src/dynamo/vllm/dual_mode.py (新增)     │          │          │
│  │  │ • 新增 --dual-mode 启动参数                        │          │          │
│  │  │ • 新增 /switch_role HTTP endpoint (FastAPI)        │          │          │
│  │  │ • 切换编排: sleep() → 角色重配 → wake_up()          │          │          │
│  │  │   (不再需要自建 drain/deregister/register!)         │          │          │
│  │  │ 复用的现有文件:                                     │          │          │
│  │  │ • components/src/dynamo/vllm/handlers.py           │          │          │
│  │  │   BaseWorkerHandler.sleep() — drain+unregister     │          │          │
│  │  │   BaseWorkerHandler.wake_up() — wake+register      │          │          │
│  │  │ • components/src/dynamo/vllm/main.py               │          │          │
│  │  │   worker() 入口, init_prefill/init 角色分支         │          │          │
│  │  │ • components/src/dynamo/common/constants.py         │          │          │
│  │  │   DisaggregationMode(AGGREGATED/PREFILL/DECODE)     │          │          │
│  │  └──────────────────────────────────────────────────┘          │          │
│  │                                                                │          │
│  │  改动 2: Rust 核心层 — 角色重配 API (工作量: 中)                │          │
│  │  ┌──────────────────────────────────────────────────┐          │          │
│  │  │ lib/llm/src/block_manager/                         │          │          │
│  │  │   block/transfer/nixl.rs, layout/nixl.rs           │          │          │
│  │  │   • reconfig_nixl(): 切换 NIXL send/recv 方向      │          │          │
│  │  │   controller.rs, pool.rs, state.rs                 │          │          │
│  │  │   • reconfig_kv_pool(): 重新分配 KV Cache 内存池   │          │          │
│  │  │ 注意: Discovery re-register 已被 sleep/wake_up     │          │          │
│  │  │ 覆盖, 无需在此层重复实现                            │          │          │
│  │  └──────────────────────────────────────────────────┘          │          │
│  │                                                                │          │
│  │  改动 3: Rust KV Router — 事件扩展 (工作量: 低, ~20 行)        │          │
│  │  ┌──────────────────────────────────────────────────┐          │          │
│  │  │ lib/llm/src/kv_router/                             │          │          │
│  │  │   publisher.rs, subscriber.rs                      │          │          │
│  │  │ lib/kv-router/src/indexer.rs                       │          │          │
│  │  │ • 新增 WorkerRoleChanged 事件类型                   │          │          │
│  │  │ • event handler: 清零 active_blocks/in_flight      │          │          │
│  │  └──────────────────────────────────────────────────┘          │          │
│  │                                                                │          │
│  └────────────────────────────────────────────────────────────────┘          │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### S2.4 DualModeWorker 详解——Dynamo 代码改动

#### S2.4.1 为什么 DualModeWorker 是改 Dynamo 而不是独立项目

```
问题: DualModeWorker 需要做什么？

答案: Worker 在运行中动态切换自己的角色 (Prefill ↔ Decode)。
      虽然 sleep()/wake_up() 覆盖了 drain/unregister/register,
      但角色重配涉及 Worker 内部的 2 个子系统 (仍需改 Dynamo):

      1. NIXL Agent 方向 (Prefill 是 sender, Decode 是 receiver)
         → NIXL Agent 在 Worker 进程内部初始化
         → 切换方向需要调用 nixl_agent 的内部方法
         → 不改 Dynamo 源码就无法调用

      2. KV Cache 内存池 (Prefill 和 Decode 的 block 分配策略不同)
         → KVBM 在 Worker 进程内部管理
         → 重新分配需要调用 KVBM 内部方法
         → 不改 Dynamo 源码就无法调用

      以下 2 个子系统已被 sleep()/wake_up() 覆盖, 无需重写:

      ✅ Discovery 注册 (sleep 自动 unregister, wake_up 自动 register)
      ✅ Drain + 请求排空 (sleep 自动 pause_generation + abort in-flight)

      结论: DualModeWorker 的角色重配逻辑必须在 Dynamo 进程内部。
            只能通过修改 Dynamo 代码来实现。
            但改动范围比原始设计小: 主要是 NIXL 和 KV Pool 重配。
            切换的"编排"(sleep → reconfig → wake_up) 和"决策"在我们的代码中。
```

#### S2.4.2 DualModeWorker Python 入口（基于 sleep/wake_up 优化）

```python
# Dynamo 代码改动: components/src/dynamo/vllm/dual_mode.py
# (新增文件，复用现有 BaseWorkerHandler.sleep()/wake_up() 机制)
#
# 复用的现有实现 (无需修改):
#   components/src/dynamo/vllm/handlers.py:
#     BaseWorkerHandler.sleep(body):
#       Step 1: unregister_endpoint_instance() — 从 Discovery 移除
#       Step 2: engine_client.pause_generation() — abort + drain in-flight
#       Step 3: engine_client.sleep(level) — 释放 GPU 显存
#     BaseWorkerHandler.wake_up(body):
#       Step 1: engine_client.wake_up() — 恢复 GPU 显存
#       Step 2: resume_generation() + register_endpoint_instance() — 重新注册
#
# 需修改的现有文件:
#   components/src/dynamo/vllm/main.py — worker() 入口, 新增 --dual-mode 参数
#   components/src/dynamo/common/constants.py — DisaggregationMode

"""
DualModeWorker: 支持运行时角色切换的 Dynamo Worker。

核心设计思路:
  sleep() 和 wake_up() 已经覆盖了切换所需的大部分生命周期:
    sleep() = drain + unregister + sleep engine
    wake_up() = wake engine + register
  
  DualModeWorker 只需在 sleep() 和 wake_up() 之间
  插入角色重配逻辑 (NIXL + KV Pool + DisaggregationMode)。

启动方式:
  dynamo-worker --dual-mode --initial-role prefill --model /data/models/qwen3-0.6b

与普通 Worker 的区别:
  - 普通 Worker: 启动时固定角色，终身不变
  - DualModeWorker: 启动时选择初始角色，运行中可通过 HTTP API 切换

共同点:
  - 使用完全相同的模型权重 (Prefill 和 Decode 用同一个模型)
  - 使用同一个 vLLM Engine 实例 (Engine 本身支持 prefill + decode)
  - GPU 显存布局一致 (模型权重 + KV Cache Pool)
"""

import asyncio
import time
from enum import Enum
from fastapi import FastAPI

class Role(Enum):
    PREFILL = "prefill"
    DECODE = "decode"

class DualModeWorker:
    """
    封装角色切换的完整流程。
    
    核心组件:
      - self.handler: BaseWorkerHandler (现有, 提供 sleep/wake_up)
      - self.nixl_agent: NIXL 传输代理 (现有, 需新增 reconfig API)
      - self.kvbm: KV Block Manager (现有, 需新增 reconfig API)
      - self.kv_publisher: KV 事件发布 (现有, 需新增 role_changed 事件)
    
    关键: handler.sleep()/wake_up() 是复用的, 不需要修改。
          只有 nixl/kvbm 的 reconfig 方法和 kv_publisher 的事件类型是新增的。
    """
    
    def __init__(self, initial_role: Role, handler, nixl_agent, kvbm, kv_publisher):
        self.current_role = initial_role
        self.handler = handler        # BaseWorkerHandler — 提供 sleep/wake_up
        self.nixl = nixl_agent        # NIXL Agent — 需新增 reconfig API
        self.kvbm = kvbm              # KV Block Manager — 需新增 reconfig API
        self.kv_publisher = kv_publisher  # KV Publisher — 需新增事件类型
        self.is_switching = False
    
    # ─── HTTP API (供 RL Scaling Controller 调用) ───
    
    async def handle_switch_role(self, target_role: str) -> dict:
        """
        POST /switch_role {"target_role": "prefill" | "decode"}
        
        切换流程 (优化后，复用 sleep/wake_up):
          1. sleep()       — 自动 drain + unregister + sleep engine [复用]
          2. 角色重配       — NIXL + KV Pool + DisaggregationMode   [新增]
          3. wake_up()     — 自动 wake engine + register            [复用]
          4. 通知 Router   — WorkerRoleChanged event               [新增]
        
        返回: {"status": "ok", "new_role": "prefill", "switch_time_ms": 2300}
        """
        target = Role(target_role)
        if target == self.current_role:
            return {"status": "already_in_role", "current_role": self.current_role.value}
        
        if self.is_switching:
            return {"status": "already_switching"}
        
        self.is_switching = True
        start_time = time.time()
        
        try:
            # ─── Step 1: Sleep (复用 BaseWorkerHandler.sleep) ───
            # 内部自动执行:
            #   1.1 unregister_endpoint_instance() → 从 Discovery 移除, Router 不再路由到此 Worker
            #   1.2 pause_generation() → abort + drain 所有 in-flight 请求
            #   1.3 engine.sleep(level=1) → 释放 GPU 显存 (保留模型权重)
            # 使用 _sleep_wake_lock 保证并发安全 (handler 内部已有)
            sleep_result = await self.handler.sleep({"level": 1})
            if sleep_result.get("status") != "ok":
                return {"status": "error", "message": f"sleep failed: {sleep_result}"}
            
            # ─── Step 2: 角色重配 (新增逻辑, sleep 和 wake_up 之间) ───
            # 此时 engine 已 sleep, 无 in-flight, 已从 Discovery 注销
            # 安全地重新配置内部子系统
            
            # 2a. 切换 DisaggregationMode
            old_role = self.current_role
            self.current_role = target
            # 修改 handler 内部的角色标识, 使 wake_up 时以新角色注册
            self.handler.set_disaggregation_mode(target.value)
            
            # 2b. NIXL 方向切换 (新增 Rust API)
            # Prefill 是 sender, Decode 是 receiver
            await self._reconfig_nixl(target)
            
            # 2c. KV Cache Pool 策略切换 (新增 Rust API)
            await self._reconfig_kv_pool(target)
            
            # ─── Step 3: Wake Up (复用 BaseWorkerHandler.wake_up) ───
            # 内部自动执行:
            #   3.1 engine.wake_up() → 恢复 GPU 显存
            #   3.2 resume_generation() → 恢复请求处理
            #   3.3 register_endpoint_instance() → 以新角色注册到 Discovery
            #       (因为 Step 2a 已修改 disaggregation_mode,
            #        register 时会注册到正确的新角色端点)
            wake_result = await self.handler.wake_up({})
            if wake_result.get("status") != "ok":
                return {"status": "error", "message": f"wake_up failed: {wake_result}"}
            
            # ─── Step 4: 通知 Router (新增事件类型) ───
            # 发送 WorkerRoleChanged 事件, Router 清零负载追踪
            await self.kv_publisher.emit_role_changed(
                old_role=old_role.value,
                new_role=target.value,
            )
            
            elapsed_ms = int((time.time() - start_time) * 1000)
            
            return {
                "status": "ok",
                "new_role": target.value,
                "switch_time_ms": elapsed_ms,
            }
        except Exception as e:
            # 异常恢复: 尝试 wake_up 以恢复服务
            try:
                await self.handler.wake_up({})
            except Exception:
                pass
            return {"status": "error", "message": str(e)}
        finally:
            self.is_switching = False
    
    # ─── 角色重配内部方法 (Step 2 的子步骤, 需要新增到 Dynamo) ───
    
    async def _reconfig_nixl(self, target_role: Role):
        """
        NIXL 方向切换 — 需要在 Dynamo Rust 层新增 API。
        
        背景: 在 PD 分离架构中:
        - Prefill Worker 的 NIXL Agent 是 SENDER (发送 KV Cache 到 Decode)
        - Decode Worker 的 NIXL Agent 是 RECEIVER (接收 KV Cache 从 Prefill)
        
        此方法在 engine sleep 状态下调用, GPU 已 quiesce, 操作安全。
        
        为什么耗时 < 0.5s:
        - Engine 已 sleep, NIXL Agent 无活跃传输
        - 只是切换内部的 send/recv loop 和角色标志
        - RDMA 连接不需要重建 (PCIe 地址不变)
        """
        if target_role == Role.DECODE:
            self.nixl.stop_send_loop()
            self.nixl.set_role("receiver")
            self.nixl.start_recv_loop()
        else:  # PREFILL
            self.nixl.stop_recv_loop()
            self.nixl.set_role("sender")
            self.nixl.start_send_loop()
        self.nixl.re_register()
    
    async def _reconfig_kv_pool(self, target_role: Role):
        """
        KV Cache 内存池重新配置 — 需要在 Dynamo Rust 层新增 API。
        
        此方法在 engine sleep 状态下调用, 所有 blocks 已释放, 操作安全。
        
        Prefill vs Decode 的 KV Cache 使用模式:
        ┌──────────────────────────────────────────────────────────┐
        │ Prefill: 临时 KV → prefill 完后 NIXL 发走 → 激进回收      │
        │ Decode:  长期 KV → 保持到生成结束 → 保守回收               │
        └──────────────────────────────────────────────────────────┘
        
        为什么耗时 < 0.5s:
        - Engine sleep 后所有 blocks 已 free
        - 只修改分配策略参数, 不需要物理搬运数据
        """
        self.kvbm.set_allocation_policy(target_role.value)
        self.kvbm.reinit_free_list()
```

> **与原始设计的对比**: 原始 S2.4.2 设计中有 7 个步骤全部从零构建 (drain → deregister → flush_kv_cache → reconfig_nixl → reconfig_kv_pool → register → notify)。优化后只有 4 个步骤，其中 Step 1 (sleep) 和 Step 3 (wake_up) 完全复用现有 API。需要新增的代码集中在 Step 2 (角色重配) 和 Step 4 (Router 通知)。这将 DualModeWorker Python 层的新增代码量从 ~300 行减少到 ~150 行。

#### S2.4.3 Router WorkerRoleChanged 事件处理

```rust
// Dynamo 代码改动: lib/llm/src/kv_router/ (scheduler.rs, publisher.rs, subscriber.rs)
// 以及 lib/kv-router/src/indexer.rs (KV 索引)
// (在现有文件中新增 ~20-30 行)

// 新增事件类型 (在 events.rs 中)
pub enum KvEvent {
    BlockStored { worker_id: u64, block_id: u64, tokens: Vec<u32> },
    BlockRemoved { worker_id: u64, block_id: u64 },
    // ▼ 新增 ▼
    WorkerRoleChanged { worker_id: u64, old_role: String, new_role: String },
}

// 在 event_handler.rs 的 handle_event 方法中新增分支:
fn handle_event(&mut self, event: KvEvent) {
    match event {
        // ... 现有的 BlockStored, BlockRemoved 处理 ...
        
        KvEvent::WorkerRoleChanged { worker_id, old_role, new_role } => {
            // 1. 清除该 worker 在 KVIndexer 中的所有条目
            //    (flush_kv_cache 已经发了 BlockRemoved events，
            //     这里是 fallback 确保完全清除)
            self.kv_indexer.remove_all_entries_for_worker(worker_id);
            
            // 2. 清零 Router 内部的负载追踪计数
            //    active_blocks: Router 追踪每个 worker 的 KV block 使用量
            //    in_flight_requests: Router 追踪每个 worker 的请求数
            if let Some(worker_state) = self.worker_states.get_mut(&worker_id) {
                worker_state.active_blocks = 0;
                worker_state.in_flight_requests = 0;
                worker_state.role = new_role.clone();
                log::info!(
                    "Worker {} role changed: {} → {}, counters reset",
                    worker_id, old_role, new_role
                );
            }
        }
    }
}
```

### S2.5 三层通知机制详解

角色切换后，Router 的状态需要全面更新。为什么需要 3 层而不是 1 层？因为 Router 内部有 3 个独立的状态子系统：

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Router 内部状态子系统 (为什么需要 3 层通知)                                  │
│                                                                            │
│ ┌──────────────────────────────────┐                                       │
│ │ 子系统 1: Worker Registry         │  ← 知道有哪些 workers，各是什么角色    │
│ │ (来源: Discovery Service)         │                                       │
│ │ 数据: {worker_id → role, addr}    │                                       │
│ │ 更新方式: K8s EndpointSlice watch │  ← Layer 1: Discovery re-register    │
│ │ 不更新会怎样: 路由到错误角色的 wkr │                                       │
│ └──────────────────────────────────┘                                       │
│                                                                            │
│ ┌──────────────────────────────────┐                                       │
│ │ 子系统 2: KV Cache Index          │  ← 知道哪个 prefix 在哪个 worker 上   │
│ │ (来源: KVPublisher ZMQ events)    │                                       │
│ │ 数据: Radix Tree {token_seq →     │                                       │
│ │        worker_id, block_ids}      │                                       │
│ │ 更新方式: ZMQ events subscription │  ← Layer 2: blocks removed events    │
│ │ 不更新会怎样: 错误的 overlap_score │                                       │
│ │   → 以为 worker 上有 KV → 路由    │                                       │
│ │   过去 → 没找到 → prefill 全量重做 │                                       │
│ └──────────────────────────────────┘                                       │
│                                                                            │
│ ┌──────────────────────────────────┐                                       │
│ │ 子系统 3: Worker Load Tracking    │  ← 知道每个 worker 负载多重           │
│ │ (来源: KV events 增量追踪)         │                                       │
│ │ 数据: {worker_id → active_blocks, │                                       │
│ │        in_flight_requests}        │                                       │
│ │ 更新方式: 从 KV events 增量计算    │  ← Layer 3: WorkerRoleChanged event  │
│ │ 不更新会怎样: 负载均衡偏差         │                                       │
│ │   → 以为 worker 很忙 → 不路由     │                                       │
│ │   → 或以为很闲 → 过度路由          │                                       │
│ └──────────────────────────────────┘                                       │
│                                                                            │
│ 总结: 3 个子系统用不同数据源更新，必须全部清理才能保证一致性                    │
└────────────────────────────────────────────────────────────────────────────┘
```

### S2.6 角色切换完整流程——时序分析（基于 sleep/wake_up 优化后）

```
时间轴 (D→P 切换示例, Qwen3-0.6B):

T+0.0s    Controller 调用 POST /switch_role {"target_role": "prefill"}
          │
          ═══ Step 1: handler.sleep({"level": 1}) [复用现有 API] ═══
          │
T+0.0s    sleep() 内部 Step 1.1: unregister_endpoint_instance()
          │ Discovery: 从 EndpointSlice 移除 decode 条目
          │ Router: 感知到 worker 离开 (watch event)
T+0.3s    sleep() 内部 Step 1.2: pause_generation()
          │ abort 所有 in-flight 请求 + 等待 drain
          │ (如果是 RL Batch 的相位切换，此时通常已无 in-flight)
T+0.5s    sleep() 内部 Step 1.3: engine.sleep(level=1)
          │ 释放 GPU 显存 (保留模型权重)
T+0.8s    sleep() 返回 {"status": "ok"}
          │
          ═══ Step 2: 角色重配 (新增逻辑, engine sleep 状态) ═══
          │
T+0.8s    Step 2a: set_disaggregation_mode("prefill")
          │ 修改 handler 内部角色标识
T+0.8s    Step 2b: reconfig_nixl(PREFILL)
          │ NIXL Agent: stop_recv_loop → set_role(SENDER) → start_send_loop
T+1.0s    Step 2c: reconfig_kv_pool(PREFILL)
          │ KVBM: set_allocation_policy → reinit_free_list
T+1.1s    角色重配完成
          │
          ═══ Step 3: handler.wake_up({}) [复用现有 API] ═══
          │
T+1.1s    wake_up() 内部 Step 3.1: engine.wake_up()
          │ 恢复 GPU 显存
T+1.4s    wake_up() 内部 Step 3.2: resume_generation()
          │ 恢复请求处理循环
T+1.4s    wake_up() 内部 Step 3.3: register_endpoint_instance()
          │ Discovery: 以新角色 (prefill) 注册到 EndpointSlice
          │ Router: 感知到新 prefill worker (watch event)
T+1.8s    wake_up() 返回 {"status": "ok"}
          │
          ═══ Step 4: 通知 Router [新增 ~20 行] ═══
          │
T+1.8s    emit WorkerRoleChanged event (ZMQ)
          │ Router: 清零 active_blocks, in_flight_requests
T+2.0s    通知完成
          │
T+2.0s    切换完成! 总耗时 ~2 秒 (无 in-flight 时)
          如果有 in-flight 请求, 加 drain 等待时间 (0-30s)

注意: 与原始 7 步设计相比, 步骤从 7 → 4, 其中 Step 1 和 Step 3
     完全复用 BaseWorkerHandler 现有代码, 无需修改。
```

### S2.7 切换触发策略

```python
# src/rl_scaling_controller/role_switch/controller.py

class ElasticRoleSwitchController:
    """
    弹性角色切换控制器 — 作为 RL Scaling Controller 的子模块。
    
    运行在 RL Scaling Controller 的后台 control loop 中,
    每 5 秒评估一次是否需要切换。
    
    决策依据: Prometheus 指标
    执行方式: HTTP 调用 Worker 的 /switch_role endpoint
    """
    
    def __init__(self, config, metrics_collector, dual_mode_client):
        self.prefill_queue_threshold = config.prefill_queue_threshold  # e.g., 10
        self.decode_idle_threshold = config.decode_idle_threshold      # e.g., 0.2
        self.min_switch_interval_sec = config.min_switch_interval      # e.g., 30
        self.min_decode_workers = config.min_decode_workers            # e.g., 1
        self.min_prefill_workers = config.min_prefill_workers          # e.g., 1
        self.metrics = metrics_collector
        self.client = dual_mode_client
        self.last_switch_time = 0
    
    async def evaluate_and_execute(self):
        """每 5 秒被 control loop 调用一次"""
        
        # 防抖: 距上次切换 < 30s 则跳过
        if time.time() - self.last_switch_time < self.min_switch_interval_sec:
            return
        
        metrics = await self.metrics.get_cluster_metrics()
        
        # ─── 场景 A: Decode → Prefill ───
        # 条件: Prefill 过载 (队列长) + Decode 空闲 (利用率低)
        if (metrics.prefill_queue_depth > self.prefill_queue_threshold
            and metrics.decode_utilization < self.decode_idle_threshold
            and metrics.decode_worker_count > self.min_decode_workers):
            
            # 选择最空闲的 Decode Worker
            target_worker = self._find_most_idle_worker(
                metrics.decode_workers, role="decode"
            )
            if target_worker:
                result = await self.client.switch_role(
                    worker_addr=target_worker.addr,
                    target_role="prefill",
                )
                if result["status"] == "ok":
                    self.last_switch_time = time.time()
                    logger.info(f"Switched {target_worker.id} to prefill "
                               f"in {result['switch_time_ms']}ms")
                return
        
        # ─── 场景 B: Prefill → Decode ───
        # 条件: Decode 过载 + Prefill 空闲
        if (metrics.decode_queue_depth > self.decode_queue_threshold
            and metrics.prefill_utilization < self.prefill_idle_threshold
            and metrics.prefill_worker_count > self.min_prefill_workers):
            
            target_worker = self._find_most_idle_worker(
                metrics.prefill_workers, role="prefill"
            )
            if target_worker:
                result = await self.client.switch_role(
                    worker_addr=target_worker.addr,
                    target_role="decode",
                )
                if result["status"] == "ok":
                    self.last_switch_time = time.time()
                return
    
    def _find_most_idle_worker(self, workers, role):
        """选择 in_flight_requests 最少的 worker"""
        eligible = [w for w in workers if w.in_flight_requests == 0]
        if not eligible:
            # 没有完全空闲的，选 in_flight 最少的
            eligible = sorted(workers, key=lambda w: w.in_flight_requests)
        return eligible[0] if eligible else None
```

```python
# src/rl_scaling_controller/role_switch/dual_mode_client.py

import httpx

class DualModeClient:
    """HTTP 客户端，调用 Worker 的 /switch_role 和 /drain endpoint"""
    
    def __init__(self):
        self.client = httpx.AsyncClient(timeout=120.0)  # 切换可能耗时较长
    
    async def switch_role(self, worker_addr: str, target_role: str) -> dict:
        """
        调用 Worker 的 /switch_role HTTP endpoint。
        
        worker_addr: Worker 的 ClusterIP + port (从 Discovery 获取)
        target_role: "prefill" 或 "decode"
        """
        resp = await self.client.post(
            f"http://{worker_addr}/switch_role",
            json={"target_role": target_role},
        )
        return resp.json()
    
    async def drain(self, worker_addr: str) -> dict:
        """调用 Worker 的 /drain endpoint"""
        resp = await self.client.post(f"http://{worker_addr}/drain")
        return resp.json()
```

### S2.8 需要改动的组件总结（sleep/wake_up 优化后）

| # | 组件 | 所属代码库 | 改动类型 | 语言 | 文件目录 | 工作量 | 描述 |
|---|------|----------|---------|------|---------|-------|------|
| 1 | DualModeWorker | **Dynamo fork** | 新增文件 | Python | `components/src/dynamo/vllm/dual_mode.py` (新增) | **中** (原: 高) | /switch_role endpoint + sleep→reconfig→wake_up 编排。Drain/Unregister/Register 全部复用 BaseWorkerHandler.sleep()/wake_up()，无需重写 |
| 2 | Worker Python 入口 | **Dynamo fork** | 修改 | Python | `components/src/dynamo/vllm/main.py`、`handlers.py` (新增 `set_disaggregation_mode()`)、`components/src/dynamo/common/constants.py` | 低 | 新增 --dual-mode 启动参数, handlers.py 新增角色标识修改方法 |
| 3 | Rust Block Manager | **Dynamo fork** | 修改 | Rust | `lib/llm/src/block_manager/` (controller.rs, pool.rs)、`block/transfer/nixl.rs`、`layout/nixl.rs` | 中 | reconfig_nixl() + reconfig_kv_pool() — 在 engine sleep 状态下切换子系统 |
| 4 | Rust KV Router | **Dynamo fork** | 新增 ~20 行 | Rust | `lib/llm/src/kv_router/publisher.rs`、`lib/kv-router/src/indexer.rs` | 低 | WorkerRoleChanged 事件类型 + handler |
| 5 | Role Switch Controller | `rl-scaling-controller/` | 新增 | Python | `rl-scaling-controller/role_switch/` | 中 | role_switch/ 子模块: 决策 + 调用 Worker API |
| 6 | DualModeClient | `rl-scaling-controller/` | 新增 | Python | `rl-scaling-controller/role_switch/dual_mode_client.py` | 低 | HTTP 调用 Worker /switch_role |
| 7 | DGD YAML | 部署配置 | 修改 | YAML | K8s manifests | 低 | dualModeEnabled: true |

> **优化效果**: 组件数从 8 → 7 (Discovery 层 re-register 被 sleep/wake_up 覆盖，无需单独改动)。DualModeWorker (#1) 工作量从"高"降为"中"。总 Dynamo fork 改动行数估计从 ~500 行降为 ~300 行。

**代码边界清晰总结**：
- **Dynamo fork 改动** (#1-4): Worker 内部的角色重配逻辑 (NIXL + KV Pool) + 切换编排 (/switch_role HTTP endpoint)。Drain/Unregister/Register 复用现有 sleep()/wake_up()
- **我们的代码** (#5-6): 切换决策逻辑，通过 HTTP 调用 Worker 提供的新 API
- 两者通过 **HTTP API** 解耦：Controller 不知道 Worker 内部实现细节，Worker 不知道切换决策逻辑

### S2.9 KV Cache 一致性保障

| 阶段 | 风险 | 保障措施 |
|------|------|---------|
| sleep() Drain | 正在 decode 的请求 KV 必须完整 | `sleep()` 内部 `pause_generation()` abort + drain in-flight 请求 (BaseWorkerHandler 现有实现) |
| Engine Sleep | GPU 显存状态 | engine.sleep(level=1) 释放 KV Cache 显存，保留模型权重 |
| 角色重配 | NIXL sender/receiver 不一致 | Engine sleep 状态下重配，无活跃传输，操作安全 |
| wake_up() Register | Discovery 间隙 (sleep → wake_up 间约 1s) | Router 自动感知，sleep 后 worker 不在路由池，无请求丢失 |
| Router 状态 | active block 计数残留 | WorkerRoleChanged event → 清零 |

**安全约束**：
1. **sleep() 保证 drain 完成**——`pause_generation()` abort + drain 所有 in-flight 请求 (复用现有实现)
2. **原子性**——sleep() → reconfig → wake_up() 作为不可中断序列，异常时自动 wake_up() 恢复
3. **最低冗余**——至少保留 `min_prefill_workers` 和 `min_decode_workers`
4. **防抖**——两次切换间隔 ≥ 30 秒，防止震荡

### S2.10 部署与测试

#### 部署

DualModeWorker 需要在 DGD 中启用：

```yaml
# dgd-dual-mode.yaml (修改现有 DGD 部署)
spec:
  services:
    prefill:
      config:
        disaggregationMode: prefill
        dualModeEnabled: true       # 新增: 启用双模式
    decode:
      config:
        disaggregationMode: decode
        dualModeEnabled: true       # 新增: 启用双模式
```

RL Scaling Controller 已包含 role_switch 子模块，无需额外部署。

#### 测试用例

| 编号 | 名称 | 方法 | 预期 |
|------|------|------|------|
| S2-T1 | D→P 切换 | 手动 POST /switch_role | Worker 成功切换，角色变为 prefill |
| S2-T2 | 切换延迟 | 测量 switch API 返回时间 | < 5s（无 in-flight）|
| S2-T3 | Drain 安全性 | 有 in-flight 时触发切换 | 等待完成后才切换，0 请求丢失 |
| S2-T4 | KVIndexer 一致性 | 切换后查 Router KVIndexer | 旧条目已全部清除 |
| S2-T5 | Active Block 重置 | 切换后检查 Router worker_states | active_blocks=0, in_flight=0 |
| S2-T6 | 切换后功能验证 | 切换后发送对应角色请求 | 正确路由 + 正确推理输出 |
| S2-T7 | 反向切换 P→D | 同 T1-T6 反向 | 同上 |
| S2-T8 | 防抖验证 | 30s 内连续触发两次 | 第二次被拒绝 |
| S2-T9 | 最低保留 | 试图切换唯一 decode worker | 拒绝切换 |
| S2-T10 | NIXL 验证 | 切换后 Prefill→Decode KV 传输 | NIXL 传输正常 |
| S2-T11 | E2E 性能 | 固定 P2D2 vs Elastic 4-worker | makespan 减少 20%+ |

---

## S3. Request Consolidation & Redirection

> ### ❌ 可行性确认 (基于 Dynamo v1.0.1 源码验证)
>
> **结论：低可行性。现有 vLLM v0 / Dynamo v1.0.1 缺少多个必要 API，完整方案需等待 vLLM 上游被动**。建议作为 future work；本项目优先实现“重新 prefill 降级方案”作为过渡。
>
> **验证过的 4 个阐必须依赖**：
> 1. **无单请求 pause API**：`BaseWorkerHandler.pause_generation()` (`handlers.py` L426) 调用 vLLM 的 `engine.pause_generation()`，**会 abort 全部 in-flight requests**，无法单独暂停一个请求。vLLM v0 schedulercore 未暴露单请求 freeze 接口。
> 2. **无 block_table 导入/导出**：vLLM 不暴露请求的 KV block 映射表。设计中 `migrate_out_freeze()` 返回 `block_ids` 不可实现；vLLM scheduler 中 `seq.block_table` 仅在内部可见。
> 3. **无外部触发 NIXL D2D 传输 API**：NIXL 传输仅由 Prefill 在生成 KV 后隐式发起，不允许从外部调用 “Decode A → Decode B 迁移 block X”。需在 `block_manager/block/transfer/` 下新增主动迁移 endpoint。
> 4. **无 per-request block 钉住**：KVBM 未提供在传输期间防止 block 被 evict 的 pin/unpin。迁移过程中源 worker 可能提前释放 block。
>
> **可行的降级方案（本项目采用）**：“重新 prefill 合并”——让源 worker 正常完成请求后释放，后期新到的请求不调度到低负载 worker；或者将剩余请求 abort 后从头重新提交到选定 worker（代价是重复计算 prefill，Qwen3-0.6B 代价 ~50-200ms，在低负载期可接受）。§S3.4 以后章节仅在 vLLM 接口可用后才作为全量实现参考。
>
> **优先级**：P2 (基于当前 Dynamo v1.0.1 评估，在1.0.x 生命周期内 future work)。上游依赖跟踪：vllm-project/vllm scheduler v1 RFC + Dynamo block_manager 主动迁移 proposal。

### S3.1 背景与需求

#### 问题

Batch 推理后期，各 Decode worker 请求分布不均。少量请求占据多个 GPU。

```
Batch 推理后期 (假设原 128 请求分配到 4 个 Decode Worker):

初始分配 (均匀):
Decoder 1: [Req 1-32]    32 requests
Decoder 2: [Req 33-64]   32 requests
Decoder 3: [Req 65-96]   32 requests
Decoder 4: [Req 97-128]  32 requests
→ 4 GPU 满载

经过一段时间 (有些请求先完成):
Decoder 1: [Req 5] [Req 12] [Req 28]     3 requests  ← GPU 利用率 ~10%
Decoder 2: [Req 33] [Req 41]             2 requests  ← GPU 利用率 ~6%
Decoder 3: [Req 72]                      1 request   ← GPU 利用率 ~3%
Decoder 4: [Req 97] [Req 100] ... [Req 115]  8 requests  ← 较正常

问题: 3 个 GPU 各跑 1-3 个请求，严重浪费
理想: 将 Decoder 1-3 的请求合并到 Decoder 4
      Decoder 4: [Req 5] [Req 12] [Req 28] [Req 33] [Req 41] [Req 72] + 原有 8 = 14 requests
      → 释放 3 个 GPU
```

#### 为什么不能等请求自然完成再释放 GPU

```
问题: 假设 avg_osl = 200 tokens, decode 速率 = 50 tok/s
      → 平均每个请求 decode 耗时 = 200/50 = 4 秒

但长尾请求 (生成很长的 response) 可能需要 20-60 秒。
这段时间里，只有 1 个请求占据了 1 个 GPU (价值 ~$0.5/hr)。

如果 RL Batch 有 128 请求分配到 4 GPU:
- 前 90% 请求在 ~5s 内完成
- 最后 10% 请求拖尾到 ~30s
- 后 25s 里，可能 3 个 GPU 各跑 1-2 个请求
- 浪费: 3 GPU × 25s = 75 GPU-seconds / batch

每天 100 个 batch → 7500 GPU-seconds = 2+ GPU-hours / day 白白浪费
```

#### 优化目标

在不显著增加 Batch 总完成时间的前提下，尽早释放空闲 GPU。

$$\text{Minimize } \sum_{g} T_{\text{idle}}(g) \quad \text{s.t. } T_{\text{batch}} \leq T_{\text{batch}}^{\text{no\_consolidation}} \times 1.05$$

### S3.2 技术方案选择

| 方案 | 描述 | 优点 | 缺点 | 推荐 |
|------|------|------|------|------|
| A: 无 KV 迁移 (重新 prefill) | 迁移请求到目标 worker，丢弃 KV，重新 prefill | 简单，利用现有机制 | 重新 prefill 消除大部分收益 | ❌ |
| B: NIXL GPU-to-GPU KV 迁移 | 通过 NIXL 传输 KV blocks 到目标 GPU | 保留 KV，无需重新 prefill | 需要扩展 NIXL 支持主动迁移 | ✅ **推荐** |
| C: 等自然完成 | 不做合并 | 零开发 | GPU 浪费 | 兜底方案 |

#### 推荐方案：B — NIXL KV 迁移 + 请求重定向

方案 A 为什么不行——成本收益分析：

```
方案 A 成本: 重新 prefill 被迁移请求
  → 假设请求已 decode 到 position 150/200 (已生成 150 tokens)
  → 原始 ISL = 500 tokens → 需要重新 prefill 500 tokens
  → 加上已生成的 150 tokens 的 KV 也要重新计算
  → prefill 650 tokens ≈ 13ms (Qwen3-0.6B on RTX 3090)
  → 看似很快，但 N 个请求 × M 次合并 累积起来不少
  → 而且大模型 (70B) 的 prefill 重新计算代价显著更高

方案 B 成本: NIXL GPU-to-GPU 传输 KV
  → 150 position × 114 KB/token (Qwen3-0.6B) = 17.1 MB
  → PCIe Gen4 双向带宽 ~25 GB/s → 传输时间 < 1ms
  → 几乎零成本!

结论: 方案 B 在任何模型大小下都优于方案 A
```

### S3.3 整体实现架构——代码改动边界

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     S3 代码改动边界图                                          │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────┐          │
│  │  我们的代码库: rl-scaling-controller/consolidation/            │          │
│  │  ─────────────────────────────────────────────                │          │
│  │  ▸ controller.py      — 合并 control loop (每 5s 评估一次)     │          │
│  │  ▸ decision_engine.py — 合并决策算法 (值不值得迁移)             │          │
│  │  ▸ migration_client.py — 调用 Dynamo Migration API            │          │
│  │  这些代码只做"决策 + 发指令"                                    │          │
│  └──────────────┬─────────────────────────────────────────────────┘          │
│                 │                                                            │
│                 │ HTTP/gRPC: 调用 Worker 的 /migrate_out 或                   │
│                 │            Migration Operator 的 API                        │
│                 ▼                                                            │
│  ┌────────────────────────────────────────────────────────────────┐          │
│  │  Dynamo 代码改动 (fork Dynamo 仓库, 提交 PR)                    │          │
│  │  ──────────────────────────────────────                        │          │
│  │                                                                │          │
│  │  改动 1: Worker — 主动 KV 导出 API (工作量: 高)                 │          │
│  │  ┌──────────────────────────────────────────────────┐          │          │
│  │  │ Python: components/src/dynamo/vllm/                │          │          │
│  │  │   handlers.py (DecodeWorkerHandler 新增 migrate)    │          │          │
│  │  │   main.py (worker 入口注册新 endpoint)               │          │          │
│  │  │ Rust: lib/llm/src/block_manager/                   │          │          │
│  │  │   block/transfer/nixl.rs (NIXL 主动 send KV)       │          │          │
│  │  │ • /migrate_out endpoint: 暂停指定请求的 decode      │          │          │
│  │  │ • export_kv(request_id) → KV metadata + block IDs  │          │          │
│  │  │ • NIXL agent: 主动 send KV blocks (非常规 P→D)     │          │          │
│  │  └──────────────────────────────────────────────────┘          │          │
│  │                                                                │          │
│  │  改动 2: Worker — KV 导入 + 继续 decode (工作量: 高)            │          │
│  │  ┌──────────────────────────────────────────────────┐          │          │
│  │  │ • /migrate_in endpoint: 接收迁入的 KV              │          │          │
│  │  │ • import_kv(): 在 engine 中注册新 blocks           │          │          │
│  │  │ • resume_decode(): 从迁入位置继续 decode            │          │          │
│  │  │ • Block Re-mapping: 将源 block IDs 映射到本地 IDs  │          │          │
│  │  └──────────────────────────────────────────────────┘          │          │
│  │                                                                │          │
│  │  改动 3: NIXL — 支持 Decode→Decode 传输 (工作量: 中)           │          │
│  │  ┌──────────────────────────────────────────────────┐          │          │
│  │  │ Rust: lib/llm/src/block_manager/                   │          │          │
│  │  │   block/transfer/nixl.rs — NIXL block 传输层       │          │          │
│  │  │   v2/physical/transfer/executor/nixl.rs             │          │          │
│  │  │ Rust: lib/memory/src/nixl.rs — 内存层 NIXL 支持     │          │          │
│  │  │ 现有: NIXL 只在 Prefill→Decode 间传输 KV           │          │          │
│  │  │ 扩展: 支持 Decode→Decode 间的 KV block 传输         │          │          │
│  │  │ 本质: NIXL GPU-to-GPU 传输层不关心角色，              │          │          │
│  │  │       只关心 src_addr → dst_addr                    │          │          │
│  │  │       需要的改动主要在上层"谁触发传输"                │          │          │
│  │  └──────────────────────────────────────────────────┘          │          │
│  │                                                                │          │
│  │  改动 4: Migration 扩展 (工作量: 中)                            │          │
│  │  ┌──────────────────────────────────────────────────┐          │          │
│  │  │ Rust: lib/llm/src/migration.rs                     │          │          │
│  │  │   (现有: RetryManager, is_migratable() —            │          │          │
│  │  │    基于 retry/re-route 的请求迁移, 不传输 KV)        │          │          │
│  │  │ Go: deploy/operator/internal/controller/            │          │          │
│  │  │   (K8s Operator — worker 管理)                     │          │          │
│  │  │ 现有: Migration 处理 worker 退出时的请求迁移         │          │          │
│  │  │       传输 token state，不传输 KV                    │          │          │
│  │  │ 扩展: 支持"主动迁移" API — 由外部 Controller 触发    │          │          │
│  │  │       配合 NIXL KV 传输，实现完整迁移                │          │          │
│  │  └──────────────────────────────────────────────────┘          │          │
│  │                                                                │          │
│  └────────────────────────────────────────────────────────────────┘          │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### S3.4 Dynamo 现有 Request Migration 分析

在扩展之前，必须理解 Dynamo **现有的 Request Migration 做了什么、没做什么**：

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Dynamo 现有 Request Migration (v1.0.1)                                    │
│                                                                          │
│ 触发时机: Worker 即将退出 (SIGTERM, graceful shutdown)                     │
│ 目的: 将该 Worker 上的 in-flight 请求迁移到其他 Worker 继续处理             │
│                                                                          │
│ 传输的内容 (token state):                                                 │
│   ✅ 已生成的 tokens (生成到第几个 token 了)                               │
│   ✅ Sampling 参数 (temperature, top_p, etc.)                             │
│   ✅ 停止条件 (stop tokens, max_tokens)                                   │
│   ✅ 当前 sequence position                                               │
│   ✅ Request ID + metadata                                                │
│                                                                          │
│ 不传输的内容:                                                              │
│   ❌ KV Cache — 不传输!                                                   │
│   → 目标 Worker 收到迁移的请求后，需要重新 prefill                          │
│   → 从 token 0 开始重算所有 KV（包括已生成部分的 KV）                       │
│   → 这就是为什么方案 A "无 KV 迁移" 的开销不可忽略                          │
│                                                                          │
│ 现有 Migration 的代码位置:                                                 │
│   Rust: lib/llm/src/migration.rs                                          │
│   → RetryManager: 追踪 token_ids/max_tokens, 管理 retry 次数              │
│   → is_migratable(): 检查 error 类型是否可重试                              │
│   → 将请求 re-route 到其他 Worker → 目标 Worker 重新 prefill → 继续 decode │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

我们的扩展:
  在现有 Migration Operator 基础上，增加 "KV 迁移" 步骤:
  migrate_request() + transfer_kv() = 完整迁移（保留 KV，不重新 prefill）
```

### S3.5 NIXL KV 迁移技术详解——字节级分析

#### S3.5.1 迁移的数据量计算

```
迁移一个请求的 KV Cache 需要传输多少数据:

KV 大小 = position × kv_size_per_token

示例 (Qwen3-0.6B, 请求已 decode 到 position 150):
  kv_size_per_token = 2 × 28 × 16 × 64 × 2 = 114,688 bytes ≈ 112 KB
  position = ISL + generated_so_far = 500 + 150 = 650
  
  总 KV 大小 = 650 × 112 KB ≈ 71 MB

传输时间:
  PCIe Gen4 x16 带宽: ~25 GB/s (同节点 GPU-to-GPU via CPU)
  NVLink (如果有): ~600 GB/s (不适用于 RTX 3090，无 NVLink)
  
  71 MB / 25 GB/s ≈ 2.8 ms  ← 几乎可以忽略!

对比大模型 (LLaMA-70B, position 650):
  kv_size_per_token = 2 × 80 × 64 × 128 × 2 = 2,621,440 bytes ≈ 2.5 MB
  总 KV 大小 = 650 × 2.5 MB ≈ 1.6 GB
  传输时间 = 1.6 GB / 25 GB/s ≈ 64 ms  ← 仍然很快
```

#### S3.5.2 NIXL 传输层原理

```
NIXL (NVIDIA Inference eXchange Library) GPU-to-GPU 传输:

现有传输路径 (Prefill → Decode):
  Prefill Worker GPU VRAM                    Decode Worker GPU VRAM
  ┌──────────────────────┐                   ┌──────────────────────┐
  │ Block 42: KV[0:16]   │───PCIe──▶CPU──PCIe──▶│ Block 7: KV[0:16]   │
  │ Block 43: KV[16:32]  │───PCIe──▶CPU──PCIe──▶│ Block 8: KV[16:32]  │
  │ Block 44: KV[32:48]  │───PCIe──▶CPU──PCIe──▶│ Block 9: KV[32:48]  │
  └──────────────────────┘                   └──────────────────────┘
  
  传输方式: GPU VRAM → PCIe → Host Memory → PCIe → GPU VRAM
  (RTX 3090 不支持 GPUDirect RDMA 或 NVLink, 只能走 CPU 中转)

扩展传输路径 (Decode → Decode):
  完全相同的传输机制! NIXL 底层只关心:
  - src: GPU 地址 (哪个 GPU 的哪段显存)
  - dst: GPU 地址 (哪个 GPU 的哪段显存)
  - size: 传输字节数
  
  与角色无关，只要知道 src 和 dst 就能传输。
  需要的改动是上层"谁触发这次传输":
  - 现有: Prefill 完成后自动触发 → 发给 Decode
  - 扩展: 合并控制器通过 API 触发 → 从 Decode_A 发给 Decode_B
```

#### S3.5.3 Block Re-mapping 详解

这是 KV 迁移中最复杂的部分——为什么需要 block re-mapping？

```
问题: 源 Worker 和目标 Worker 的 block 编号是独立的!

源 Decode Worker (Worker A):
  Block Table for Request 72:
  ┌─────────────────────────────┐
  │ Position 0-15   → Block 42  │
  │ Position 16-31  → Block 43  │
  │ Position 32-47  → Block 44  │
  │ ...                         │
  │ Position 640-649 → Block 85 │  (共 41 个 blocks)
  └─────────────────────────────┘

目标 Decode Worker (Worker B):
  已有 8 个请求，blocks 0-120 中很多已被占用
  Free blocks: [121, 122, 123, 125, 127, 130, ...]

问题: 不能把 Block 42 直接放到目标的 Block 42 位置——那里可能已经被占了!

解决: Block Re-mapping

步骤:
1. 源 Worker 导出 KV metadata:
   {request_id: 72, blocks: [42,43,44,...,85], total: 41 blocks}

2. 目标 Worker 从 free list 分配 41 个新 blocks:
   new_blocks = [121, 122, 123, 125, 127, ...]

3. 建立映射表:
   mapping = {42→121, 43→122, 44→123, 45→125, ...}

4. NIXL 传输时，逐 block 传输:
   source Block 42 的物理内容 → target Block 121 的物理位置
   source Block 43 的物理内容 → target Block 122 的物理位置
   ...

5. 在目标 Worker 的 engine 中注册:
   Request 72 的 Block Table = [121, 122, 123, 125, 127, ...]
   → engine 根据新 Block Table 继续 decode

6. 通知 KVIndexer:
   source: emit BlockRemoved × 41 (Worker A 上 Request 72 的 blocks)
   target: emit BlockStored × 41 (Worker B 上 Request 72 的 blocks)

为什么这样设计:
- Block 是物理 GPU 显存上的固定大小区域
- 每个 Worker 独立管理自己的 block 编号空间
- 不同 Worker 的 block 42 对应不同的物理地址
- 必须通过 re-mapping 将内容放到目标的正确物理位置
```

### S3.6 完整迁移流程——从决策到 GPU 释放

```
时间轴 (合并 Decoder 3 的 1 个请求到 Decoder 4):

T+0.0s   Consolidation Controller 决策:
         │ Decoder 3: 只有 Req 72, 利用率 3%
         │ Decoder 4: 有 8 个请求, 还能容纳 56 个
         │ → 值得迁移!
         │
T+0.0s   Step 1: 暂停源 Worker (Decoder 3) 对 Req 72 的 decode
         │ Controller → POST Decoder_3:/migrate_out {request_id: 72}
         │ Decoder 3:
         │   a. 暂停 Req 72 的 decode iteration (不影响其他请求)
         │   b. 等待当前 decode step 完成 (最多 1 个 step, ~20ms)
         │   c. 返回 KV metadata:
         │      {
         │        request_id: 72,
         │        position: 650,        // 已处理 650 tokens
         │        blocks: [42,43,...,85],// 41 个 blocks
         │        block_size: 16,       // 每 block 16 tokens
         │        kv_bytes_per_block: 1,835,008, // 16 × 114,688
         │        total_bytes: 75,235,328,       // 41 × 1,835,008 ≈ 72 MB
         │        token_state: {        // Migration Operator 格式
         │          generated_tokens: [tok1, tok2, ...],
         │          sampling_params: {temperature: 0.7, ...},
         │          stop_conditions: {max_tokens: 200, ...},
         │        }
         │      }
T+0.1s   │
         │
T+0.1s   Step 2: 在目标 Worker (Decoder 4) 预分配 blocks
         │ Controller → POST Decoder_4:/migrate_in/prepare {n_blocks: 41}
         │ Decoder 4:
         │   a. KVBM.allocate(41) → new_blocks = [121,122,...,161]
         │   b. 返回 block mapping + NIXL recv address:
         │      {
         │        new_blocks: [121,122,...,161],
         │        nixl_recv_addr: "gpu4:0x7f1234000000", // GPU 物理地址
         │      }
T+0.2s   │
         │
T+0.2s   Step 3: NIXL GPU-to-GPU 传输
         │ Controller → POST Decoder_3:/migrate_out/transfer {
         │   mapping: {42→(gpu4,0x7f1234000000+offset_121), ...},
         │   target_addr: "gpu4_nixl_endpoint"
         │ }
         │ 
         │ 传输过程 (每个 block 独立传输，可并行):
         │ GPU 3 Block 42 ──PCIe──▶ CPU RAM ──PCIe──▶ GPU 4 Block 121
         │ GPU 3 Block 43 ──PCIe──▶ CPU RAM ──PCIe──▶ GPU 4 Block 122
         │ ... (41 个 blocks 并行流水线传输)
         │
         │ 总数据: ~72 MB, PCIe Gen4 ~25 GB/s → ~3 ms
T+0.3s   │
         │
T+0.3s   Step 4: 在目标 Worker 注册 KV 并继续 decode
         │ Controller → POST Decoder_4:/migrate_in/activate {
         │   request_id: 72,
         │   block_table: [121,122,...,161],
         │   position: 650,
         │   token_state: {...},
         │ }
         │ Decoder 4:
         │   a. 在 vLLM engine 中注册新的 KV block table
         │   b. 恢复请求状态 (position, sampling params, stop conditions)
         │   c. 将 Req 72 加入 decode scheduling
         │   d. 继续从 position 650 开始 decode
T+0.5s   │
         │
T+0.5s   Step 5: 清理源 Worker
         │ Controller → POST Decoder_3:/migrate_out/complete {request_id: 72}
         │ Decoder 3:
         │   a. KVBM.free(blocks [42,...,85]) → 释放 GPU 显存
         │   b. KVPublisher.emit(BlockRemoved × 41) → Router KVIndexer 更新
         │   c. 确认 Req 72 已从本地移除
T+0.6s   │
         │
T+0.6s   Step 6: 更新全局索引
         │ Decoder 4:
         │   KVPublisher.emit(BlockStored × 41) → Router KVIndexer 更新
         │   (现在 Router 知道 Req 72 的 KV 在 Decoder 4 上)
T+0.7s   │
         │
T+0.7s   Step 7: 检查源 Worker 是否可以释放
         │ Controller 检查: Decoder 3 还有其他请求吗？
         │   → 没有了 (Req 72 是最后一个)
         │   → 可以 scale down!
         │ Controller → patch DGDSA decode replicas -= 1
         │ → K8s 终止 Decoder 3 Pod
         │ → GPU 释放!
T+1.0s   │
         │
T+1.0s   合并完成!
         │ 总耗时: ~1 秒 (Qwen3-0.6B)
         │ 节省: 1 个 GPU × Req 72 剩余 decode 时间
         │ 
         │ 对 Req 72 的影响:
         │   暂停时间 = ~0.5s (Step 1-4)
         │   → 相当于多等了 0.5 秒
         │   → 但节省了整个 GPU
```

### S3.7 Consolidation Decision Engine 详解

```python
# src/rl_scaling_controller/consolidation/decision_engine.py

from dataclasses import dataclass
from typing import List, Optional
import logging

logger = logging.getLogger(__name__)

@dataclass
class WorkerState:
    worker_id: str
    addr: str
    active_requests: int
    active_request_ids: List[str]
    available_capacity: int          # 还能容纳多少请求
    estimated_remaining_time: float  # 预估剩余 decode 时间 (秒)
    active_kv_blocks: int           # 当前占用的 KV blocks 数

@dataclass
class ConsolidationPlan:
    source_worker: WorkerState
    target_worker: WorkerState
    request_ids: List[str]            # 要迁移的请求 IDs
    estimated_kv_bytes: int          # 预估迁移数据量
    estimated_migration_time: float  # 预估迁移耗时
    estimated_gpu_savings: float     # 预估节省 GPU 时间 (秒)

class ConsolidationDecisionEngine:
    """
    合并决策引擎。
    
    运行在 RL Scaling Controller 的后台 control loop 中。
    每 5 秒评估一次是否有 Worker 可以合并释放。
    
    核心决策逻辑:
    1. 找出"源 Worker" — 请求数很少的 Worker (≤ threshold)
    2. 找出"目标 Worker" — 有足够容量接收的 Worker
    3. 评估成本收益:
       - 成本: 迁移时间 (请求暂停 ~0.5s)
       - 收益: 释放 GPU × 剩余时间
    4. 如果收益 > 成本 → 执行合并
    """
    
    def __init__(self, config):
        # 源 Worker 请求数 ≤ 此值时才考虑合并
        self.consolidation_threshold = config.threshold  # e.g., 3
        
        # batch 完成度 > 此值时才启用合并 (避免在 batch 初期就合并)
        self.min_batch_completion_pct = config.min_completion  # e.g., 0.6
        
        # 单个请求的预估迁移开销 (秒)
        self.per_request_migration_overhead = config.overhead  # e.g., 0.5
        
        # 最少保留的 Decode Worker 数
        self.min_decode_workers = config.min_decode_workers  # e.g., 1
    
    def evaluate(self, workers: List[WorkerState], 
                 batch_completion_pct: float) -> List[ConsolidationPlan]:
        """
        评估并返回合并计划列表。
        
        算法:
        1. 按请求数升序排序 Workers
        2. 双指针: source 从最少开始, target 从最多开始
        3. 逐一评估是否值得迁移
        """
        if batch_completion_pct < self.min_batch_completion_pct:
            return []  # batch 还没到后期，不合并
        
        active_workers = [w for w in workers if w.active_requests > 0]
        
        if len(active_workers) <= self.min_decode_workers:
            return []  # 已经是最少 Worker 数了
        
        plans = []
        sorted_workers = sorted(active_workers, key=lambda w: w.active_requests)
        
        source_idx = 0
        target_idx = len(sorted_workers) - 1
        
        while source_idx < target_idx:
            source = sorted_workers[source_idx]
            target = sorted_workers[target_idx]
            
            # 源 Worker 请求太多，不值得迁移
            if source.active_requests > self.consolidation_threshold:
                break
            
            # 目标 Worker 容量不足
            if target.available_capacity < source.active_requests:
                target_idx -= 1
                continue
            
            # 成本收益分析
            migration_time = (source.active_requests * 
                            self.per_request_migration_overhead)
            remaining_time = source.estimated_remaining_time
            
            # 只有当迁移时间 < 剩余时间的 50% 时才迁移
            # (否则还不如让请求在原 Worker 上跑完)
            if migration_time < remaining_time * 0.5:
                estimated_kv_bytes = source.active_kv_blocks * 16 * 114688
                
                plans.append(ConsolidationPlan(
                    source_worker=source,
                    target_worker=target,
                    request_ids=source.active_request_ids,
                    estimated_kv_bytes=estimated_kv_bytes,
                    estimated_migration_time=migration_time,
                    estimated_gpu_savings=remaining_time,  # 释放 1 GPU × remaining_time
                ))
                
                # 更新 target 的可用容量 (用于下一轮评估)
                target.available_capacity -= source.active_requests
                source_idx += 1
            else:
                # 不值得迁移，跳过
                source_idx += 1
        
        return plans
```

### S3.8 Consolidation Controller 完整实现

```python
# src/rl_scaling_controller/consolidation/controller.py

class ConsolidationController:
    """
    合并控制器 — 作为 RL Scaling Controller 的子模块。
    
    在 state_machine 处于 ACTIVE 状态时运行。
    每 5 秒评估一次，执行合并计划。
    """
    
    def __init__(self, config, metrics_collector, migration_client, dgdsa_client):
        self.engine = ConsolidationDecisionEngine(config)
        self.metrics = metrics_collector
        self.migration = migration_client
        self.dgdsa = dgdsa_client
        self.is_consolidating = False
    
    async def control_loop_tick(self, batch_completion_pct: float):
        """每 5 秒被调用一次"""
        
        if self.is_consolidating:
            return  # 上一轮合并还没完成
        
        # 获取所有 Decode Worker 的状态
        workers = await self.metrics.get_decode_worker_states()
        
        # 决策
        plans = self.engine.evaluate(workers, batch_completion_pct)
        
        if not plans:
            return
        
        self.is_consolidating = True
        try:
            for plan in plans:
                logger.info(
                    f"Consolidating {plan.source_worker.worker_id} "
                    f"({plan.source_worker.active_requests} reqs) "
                    f"→ {plan.target_worker.worker_id} "
                    f"(saving ~{plan.estimated_gpu_savings:.1f}s GPU time)"
                )
                await self._execute_plan(plan)
        finally:
            self.is_consolidating = False
    
    async def _execute_plan(self, plan: ConsolidationPlan):
        """执行单个合并计划"""
        source = plan.source_worker
        target = plan.target_worker
        
        for request_id in plan.request_ids:
            try:
                # Step 1: 暂停源 Worker 上的请求，获取 KV metadata
                kv_meta = await self.migration.migrate_out_prepare(
                    source.addr, request_id
                )
                
                # Step 2: 在目标 Worker 上预分配 blocks
                alloc = await self.migration.migrate_in_prepare(
                    target.addr, kv_meta["n_blocks"]
                )
                
                # Step 3: NIXL GPU-to-GPU KV 传输
                await self.migration.transfer_kv(
                    source.addr, target.addr,
                    kv_meta, alloc
                )
                
                # Step 4: 在目标 Worker 上激活请求
                await self.migration.migrate_in_activate(
                    target.addr, request_id,
                    kv_meta["token_state"],
                    alloc["block_table"],
                    kv_meta["position"],
                )
                
                # Step 5: 清理源 Worker
                await self.migration.migrate_out_complete(
                    source.addr, request_id
                )
                
                logger.info(f"Request {request_id} migrated successfully")
                
            except Exception as e:
                # 失败回滚: 请求在源 Worker 上恢复 decode
                logger.error(f"Migration failed for {request_id}: {e}")
                await self.migration.migrate_out_rollback(
                    source.addr, request_id
                )
        
        # 检查源 Worker 是否可以释放
        remaining = await self.metrics.get_worker_request_count(source.worker_id)
        if remaining == 0:
            logger.info(f"Source worker {source.worker_id} empty, scaling down")
            current_replicas = await self.dgdsa.get_replicas("decode")
            self.dgdsa.patch("decode", current_replicas - 1)
```

### S3.9 失败回滚机制

```
失败回滚设计 — "Keep Source Alive" 原则:

核心原则: 在确认目标 Worker 成功接管之前，不释放源 Worker 上的 KV

┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│  Step 1: migrate_out_prepare (暂停请求)                            │
│    失败: 请求继续在源 Worker decode (无影响)                        │
│                                                                    │
│  Step 2: migrate_in_prepare (分配 blocks)                          │
│    失败: 恢复源 Worker 请求的 decode (无影响)                       │
│    清理: 目标 Worker 释放预分配的 blocks                            │
│                                                                    │
│  Step 3: transfer_kv (NIXL 传输)                                   │
│    失败: 恢复源 Worker 请求的 decode (无影响)                       │
│    清理: 目标 Worker 释放预分配的 blocks                            │
│    注意: 传输失败不影响源 Worker 上的原始 KV 数据                    │
│           (NIXL 是 copy, 不是 move)                                │
│                                                                    │
│  Step 4: migrate_in_activate (目标开始 decode)                     │
│    失败: 恢复源 Worker 请求的 decode (无影响)                       │
│    清理: 目标 Worker 释放 blocks + 移除请求注册                     │
│                                                                    │
│  Step 5: migrate_out_complete (释放源 KV)                          │
│    只有到这一步才真正释放源 Worker 上的 KV                          │
│    如果 Step 4 成功但 Step 5 失败:                                  │
│      → 请求在目标 Worker 上继续 (已成功迁移)                        │
│      → 源 Worker 上的 KV 会在 Pod 终止时自然释放                    │
│                                                                    │
│  关键: NIXL 传输是 "copy" 不是 "move"!                             │
│        传输完成后，源和目标都有完整的 KV 数据                        │
│        只有确认目标成功后才删除源的 KV                               │
│        这就是 "Keep Source Alive" 的含义                             │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### S3.10 需要改动的组件总结

| # | 组件 | 所属代码库 | 改动类型 | 语言 | 文件目录 | 工作量 | 描述 |
|---|------|----------|---------|------|---------|-------|------|
| 1 | Consolidation Controller | `rl-scaling-controller/` | 新增 | Python | `rl-scaling-controller/consolidation/` | 中 | consolidation/ 子模块: 决策 + 编排迁移 |
| 2 | Decision Engine | `rl-scaling-controller/` | 新增 | Python | `rl-scaling-controller/consolidation/decision_engine.py` | 中 | 双指针合并算法 + 成本收益分析 |
| 3 | Migration Client | `rl-scaling-controller/` | 新增 | Python | `rl-scaling-controller/consolidation/migration_client.py` | 低 | HTTP 调用 Worker migration API |
| 4 | Worker /migrate_out API | **Dynamo fork** | 新增 | Python+Rust | Python: `components/src/dynamo/vllm/handlers.py` (DecodeWorkerHandler 新增 migrate_out)、`main.py` (注册 endpoint)；Rust: `lib/llm/src/block_manager/block/transfer/nixl.rs` (NIXL 主动 send) | 高 | 暂停请求, 导出 KV metadata, NIXL send |
| 5 | Worker /migrate_in API | **Dynamo fork** | 新增 | Python+Rust | Python: `components/src/dynamo/vllm/handlers.py` (DecodeWorkerHandler 新增 migrate_in)；Rust: `lib/llm/src/block_manager/` (controller.rs, pool.rs 分配 blocks) | 高 | 分配 blocks, NIXL recv, 注册 KV, 继续 decode |
| 6 | Block Re-mapping | **Dynamo fork** | 新增 | Rust | `lib/llm/src/block_manager/` (controller.rs, state.rs, connector.rs) | 高 | 源 block IDs → 目标 block IDs 映射 |
| 7 | NIXL D2D 传输 | **Dynamo fork** | 扩展 | Rust | `lib/llm/src/block_manager/block/transfer/nixl.rs`、`v2/physical/transfer/executor/nixl.rs`、`lib/memory/src/nixl.rs` | 中 | 支持 Decode→Decode KV 传输 (原仅 P→D) |
| 8 | Migration 扩展 | **Dynamo fork** | 扩展 | Rust+Go | Rust: `lib/llm/src/migration.rs`；Go: `deploy/operator/internal/controller/` | 中 | 支持主动迁移触发 (原仅 graceful shutdown re-route) |

**代码边界清晰总结**：
- **我们的代码** (#1-3): 合并决策 + 编排，通过 HTTP 调用 Worker API
- **Dynamo fork 改动** (#4-8): Worker 内部的迁移执行逻辑、NIXL 扩展、Migration Operator 扩展

### S3.11 KV Cache 一致性保障

| 挑战 | 风险 | 保障措施 |
|------|------|---------|
| 传输中数据一致性 | 源 Worker 在传输过程中继续修改 KV | Pause-then-transfer: 暂停该请求的 decode，KV 不会变化 |
| Block 编号冲突 | 源/目标 block 编号空间独立 | Block Re-mapping: 目标分配新 blocks，建立映射表 |
| KVIndexer 更新 | 全局索引不一致 | 原子事件对: source BlockRemoved + target BlockStored |
| Request Stream 重定向 | 客户端接收中断 | Migration Operator 无缝切换: 目标 Worker 继续向 Frontend 发 token |
| 传输失败 | KV 丢失 | Keep Source Alive: NIXL 是 copy 不是 move，失败则回滚到源 |
| 目标 OOM | 目标 GPU 显存不足 | migrate_in_prepare 预分配检查: 分配失败则不迁移 |

### S3.12 部署与测试

Consolidation Controller 作为 RL Scaling Controller 的子模块，无需额外部署。启用方式：

```yaml
# rl-scaling-controller deployment.yaml 环境变量
- name: CONSOLIDATION_ENABLED
  value: "true"
- name: CONSOLIDATION_THRESHOLD
  value: "3"                  # 请求数 ≤ 3 的 Worker 才考虑合并
- name: MIN_BATCH_COMPLETION
  value: "0.6"                # batch 完成 60% 后才开始评估合并
- name: PER_REQUEST_MIGRATION_OVERHEAD
  value: "0.5"                # 单个请求迁移开销预估 0.5s
```

#### 测试用例

| 编号 | 名称 | 方法 | 预期 |
|------|------|------|------|
| S3-T1 | KV 迁移正确性 | 迁移后对比生成输出 | 与不迁移的输出 bit-exact 一致 |
| S3-T2 | 单请求迁移延迟 | 测量 migrate_out → migrate_in_activate | < 1s (Qwen3-0.6B) |
| S3-T3 | Block Re-mapping | 迁移后检查目标 block table | 映射正确，blocks 可用 |
| S3-T4 | GPU 节省 | 对比有/无 consolidation 的 GPU hours | 后期 GPU 减少 20-30% |
| S3-T5 | Batch 时间影响 | 对比有/无 consolidation 的 batch 完成时间 | 增加 < 5% |
| S3-T6 | NIXL 传输验证 | 手动触发 D2D KV 传输 | 数据完整传输 |
| S3-T7 | 失败回滚 | 在 Step 3 注入 NIXL 失败 | 请求在源 Worker 恢复 decode |
| S3-T8 | 目标 OOM | 目标 Worker 显存不足时触发迁移 | 预分配失败，不迁移 |
| S3-T9 | 多请求批量迁移 | 源 Worker 有 3 个请求 | 3 个请求全部成功迁移 |
| S3-T10 | KVIndexer 一致性 | 迁移后查询 Router KVIndexer | 旧条目清除，新条目正确 |
| S3-T11 | E2E 性能 | 128 请求 batch，观察后期合并 | 合并释放 1-2 GPU |

---

# 工程篇

---

## E1. 实现优先级与开发路线图

### E1.1 优先级排序

| 优先级 | 场景 | 难度 | 预期收益 | 依赖 |
|-------|------|------|---------|------|
| **P0** | S1: Rollout Scale | ⭐⭐ | ⭐⭐⭐⭐⭐ 极高（GPU 成本直接节省） | KEDA + DGDSA（v1.0.1 已有） |
| **P1** | S2: Elastic Role Switch | ⭐⭐⭐⭐ | ⭐⭐⭐ 高（GPU 利用率提升） | P0 + DualModeWorker 改造 (Dynamo fork) |
| **P2** | S3: Request Consolidation | ⭐⭐⭐⭐⭐ | ⭐⭐ 中（后期 GPU 节省） | P0 + P1 + NIXL D2D 扩展 + vLLM 单请求 pause API |

### E1.2 开发路线图

```
Phase 1 (4 weeks): Foundation + Rollout Scale (P0, S1)
├── Week 1-2: 搭建 v1.0.1 开发环境, 研读 Planner/DGDSA Operator 源码
│            (deploy/operator/internal/controller/dynamographdeploymentscalingadapter_controller.go,
│             components/src/dynamo/planner/)
├── Week 3-4: 实现 RL Scaling Controller (S1)
│            ├── RL Signal Emitter SDK
│            ├── DGDSA patch 客户端 + 状态机 + Capacity Planner
│            └── 基础 Scale Up/Down 测试 + KEDA scale-to-zero

Phase 2 (4 weeks): Elastic Role Switch (P1, S2)
├── Week 5-6: DualModeWorker Python 层原型 (S2)
│             ├── 在 BaseWorkerHandler 新增 set_disaggregation_mode() 方法
│             ├── /switch_role HTTP endpoint (sleep → reconfig → wake_up 编排)
│             └── 复用现有 sleep()/wake_up() (handlers.py L364/L406/L438)
├── Week 7-8: Rust 子系统改造 + Router 通知
│             ├── lib/llm/src/block_manager: reconfig_nixl + reconfig_kv_pool API
│             ├── lib/kv-router/src/protocols.rs: 新增 WorkerRoleChanged 事件
│             ├── Role Switch Controller 子模块 + DualModeClient
│             └── E2E 测试 + 性能优化

Phase 3 (4 weeks): Request Consolidation (P2, S3, 仅当 vLLM 暴露所需 API)
├── Week 9-10: vLLM API 评估 (block_table 导入/导出 + 单请求 pause)
│             ├── 若可用: 实现 NIXL Decode→Decode 触发 + Block Re-mapping
│             └── 若不可用: 退回到 "recompute prefill" 简化方案
├── Week 11-12: Consolidation Controller + 端到端测试

Phase 4 (2 weeks): Integration & Thesis
├── Week 13-14: 全场景集成测试
│             ├── 8× RTX 3090 端到端验证
│             ├── 性能数据收集
│             └── 论文写作素材准备
```

---

## E2. 最小化部署方案

### E2.1 部署拓扑

```
gpu14 节点 (8× RTX 3090, 24 GiB each)

┌───────────────────────────────────────────────────────┐
│  最小部署配置                                           │
│                                                       │
│  GPU 0: Prefill Worker (DualMode)                     │
│  GPU 1: Decode Worker  (DualMode)                     │
│  GPU 2: (空闲, 用于 scale-up 验证)                     │
│  GPU 3-7: (空闲)                                      │
│                                                       │
│  CPU: Frontend Pod (含 Router)                         │
│  CPU: RL Scaling Controller Pod                        │
│  CPU: Prometheus + Grafana                             │
│                                                       │
│  模型: Qwen3-0.6B                                     │
└───────────────────────────────────────────────────────┘
```

### E2.2 部署步骤

#### Step 1: 基础设施

```bash
# K8s + GPU Operator (已有)
# Prometheus + Grafana
./tutorial/dynamo-auto-deploy/k8s/deploy-Prometheus-Grafana.sh
```

#### Step 2: Dynamo v1.0.1 Platform

```bash
helm repo add nvidia-dynamo https://helm.ngc.nvidia.com/nvidia/dynamo
helm repo update

helm install dynamo-platform nvidia-dynamo/dynamo \
  --namespace $NAMESPACE \
  --version 1.0.1 \
  --set operator.enabled=true \
  --set dgdsa.enabled=true
```

#### Step 3: DGD (DynamoGraphDeployment)

```yaml
apiVersion: dynamo.nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: rl-serving
  namespace: ${NAMESPACE}
spec:
  model:
    name: Qwen/Qwen3-0.6B
  services:
    frontend:
      replicas: 1
      resources:
        requests: { cpu: "2", memory: "4Gi" }
      config:
        routerMode: kv
    prefill:
      replicas: 1
      resources:
        limits: { nvidia.com/gpu: "1" }
      config:
        disaggregationMode: prefill
        dualModeEnabled: true          # S2
    decode:
      replicas: 1
      resources:
        limits: { nvidia.com/gpu: "1" }
      config:
        disaggregationMode: decode
        dualModeEnabled: true          # S2
```

#### Step 4: RL Scaling Controller

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rl-scaling-controller
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: controller
        image: ${REGISTRY}/rl-scaling-controller:latest
        env:
        - name: DYNAMO_NAMESPACE
          value: ${NAMESPACE}
        - name: PROMETHEUS_URL
          value: http://prometheus-kube-prometheus-prometheus.monitoring:9090
        - name: PRE_WARM_THRESHOLD
          value: "0.8"
        - name: COOLDOWN_SECONDS
          value: "30"
        - name: PREFILL_QUEUE_THRESHOLD
          value: "10"
        - name: DECODE_IDLE_THRESHOLD
          value: "0.2"
        - name: MIN_SWITCH_INTERVAL
          value: "30"
      serviceAccountName: rl-scaling-controller
```

#### Step 5: KEDA (可选)

```bash
helm install keda kedacore/keda --namespace keda --create-namespace
kubectl apply -f keda-scaled-object.yaml
```

### E2.3 部署验证清单

| 验证项 | 命令 | 预期 |
|-------|------|------|
| DGD 部署成功 | `kubectl get dgd -n $NS` | Ready |
| Frontend 可访问 | `curl http://frontend:8000/v1/models` | 模型列表 |
| Worker 运行 | `kubectl get pods -l role=prefill` | Running |
| Router KV 模式 | 检查 Frontend 日志 | `router_mode=kv` |
| DGDSA 可用 | `kubectl get dgdsa` | Ready |
| Prometheus 采集 | 查询 `dynamo_frontend_queued_requests` | 有数据 |
| RL Controller 运行 | `kubectl get pods -l app=rl-scaling-controller` | Running |

---

## E3. 部署拓扑与系统集成

### E3.1 完整 Service/Pod 清单

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  gpu14 节点 (单节点 K8s, 8× RTX 3090 24GiB, 256GB RAM, NVMe SSD)            │
│                                                                              │
│  ┌─ Dynamo 基础设施 (Helm 部署, nvidia-dynamo namespace) ───────────────────┐ │
│  │                                                                          │ │
│  │  Pod: dynamo-operator          (CPU-only, Deployment, 1 replica)         │ │
│  │    └─ Container: operator      — Dynamo K8s Operator                     │ │
│  │       功能: reconcile DGD/DGDSA CRDs, 管理 Worker Pod 生命周期            │ │
│  │       Service: dynamo-operator-webhook (ClusterIP, :9443)                │ │
│  │                                                                          │ │
│  │  Pod: dynamo-store             (CPU-only, StatefulSet, 1 replica)        │ │
│  │    └─ Container: nats          — NATS JetStream (Event Plane)            │ │
│  │       功能: ZMQ Event Plane 的 backing store (KV events, discovery)       │ │
│  │       Service: dynamo-store (ClusterIP, :4222, :8222)                    │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌─ Dynamo Serving (DGD 管理, dynamo namespace) ───────────────────────────┐ │
│  │                                                                          │ │
│  │  Pod: rl-serving-frontend-xxx  (CPU-only, Deployment, 1 replica)         │ │
│  │    └─ Container: frontend      — Frontend + Router (Rust binary)         │ │
│  │       功能: HTTP API 接入点, KV-aware Router, Batch API                   │ │
│  │       组件: KVRouter + KVScheduler + KVIndexer + WorkerMonitor            │ │
│  │       Service: rl-serving-frontend (ClusterIP, :8000)                     │ │
│  │       Endpoints: /v1/chat/completions, /v1/completions,                  │ │
│  │                  /v1/batch/completions (S1 新增), /v1/models              │ │
│  │                                                                          │ │
│  │  Pod: rl-serving-prefill-0     (GPU, DGDSA 管理, 初始 1 replica)         │ │
│  │    └─ Container: worker        — Prefill Worker (Python + Rust)          │ │
│  │       功能: Prefill 推理, KV Cache 生成, NIXL KV 发送 (sender)            │ │
│  │       GPU: 1× RTX 3090 (GPU 0)                                          │ │
│  │       模型: Qwen3-0.6B (从 NVMe PVC 加载, ~1.2 GB VRAM)                  │ │
│  │       Service: rl-serving-prefill (Headless, :8001)                      │ │
│  │       HTTP: /sleep, /wake_up, /switch_role (S2 新增), /metrics           │ │
│  │       如启用 S2: DualModeWorker (可在运行时切换为 Decode)                  │ │
│  │                                                                          │ │
│  │  Pod: rl-serving-decode-0      (GPU, DGDSA 管理, 初始 1 replica)         │ │
│  │    └─ Container: worker        — Decode Worker (Python + Rust)           │ │
│  │       功能: Decode 推理 (autoregressive), KV Cache 接收 (receiver)        │ │
│  │       GPU: 1× RTX 3090 (GPU 1)                                          │ │
│  │       模型: Qwen3-0.6B (同上)                                             │ │
│  │       Service: rl-serving-decode (Headless, :8001)                       │ │
│  │       HTTP: /sleep, /wake_up, /switch_role (S2 新增), /metrics           │ │
│  │       如启用 S2: DualModeWorker (可在运行时切换为 Prefill)                 │ │
│  │                                                                          │ │
│  │  [Scale Up 时动态创建 — DGDSA 管理]                                       │ │
│  │  Pod: rl-serving-prefill-1..N  (GPU 2..N, 按需创建/销毁)                 │ │
│  │  Pod: rl-serving-decode-1..N   (GPU 2..N, 按需创建/销毁)                 │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌─ RL Scaling 系统 (我们的代码, rl-scaling namespace) ────────────────────┐ │
│  │                                                                          │ │
│  │  Pod: rl-scaling-controller-xxx (CPU-only, Deployment, 1 replica)        │ │
│  │    └─ Container: controller    — RL Scaling Controller (Python)           │ │
│  │       功能: 接收 RL 信号, 状态机决策, 驱动 DGDSA 扩缩容                    │ │
│  │       子模块:                                                             │ │
│  │         ▸ Signal Receiver (FastAPI :8080) — 接收 rl-signal-sdk 事件       │ │
│  │         ▸ State Machine — IDLE/WARM_UP/ACTIVE/COOL_DOWN                  │ │
│  │         ▸ Capacity Planner — 计算目标 P/D replicas                        │ │
│  │         ▸ Metrics Collector — 查询 Prometheus                             │ │
│  │         ▸ Role Switch Controller (S2) — 弹性角色切换决策                   │ │
│  │         ▸ Consolidation Controller (S3) — 请求合并决策                     │ │
│  │       Service: rl-scaling-controller (ClusterIP, :8080)                   │ │
│  │       RBAC: ServiceAccount + ClusterRole (DGDSA patch 权限)              │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌─ 可观测性 (monitoring namespace) ──────────────────────────────────────┐  │
│  │                                                                          │ │
│  │  Pod: prometheus-xxx            (CPU, StatefulSet)                        │ │
│  │    功能: 采集 Dynamo + RL Controller metrics                              │ │
│  │    Service: prometheus (ClusterIP, :9090)                                 │ │
│  │                                                                          │ │
│  │  Pod: grafana-xxx               (CPU, Deployment)                        │ │
│  │    功能: 可视化监控面板                                                    │ │
│  │    Service: grafana (NodePort, :3000 → 30030)                            │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌─ 外部访问 (ingress-nginx namespace) ──────────────────────────────────┐   │
│  │                                                                          │ │
│  │  Pod: ingress-nginx-controller  (CPU, DaemonSet/Deployment)              │ │
│  │    功能: L7 反向代理, TLS 终结, 外部流量入口                               │ │
│  │    Service: ingress-nginx (NodePort, :80→30080, :443→30443)              │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌─ RL Training Framework (用户的训练代码, 可能在集群内或集群外) ───────────┐  │
│  │                                                                          │ │
│  │  进程: RL Training Loop (Python)                                         │ │
│  │    依赖: rl-signal-sdk (pip install)                                     │ │
│  │    功能: Sampling → Batch Inference → Training 循环                       │ │
│  │    交互: HTTP POST → rl-scaling-controller:8080                          │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### E3.2 RL Framework 集成方式

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  RL Training Framework 与系统集成                                             │
│                                                                              │
│  RL 框架 (用户代码)                                                           │
│  ┌────────────────────────────────────────────┐                              │
│  │ import rl_signal                            │  ← pip install rl-signal-sdk│
│  │                                             │                             │
│  │ emitter = rl_signal.Emitter(                │                             │
│  │   controller_url="http://rl-scaling-        │                             │
│  │     controller.rl-scaling:8080"             │                             │
│  │ )                                           │                             │
│  │                                             │                             │
│  │ # ═══ Sampling Phase ═══                    │                             │
│  │ emitter.sampling_start(batch_id, meta)  ────┼──→ Controller: IDLE→IDLE    │
│  │ for step in sampling_loop:                  │     (记录, 不动作)           │
│  │   ...                                       │                             │
│  │   if progress >= 0.8:                       │                             │
│  │     emitter.sampling_progress(0.8, meta) ───┼──→ Controller: IDLE→WARM_UP │
│  │                                             │     → patch DGDSA replicas  │
│  │                                             │       (pre-warming scale up)│
│  │ emitter.sampling_done(batch_meta)  ─────────┼──→ Controller: WARM_UP→     │
│  │                                             │     ACTIVE                  │
│  │                                             │     → 确认所有 Worker Ready  │
│  │                                             │                             │
│  │ # ═══ Inference Phase ═══                   │                             │
│  │ response = requests.post(                   │                             │
│  │   "http://rl-serving-frontend:8000"         │                             │
│  │   "/v1/batch/completions",                  │     (直接调用 Dynamo API,    │
│  │   json={"requests": batch}                  │      不经过 Controller)      │
│  │ )                                           │                             │
│  │                                             │                             │
│  │ # ═══ Training Phase ═══                    │                             │
│  │ emitter.batch_complete()  ──────────────────┼──→ Controller: ACTIVE→      │
│  │                                             │     COOL_DOWN               │
│  │ # 训练代码...                                │     → patch DGDSA replicas=0│
│  │ emitter.training_done()  ───────────────────┼──→ Controller: COOL_DOWN→   │
│  │                                             │     IDLE (scale down 完成)   │
│  └────────────────────────────────────────────┘                              │
│                                                                              │
│  关键设计: RL 框架只需 import 一个 SDK, 在关键时间点发送事件。                    │
│  推理请求直接发给 Dynamo Frontend, 不经过 Controller (最短路径)。               │
│  Controller 只负责"何时 scale"的决策, 不处理实际推理流量。                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

### E3.3 典型推理请求路径

```
一个完整的 Batch 推理请求路径 (PD 分离模式):

Client (RL Framework)
  │
  │ HTTP POST /v1/batch/completions
  │ Body: {"requests": [{"prompt": "...", "max_tokens": 200}, ...]}
  ▼
┌────────────────────────────────────────────────────────┐
│  ingress-nginx (如果从集群外部访问)                      │
│  ← 可选, 集群内直接访问 Frontend Service                 │
│  路由规则: /v1/* → rl-serving-frontend:8000              │
└────┬───────────────────────────────────────────────────┘
     │
     ▼
┌────────────────────────────────────────────────────────┐
│  Frontend Pod (rl-serving-frontend)                     │
│                                                        │
│  1. HTTP Handler: 解析请求, 拆分 Batch 为单个 request   │
│  2. KVRouter.route(request):                           │
│     a. 查 KVIndexer (Radix Tree): 有无 prefix overlap  │
│     b. 查 WorkerMonitor: 各 Prefill Worker 负载         │
│     c. KVScheduler.schedule(): 选择最优 Prefill Worker  │
│        ┌─────────────────────────────────────────┐     │
│        │ 调度策略 (v1.0.1 默认 KV-Aware):          │     │
│        │ • Overlap Score: 有 KV Cache 复用的优先    │     │
│        │ • Load Balance: 均匀分配到各 Prefill       │     │
│        │ • Cost Model + Softmax 选择              │     │
│        └─────────────────────────────────────────┘     │
│  3. 将请求发送到选定的 Prefill Worker                   │
└────┬───────────────────────────────────────────────────┘
     │
     │ gRPC/internal: forward request
     ▼
┌────────────────────────────────────────────────────────┐
│  Prefill Worker Pod (rl-serving-prefill-X)              │
│                                                        │
│  1. vLLM Engine: 执行 prefill (一次性计算所有 attention) │
│     → 输入 tokens → 输出 KV Cache + first token         │
│  2. NIXL Agent (sender): 将 KV Cache blocks 通过        │
│     PCIe Gen4 传输到目标 Decode Worker                   │
│     ┌─────────────────────────────────────────┐        │
│     │ NIXL 传输: KV Cache blocks (GPU VRAM)    │        │
│     │ 带宽: PCIe Gen4 x16 ~25 GB/s            │        │
│     │ Qwen3-0.6B ISL=500: ~57 MB, 传输 ~2ms   │        │
│     └─────────────────────────────────────────┘        │
│  3. KVPublisher: 发送 BlockStored events (ZMQ)          │
│     → Router KVIndexer 更新 radix tree                  │
│  4. 返回 first token 到 Frontend                        │
└────┬───────────────────────────────────────────────────┘
     │
     │ NIXL GPU-to-GPU: KV Cache transfer
     ▼
┌────────────────────────────────────────────────────────┐
│  Decode Worker Pod (rl-serving-decode-X)                │
│                                                        │
│  1. NIXL Agent (receiver): 接收 KV Cache blocks         │
│  2. vLLM Engine: 执行 autoregressive decode             │
│     → 逐 token 生成, 每步读取 KV Cache + 计算 attention  │
│  3. Streaming: 逐 token 返回                            │
│     → 通过 Frontend 转发给 Client                       │
│  4. 请求完成: 释放 KV blocks, 发送 BlockRemoved events   │
└────┬───────────────────────────────────────────────────┘
     │
     │ Streaming tokens
     ▼
Frontend → Client (RL Framework)
  完整响应: {"choices": [{"text": "generated text..."}]}
```

### E3.4 各场景的 Scaling 路径

#### S1: Rollout Scale Up/Down

```
触发: RL Signal SDK 事件
路径: rl-signal-sdk → RL Scaling Controller → K8s API → DGDSA → Dynamo Operator → Worker Pods

RL Framework          RL Scaling Controller       K8s API Server       Dynamo Operator
    │                       │                         │                     │
    │ sampling_progress     │                         │                     │
    │ (0.8) ───────────────▶│ State: IDLE→WARM_UP     │                     │
    │                       │                         │                     │
    │                       │ PATCH DGDSA             │                     │
    │                       │ replicas: {             │                     │
    │                       │   prefill: 2,           │                     │
    │                       │   decode: 4             │                     │
    │                       │ } ─────────────────────▶│ DGDSA updated       │
    │                       │                         │─────────────────────▶│
    │                       │                         │                     │ Reconcile:
    │                       │                         │                     │ 创建新 Worker Pods
    │                       │                         │                     │ (GPU 分配, 模型加载,
    │                       │                         │                     │  Discovery 注册)
    │                       │                         │                     │
    │ sampling_done ────────▶│ State: WARM_UP→ACTIVE   │                     │
    │                       │ (确认 Workers Ready)     │                     │
    │                       │                         │                     │
    │ POST /v1/batch/ ──────────────────────────────────────────────────────▶ Workers 处理推理
    │                       │                         │                     │
    │ batch_complete ───────▶│ State: ACTIVE→COOL_DOWN │                     │
    │                       │ PATCH DGDSA             │                     │
    │                       │ replicas: {             │                     │
    │                       │   prefill: 0,           │                     │
    │                       │   decode: 0             │                     │
    │                       │ } ─────────────────────▶│ DGDSA updated       │
    │                       │                         │─────────────────────▶│
    │                       │                         │                     │ Reconcile:
    │                       │                         │                     │ 删除 Worker Pods
    │                       │                         │                     │ (释放 GPU)
```

#### S2: Elastic Role Switch

```
触发: RL Scaling Controller 检测到 P/D 负载不均衡
路径: Controller → Worker HTTP API (/switch_role) → Worker 内部 sleep→reconfig→wake_up

RL Scaling Controller           Worker Pod (DualMode)          Router (Frontend)
    │                               │                              │
    │ (metrics: prefill_queue       │                              │
    │  high, decode idle)           │                              │
    │                               │                              │
    │ POST /switch_role             │                              │
    │ {"target_role":               │                              │
    │  "prefill"} ─────────────────▶│                              │
    │                               │ 1. sleep():                  │
    │                               │    unregister ──────────────▶│ Worker 从 decode
    │                               │    pause_generation          │ 路由池移除
    │                               │    engine.sleep()            │
    │                               │                              │
    │                               │ 2. reconfig:                 │
    │                               │    DisaggMode → PREFILL      │
    │                               │    NIXL: recv → send         │
    │                               │    KV Pool: decode → prefill │
    │                               │                              │
    │                               │ 3. wake_up():                │
    │                               │    engine.wake_up()          │
    │                               │    register ────────────────▶│ Worker 加入 prefill
    │                               │                              │ 路由池
    │                               │                              │
    │                               │ 4. emit RoleChanged ────────▶│ 清零负载计数
    │                               │                              │
    │ ◀──── {"status": "ok",        │                              │
    │        "switch_time_ms": 2000}│                              │

涉及组件: RL Scaling Controller + Worker Pod (Dynamo fork 内部)
不创建/销毁 Pod, 不涉及 DGDSA, 纯 Worker 内部状态切换
```

#### S3: Request Consolidation

```
触发: RL Scaling Controller 检测到 Decode Workers 请求不均衡 (尾部稀疏)
路径: Controller → Source Worker /migrate_out → NIXL KV transfer → Target Worker /migrate_in

RL Scaling Controller    Source Decode Worker      Target Decode Worker    K8s API
    │                        │                          │                    │
    │ (metrics: worker_A     │                          │                    │
    │  has 2 req, worker_B   │                          │                    │
    │  has 12 req, worth     │                          │                    │
    │  consolidating)        │                          │                    │
    │                        │                          │                    │
    │ POST /migrate_out      │                          │                    │
    │ {requests: [r1, r2],   │                          │                    │
    │  target: worker_B} ───▶│                          │                    │
    │                        │ 1. pause decode(r1,r2)   │                    │
    │                        │ 2. export_kv(r1,r2)      │                    │
    │                        │ 3. NIXL send KV ────────▶│ import_kv(r1,r2)   │
    │                        │    (GPU-to-GPU transfer)  │ resume_decode()   │
    │                        │ 4. cleanup local KV      │                    │
    │                        │                          │                    │
    │ (Source worker now     │                          │                    │
    │  has 0 requests)       │                          │                    │
    │                        │                          │                    │
    │ PATCH DGDSA            │                          │                    │
    │ replicas -= 1 ─────────┼──────────────────────────┼───────────────────▶│
    │                        │  (Operator 删除空 Worker) │                    │

涉及组件: RL Scaling Controller + Worker Pods (Dynamo fork) + DGDSA
最终可释放空闲 GPU
```

### E3.5 服务发现与网络拓扑

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  服务发现机制                                                                 │
│                                                                              │
│  Dynamo 内部 (Worker ↔ Router):                                              │
│  ─────────────────────────────                                               │
│  机制: K8s EndpointSlice + Dynamo Discovery Service                          │
│  流程:                                                                       │
│    1. Worker Pod 启动 → register_endpoint_instance()                         │
│       → 向 K8s EndpointSlice 注册 (worker IP + port + 角色标签)               │
│    2. Frontend/Router → WorkerMonitor 持续 watch EndpointSlice               │
│       → 实时感知 Worker 加入/离开/角色变更                                     │
│    3. 补充: KVPublisher ZMQ events → Router KVIndexer                        │
│       → 实时感知每个 Worker 上的 KV Cache 分布                                │
│                                                                              │
│  RL Scaling Controller → Dynamo:                                             │
│  ─────────────────────────────                                               │
│  机制: K8s Service DNS                                                       │
│  流程:                                                                       │
│    1. Controller 通过 DNS 找到 Frontend                                      │
│       → rl-serving-frontend.dynamo.svc.cluster.local:8000                    │
│    2. Controller 通过 DNS 找到 Worker (Headless Service)                     │
│       → rl-serving-prefill-0.rl-serving-prefill.dynamo.svc:8001              │
│       → rl-serving-decode-0.rl-serving-decode.dynamo.svc:8001                │
│    3. Controller 通过 K8s API 查询 DGDSA/Pod 状态                            │
│       → 使用 ServiceAccount + RBAC                                           │
│                                                                              │
│  外部访问 → Dynamo:                                                          │
│  ─────────────────                                                           │
│  机制: ingress-nginx (可选)                                                   │
│  流程:                                                                       │
│    1. Ingress 规则: /v1/* → rl-serving-frontend:8000                         │
│    2. 外部 Client → NodePort :30080 → ingress-nginx → Frontend               │
│    3. 如果 Client 在集群内 (如 RL Training Pod):                              │
│       直接访问 rl-serving-frontend.dynamo:8000 (跳过 ingress)                 │
│                                                                              │
│  RL Framework → RL Scaling Controller:                                       │
│  ─────────────────────────────────                                           │
│  机制: K8s Service DNS                                                       │
│  流程:                                                                       │
│    1. rl-signal-sdk 通过 DNS 找到 Controller                                 │
│       → rl-scaling-controller.rl-scaling.svc.cluster.local:8080              │
│    2. HTTP POST 发送生命周期事件                                              │
│    3. 如果 RL Framework 在集群外部:                                           │
│       通过 NodePort 或 Ingress 访问 Controller                               │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### E3.6 GPU 分配策略

```
gpu14 节点 GPU 分配 (8× RTX 3090):

┌──────────────────────────────────────────────────────────────────────────────┐
│  场景: 最小部署 (P0 验证)                                                     │
│  GPU 0: Prefill Worker #0  (DualMode)                                        │
│  GPU 1: Decode Worker #0   (DualMode)                                        │
│  GPU 2-7: 空闲 (可用于 scale-up 测试)                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│  场景: Batch Inference 高峰 (S1 Scale Up 后)                                 │
│  GPU 0-1: Prefill Workers #0-1  (处理并发 Batch prefill)                     │
│  GPU 2-5: Decode Workers #0-3   (4 GPU decode, Qwen3-0.6B 128 requests)     │
│  GPU 6-7: 空闲 (预留)                                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│  场景: S2 Elastic Role Switch (Prefill 满载 → 全部切 Prefill)                │
│  GPU 0-5: ALL Prefill Workers (DualMode, 从 P2D4 → P6D0)                    │
│  GPU 6-7: 空闲                                                               │
│  → Prefill 完成后: ALL Decode Workers (P0D6)                                 │
├──────────────────────────────────────────────────────────────────────────────┤
│  场景: S3 Request Consolidation (Batch 尾部, 请求稀疏)                       │
│  GPU 0: Decode Worker #0 (合并了所有剩余请求)                                 │
│  GPU 1-5: 已释放 (consolidated → scale down)                                 │
│  GPU 6-7: 空闲                                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│  场景: IDLE (RL Training Phase)                                              │
│  GPU 0-7: 全部空闲 (scale-to-zero) 或由 RL Training 使用                     │
└──────────────────────────────────────────────────────────────────────────────┘

GPU 资源管理:
  → DGDSA 控制 Worker Pod 的 replicas → Dynamo Operator reconcile → 创建/删除 Pod
  → 每个 Worker Pod 请求 1 个 nvidia.com/gpu → nvidia-device-plugin 分配物理 GPU
  → Scale down: Operator 删除 Pod → GPU 自动释放回 K8s 资源池
  → 无需手动管理 GPU 分配, 全部由 K8s 调度器 + nvidia-device-plugin 处理
```

### E3.7 网络架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  网络拓扑 (单节点 K8s, 所有通信走 localhost 或 Pod CIDR)                      │
│                                                                             │
│  外部                                                                       │
│  ┌─────┐   NodePort :30080                                                  │
│  │ 用户 │──────────────────▶ ingress-nginx ─── /v1/* ──▶ Frontend :8000     │
│  └─────┘                    (L7 反向代理)                                    │
│                                                                             │
│  集群内                                                                      │
│  ┌──────────────────┐  HTTP :8080   ┌────────────────────────┐              │
│  │ RL Training      │──────────────▶│ RL Scaling Controller  │              │
│  │ Framework        │               │ (Signal Receiver)      │              │
│  │ (import          │               └──────┬─────────────────┘              │
│  │  rl_signal)      │                      │                                │
│  │                  │                      │ K8s API (PATCH DGDSA)           │
│  │                  │                      │ HTTP (Worker /switch_role)       │
│  │                  │                      │ PromQL (Prometheus :9090)        │
│  │                  │                      ▼                                │
│  │                  │  HTTP :8000   ┌────────────────────────┐              │
│  │                  │──────────────▶│ Frontend Pod           │              │
│  └──────────────────┘               │ (KVRouter + HTTP API)  │              │
│                                     └──────┬─────────────────┘              │
│                                            │                                │
│                          ┌─────────────────┼─────────────────┐              │
│                          │                 │                 │              │
│                          ▼                 ▼                 ▼              │
│                   ┌──────────┐      ┌──────────┐      ┌──────────┐         │
│                   │ Prefill  │      │ Decode   │      │ Decode   │         │
│                   │ Worker   │ NIXL │ Worker   │      │ Worker   │         │
│                   │ (GPU 0)  │─────▶│ (GPU 1)  │      │ (GPU 2)  │         │
│                   │ :8001    │ KV   │ :8001    │      │ :8001    │         │
│                   └──────────┘ Xfer └──────────┘      └──────────┘         │
│                                                                             │
│  通信协议:                                                                   │
│  • Client ↔ Frontend:  HTTP/1.1 (REST API, SSE for streaming)               │
│  • Frontend ↔ Worker:  gRPC / Dynamo internal protocol (Rust)               │
│  • Worker ↔ Worker:    NIXL (PCIe Gen4 GPU-to-GPU, ~25 GB/s)               │
│  • Worker → Router:    ZMQ (KV events: BlockStored/BlockRemoved)            │
│  • Controller ↔ K8s:   K8s API (HTTPS, ServiceAccount token auth)           │
│  • Controller ↔ Prom:  PromQL over HTTP (Prometheus Query API)              │
│  • RL SDK → Controller: HTTP/1.1 (JSON events)                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## E4. 验证与测试策略

### E3.1 测试金字塔

```
┌─────────────────────────────────────────────────────────┐
│  Layer 4: End-to-End RL Simulation                      │
│  ├── 完整 RL loop (sampling → infer → train)             │
│  ├── 8 GPU 全量测试                                      │
│  └── 对比基线性能数据                                     │
├─────────────────────────────────────────────────────────┤
│  Layer 3: Integration Tests                             │
│  ├── Role Switch 端到端（含 Router 状态验证）              │
│  ├── Scale Up/Down 端到端（含 KV Cache 持久化）           │
│  └── Request Consolidation 端到端                         │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Component Tests                               │
│  ├── RL Scaling Controller 状态机测试                     │
│  ├── Role Switch Controller 决策逻辑测试                  │
│  └── Consolidation Decision Engine 测试                  │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Smoke Tests                                   │
│  ├── 部署健康检查                                        │
│  ├── API 可达性                                          │
│  └── 基本请求/响应                                       │
└─────────────────────────────────────────────────────────┘
```

### E3.2 基线 (Baseline) 性能采集

在实现优化前，先采集基线数据：

```bash
# 1. 部署标准 P1D1（不开启任何优化）
kubectl apply -f dgd-baseline.yaml

# 2. 采集 Batch 完成时间（FIFO）
python benchmark.py \
  --mode fifo \
  --batch-sizes 32,64,128,256 \
  --isl-range 100-2000 \
  --osl-range 50-500 \
  --repeats 5 \
  --output baseline_fifo.json

# 3. 采集 GPU 利用率（always-on）
python benchmark.py \
  --mode rl-simulation \
  --sampling-time 300 \
  --inference-time 60 \
  --cycles 5 \
  --output baseline_gpu.json

# 4. 基线指标:
#    batch_makespan_p50/p95/p99
#    gpu_utilization_during_idle
#    gpu_hours_per_cycle
#    ttft_p50, itl_p50
```

### E3.3 测试自动化框架

```python
import pytest, httpx, time
from kubernetes import client, config

class DynamoTestBase:
    """测试基类 — 与 Dynamo 的 K8s native 风格一致"""

    @classmethod
    def setup_class(cls):
        config.load_kube_config()
        cls.k8s = client.CoreV1Api()
        cls.custom = client.CustomObjectsApi()
        cls.frontend_url = "http://frontend:8000"
        cls.controller_url = "http://rl-scaling-controller:8080"

    def send_batch(self, requests, timeout=300):
        resp = httpx.post(
            f"{self.frontend_url}/v1/batch/completions",
            json={"requests": requests}, timeout=timeout
        )
        return resp.json()

    def get_worker_pods(self, role=None):
        label = f"dynamo.nvidia.com/role={role}" if role else ""
        return self.k8s.list_namespaced_pod(
            namespace=NAMESPACE, label_selector=label
        ).items

    def wait_for_condition(self, check_fn, timeout=120, interval=5):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if check_fn():
                return True
            time.sleep(interval)
        raise TimeoutError(f"Condition not met within {timeout}s")


class TestRoleSwitch(DynamoTestBase):
    """S2 测试示例"""

    def test_decode_to_prefill_switch(self):
        """S2-T1"""
        decode_pods = self.get_worker_pods(role="decode")
        assert len(decode_pods) > 0
        target = decode_pods[0].metadata.name

        resp = httpx.post(f"{self.controller_url}/api/v1/switch",
                         json={"worker": target, "to_role": "prefill"})
        assert resp.status_code == 200

        self.wait_for_condition(lambda: any(
            p.metadata.labels.get("dynamo.nvidia.com/role") == "prefill"
            for p in self.get_worker_pods() if p.metadata.name == target
        ))

    def test_switch_latency(self):
        """S2-T2"""
        decode_pods = self.get_worker_pods(role="decode")
        target = decode_pods[0].metadata.name

        start = time.time()
        httpx.post(f"{self.controller_url}/api/v1/switch",
                   json={"worker": target, "to_role": "prefill"})
        self.wait_for_condition(lambda: target in [
            p.metadata.name for p in self.get_worker_pods(role="prefill")
        ])
        assert time.time() - start < 5.0

    def test_no_request_loss(self):
        """S2-T3"""
        import threading
        results = []
        def send():
            r = httpx.post(f"{self.frontend_url}/v1/completions", json={
                "model": "Qwen/Qwen3-0.6B",
                "prompt": "Write a long story " + "x" * 500,
                "max_tokens": 200
            }, timeout=120)
            results.append(r.status_code)

        threads = [threading.Thread(target=send) for _ in range(5)]
        for t in threads: t.start()
        time.sleep(2)

        decode_pods = self.get_worker_pods(role="decode")
        httpx.post(f"{self.controller_url}/api/v1/switch",
                   json={"worker": decode_pods[0].metadata.name, "to_role": "prefill"})

        for t in threads: t.join(timeout=120)
        assert all(s == 200 for s in results)

    def test_anti_flapping(self):
        """S2-T8"""
        decode_pods = self.get_worker_pods(role="decode")
        target = decode_pods[0].metadata.name

        r1 = httpx.post(f"{self.controller_url}/api/v1/switch",
                       json={"worker": target, "to_role": "prefill"})
        assert r1.status_code == 200
        time.sleep(5)

        r2 = httpx.post(f"{self.controller_url}/api/v1/switch",
                       json={"worker": target, "to_role": "decode"})
        assert r2.status_code == 429  # Rate limited
```

### E3.4 测试执行优先级

| 优先级 | 测试组 | 依赖 | 预计时间 |
|-------|-------|------|---------|
| P0 | Baseline 性能采集 | v1.0.1 标准部署 | 1 天 |
| P1 | S1-T1~T9 (Scale Up/Down) | RL Scaling Controller | 2 天 |
| P2 | S2-T1~T11 (Role Switch) | DualModeWorker + Controller | 3 天 |
| P3 | S3-T1~T11 (Consolidation, 视 vLLM API 可用性) | NIXL D2D 扩展 + vLLM block_table API | 2 天 |
| P4 | Layer 4 E2E (全量 RL 模拟) | 所有组件 | 2 天 |

---

## E5. 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| vLLM 内部 API 变更 | 中 | 高 | 锁定 v1.0.1 内置版本；封装 adapter 层 |
| NIXL KV 迁移性能不达标 | 低 | 高 | NVLink 同机 ~600GB/s；预测单请求 KV 量 < decode 剩余时间 |
| Elastic Switch 切换延迟过长 | 中 | 中 | sleep/wake_up 复用后预估 ~2s；Aggregated Fallback 兜底 |
| RTX 3090 不支持 cuda-checkpoint | 中 | 低 | Dynamo v1.0.1 内建完整 Snapshot 系统 (CRIU + cuda-checkpoint + K8s CRD)，但 Ampere 消费级 GPU 不支持 cuda-checkpoint API (详见 S1.2 Snapshot 决策)。不影响本项目：S1 使用冷启动方案，S2 使用 sleep/wake_up 方案 |
| v1.1 Pluggable Scheduling 接口变更 | 低 | 低 | 设计时参考 #7260 PR，保持兼容 |

---

# 附录

## 附录 A：关键术语表

| 术语 | 全称 | 含义 |
|------|------|------|
| PD 分离 | Prefill-Decode Disaggregation | 将推理的 prefill 和 decode 阶段分到不同 GPU |
| KV Cache | Key-Value Cache | Transformer attention 中缓存的 K/V 张量 |
| NIXL | NVIDIA Inference Xfer Library | GPU-to-GPU 高性能数据传输库 |
| KVBM | KV Block Manager | KV Cache 块级管理器，支持多层存储 |
| KVIndexer | KV Cache Indexer | 全局 KV Cache Prefix Tree 索引 |
| DGDSA | DynamoGraphDeploymentScalingAdapter | K8s Scaling 适配器 |
| KEDA | Kubernetes Event Driven Autoscaling | 事件驱动的 K8s 自动缩放器 |
| ISL | Input Sequence Length | 输入序列长度 |
| OSL | Output Sequence Length | 输出序列长度 |
| TTFT | Time To First Token | 首 token 延迟 |
| ITL | Inter-Token Latency | token 间延迟 |
| LPT | Longest Processing Time First | 经典调度算法 |
| xPyD | x Prefill y Decode | P/D 比例配置 |
| FPM | ForwardPassMetrics | 前向传播性能指标 |
| DGD | DynamoGraphDeployment | Dynamo 的 K8s 部署对象 |
| ZMQ | ZeroMQ | Dynamo v1.0+ 默认 Event Plane 传输协议 |

## 附录 B：参考链接

| 资源 | 路径/URL | 内容 |
|------|---------|------|
| Dynamo Router Design | `docs/design-docs/router-design.md` | KV Router 架构、成本模型、事件系统 |
| Dynamo Planner Design | `docs/design-docs/planner-design.md` | Throughput/Load-based scaling |
| Dynamo Architecture | `docs/design-docs/architecture.md` | 三平面架构、xPyD、KVBM、NIXL |
| Dynamo Autoscaling | `docs/kubernetes/autoscaling.md` | DGDSA、HPA、KEDA、Planner 集成 |
| Dynamo Disagg-Serving | `docs/design-docs/disagg-serving.md` | PD 分离流程、NIXL KV 传输 |
| Dynamo Request Migration | `docs/fault-tolerance/request-migration.md` | Token state tracking、迁移流程 |
| Dynamo v1.0.1 Release | `github.com/ai-dynamo/dynamo/releases/tag/v1.0.1` | 最新稳定版 |
| Dynamo v1.1.0-dev.1 | `github.com/ai-dynamo/dynamo/releases/tag/v1.1.0-dev.1` | Pluggable Scheduling |
| NIXL Library | `github.com/ai-dynamo/nixl` | GPU-to-GPU 传输库 |
| LPT Scheduling | Graham (1969) | "Bounds on Multiprocessing Timing Anomalies" |

---

# Phase 2 — 端到端最优实现 (mandatory)

> **本节是对 Phase 1 (S2 stub + S3 recompute-prefill) 的重定向。**
> Phase 1 把 NIXL 重配 / KV 池重配 / 请求级 KV 迁移都归为 *future work*，
> 用 Python orchestration 把"控制面正确"先跑通了。Phase 2 的目标是
> **端到端正确性 + 最小化 RL batch 处理时间**，因此 Phase 1 中所有
> "stub / recompute fallback" 都 **必须** 替换为真实实现。

## P2.0 为什么 Phase 1 选了 stub / recompute？(诚实回顾)

| Phase 1 选择 | 当时给出的理由 | 实际结果 |
|---|---|---|
| `_reconfig_nixl` = no-op | "Rust 侧 NIXL agent 没有 reconfig API" | 角色翻转后路由不变；vLLM 路径上无差异，所以"切了等于没切" |
| `_reconfig_kv_pool` = no-op | "vLLM 1.0.1 没有运行时 KV 池缩放接口" | 翻转后 Decode 端只能用 Prefill 大小的 KV 池（或反之），吞吐打折 |
| S3 用 recompute-prefill | "无需新增 transport 代码" | 每次迁移多花 1 次 prefill。对长 OSL 请求来说这一次 prefill 可能等于剩余 decode 时间的 50–80%，把"迁移加速 batch"的收益吃掉一半以上 |

**结论**：Phase 1 是合理的"先把控制面跑通"工程取舍，但 **不满足 RL Scaling
的最终目标**（最小 batch 处理时间）。下面给出 Phase 2 的真实实现方案，每一项
都对照已有 Rust/Python 代码点出落地路径。

## P2.1 重新表述目标

> 在 RL training 的 rollout 阶段，给定 N 张 GPU，**端到端 batch 完成时间最小化**。
> 这要求：
> 1. P/D 比例可以在 batch 内随负载自适应（→ **真**角色翻转，不是只翻 metadata）；
> 2. 长尾 decode 请求在剩余生命周期内可以被搬到空闲 GPU 上而不重新 prefill
>    （→ **真** KV-D2D 迁移）；
> 3. 角色翻转 + 迁移本身的开销 ≪ 所节省的 batch tail。

数量化的可观察目标 (Qwen3-0.6B, 单节点 RTX 3090)：

| 指标 | Phase 1 (stub) | Phase 2 目标 |
|---|---|---|
| 角色翻转后单 token decode 吞吐 | ≈ 旧角色（无效切换） | ≥ 90% 同尺寸 worker 原生水平 |
| 单请求迁移时间 (剩余 800 tokens) | ≈ 1 × prefill ≈ 100 ms | ≤ 15 ms (NVLink) / ≤ 60 ms (PCIe) |
| Batch 尾延迟（RL rollout, 1k req） | 基线 | ↓ 20–35% |

## P2.2 S2-v2：真实角色翻转

### P2.2.1 三段缺失能力

```
┌────────────────────────────────────────────────────────────────────┐
│ 缺失 A：NIXL Agent 方向切换                                          │
│   Phase 1: dual_mode.py:_reconfig_nixl 仅 logger.info()              │
│   需要的 Rust API:                                                   │
│     fn nixl_agent.set_direction(Sender|Receiver) -> Result<()>       │
│     fn nixl_agent.rebind_buffers(layout: &PhysicalLayout)            │
│   已有可用基础:                                                      │
│     lib/llm/src/block_manager/v2/physical/transfer/nixl_agent/       │
│     —— transfer_blocks(src,dst,...) 已经在用 NIXL 做 D2D，agent 内    │
│        部已封装 send/recv loop，只是没有暴露方向切换。                │
├────────────────────────────────────────────────────────────────────┤
│ 缺失 B：KV Cache 池运行时缩放                                         │
│   Phase 1: dual_mode.py:_reconfig_kv_pool 仅 logger.info()           │
│   需要的 vLLM patch (worker 进程内, 不需要改 vLLM repo, 只在 wrapper │
│   层调内部方法):                                                     │
│     1. engine.engine_core.scheduler.kv_cache_manager 重建            │
│        (vLLM 0.7+ 已有 reset_prefix_cache + _initialize_kv_caches)   │
│     2. 调整 num_gpu_blocks (cache_config.num_gpu_blocks_override)    │
│     3. NIXL 注册 buffer 重新登记                                      │
│   已有可用基础:                                                      │
│     handler.sleep(level=2) 已经把 KV 显存释放了，重建窗口是安全的。   │
├────────────────────────────────────────────────────────────────────┤
│ 缺失 C：Router 状态切换                                               │
│   Phase 1: _emit_role_changed 仅在 publisher 存在时 publish_role_… │
│   需要的 Rust API:                                                   │
│     KvEvent::WorkerRoleChanged { worker_id, old_role, new_role }     │
│     在 lib/llm/src/kv_router/protocols.rs 增加变体，                  │
│     scheduler.rs handle_event 中清零 active_blocks/in_flight_requests│
│     并把 worker 移出旧角色池 / 加入新角色池。                          │
└────────────────────────────────────────────────────────────────────┘
```

### P2.2.2 落地任务清单 (S2-v2)

| ID | 文件 | 改动 | 工作量 |
|---|---|---|---|
| S2-v2-R1 | `lib/llm/src/block_manager/v2/physical/transfer/nixl_agent/mod.rs` | 暴露 `set_direction(Direction)` + `rebind(layout)`；通过 PyO3 在 `lib/bindings/python/` 暴露 | M |
| S2-v2-R2 | `lib/llm/src/kv_router/protocols.rs` + `scheduler.rs` | 新增 `WorkerRoleChanged` 事件 + handler 分支 | S |
| S2-v2-V1 | `components/src/dynamo/vllm/dual_mode.py:_reconfig_kv_pool` | 调用 `engine.engine_core.reset_prefix_cache()` → 修改 `cache_config.num_gpu_blocks_override` → `_initialize_kv_caches()` | M |
| S2-v2-P1 | `components/src/dynamo/vllm/dual_mode.py:_reconfig_nixl` | 通过新增的 PyO3 binding 调用 `nixl_agent.set_direction(...)` | S |
| S2-v2-P2 | `dual_mode.py:_emit_role_changed` | 不再做 `if publisher is None: return`；改用 `kv_publisher.emit_role_changed(...)`（必须有 publisher） | S |

> 注：vLLM 1.0.1 内部已有 `reset_prefix_cache()` 和
> `KVCacheManager.__init__`，所以"运行时缩放"在 worker wrapper 层完全可达，
> 不需要 fork vLLM。

### P2.2.3 切换时序（Phase 2 真实实现）

```
T+0.0s  POST /switch_role {target:prefill}
T+0.0s  handler.sleep(level=2)                    # 复用 (Phase 1 已有)
T+0.8s  ─── KV 池重建 (新增) ───
        engine.reset_prefix_cache()
        cache_config.num_gpu_blocks_override = NEW_PREFILL_BLOCKS
        engine._initialize_kv_caches()
T+1.2s  ─── NIXL 方向切换 (新增) ───
        nixl_agent.set_direction(Sender)
        nixl_agent.rebind_buffers(new_layout)
T+1.3s  handler.set_disaggregation_mode("prefill")
T+1.3s  handler.wake_up({})                       # 复用
T+1.7s  emit WorkerRoleChanged → router 重定向
T+1.9s  Router 把新 prefill worker 加入 prefill 池
T+1.9s  完成 — 第一笔新角色请求可达
```

## P2.3 S3-v2：真实 KV-D2D 请求迁移

### P2.3.1 设计澄清：为什么不能用 disagg 现成的 P→D KV 通路？

Phase 1 文档里曾说"disagg 已经有 NIXL P→D 传输，理论上可以复用"。
代码层面这个判断对了一半：**transport 层** 的确已经存在
(`lib/llm/src/block_manager/v2/physical/transfer/mod.rs::transfer_blocks(
src, dst, src_block_ids, dst_block_ids, ctx)`，
[transfer/mod.rs](dynamo/lib/llm/src/block_manager/v2/physical/transfer/mod.rs))，
disagg 用的就是它。

**真正缺的是请求层的两个映射 + 一个引擎注入接口**：

| 缺失 | 详情 |
|---|---|
| **缺失 D**：`request_id → vec<block_id>` 映射 | KVBM 内部知道 block 归属哪个 sequence，但没有按 worker 暴露这张表。disagg 不需要它 (P 端 prefill 完直接 send，不按 request 做切片)；migration 需要它，因为我们要按 request 迁。 |
| **缺失 E**：跨 worker 的 `MigrateRequestBlocks` ZMQ 消息 | disagg 是点对点 NIXL，KV router/leader 只协调 transfer。Migration 需要由 controller 发起、worker 之间协商目标 block 槽位、确认 transfer 完成、然后 commit。 |
| **缺失 F**：vLLM "注入已有 KV 的 sequence" | 当前 vLLM 只能从 prompt 开始，由 scheduler 自己分配 block。Migration 需要把"这串 block 已经填好了，请你接着 decode"这一信号注入。vLLM 0.7+ 的 `KVConnector` 接口（被 LMCache / Mooncake 使用）就是干这个的；我们要么用 connector 路径，要么写一个 minimal patch 在 wrapper 里直接灌 block。 |

### P2.3.2 落地任务清单 (S3-v2)

| ID | 文件 | 改动 | 工作量 |
|---|---|---|---|
| S3-v2-R1 | `lib/llm/src/block_manager/distributed/utils.rs` | 新增 ZMQ msg `ZMQ_MIGRATE_REQUEST_BLOCKS_MESSAGE` + `MigrateRequestBlocks { rid, src_worker, dst_worker, src_block_ids, dst_block_ids }` | S |
| S3-v2-R2 | `lib/llm/src/block_manager/distributed/leader.rs` | 新增 `migrate_request(...)`，复用 `transfer_blocks_request` pipeline | M |
| S3-v2-R3 | `lib/llm/src/block_manager/v2/physical/`（新增 module） | 维护 `request_id → Vec<BlockId>` 表（订阅 KVPublisher events），通过 PyO3 暴露 | M |
| S3-v2-V1 | `components/src/dynamo/vllm/migration.py:MigrationHandler.migrate_out` | 调用 `request_block_map.lookup(rid)` 拿到 src_block_ids；分配 dst 上同等数量的 free block；触发 R2 的 ZMQ；等 transfer 完成；abort src request；返回 `dst_block_ids` | M |
| S3-v2-V2 | `migration.py:MigrationHandler.migrate_in` | 不再 `submit_request(prompt+generated)`；改为通过 vLLM `KVConnector` 把 `dst_block_ids` 灌入 scheduler，注册请求为 "decode-ready, position=K"，从下一 token 开始 decode | L |
| S3-v2-V3 | wrapper 内 vLLM glue | 实现一个 `RLScalingKVConnector(KVConnector)`，仅实现 `recv_kv_caches_and_hidden_states` 把已经在显存里的 dst blocks 接到 sequence 上 | M |

### P2.3.3 迁移时序（Phase 2 真实实现）

```
T+0.0s  controller: migrate(rid=r1, src=W2, dst=W4)
T+0.0s  W2.migrate_out({rid:r1})
T+0.0s    src_blocks = block_map[r1]              # 例如 [12,13,14,15]
T+0.0s    POST W4.allocate_blocks(n=4)            # 拿到 dst_blocks=[7,8,9,10]
T+0.0s    leader.migrate_request(r1, W2, W4,
                                 src=[12..15], dst=[7..10])
T+0.0s    NIXL D2D: 4 blocks * 16 KiB ≈ 64 KiB    # NVLink ~0.1 ms, PCIe ~5 ms
T+0.0s    transfer_done notification
T+0.0s    W2.engine.abort_request(r1)
T+0.0s    return {status:ok, dst_blocks:[7..15]}
T+0.001s W4.migrate_in({rid:r1, dst_blocks, last_token, sampling_params})
T+0.001s   connector.attach_blocks(r1, dst_blocks, position=K)
T+0.001s   scheduler.add_request(r1, mode=decode_only)
T+0.002s W4 第一个新 token 已生成
                                ─────────
总耗时 ≈ 2 ms（NVLink）vs Phase 1 recompute-prefill ≈ 100 ms（50× 加速）
```

## P2.4 总改动估算

| 类别 | Phase 1 | Phase 2 增量 |
|---|---|---|
| Python (RL-Scaling repo) | ~2.4k 行 | ~200 行 (controller 不变，只改 migration 调用形态) |
| Python (dynamo/components) | ~600 行 (含 dual_mode + migration + tests) | ~400 行 (KV connector + migrate_in 重写) |
| Rust (dynamo/lib) | 0 行（全部 stub） | ~600 行 (NIXL set_direction + WorkerRoleChanged + MigrateRequestBlocks + request_block_map) |
| vLLM patch | 无 | 无 fork；用现有 `KVConnector` 接口 + wrapper 内调 `reset_prefix_cache` |

## P2.5 风险 & 验证策略（与测试计划联动）

| 风险 | 验证方式（详见 TEST_PLAN.zh-CN.md Phase 2 节） |
|---|---|
| KV 池重建过程中残留显存 | `nvidia-smi` 显存差 < 50 MB；`engine._kv_cache_config.num_gpu_blocks` == 新值 |
| NIXL 方向切换后旧 send loop 未释放 | `nixl_agent.stats()` 中 `active_transfers == 0`；ZMQ 端口未泄漏 |
| Connector 注入的 block 与 sequence position 不一致 | greedy + seed 固定下，迁移后 next-token 与基线 byte-equal |
| `request_block_map` 与 KVPublisher 事件竞态 | 单元测试 + 压测下 1k 并发请求迁移成功率 == 100% |
| 长 OSL 场景下迁移收益是否真的高于 Phase 1 | 端到端基准: 同一 batch、同一 seed、有/无迁移开关，比较 batch 完成时间 |

