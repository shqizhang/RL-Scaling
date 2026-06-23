# GPU 编排、vGPU 与 GPU Multiplexing：面向 RL-Scaling 的统一学习与需求文档

> 目标：把 GPU 编排、Kubernetes、Dynamo、vGPU/MIG/MPS 与 GPU multiplexing 放到同一个抽象层级中解释清楚，说明它们分别解决什么问题、为什么 vGPU 不能单独解决 multiplexing、二者如何协作，并进一步落到强化学习后训练 pipeline 中的多模型单卡调度需求、用户故事和验收标准。
>
> 范围：本文不删除也不替代已有两份文档：
> [GPU-multiplexing-multi-model-scheduling-zh.md](GPU-multiplexing-multi-model-scheduling-zh.md) 和
> [GPU-multiplexing-requirements-analysis-zh.md](GPU-multiplexing-requirements-analysis-zh.md)。本文是二者的整合版与学习路径版。

---

## 1. 一句话总览

GPU 资源调度不是一个单层问题，而是一组从粗到细的分层抽象：

```text
Kubernetes GPU scheduling
  -> 决定 pod 拿到哪张物理 GPU 或哪个逻辑 GPU

vGPU / MIG / device plugin
  -> 把物理 GPU 暴露成更小、更灵活或更隔离的逻辑资源单位

Dynamo discovery / routing
  -> 决定哪个 worker 对哪个模型、哪个 endpoint、哪个角色可见

vLLM / serving runtime
  -> 管理请求、continuous batching、KV cache、prefill/decode 执行

GPU multiplexing
  -> 在同一张 GPU 或同一个逻辑 GPU 内部，调度多个模型、请求队列、KV budget 和 SLO
```

从这个层级看，vGPU 和 GPU multiplexing 不是同义词。vGPU 解决的是 **GPU 资源单位虚拟化和隔离**；GPU multiplexing 解决的是 **LLM serving 语义下的模型、请求和 KV cache 复用**。前者让 GPU 申请单位更灵活，后者让已经拿到 GPU 的 worker 内部使用得更聪明。

---

## 2. GPU 编排到底在编排什么

谈 GPU 编排时，容易把所有能力都混成“提高利用率”。实际上，不同层级看到的对象完全不同。

### 2.1 Kubernetes 层：编排 pod 与设备

Kubernetes 默认通过 device plugin 暴露 GPU，例如：

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

这一层的核心问题是：

- 哪个 pod 应该调度到哪个 node；
- 这个 pod 申请几张 GPU；
- node 上是否还有满足条件的设备；
- pod 生命周期如何与 deployment、operator、autoscaler 配合。

Kubernetes 的优点是通用、稳定、生态完整；缺点是默认粒度很粗。它一般不知道：

- 这个 GPU 上跑的是 policy model 还是 reward model；
- 当前请求处于 prefill 还是 decode；
- KV cache 已用了多少 block；
- 某个模型现在 idle，另一个模型正在排队；
- RL pipeline 即将从 rollout 切到 reward scoring。

因此，Kubernetes 可以做整卡/整 pod 的扩缩容，但无法独立完成 LLM/RL 场景中的细粒度 GPU 复用。

### 2.2 GPU 虚拟化层：把物理卡变成逻辑单位

vGPU、MIG、time-slicing device plugin、MPS 等能力都在试图解决一个问题：物理 GPU 太粗，能不能拆得更细或共享得更灵活。

| 技术 | 抽象对象 | 主要能力 | 典型调度单位 |
|------|----------|----------|--------------|
| vGPU | 虚拟 GPU 设备 | 将物理 GPU 虚拟成多个逻辑 GPU，给 VM/容器使用 | `1 vGPU`, `2 vGPU` |
| MIG | 硬件 GPU instance | 将支持 MIG 的 GPU 切成硬件隔离分区 | `1g.10gb`, `2g.20gb` 等 |
| Time-slicing | 时间片共享 | 多个 pod 轮流使用同一物理 GPU | 共享同一 GPU 的多个容器 |
| CUDA MPS | 多进程执行共享 | 多进程共享 GPU context，提高 kernel 并发 | 同机多进程 |

这一层可以让调度器“申请更小的 GPU 单位”，也可以改善隔离和设备利用率。但它仍然不了解 LLM 业务语义。

### 2.3 Dynamo 层：编排模型可见性与请求路由

Dynamo 的核心抽象不是 GPU device，而是 worker、ModelCard、endpoint、WorkerSet 和 router。

在当前 RL-Scaling 中，Dynamo 的价值在于：

- 每个 worker 通过 `DynamoWorkerMetadata` CR 暴露自己的模型与 endpoint；
- frontend 的 ModelWatcher 通过 list/watch CR 重建 WorkerSet；
- router 根据 ModelCard 和请求语义把流量发给合适 worker；
- S2 已经证明可以通过修改 ModelCard 做角色切换；
- S3 已经证明可以通过 sidecar 与 runtime 状态做请求迁移。

也就是说，Dynamo 位于 Kubernetes 和 vLLM 中间：Kubernetes 管 pod 和 GPU，Dynamo 管 worker 能力和服务发现。

### 2.4 vLLM 层：编排 token、batch 与 KV cache

vLLM 看到的对象比 Dynamo 更细：

- request；
- prompt tokens；
- generated tokens；
- prefill/decode 阶段；
- continuous batch；
- KV cache block；
- prefix cache；
- scheduler queue。

LLM 推理效率主要由这一层决定。对于 RL rollout 来说，vLLM 承担 policy generation、reference logprob、reward/judge scoring、evaluation generation 等前向推理场景。训练更新本身通常不在 vLLM 中完成。

### 2.5 GPU multiplexing 层：编排单卡内模型和请求

GPU multiplexing 的位置在 Kubernetes 整卡分配之后、Dynamo/vLLM worker 内部。它关心的问题是：

```text
同一张 GPU 已经被一个 worker pod 拿到了，
这个 worker 内部能不能同时服务多个模型，
并且按模型优先级、KV budget、请求队列和 RL 阶段做动态资源分配？
```

因此，GPU multiplexing 的编排对象不是 pod，也不是虚拟设备，而是：

- 模型常驻与卸载；
- 每模型 request queue；
- 每模型 max concurrency；
- 每模型 KV cache budget；
- 每模型 SLO 和 priority；
- 模型之间的 opportunistic sharing；
- 何时暂停 admission、迁移请求、热加载或撤回 ModelCard。

---

## 3. vGPU 和 GPU multiplexing 的区别

### 3.1 vGPU 解决了什么

vGPU 的直觉是正确的：一张物理 GPU 太粗，可以虚拟成多个逻辑 GPU，使资源申请更灵活。例如一张 24GB 或 80GB GPU 可以被平台暴露成多个逻辑单位，分别给不同 VM、pod 或用户使用。

它能解决的问题包括：

1. **资源申请粒度更细**

   用户不必总是申请一整张物理 GPU，可以申请更小的逻辑单位。

2. **调度层更容易装箱**

   Kubernetes 或云平台可以把多个小 workload 放到一张物理卡上，提高物理卡分配率。

3. **隔离边界更清晰**

   对多租户环境，vGPU/MIG 这类机制能提供比同进程共驻更强的资源和故障隔离。

4. **对应用透明**

   应用看到的是一个 GPU-like device，不需要理解底层物理卡如何共享。

### 3.2 vGPU 为什么不能单独解决 multiplexing

vGPU 提高的是“设备分配灵活性”，但 GPU multiplexing 要解决的是“LLM serving 运行时效率”。这中间有几个关键断层。

#### 断层一：vGPU 不知道模型语义

vGPU 只知道逻辑设备容量，不知道里面跑的是：

- policy model；
- reward model；
- reference model；
- embedding model；
- eval/judge model。

它也不知道这些模型在 RL pipeline 中哪个阶段忙、哪个阶段闲。因此它无法根据 `rollout_start` 或 `reward_scoring_start` 自动调整模型优先级。

#### 断层二：vGPU 不知道请求和 token

LLM 推理的核心负载单位不是进程，而是 request 和 token。一个 request 可能处于 prefill，也可能处于 decode；decode 可能只剩 10 个 token，也可能还剩 2000 个 token。

vGPU 不能回答：

- 哪个请求是长尾；
- 哪个请求应该迁移；
- 哪个 batch 可以合并；
- 哪个模型的 p99 token latency 已经超标；
- 哪个请求适合被低优先级排队。

这些只能由 vLLM/Dynamo/RL-Scaling 这类懂请求语义的层来处理。

#### 断层三：vGPU 不知道 KV cache

LLM serving 最大的运行时状态是 KV cache。两个模型的权重能放进同一个物理 GPU，不代表它们的 KV cache 也能安全增长。

vGPU 只会给每个逻辑 GPU 一个显存边界，不会理解：

- 某个模型当前 KV block 已接近上限；
- policy model 需要 reserved KV budget；
- reward model 可以在低压时临时借用剩余 KV；
- 长尾 decode 请求迁走后可以释放多少 KV；
- prefix cache 是否值得保留。

而 multiplexing 的关键恰恰是动态管理这些 KV budget。

#### 断层四：vGPU 静态切分可能降低弹性

如果把一张 GPU 静态切成多个 vGPU 或 MIG slice，每个 slice 的容量边界会变得更硬。对通用多租户这是优点；对 RL pipeline 的阶段性负载可能是缺点。

例如：

```text
rollout 阶段：policy 需要尽可能多的 KV cache 和 decode bandwidth
scoring 阶段：reward model 需要批量 forward
training 阶段：inference worker 大量 idle
```

如果资源被静态切成固定 slice，policy 在 rollout 阶段可能无法借用 reward slice 的空闲容量。GPU multiplexing 希望的是同一可信 pipeline 内的动态借用，而不是固定边界。

#### 断层五：vGPU 不会做 Dynamo 路由和 ModelCard 管理

当某个模型不可服务时，Dynamo router 需要知道是否撤回 ModelCard、是否暂停 admission、是否把流量转给其他 worker。vGPU 不参与这些服务发现和路由语义。

### 3.3 一个对照表

| 维度 | vGPU | GPU multiplexing |
|------|------|------------------|
| 主要目标 | 设备虚拟化、隔离、逻辑 GPU 分配 | 单卡内模型/请求/KV/SLO 调度 |
| 抽象层级 | 驱动/虚拟化/云平台/device plugin | serving runtime/control plane |
| 调度对象 | 虚拟 GPU 设备 | 模型、请求队列、KV budget、batch、priority |
| 是否理解 LLM token | 否 | 是，应由 vLLM/Dynamo 暴露 |
| 是否理解 RL phase | 否 | 是，应由 RL-Scaling controller 使用 |
| 是否提供隔离 | 强于 runtime 共驻 | 较弱，依赖进程和 runtime guardrail |
| 是否适合不可信多租户 | 适合 | 不优先适合 |
| 是否适合同一 RL pipeline 效率优化 | 可作为底座 | 是核心机制 |
| 主要风险 | 切分过硬、资源碎片、语义缺失 | 干扰、OOM、调度复杂、隔离弱 |

---

## 4. vGPU 与 GPU multiplexing 如何协作

vGPU 不能替代 multiplexing，但可以和 multiplexing 组合。关键是明确分工。

### 4.1 协作模式 A：vGPU/MIG 做隔离，multiplexing 做 slice 内语义调度

适合多租户或多团队共享集群：

```text
Physical GPU
  ├── vGPU/MIG slice A -> team A / pipeline A
  │       └── runtime-level multiplexing: policy-small + reward + embed
  └── vGPU/MIG slice B -> team B / pipeline B
          └── runtime-level multiplexing: eval + rerank + filter
```

vGPU/MIG 保证团队之间不会互相 OOM 或抢占过界；multiplexing 在每个可信边界内部继续做模型和请求级调度。

### 4.2 协作模式 B：Kubernetes 申请逻辑 GPU，Dynamo worker 管理多模型 endpoint

在 Kubernetes 中，pod 申请的是逻辑 GPU：

```yaml
resources:
  limits:
    nvidia.com/vgpu: 1
```

但 pod 内部仍然运行 multi-model worker：

```text
worker pod on vGPU-0
  ├── /policy/generate
  ├── /reward/score
  └── /embedding/embed
```

Dynamo 仍通过 ModelCard 暴露 endpoint，可见性由 worker sidecar 动态控制。这样做的好处是平台层仍使用标准 GPU 资源申请，而 AI serving 层保留模型语义。

### 4.3 协作模式 C：vGPU 负责 quota，multiplexing 负责 burst sharing

在云平台中，vGPU 可以定义每个团队或 pipeline 的基础 quota。multiplexing 在 quota 内做资源复用，并在同一可信 pipeline 内允许临时借用 idle budget。

这适合以下策略：

- policy 关键路径拥有 reserved GPU/KV budget；
- reward/eval/filter 使用 opportunistic budget；
- 超过 SLO 时收回 opportunistic budget；
- 需要强隔离时退回 vGPU/MIG 固定边界。

### 4.4 协作边界

不建议把所有问题都交给 vGPU，也不建议完全绕开底层隔离。

合理边界是：

- **跨租户、跨团队、强安全边界**：优先 vGPU/MIG/独立 GPU；
- **同一 RL pipeline 内可信多模型**：优先 runtime-level multiplexing；
- **资源申请和 quota 管理**：Kubernetes + device plugin/vGPU；
- **模型可见性和服务路由**：Dynamo ModelCard/WorkerSet；
- **请求、KV 和 batch 调度**：vLLM + GPU-local scheduler；
- **阶段策略和自动伸缩**：RL-Scaling controller。

---

## 5. 从 GPU 编排递进到 RL-Scaling 的统一架构

最终系统可以按以下层次理解：

```text
┌──────────────────────────────────────────────────────────────┐
│ RL policy layer                                               │
│ rollout_start / scoring_start / training_start / eval_start   │
│ 决定当前阶段谁是关键路径，谁可以降级或机会式运行               │
├──────────────────────────────────────────────────────────────┤
│ RL-Scaling controller                                         │
│ S1 replica scaling + S2 role switch + S3 request migration +  │
│ S4 GPU multiplexing policy                                    │
├──────────────────────────────────────────────────────────────┤
│ Dynamo serving/discovery layer                                │
│ ModelCard、WorkerSet、endpoint、router、sidecar API            │
├──────────────────────────────────────────────────────────────┤
│ vLLM runtime layer                                             │
│ request queue、continuous batching、prefill/decode、KV cache   │
├──────────────────────────────────────────────────────────────┤
│ GPU virtualization/execution layer                            │
│ vGPU、MIG、MPS、CUDA stream、allocator                         │
├──────────────────────────────────────────────────────────────┤
│ Kubernetes resource layer                                      │
│ node、pod、device plugin、operator、scheduler                  │
└──────────────────────────────────────────────────────────────┘
```

每层有不同的“能看见什么”和“能控制什么”：

| 层级 | 能看见 | 能控制 | 不能解决 |
|------|--------|--------|----------|
| Kubernetes | pod、node、GPU resource | pod placement、replica、整卡申请 | LLM request/KV 语义 |
| vGPU/MIG | 物理 GPU 与逻辑 GPU | 逻辑设备切分、隔离、quota | 模型阶段和 token 调度 |
| Dynamo | worker、ModelCard、endpoint | 服务发现、路由可见性、角色切换 | GPU 内部 KV budget 细节 |
| vLLM | request、batch、KV cache | token 调度、prefix cache、batch | 全局 RL 阶段策略 |
| GPU multiplexing | 模型、队列、KV budget、SLO | 单卡内多模型调度 | 跨节点整卡容量供给 |
| RL-Scaling | phase、metrics、策略目标 | S1/S2/S3/S4 联合决策 | 底层硬隔离本身 |

这个表是理解方案边界的关键：vGPU 的确能让申请 GPU 更灵活，但它仍然停留在“逻辑设备”层；multiplexing 才进入“模型和请求”层。

---

## 6. RL pipeline 中 vLLM 推理的位置

在强化学习后训练中，vLLM 主要用于推理侧，而不是训练反向传播侧。

| RL 环节 | 是否使用 vLLM | 需要模型 | 推理类型 | GPU 特点 |
|---------|---------------|----------|----------|----------|
| Prompt batch 准备 | 否 | 无或轻量过滤模型 | 数据管道 | 通常 CPU/存储瓶颈 |
| Policy rollout generation | 是，最典型 | policy/actor | 生成 response | decode 长、KV cache 大、吞吐关键 |
| Reference logprob/KL | 可用 | reference | prompt+response forward/logprob | 批量前向，可能不生成 token |
| Reward scoring | 常用 | reward/verifier/judge | 打分、比较、判别 | 阶段性突发，可批处理 |
| Critic/value 估计 | 视算法而定 | critic/value | value forward | PPO 常见，GRPO 可省略 critic |
| Advantage/return 计算 | 否 | 无 | 张量计算 | 不属于 serving 推理 |
| Policy update | 否 | trainable actor | 反向传播 | 梯度、激活、优化器状态占显存 |
| Weight sync | 间接相关 | policy inference replica | 更新 vLLM worker 权重 | 影响版本一致性和冷启动 |
| Evaluation | 是 | policy + judge/reward/eval | 生成与打分 | 周期性运行，适合预热/热加载 |

一个典型 RLHF/PPO/GRPO 周期可以理解为：

```text
prompt batch
  -> policy rollout generation on vLLM
  -> reward/judge scoring
  -> reference/KL 或 critic/value forward
  -> advantage/return calculation
  -> policy training update
  -> weight sync to vLLM rollout workers
  -> evaluation
  -> next iteration
```

这条链路的 GPU 忙闲具有强阶段性：rollout 时 policy 忙，reward 闲；scoring 时 reward 忙，policy 可能部分闲；training update 时 serving workers 可能 idle；eval 时 judge/eval 短暂忙。这种互补性是 GPU multiplexing 在 RL 场景中成立的业务前提。

---

## 7. RTX 3090 24GB 下的模型容量事实

如果实验环境使用 RTX 3090，单卡显存是 24GB。对 LLM 推理来说，这 24GB 不能全部给权重，还要预留：

- KV cache；
- CUDA context；
- vLLM block manager；
- temporary workspace；
- allocator 碎片；
- 通信 buffer；
- emergency reserve。

粗略权重显存估算如下：

| 模型规模 | BF16/FP16 权重 | INT8 权重 | INT4 权重 | 3090 24GB 上的含义 |
|----------|----------------|-----------|-----------|---------------------|
| 0.5B | 约 1GB | 约 0.5GB | 约 0.25GB | 很适合共驻 |
| 1B | 约 2GB | 约 1GB | 约 0.5GB | 适合 reward/filter/embedding 小模型 |
| 3B | 约 6GB | 约 3GB | 约 1.5GB | 可共驻，但要限制 KV 和并发 |
| 7B | 约 14GB | 约 7GB | 约 3.5GB | BF16 可单模型推理，共驻空间有限 |
| 14B | 约 28GB | 约 14GB | 约 7GB | BF16 超单卡，量化后仍需谨慎 |
| 32B | 约 64GB | 约 32GB | 约 16GB | 通常不适合单 3090，高风险 |
| 70B | 约 140GB | 约 70GB | 约 35GB | 单 3090 不可行 |

需求含义：

- 3090 上的 multiplexing MVP 不应从多个 7B/14B BF16 模型共驻开始；
- 更合理的 MVP 是 `7B policy` 半独占，加 `0.5B/1B/3B reward/filter/embed` 机会式共驻；
- 或者 `3B policy + 1B reward + 1B embedding` 这类中小模型组合；
- 14B BF16、32B、70B 应走多卡并行、远端服务、独占 worker pool 或量化后低并发实验；
- 任何共驻计划都必须计算 `weights + min_kv_budget + runtime_overhead + reserve`，不能只看权重。

---

## 8. GPU multiplexing 的需求定义

### 8.1 业务目标

GPU multiplexing 的目标不是简单把更多模型塞进一张卡，而是在保证 RL 关键路径正确性的前提下提高 GPU-hour 效率。

核心目标：

1. 多模型共驻，减少小模型独占 GPU 的浪费；
2. 阶段感知调度，利用 rollout、scoring、training、eval 的 busy/idle 互补；
3. 主模型 SLO 保护，policy rollout 优先级最高；
4. 单卡内细粒度调度，控制 queue、KV budget、max concurrency、admission；
5. 与 S1/S2/S3 统一，形成分层调度策略。

### 8.2 非目标

1. 不以跨不可信租户共享为第一目标；强隔离优先 vGPU/MIG/独立 GPU。
2. 不要求超单卡大模型被单卡 multiplexing 承载。
3. 不在 MVP 阶段修改 Kubernetes scheduler。
4. 不牺牲 policy rollout 的 p95/p99 latency 和成功率。
5. 不把训练反向传播纳入 vLLM worker 内部复用。

### 8.3 关键约束

| 约束 | 说明 | 需求结论 |
|------|------|----------|
| 权重显存 | 多模型权重相加可能超过单卡 | 必须有 placement fit check |
| KV cache | 长上下文和高并发会膨胀 | 必须有 per-model KV budget |
| SLO 干扰 | 后台模型可能拖慢 policy | 必须有 priority 和 SLO guard |
| 模型加载 | 热加载有秒级成本 | 必须利用 RL phase 预测 preload |
| 模型大小差异 | 小模型适合共驻，大模型不一定 | 模型必须分级处理 |
| 服务发现 | 模型不可服务时 router 要知道 | Dynamo ModelCard 必须和 admission 状态一致 |
| 隔离要求 | runtime 共驻隔离弱 | 不可信模型走 vGPU/MIG/独立部署 |

---

## 9. 方案设计

### 9.1 分层控制策略

推荐按从细到粗的顺序调度：

```text
S4 GPU-local multiplexing
  -> 调 queue weight、admission、KV budget、max concurrency

S3 request consolidation
  -> 迁移长尾请求，释放 KV 和 GPU 尾部碎片

S2 elastic role switch
  -> 调整 prefill/decode 或其他 endpoint 能力

S1 Kubernetes scaling
  -> 调整总 pod/GPU 容量
```

这样做的原因是：越靠上层的动作越快、越细、成本越低；Kubernetes replica scaling 最慢、最粗，应作为最后手段。

### 9.2 组件架构

```text
RL trainer / rollout controller
        │ phase signal
        ▼
RL-Scaling Controller
        ├── S1 Kubernetes replica planner
        ├── S2 role switch planner
        ├── S3 request consolidation planner
        └── S4 GPU multiplexing planner
                │
                ▼
Multi-model worker sidecar
        ├── set_model_admission(model, enabled)
        ├── set_queue_weight(model, weight)
        ├── set_kv_budget(model, blocks)
        ├── set_max_concurrency(model, n)
        ├── preload_model(model)
        ├── unload_model(model)
        └── publish_or_withdraw_modelcard(model)
                │
                ▼
GPU-local runtime scheduler
        ├── model registry
        ├── per-model queues
        ├── memory/KV budget manager
        ├── batch scheduler
        ├── SLO guard
        └── Dynamo ModelCard publisher
```

### 9.3 模型放置策略

| 模型情况 | 推荐策略 | 不推荐策略 | 原因 |
|----------|----------|------------|------|
| 小模型、低频、可延迟 | 常驻共驻或低优先级 queue | 独占 GPU | 独占浪费高 |
| 中模型、阶段性突发 | 阶段前热加载，阶段内提高权重 | 长期独占 | RL 阶段可预测 |
| 大模型但可量化 | 量化后评估共驻 | 直接 FP16 共驻 | 权重显存过大 |
| 超单卡关键模型 | 多卡并行或独占 pool | 单卡 multiplexing | 物理容量不满足 |
| 强隔离/不可信模型 | vGPU/MIG/独立 GPU | runtime 共驻 | 安全与故障边界不足 |
| 长尾 decode 请求 | S3 迁移/合并 | 等待自然完成 | GPU tail waste 高 |

---

## 10. 用户故事、Criteria 与验收标准

### 10.1 Story 1：小模型共驻

作为平台工程师，我希望 reward、embedding、filter 等中小模型可以共驻在一张 GPU 上，从而减少低利用率独占卡。

Criteria：

- 输入每个模型的权重大小、量化格式、min/max KV budget、max concurrency；
- planner 能判断共驻组合是否满足 3090 24GB 或目标 GPU 容量；
- 共驻后每个模型可独立开启/关闭 admission；
- 共驻后主模型 p95/p99 latency 不超过阈值。

验收标准：

- 给定 `policy-3b + reward-1b + embedding-1b`，planner 生成可执行共驻计划；
- 给定 `policy-7b BF16 + reward-7b BF16`，planner 拒绝共驻并输出原因；
- 压测期间无 OOM；
- 低优先级模型可被暂停且不影响主模型继续服务。

### 10.2 Story 2：policy 关键路径保护

作为 RL 训练负责人，我希望 policy rollout 阶段始终优先于 reward/eval 后台任务，避免资源复用破坏采样吞吐。

Criteria：

- controller 能识别 `rollout_start`；
- policy model 获得 reserved KV budget 和最高 queue weight；
- reward/eval/filter 只使用 opportunistic budget；
- policy latency 超阈值时自动暂停低优先级 admission。

验收标准：

- rollout 阶段 policy queue weight 自动升高；
- policy p95/p99 超阈值后，后台模型 admission 变为 disabled；
- pressure 解除后，后台模型可恢复；
- decision log 记录触发原因、调整动作和恢复条件。

### 10.3 Story 3：vGPU 与 multiplexing 协作

作为平台管理员，我希望在需要隔离时使用 vGPU/MIG 划定资源边界，同时在每个可信边界内部继续使用 runtime-level multiplexing 提升利用率。

Criteria：

- 系统能识别模型或 pipeline 的 isolation class；
- `trusted_pipeline` 可进入 runtime multiplexing；
- `untrusted_tenant` 必须使用 vGPU/MIG/独立 GPU；
- vGPU slice 内仍可发布多个 Dynamo ModelCard。

验收标准：

- 同一 RL pipeline 的 reward/embed 可与 policy worker 共驻；
- 不同租户模型不会被放进同一个 runtime worker；
- vGPU/MIG 边界内的 worker 仍支持 per-model queue、admission 和 KV budget；
- 文档化每次 placement 决策中的隔离原因。

### 10.4 Story 4：阶段性热加载

作为平台工程师，我希望 eval/judge 模型不长期占用显存，但能在 eval 阶段前被提前加载。

Criteria：

- controller 能接收 `eval_start` 或预测 eval window；
- worker 支持 `preload_model` 和 `unload_model`；
- preload 完成后再发布 Dynamo ModelCard；
- unload 前先关闭 admission 并等待请求 drain。

验收标准：

- eval 前模型成功热加载；
- ModelCard 发布后 router 才能派发请求；
- eval 结束后模型释放显存；
- 加载失败时不影响 policy 继续 rollout。

### 10.5 Story 5：超单卡模型处理

作为系统设计者，我希望超过单卡容量的模型不会被错误放入 multiplexing pool，而是进入合理的多卡或独占部署路径。

Criteria：

- planner 强制检查 `weights + min_kv_budget + overhead + reserve <= capacity`；
- 不满足条件时标记为 `requires_multi_gpu`、`exclusive` 或 `remote_service`；
- 可给出推荐：tensor parallel、量化、独立部署、远端服务；
- 不生成不可执行的共驻计划。

验收标准：

- 14B BF16 在 3090 上被拒绝单卡共驻；
- 70B 被标记为 multi-GPU/remote；
- 7B INT4 可进入候选，但要求质量验证和 KV budget 限制；
- 拒绝原因包含权重、KV、overhead 和 reserve 的估算明细。

### 10.6 Story 6：与 S1/S2/S3 联动

作为调度系统，我希望在 multiplexing 不足以解决资源压力时，能继续调用已有 S1/S2/S3 原语。

Criteria：

- 当单卡内可调资源足够时，优先使用 S4；
- 当长尾 decode 占住 KV 或 GPU 时，触发 S3；
- 当 prefill/decode 池比例失衡时，触发 S2；
- 当总热资源不足时，触发 S1；
- 每次决策输出顺序和原因。

验收标准：

- 单卡 queue pressure 可通过 admission/weight 调整缓解；
- KV pressure 无法缓解时触发 request migration；
- role imbalance 时触发 role switch；
- 所有本地动作失败或容量不足时才扩容 Kubernetes replicas。

---

## 11. MVP 与后续路线

### 11.1 MVP 范围

MVP 只支持可信同 pipeline 内的小/中模型复用：

- 静态 `ModelResourceProfile`；
- single-GPU fit check；
- per-model admission；
- per-model queue weight；
- per-model max concurrency；
- 简单 KV budget；
- Dynamo 多 ModelCard 注册/撤回；
- RL phase 驱动策略切换；
- S1/S2/S3/S4 决策顺序集成。

MVP 不做：

- 自动模型并行切分；
- 任意跨租户 runtime 共驻；
- 修改 Kubernetes scheduler；
- 复杂抢占式 kernel 调度；
- 完整动态模型下载系统。

### 11.2 后续增强

- 与 vGPU/MIG 的 isolation class 集成；
- 动态模型热加载和 CPU/NVMe cache；
- KV budget 借用和回收；
- S3 迁移与多模型 KV pressure 联动；
- 自动 packing report；
- 多阶段 RL E2E GPU-hour 对比报告。

---

## 12. 结论

GPU multiplexing 解决的是 **单卡内部小模型/中模型/低优先级模型的资源调度编排**，尤其适合 RL pipeline 内可信模型之间的 busy/idle 互补。vGPU 解决的是 **物理 GPU 到逻辑 GPU 的虚拟化、隔离和 quota**，它能让 GPU 申请更灵活，但不理解 LLM 模型、请求、token、KV cache、Dynamo ModelCard 或 RL phase，因此不能单独完成 multiplexing。

两者最合理的关系是协作：

```text
vGPU/MIG 提供资源边界和隔离
  + Kubernetes 提供 pod 与逻辑设备编排
  + Dynamo 提供模型可见性和路由
  + vLLM 提供 request/batch/KV runtime
  + GPU multiplexing 提供单卡内模型级调度
  + RL-Scaling 提供阶段感知策略
```

对于当前 RL-Scaling，下一步不是把 vGPU 当作替代方案，而是把它作为可选底层资源边界；真正的 S4 能力应落在 Dynamo/vLLM worker 内部：按模型画像、KV budget、queue、admission、SLO 和 RL phase 做 GPU-local scheduling，并与 S1/S2/S3 一起形成从整卡到请求再到单卡内模型的完整资源调度体系。