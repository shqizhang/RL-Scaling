# GPU Multiplexing 与多模型单卡资源调度：面向 RL-Scaling 的下一层自动伸缩方案


> **GPU multiplexing**，即在一张物理 GPU 上通过运行时调度、显存准入、模型常驻、请求批处理
> 与隔离策略，使多个模型、多个实例或多个服务阶段共享同一块 GPU。
>
> 目标：解释 GPU multiplexing 解决的问题、实现原理、抽象层级、与 Dynamo/Kubernetes/vGPU
> 的关系，并总结强化学习后训练工作负载中的经典 GPU idle/busy 特征，提出可与当前
> RL-Scaling S1/S2/S3 方案结合的一致自动伸缩路线。

---

## 1. 术语澄清：什么是 GPU multiplexing

**GPU multiplexing**，也可以称为
**GPU 多路复用**、**单卡多租户调度**或**多模型 GPU 复用**。

它的核心定义是：

> 在不把一张物理 GPU 固定绑定给单个模型/单个 pod/单个推理进程的前提下，系统把 GPU
> 的显存、计算时间片、KV cache、batch 槽位和请求队列抽象为可调度资源，并在运行时把这些资源
> 分配给多个模型或多个工作负载。

这和传统 Kubernetes GPU 调度的区别很关键：Kubernetes 默认看到的是
`nvidia.com/gpu: 1` 这种粗粒度资源。只要一个 pod 申请了一张 GPU，这张 GPU 在调度器看来就被
该 pod 独占，即使模型只有 4GB、请求间隔很长、SM 利用率只有 10%，K8s 也不会再把另一个模型
放到同一张卡上。GPU multiplexing 试图把调度粒度从“整卡”下沉到“模型实例 / 显存区间 /
请求批次 / 时间片 / KV 块”级别。

---

## 2. 它解决的问题领域

GPU multiplexing 主要解决的是 **GPU 资源碎片化与低利用率** 问题，尤其适用于以下领域：

1. **多模型在线推理**

   一个集群同时服务多个模型，例如 policy model、reward model、embedding model、reranker、guardrail
   model、small assistant model 等。许多模型体积不同、请求到达率不同。如果每个模型都独占 GPU，
   会产生大量低利用率卡。

2. **强化学习后训练中的异步推理服务**

   RLHF、GRPO、DPO 类流程中，rollout、打分、过滤、评估、训练并非持续均匀运行，而是阶段性爆发。
   单个模型在某一阶段繁忙，其他模型或组件可能空闲。GPU multiplexing 可以利用这种互补性。

3. **长尾与突发混合的 LLM serving**

   Decode 阶段长尾请求会让少量 GPU 被拖住；同时另一些模型的短请求可能只需要很小的计算窗口。
   如果运行时能把短请求插入空隙，整卡利用率会提高。

4. **小模型与 LoRA/adapter 服务**

   多个小模型、多个 LoRA adapter、多个任务头常常无法单独填满 GPU。把它们打包到一张卡上，比按
   deployment 独占 GPU 更经济。

5. **离线与在线混部**

   在线服务需要低延迟保障，离线 batch 任务关注吞吐。GPU multiplexing 可以在在线负载低谷时把
   剩余 token budget、SM 时间或显存预算交给离线任务。

从资源调度角度看，它处理的不是“如何把 pod 放在哪个节点上”这一层问题，而是
**已经拿到 GPU 之后，如何在 GPU 内部进行更细粒度的资源复用**。

---

## 3. 实现原理

GPU multiplexing 的实现可以分为五个互相配合的层面。

### 3.1 显存准入与模型常驻

首先，调度器需要知道每个模型的显存需求，包括：

- 权重显存：模型参数、量化格式、tensor parallel 切分后的常驻大小；
- KV cache 预算：与并发请求数、上下文长度、batch 大小相关；
- 临时 workspace：算子执行、attention kernel、通信 buffer；
- 框架开销：CUDA context、allocator、NIXL/NCCL buffer、runtime metadata。

只有当总需求满足以下约束时，多模型才可以安全共驻：

```text
sum(model_weights) + reserved_kv_cache + runtime_overhead + safety_margin <= physical_gpu_memory
```

这一步相当于 GPU 内部的 admission control。它回答的问题是：哪些模型能同时放在一张卡上，
每个模型最多允许多少并发，KV cache 上限是多少，是否需要 eviction 或降级。

### 3.2 请求级调度与 batch 复用

模型常驻只是第一步。真正的利用率提升来自请求级调度。运行时需要维护多个队列：

```text
GPU worker
  ├── model A queue: prefill/decode requests
  ├── model B queue: reward scoring requests
  ├── model C queue: embedding requests
  └── background queue: offline/batch requests
```

调度器在每个 tick 中根据策略选择下一批请求：

- latency-first：优先满足在线请求 SLO；
- throughput-first：尽量合并 batch，提高 tokens/s；
- fairness：避免低流量模型长期饥饿；
- priority：RL rollout 关键路径优先于后台评估；
- deadline-aware：接近超时的请求优先；
- cache-aware：共享 prefix 或 adapter 的请求优先合并。

对 LLM 来说，prefill 和 decode 的资源形态不同。Prefill 是 compute-bound，decode 更偏 memory-bandwidth-bound。
理想的 multiplexing 调度会把不同资源瓶颈的任务交错执行，使 SM、HBM、KV cache 和通信链路都更少空转。

### 3.3 时间片、空间切分与运行时隔离

GPU multiplexing 可以通过三种方式复用单卡：

| 方式 | 粒度 | 典型机制 | 优点 | 局限 |
|------|------|----------|------|------|
| 时间复用 | 毫秒级/请求级 | CUDA stream、runtime scheduler、MPS | 灵活，适合突发流量 | 延迟抖动，需要抢占/优先级控制 |
| 空间复用 | SM/显存分区 | MIG、静态 memory partition | 隔离强，可预测 | 粒度固定，弹性差 |
| 语义复用 | 模型/请求/KV 级 | vLLM continuous batching、prefix cache、adapter batching | 最懂 LLM 工作负载 | 需要深度接入 serving runtime |

对当前 RL-Scaling 项目来说，最有价值的是第三类：**语义复用**。因为系统已经在 Dynamo/vLLM 层面掌握
请求、KV cache、prefill/decode、ModelCard、WorkerSet 等语义信息，这比只在 GPU 驱动层做黑盒时间片
更容易做出正确调度。

### 3.4 KV cache 与跨模型资源预算

LLM serving 的特殊点是 KV cache 会随请求长度增长，并长期占据显存。多模型单卡复用时，最容易出问题的
不是权重显存，而是 KV cache 膨胀。

因此 GPU multiplexing 需要引入 KV budget：

```text
GPU total memory
  ├── model A weights
  ├── model B weights
  ├── shared runtime / connector buffers
  ├── KV budget A
  ├── KV budget B
  └── emergency reserve
```

调度策略需要能回答：

- 哪个模型当前可以接收新请求；
- 哪个模型的 KV cache 已接近上限；
- 是否需要降低并发、拒绝长上下文、迁移请求或释放 prefix cache；
- 是否允许某个模型临时借用另一个模型未使用的 KV budget。

这与当前 S3 request consolidation 很容易结合：S3 已经把“请求及其 KV 状态可以跨 worker 迁移”作为运行时原语。
GPU multiplexing 可以进一步把迁移动作扩展为“当某张卡上的某个模型 KV budget 紧张时，把低优先级或长尾请求迁移到其他卡”。

### 3.5 控制面：指标、预测与策略

一个完整的 GPU multiplexing 控制器需要采集：

- 每模型 QPS、排队长度、prefill/decode token 速率；
- 每模型 p50/p95/p99 latency；
- 每 GPU SM utilization、HBM bandwidth、显存占用、KV block 使用率；
- 每模型 active request 数、平均剩余 token、长尾请求分布；
- RL 阶段信号：rollout_start、sampling_progress、training_start、eval_start；
- 模型优先级与 SLO：policy/reward/embedding/offline 的不同服务等级。

控制器输出不是简单的 replica 数，而是一组更细的决策：

```text
- 哪些模型可以共驻同一张 GPU
- 每个模型的最大并发和 KV budget
- 哪些请求队列被暂停、限流或降级
- 是否触发 S2 角色切换
- 是否触发 S3 请求迁移/合并
- 是否需要向 Kubernetes 请求新的整卡资源
```

---

## 4. 为什么它能优化资源调度

GPU multiplexing 能优化资源调度，本质原因是它减少了三类浪费。

### 4.1 减少整卡独占浪费

如果每个模型独占一张 GPU，利用率下界由“最闲模型”决定。例如：

```text
GPU-0: policy model   80% busy
GPU-1: reward model   15% busy
GPU-2: embedding       8% busy
GPU-3: eval model      5% busy
```

Kubernetes 看到的是 4 张 GPU 都被占用，但系统真实有效计算可能只有 1.08 张 GPU。GPU multiplexing 可以把
reward、embedding、eval 等模型合并到一张或两张卡上，把剩余 GPU 释放给 policy rollout 或训练。

### 4.2 利用不同模型的峰谷互补

RL 后训练不是稳定在线服务。一个典型周期可能是：

```text
rollout sampling:   policy model busy, reward model idle
reward scoring:     reward model busy, policy model partly idle
filter/eval:        small models busy, large policy idle
training step:      inference workers idle, trainer busy
```

如果模型按 deployment 静态独占 GPU，各阶段都会产生闲置池。GPU multiplexing 允许多个阶段的模型在同一张卡上共驻，
并随 RL 阶段动态调整队列优先级和并发预算。

### 4.3 提升 tail 阶段 GPU 利用率

LLM decode 的尾部有典型“少数长请求拖住整卡”的问题。当前 S3 方案通过 request consolidation 把长尾请求合并到少数 decoder。
GPU multiplexing 可以在同一张尾部 decoder 上填入其他模型的短任务，例如 reward scoring 或 embedding，避免 GPU 在等待少量 decode token
时低效空转。

### 4.4 比 K8s HPA 更细、更快

K8s HPA/KEDA/自定义 controller 的基本动作是改 replica，冷启动路径包括调度、拉镜像、加载权重、注册发现、warmup。
这通常是秒级到分钟级。GPU multiplexing 的动作发生在已经热启动的 worker 内部：

```text
调整队列权重 / 并发上限 / KV budget / model admission
```

这些动作可以是毫秒到百毫秒级，因此更适合一次 rollout 内部的细粒度控制。

---

## 5. 它是哪一层的抽象与封装

GPU multiplexing 不是单一层的功能，而是跨层封装。可以分成四层：

```text
┌──────────────────────────────────────────────────────────────┐
│ RL autoscaling policy layer                                  │
│ 根据 rollout 阶段、SLO、GPU 利用率决定资源策略                 │
├──────────────────────────────────────────────────────────────┤
│ Serving runtime layer                                         │
│ Dynamo/vLLM 感知模型、请求、batch、KV cache、ModelCard         │
├──────────────────────────────────────────────────────────────┤
│ GPU execution layer                                           │
│ CUDA stream、MPS、MIG、allocator、KV block manager、NIXL        │
├──────────────────────────────────────────────────────────────┤
│ Kubernetes resource layer                                     │
│ pod、node、GPU device plugin、CRD、scheduler、operator          │
└──────────────────────────────────────────────────────────────┘
```

对本项目来说，最合适的抽象位置是：

> 在 Kubernetes 整卡调度之上、Dynamo/vLLM worker 内部，新增一个
> **GPU-local model scheduler** 或 **multi-model worker runtime**。

它对上暴露为“一个可服务多个模型的 worker”，对下管理同一张 GPU 上的模型权重、KV cache 和请求队列。
这样做的好处是：

- Kubernetes 仍然负责节点级和整卡级资源分配；
- Dynamo 仍然负责 discovery、ModelCard、WorkerSet 与路由；
- GPU-local scheduler 负责单卡内部的多模型复用；
- RL-Scaling controller 负责跨阶段、跨模型、跨 worker 的策略决策。

---

## 6. 与 Dynamo/Kubernetes 的关系

### 6.1 当前 RL-Scaling 方案已经覆盖的层面

当前实现主要优化的是 **单模型、单服务图、Kubernetes/Dynamo worker 级资源重塑**：

| 已有方案 | 调度粒度 | 解决的问题 | 典型动作 |
|----------|----------|------------|----------|
| S1 rollout-driven scaling | pod replica / GPU pool | RL 阶段性扩缩容 | patch prefill/decode replica |
| S2 elastic PD role switch | worker role / ModelCard | prefill/decode 池比例不匹配 | decode ↔ prefill 原地切换 |
| S3 request consolidation | in-flight request / KV block | decode 长尾拖住 GPU | migrate_out/in/complete |

这三者的共同点是：它们仍然假设每个 worker 主要服务一个模型，且一张 GPU 基本对应一个 worker/pod 的执行上下文。

### 6.2 GPU multiplexing 补充的层面

GPU multiplexing 引入的是 **单卡内部多模型复用**：

```text
Before:
  GPU-0 -> policy decode worker
  GPU-1 -> reward worker
  GPU-2 -> embedding worker

After:
  GPU-0 -> multi-model worker
           ├── policy decode queue
           ├── reward scoring queue
           └── embedding queue
```

它不是替代 Dynamo/Kubernetes，而是补上 K8s 粗粒度 GPU 调度看不到的部分。可以理解为：

- Kubernetes：决定哪台机器上的哪张 GPU 给哪个 worker pod；
- Dynamo：决定哪些 worker 对哪些模型/端点可见，并把请求路由过去；
- GPU multiplexing runtime：决定同一个 worker pod 内，多个模型请求如何共享这一张 GPU；
- RL-Scaling controller：决定什么时候需要整卡伸缩、角色切换、请求迁移或单卡内共驻。

### 6.3 与 Dynamo ModelCard/WorkerSet 的结合方式

Dynamo 的 discovery 以 ModelCard 和 WorkerSet 为核心。多模型单卡 worker 可以把自己注册为多个 ModelCard：

```text
DynamoWorkerMetadata for pod gpu-worker-0
  model_cards:
    /policy/generate/instance-0
    /reward/score/instance-0
    /embedding/embed/instance-0
```

前端或 router 仍然按模型名/endpoint 选择 worker；被选中的 worker 内部再由 GPU-local scheduler 做队列与 batch 决策。
这与当前 S2 的角色切换机制非常一致：S2 已经证明了“通过修改 ModelCard 改变路由可见性”是可行路径。
GPU multiplexing 只是把 ModelCard 从“decode/prefill 角色”扩展到“多个模型/多个 endpoint”。

---

## 7. 与 vGPU 的联系和区别

vGPU、MIG、MPS、GPU multiplexing 经常被混用，但它们层级不同。

| 技术 | 所在层 | 提供什么 | 与本文关系 |
|------|--------|----------|------------|
| vGPU | 虚拟化/云平台层 | 把物理 GPU 虚拟成多个虚拟设备，给 VM 或容器使用 | 可作为隔离手段，但不了解模型和请求 |
| MIG | GPU 硬件分区层 | 把 A100/H100 等切成固定 GPU instance | 空间隔离强，但切分粒度固定 |
| CUDA MPS | 驱动/执行层 | 多进程共享 GPU execution context，提高并发 | 有助于时间复用，但不做 LLM 语义调度 |
| GPU multiplexing | serving runtime / control plane 层 | 按模型、请求、KV cache、SLO 做单卡复用 | 本文讨论的核心 |

因此，GPU multiplexing 和 vGPU 的关系是：

- vGPU 是一种底层隔离/虚拟化机制；
- GPU multiplexing 是一种上层资源调度策略；
- vGPU 可以承载 multiplexing，但不是必须条件；
- 仅有 vGPU 不足以解决 LLM serving 的低利用率，因为 vGPU 不知道 prefill/decode、KV cache、token、batch 和 SLO。

如果目标是强租户隔离，比如多个用户互不信任，vGPU/MIG 很有价值。如果目标是同一 RL pipeline 内多个模型的资源效率，
基于 Dynamo/vLLM 的 runtime-level multiplexing 更合适，因为它能利用模型语义和请求语义。

---

## 8. RL 工作负载中经典的 GPU idle/busy 特点

强化学习后训练的 GPU 利用率具有明显的阶段性和结构性。

### 8.1 跨阶段忙闲交替

典型流程如下：

```text
┌──────────────┬─────────────────┬──────────────────┬──────────────┐
│ rollout      │ reward scoring  │ training update  │ evaluation   │
├──────────────┼─────────────────┼──────────────────┼──────────────┤
│ policy 忙    │ reward 忙        │ trainer 忙        │ eval 忙       │
│ reward 闲    │ policy 部分闲    │ inference 闲      │ policy 可闲   │
│ trainer 闲   │ trainer 闲       │ policy/reward 闲  │ reward 可闲   │
└──────────────┴─────────────────┴──────────────────┴──────────────┘
```

这种 busy/idle 不是随机噪声，而是由算法阶段决定的。它可以被 RL controller 预测和利用。

### 8.2 Prefill 与 decode 的资源形态不同

在 LLM rollout 中：

- prefill 阶段处理 prompt，计算密集，短时间爆发；
- decode 阶段逐 token 生成，持续时间长，更受 memory bandwidth 和 KV cache 影响；
- 长尾 decode 会让少量请求占住 GPU；
- batch 中样本长度差异越大，尾部浪费越明显。

这正是当前 S2/S3 的依据：

- S2 用角色切换解决 prefill/decode 池比例和阶段不匹配；
- S3 用请求合并解决 decode 尾部浪费。

### 8.3 多模型 RL pipeline 的互补性更强

单模型场景中，主要矛盾是 prefill/decode。多模型场景中，还会出现：

- policy model 忙时，reward model 可能闲；
- reward scoring 忙时，policy model 的 decode worker 可能低负载；
- embedding/filter/eval 模型通常轻量但需要低启动延迟；
- trainer 占用 GPU 时，inference 侧可能整体下降；
- 同一阶段内不同模型的请求长度、batch 形态和 SLO 不同。

因此，多模型 RL pipeline 的 autoscaling 不应只看“副本数”，而应同时看：

```text
phase × model × role × GPU-local resource
```

---

## 9. Auto Scaling 可以做的方向

面向 RL-Scaling，自动伸缩可以系统化分为六个方向。

### 9.1 方向 A：整卡/Pod 级伸缩

这是 Kubernetes 最擅长的层面。

- 触发信号：rollout_start、sampling_done、training_start、queue depth；
- 动作：patch replica、scale-to-zero、pre-warm；
- 优点：隔离清晰，和 K8s 生态兼容；
- 缺点：冷启动慢，粒度粗。

当前 S1 属于这个方向。

### 9.2 方向 B：Worker 角色级伸缩

这是当前 S2 的核心。

- 触发信号：prefill queue 高、decode queue 低，或反之；
- 动作：decode ↔ prefill 原地切换；
- 优点：无需新建 pod，亚秒级改变有效池比例；
- 缺点：仍然是单模型、单角色视角。

### 9.3 方向 C：请求级伸缩/合并

这是当前 S3 的核心。

- 触发信号：decoder 上 active request 低于阈值、剩余 token 足够长、目标端有容量；
- 动作：migrate_out、migrate_in、migration_complete；
- 优点：释放尾部 GPU，避免等待最后几个长请求；
- 缺点：需要强 KV 一致性与迁移收益判断。

### 9.4 方向 D：单卡多模型复用

这是本文提出的新方向。

- 触发信号：某模型低利用、另一模型排队，或 RL 阶段切换；
- 动作：调整模型共驻组合、队列权重、并发上限、KV budget；
- 优点：比 pod 级伸缩更细，能消除多模型碎片；
- 缺点：需要 runtime-level scheduler，复杂度高。

### 9.5 方向 E：队列和 SLO 级自适应

即使不移动模型，也可以动态调整服务策略。

- 对在线请求保持低延迟优先；
- 对离线 reward/eval 批量任务使用低优先级填充；
- 对长上下文请求做限流或迁移；
- 对接近 deadline 的请求提高优先级；
- 在 GPU pressure 高时降低 max_tokens 或拒绝低优先级请求。

### 9.6 方向 F：训练/推理协同调度

在 RL 后训练中，trainer 和 inference 并不是孤立系统。更一致的方案应让 trainer 暴露阶段信号：

```text
sampling_start -> inference prewarm / policy priority up
sampling_tail  -> consolidation / multiplex background reward
scoring_start  -> reward model priority up
training_start -> inference scale down or switch to shared low-priority mode
```

这比单纯使用 Prometheus GPU 利用率更可靠，因为它利用了 RL pipeline 的可预测结构。

---

## 10. 与当前实现结合的一致方案

可以把当前 RL-Scaling 扩展为四层统一控制框架。

```text
┌────────────────────────────────────────────────────────────┐
│ L4: Multi-model GPU multiplexing                           │
│     单卡内多个模型共驻，调整 KV budget / queue / priority    │
├────────────────────────────────────────────────────────────┤
│ L3: Request consolidation                                  │
│     在线请求跨 GPU 迁移，释放尾部 decoder                    │
├────────────────────────────────────────────────────────────┤
│ L2: Elastic PD role switch                                 │
│     decode ↔ prefill 原地切换，重塑单模型 PD 池比例           │
├────────────────────────────────────────────────────────────┤
│ L1: K8s rollout-driven scaling                             │
│     replica / pod / GPU pool 级扩缩容                       │
└────────────────────────────────────────────────────────────┘
```

这四层不是互斥关系，而是按成本和粒度排序：

| 层级 | 粒度 | 动作成本 | 反应速度 | 适合解决 |
|------|------|----------|----------|----------|
| L1 K8s scaling | pod/GPU | 高 | 慢 | 阶段级总容量变化 |
| L2 role switch | worker role | 中 | 亚秒级 | prefill/decode 比例失衡 |
| L3 request migration | request/KV | 中 | 百毫秒级 | decode 长尾碎片 |
| L4 multiplexing | model/queue/KV budget | 低到中 | 毫秒到百毫秒 | 多模型单卡碎片 |

### 10.1 推荐架构

新增组件可以命名为 `GPUResourceMuxController` 或 `MultiModelGpuScheduler`：

```text
RL signal / metrics
        │
        ▼
RL-Scaling Controller
        │
        ├── S1: K8s replica planner
        ├── S2: role switch planner
        ├── S3: request consolidation planner
        └── S4: GPU multiplexing planner
                  │
                  ▼
          worker sidecar / runtime API
                  │
                  ├── set_model_admission(model, enabled)
                  ├── set_queue_weight(model, weight)
                  ├── set_kv_budget(model, blocks)
                  ├── set_max_concurrency(model, n)
                  └── evict_or_load_model(model)
```

worker 侧则需要一个 GPU-local runtime：

```text
MultiModelWorker
  ├── model registry
  ├── per-model request queues
  ├── memory/KV budget manager
  ├── batch scheduler
  ├── priority/SLO policy
  └── Dynamo ModelCard publisher
```

### 10.2 决策顺序

一个稳定策略可以按以下顺序决策：

1. **先用 L4 multiplexing 填补单卡碎片。** 如果某张 GPU 还有安全显存和低优先级算力窗口，优先接纳小模型或后台任务。
2. **再用 L3 consolidation 清理尾部。** 当某模型/某角色只剩少量长请求时，把它们迁走，释放整张卡或腾出 KV budget。
3. **再用 L2 role switch 改变 PD 比例。** 当 prefill/decode 出现阶段性瓶颈时，把热 worker 切到需要的角色。
4. **最后用 L1 K8s scaling 改变总容量。** 当热资源不足或整个阶段结束时，再扩容/缩容 pod。

这样的顺序能避免把所有问题都交给最慢、最粗粒度的 K8s replica 调整。

### 10.3 多模型 RL 示例

假设一个 RL pipeline 包含：

- `policy-7b`：rollout 主模型；
- `reward-3b`：reward scoring；
- `embed-1b`：检索或过滤；
- `eval-7b`：周期性评估。

一个统一策略可以是：

```text
rollout_start:
  - S1: prewarm policy prefill/decode workers
  - S2: decode -> prefill if prompt burst dominates
  - S4: reward/embed 降低 queue weight，只保留少量常驻 capacity

rollout_tail:
  - S3: consolidate policy decode long-tail requests
  - S4: 在释放出的低负载 decoder 上提高 reward/embed queue weight

reward_scoring_start:
  - S4: reward model 获得更高 KV/queue budget
  - S2: 若 policy decode 已低负载，可切部分 worker 到 reward/prefill-like endpoint

training_start:
  - S1: inference pool 缩容或 scale-to-zero
  - S4: 保留小模型低成本常驻，避免下一阶段冷启动
```

这形成的不是四套割裂方案，而是一套从粗到细的分层控制系统。

---

## 11. 实现方案路线图

### 11.1 Phase 1：观测与建模

先不做真正多模型共驻，只补观测：

- 每模型 QPS、tokens/s、queue depth；
- 每模型显存占用和 KV block 使用；
- 每 GPU idle window、SM utilization、HBM bandwidth；
- 每 RL 阶段中各模型 busy/idle 时间分布。

输出一个 packing report：如果做 multiplexing，哪些模型可以共驻，预计节省多少 GPU-hour。

### 11.2 Phase 2：单进程多 endpoint / 多 ModelCard

在一个 worker pod 中注册多个 endpoint/model card，但先限制为同一类小模型或同一 base model 的多个 adapter。

目标：验证 Dynamo discovery 能稳定表达“一个 worker 服务多个模型”。

### 11.3 Phase 3：GPU-local queue scheduler

实现 per-model queue 和 priority scheduler：

- 每模型最大并发；
- 每模型 queue weight；
- online/offline 优先级；
- 简单 KV budget 限制。

这一阶段不一定要做复杂抢占，只需要 admission control + batch 调度即可产生收益。

### 11.4 Phase 4：与 S2/S3 联动

将 S2/S3 纳入多模型策略：

- S3 迁移低优先级或长尾请求，为高优先级模型腾出 KV budget；
- S2 角色切换后，worker 可以从单模型 prefill/decode 变成多模型 shared worker；
- RL controller 根据阶段选择 worker 的 role、model set 和 queue policy。

### 11.5 Phase 5：安全边界与生产化

补齐生产必要条件：

- per-model SLO guardrail；
- OOM 保护和 emergency reserve；
- 模型 eviction 和 reload 策略；
- tenant/model 隔离策略；
- CI/E2E 测试：模型共驻、限流、OOM 防护、SLO 降级、阶段切换。

---

## 12. 风险与边界

GPU multiplexing 不是无条件收益。需要注意：

1. **显存是硬约束。** 多模型权重常驻很容易挤压 KV cache，导致长上下文能力下降。
2. **延迟抖动会增加。** 多队列共享一张卡，如果没有优先级和 deadline 控制，在线请求 p99 可能恶化。
3. **模型异构会降低 batch 效率。** 不同模型无法直接合批，只能时间复用；收益取决于空隙是否足够。
4. **隔离弱于 vGPU/MIG。** 同一进程或同一 worker 内复用更高效，但故障隔离和安全隔离较弱。
5. **调度器复杂度上升。** 需要同时理解模型、请求、KV、GPU 指标和 RL 阶段。

因此推荐把 GPU multiplexing 定位为 **同一 RL pipeline 内可信模型之间的效率优化**，而不是首先用于强隔离多租户云平台。

---

## 13. 总结

当前 RL-Scaling 已经实现的是 **基于 Kubernetes + Dynamo 的单模型资源调度优化**：

- S1 在 pod/GPU pool 层做阶段级伸缩；
- S2 在 worker/ModelCard 层做 prefill/decode 角色切换；
- S3 在 request/KV 层做 decode 长尾请求合并。

GPU multiplexing 可以成为下一阶段 S4：

> 在单张 GPU 内部，把多个模型、多个请求队列和多个 KV budget 纳入统一调度，利用 RL
> pipeline 中天然存在的 busy/idle 互补性，减少整卡独占浪费和多模型碎片。

它与 Dynamo/Kubernetes 的关系是互补而非替代：Kubernetes 管整卡和 pod，Dynamo 管服务发现和路由，
vLLM/Dynamo worker 内部的 multiplexing runtime 管单卡内模型与请求的细粒度复用。它与 vGPU 的关系是上下层关系：
vGPU/MIG/MPS 可以提供底层隔离或并发执行能力，但真正理解 LLM 模型、token、KV cache、prefill/decode
和 RL 阶段信号的，应该是 serving runtime 和 RL-Scaling controller。

最终一致方案应是分层自动伸缩：

```text
K8s replica scaling
  + Elastic PD role switch
  + Request consolidation
  + Multi-model GPU multiplexing
  = RL-aware GPU-hour optimization
```

这条路线可以把当前“单模型、单服务图”的 RL-Scaling 扩展为“多模型、单卡复用、跨阶段协同”的 GPU 资源调度系统。
