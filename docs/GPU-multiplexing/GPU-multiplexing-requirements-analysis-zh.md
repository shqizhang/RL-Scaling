# GPU Multiplexing 多模型单卡调度需求分析

> 角色视角：AI Infra / GPU 资源调度 / Kubernetes / Dynamo / RL 推理系统需求分析。
>
> 目标：在当前 RL-Scaling 已完成“单模型、基于 Kubernetes 与 Dynamo 的资源调度优化”基础上，进一步分析
> **GPU 单卡 multiplexing** 场景的业务需求、技术约束、方案选择、预期结果和验收标准，为后续实现
> multi-model single-GPU scheduling 提供清晰需求边界。

---

## 1. 需求背景

当前 RL-Scaling 的优化对象主要是单个模型在 Dynamo PD-disaggregated serving 下的 GPU 资源效率：

- S1：根据 RL rollout 阶段对 Kubernetes prefill/decode worker pool 做扩缩容；
- S2：通过 Dynamo ModelCard / WorkerSet 变更实现 decode 与 prefill 的原地角色切换；
- S3：通过在线请求迁移与 KV block-hold 协议合并 decoder 长尾请求。

这些方案解决的是 **同一个模型在不同推理阶段的 GPU 池比例失衡和尾部浪费**。但真实 RL 后训练 pipeline 往往不是单模型系统，而是多模型协同系统：

- policy / actor model 负责 rollout 生成；
- reward model 负责打分；
- reference model 或 critic model 参与 KL、advantage 或 value 计算；
- embedding / reranker / filter model 用于检索、筛选和质量控制；
- eval model 或 judge model 周期性评估策略质量。

### 1.1 vLLM 在 RL pipeline 中承担什么推理场景

vLLM 的核心价值是高吞吐、低延迟、支持 continuous batching 和 KV cache 管理的 LLM 推理。它并不负责
反向传播和参数更新；训练更新通常由 PyTorch/FSDP、DeepSpeed、Megatron 或 Ray-based trainer 完成。
在 RL pipeline 中，vLLM 主要出现在所有“需要大量前向推理或文本生成”的环节：

| RL 环节 | 是否适合使用 vLLM | 需要的模型 | 推理类型 | 资源特点 |
|---------|------------------|------------|----------|----------|
| Prompt sampling / 数据取样 | 否 | 无或轻量过滤模型 | CPU/数据管道 | 不消耗主要 GPU 推理资源 |
| Rollout generation | 是，最典型 | policy / actor model | 根据 prompt 生成 response | decode 长、KV cache 大、吞吐关键 |
| Reference logprob / KL | 可用，但不一定必须 | reference model | 对 prompt+response 计算 logprob | 不一定生成 token，但需要大批量前向 |
| Reward scoring | 常用 | reward model 或 LLM judge | 对 response 打分或比较 | 可批处理，阶段性突发 |
| Critic / value 估计 | 视算法而定 | critic / value model | value forward | PPO 常见，GRPO 可弱化或省略 critic |
| Advantage / return 计算 | 否 | 无 | 张量计算 | 通常不是 serving 推理问题 |
| Policy update | 否 | trainable actor | 反向传播与优化器更新 | 显存主要被梯度、优化器状态占用 |
| Evaluation | 是 | policy + eval/judge/reward model | 生成、打分、评估 | 周期性运行，适合预热或热加载 |
| Checkpoint sync / weight update | 间接相关 | policy inference replica | 更新 vLLM worker 权重 | 影响 rollout server 新旧权重一致性 |

因此，本文讨论的 GPU multiplexing 主要服务于 **RL 推理侧**，特别是 rollout generation、reward scoring、reference/KL
forward 和 evaluation。训练侧虽然也消耗 GPU，但它的资源形态是梯度、激活和优化器状态，不适合简单纳入 vLLM
serving worker 的单卡 multiplexing；更合理的方式是通过 RL phase signal 协调训练 GPU 与推理 GPU 的生命周期。

### 1.2 当下典型 RL 后训练全流程

以 RLHF/PPO 或 GRPO 类 pipeline 为例，一个完整周期通常如下：

```text
1. Prompt batch 准备
   -> 从数据集、replay buffer 或在线任务队列中采样 prompts

2. Policy rollout generation
   -> vLLM 承载 policy/actor inference
   -> 对每个 prompt 生成一个或多个 responses
   -> 这是最典型、最重的 vLLM 推理场景

3. Reward / verifier / judge scoring
   -> reward model、rule verifier 或 LLM judge 对 responses 打分
   -> 可以是小模型分类器，也可以是另一个 LLM 推理服务

4. Reference model logprob / KL 计算
   -> reference model 对生成结果计算 logprob
   -> PPO/RLHF 中常用于 KL penalty，GRPO 中也可能保留 reference 约束

5. Critic / value 估计（算法可选）
   -> PPO 通常需要 value model
   -> GRPO 类方法可不使用独立 critic，减少一个大模型常驻压力

6. Advantage / return 计算
   -> 聚合 reward、KL、value，生成训练样本权重

7. Policy training update
   -> trainer 做反向传播，更新 actor 权重
   -> 这一步通常不使用 vLLM，而使用训练框架

8. Checkpoint / weight sync
   -> 将新 policy 权重同步给 rollout vLLM workers
   -> 可能涉及热更新、重启、权重广播或版本切换

9. Evaluation / validation
   -> 使用 policy 生成评测集答案
   -> reward/judge/eval model 打分
   -> 输出指标后进入下一轮
```

这条流水线的关键特征是：每一阶段需要的模型不同，且 busy/idle 呈周期性。rollout 阶段 policy 最忙；scoring
阶段 reward/judge 最忙；training update 阶段 vLLM inference workers 可能空闲；evaluation 阶段 eval/judge
模型短暂繁忙。GPU multiplexing 的需求正是从这个阶段性互补中产生的。

### 1.3 模型显存规模与 RTX 3090 24GB 的关系

当前单机实验环境常见 GPU 是 RTX 3090，显存为 24GB。对 LLM 推理来说，24GB 不是“可全部用于权重”的空间，
还要预留 KV cache、CUDA runtime、allocator 碎片、通信 buffer、vLLM block manager 和安全余量。下面是粗略估算，
用于需求分析和方案选择，不替代真实 profiling：

| 模型规模 | BF16/FP16 权重 | INT8 权重 | INT4 权重 | 在 3090 24GB 上的含义 |
|----------|----------------|-----------|-----------|------------------------|
| 0.5B | 约 1GB | 约 0.5GB | 约 0.25GB | 很适合与其他模型共驻 |
| 1B | 约 2GB | 约 1GB | 约 0.5GB | 适合 embedding/filter/reward 小模型共驻 |
| 3B | 约 6GB | 约 3GB | 约 1.5GB | 可共驻，但要限制 KV 和并发 |
| 7B | 约 14GB | 约 7GB | 约 3.5GB | BF16 可单模型推理；与其他模型共驻空间有限 |
| 14B | 约 28GB | 约 14GB | 约 7GB | BF16 超过 3090；量化后可考虑，但 KV 空间紧张 |
| 32B | 约 64GB | 约 32GB | 约 16GB | BF16/INT8 不适合单 3090；INT4 仍需非常保守 |
| 70B | 约 140GB | 约 70GB | 约 35GB | 单 3090 不可行，应走多卡并行或远端独占服务 |

还需要额外考虑 KV cache。以 7B 级模型为例，BF16 权重约 14GB，加上 vLLM 运行时、CUDA context、临时 workspace
和安全余量后，留给 KV cache 的空间可能只有数 GB。长上下文、大 batch 或多并发 decode 会迅速吃掉这部分空间。
因此：

- **7B BF16 policy on 3090**：适合作为单模型 rollout worker；可以做 S2/S3，但不适合再常驻多个中型模型；
- **7B INT4/INT8 policy on 3090**：释放出更多空间，可尝试共驻 1B/3B reward 或 embedding，但要做质量验证；
- **14B BF16 policy on 3090**：权重本身已超过单卡，不应进入单卡 multiplexing；
- **14B INT4/INT8**：可能单卡可跑，但 KV budget 很紧，适合低并发或离线 scoring，不适合作为高并发 rollout；
- **32B/70B**：应使用 tensor parallel、多卡 worker pool 或外部大模型服务，单卡 multiplexing 只处理其周边小模型。

这意味着后续需求分析必须把模型分成四类：

| 类别 | 判定标准 | 推荐处理 |
|------|----------|----------|
| 小模型 | 权重小于约 3GB，KV 需求低 | 优先共驻，作为 multiplexing MVP 目标 |
| 中模型 | 权重约 3GB 到 10GB，阶段性使用 | 量化、热加载、限制并发后共驻 |
| 单卡主模型 | 7B BF16 或 14B 量化等接近 3090 上限 | 独占或半独占，低优先级模型只能 opportunistic 复用 |
| 超单卡模型 | BF16 权重或最小运行预算超过 24GB | 多卡并行、远端服务或独立 GPU pool，不纳入单卡共驻 |

这个约束也解释了为什么 GPU multiplexing 不是简单“显存分片”。在 3090 这类 24GB 消费级 GPU 上，真正可落地的
MVP 更应该是：一个 7B 或 3B 主模型旁边共驻 0.5B/1B/3B 的 reward、embedding、filter 模型，或在 policy
低负载阶段热加载 reward/eval 模型；而不是试图把多个 7B/14B BF16 模型同时塞进一张卡。

这些模型的请求到达、显存需求、延迟目标、阶段优先级并不一致。如果仍按“一模型一组 GPU worker”独占部署，会出现新的浪费：

```text
GPU-0: policy model rollout 阶段很忙
GPU-1: reward model 在 rollout 阶段空闲
GPU-2: embedding/filter model 低频请求，长期低利用
GPU-3: eval model 只在评估窗口短暂忙碌
```

Kubernetes 只能看到这些 GPU 都已经被 pod 申请，无法理解“某个模型当前 idle、另一模型当前 busy”的细粒度事实。因此，需要引入 **GPU multiplexing**：在同一张物理 GPU 内部，对多个模型、多个请求队列和多个 KV cache budget 做运行时调度。

---

## 2. 业务目标

本需求的业务目标不是单纯“把更多模型塞进一张卡”，而是在保证 RL 推理关键路径正确性和 SLO 的前提下，提高 GPU-hour 使用效率。

### 2.1 核心目标

1. **提升多模型 RL pipeline 的 GPU 利用率**

   将不同阶段、不同模型的 busy/idle 峰谷互补起来，减少独占部署导致的空闲卡。

2. **降低模型冷启动和阶段切换成本**

   对高频或下一阶段即将使用的模型，尽量保持热驻留或半热状态，避免每个阶段都重新调度 pod、加载权重、注册 discovery。

3. **提高单卡内部调度粒度**

   将资源调度粒度从 Kubernetes 的整卡级别细化到模型、请求队列、KV cache、并发槽位和优先级。

4. **与当前 S1/S2/S3 形成一致控制面**

   GPU multiplexing 应作为 S4 原语，与已有 Kubernetes scaling、PD role switch、request consolidation 协同，而不是另起一套割裂调度系统。

### 2.2 非目标

1. 不以强多租户安全隔离为第一目标。跨组织、跨不可信租户的硬隔离应优先使用 MIG/vGPU/独立节点。
2. 不要求第一阶段支持所有超大模型在单卡上运行。超过单卡容量的模型应通过路由到多卡部署、量化、分片或热加载策略处理。
3. 不替代 Kubernetes scheduler。Kubernetes 仍负责节点级、pod 级、整卡级调度；multiplexing 负责 worker 内部的 GPU-local 调度。
4. 不牺牲 policy rollout 关键路径的正确性。低优先级模型只能使用被授予的剩余资源，不能破坏主模型 SLO。

---

## 3. 需要完成的任务

### 3.1 需求侧任务

1. 定义多模型单卡复用的目标模型集合：policy、reward、reference、embedding、filter、eval 等。
2. 为每个模型定义服务等级：关键路径、近实时、后台批处理、可延迟任务。
3. 为每个模型定义资源画像：权重大小、量化格式、KV cache 需求、最大上下文、典型并发、峰值 QPS。
4. 为每个 RL 阶段定义模型优先级：rollout、reward scoring、training、evaluation、idle/prewarm。
5. 定义冲突处理策略：当显存不足、队列堆积、SLO 下降或 GPU pressure 过高时，优先保护哪些模型。

### 3.2 控制面任务

1. 扩展 RL-Scaling controller，使其能理解 `phase × model × role × GPU-local resource`。
2. 建立 GPU-local placement planner，判断哪些模型可以共驻同一 GPU。
3. 建立 per-model admission controller，控制每个模型是否允许接收新请求。
4. 建立 per-model KV budget 和 max concurrency 策略。
5. 将 S1/S2/S3/S4 决策放入同一调度顺序，避免策略互相打架。

### 3.3 Worker/runtime 任务

1. 在一个 worker pod 内支持多个 model endpoint 或多个 ModelCard。
2. 在 worker 内维护 per-model request queue。
3. 在 worker 内维护 per-model memory/KV budget。
4. 支持动态调整 queue weight、max concurrency、admission 状态和模型热驻留状态。
5. 暴露 sidecar API，供 RL-Scaling controller 下发 multiplexing 策略。

### 3.4 观测与验证任务

1. 采集每模型 tokens/s、queue depth、latency、active requests。
2. 采集每模型 KV block 使用量和显存预算占用。
3. 采集整卡 SM utilization、HBM bandwidth、显存占用和 OOM 风险指标。
4. 生成每个 RL 阶段的 GPU busy/idle 报告。
5. 建立 E2E 测试，证明 multiplexing 提高 GPU 利用率且不破坏主模型 SLO。

---

## 4. 关键限制条件与需求分析

### 4.1 模型大小不一致

多模型场景中，模型大小差异是首要约束。典型情况包括：

| 模型类型 | 可能大小 | 特点 | 调度含义 |
|----------|----------|------|----------|
| policy model | 7B/14B/32B/70B | rollout 关键路径，高优先级 | 优先保证显存和 KV budget |
| reward model | 1B/3B/7B/13B | scoring 阶段突发，常可批处理 | 适合低谷热驻留或阶段性加载 |
| reference model | 与 policy 接近 | 可能与 policy 共享 tokenizer/结构 | 若太大，不适合和 policy 单卡共驻 |
| embedding/filter | 0.1B/1B/3B | 请求短、显存小 | 最适合单卡 multiplexing |
| judge/eval model | 7B+ | 周期性使用 | 可热加载或独立部署 |

需求结论：模型不能只按“数量”调度，必须按 **显存足迹 + 阶段优先级 + 请求形态 + SLO** 综合调度。

### 4.2 模型超过单卡容量时怎么办

如果模型权重本身已经超过单卡容量，不能把它纳入“单卡共驻”集合。此时有几类方案。

#### 方案 A：模型并行 / 显存分片

适用条件：模型是关键路径大模型，例如 70B policy 或 reference model。

做法：使用 tensor parallel、pipeline parallel、expert parallel 或其他模型并行机制，把模型切到多张 GPU 上。

优点：可以服务超单卡模型，是大模型推理的常规方式。

缺点：它解决的是“单模型跨卡运行”，不是“多模型单卡复用”。通信开销和调度复杂度更高。

需求结论：超过单卡容量的主模型应进入 **multi-GPU placement pool**，不应强行纳入 single-GPU multiplexing。multiplexing 可以作用在它的周边小模型或同节点剩余 GPU 上。

#### 方案 B：量化后共驻

适用条件：模型精度允许降低，例如 reward/filter/eval 模型可接受 INT8/FP8/INT4。

做法：对模型做量化，降低权重显存，再评估是否可与其他模型共驻。

优点：实现成本相对低，能显著降低权重显存。

缺点：可能影响 reward 排序质量或 eval 稳定性，需要质量验证。

需求结论：量化是中小模型进入 multiplexing pool 的优先手段，但必须把精度影响纳入验收标准。

#### 方案 C：热加载 / 冷加载

适用条件：模型不是持续高频使用，而是阶段性使用，例如 eval model、judge model。

做法：模型不常驻 GPU，而是在阶段开始前预加载，阶段结束后卸载或转入 CPU/NVMe 缓存。

优点：节省 GPU 显存，适合低频模型。

缺点：加载延迟可能是秒级到分钟级，不适合突然到达的在线请求。

需求结论：热加载适合 **可预测阶段**，尤其 RL pipeline 已知 `eval_start` 或 `reward_scoring_start` 的场景。它需要与 RL signal 结合做提前 prefetch。

#### 方案 D：独立部署，不参与共驻

适用条件：模型大、SLO 严格、请求高频或隔离要求强。

做法：仍然使用独立 pod / 独立 GPU pool，通过 Dynamo routing 访问。

优点：风险最低，性能最可预测。

缺点：GPU 利用率可能较低。

需求结论：不是所有模型都应该 multiplex。系统必须允许模型被标记为 `exclusive`，避免为了复用而破坏稳定性。

### 4.3 权重显存与 KV cache 的冲突

LLM 推理中，KV cache 会随并发和生成长度增长。即使两个模型权重能放进一张卡，也不代表它们能安全共驻。

约束公式应从简单权重相加升级为：

```text
sum(weights_resident)
  + sum(kv_budget_per_model)
  + runtime_overhead
  + communication_buffer
  + fragmentation_margin
  + emergency_reserve
  <= gpu_memory_capacity
```

需求结论：

- 每个模型必须声明 `min_kv_budget` 和 `max_kv_budget`；
- scheduler 可以在安全范围内动态借用未使用 KV budget；
- 主模型必须拥有不可被抢占的 reserved KV budget；
- 当 KV pressure 超过阈值时，低优先级模型应停止 admission、迁移请求或降级 max_tokens。

### 4.4 延迟 SLO 与吞吐目标冲突

多模型共驻会带来排队和干扰。比如 reward batch 吞吐很高，但可能拖慢 policy decode 的 token latency。

需求结论：

- 每个模型必须有 `priority_class`；
- policy rollout decode token latency 应作为最高优先级保护指标；
- reward/eval/offline 任务默认使用 opportunistic scheduling；
- 当主模型 p95/p99 超阈值时，自动降低后台模型 queue weight 或暂停 admission。

### 4.5 模型加载时间与阶段预测

热加载能节省显存，但会引入加载延迟。RL 场景的优势是阶段可预测：controller 通常知道 rollout、scoring、training 的阶段边界。

需求结论：

- 对可预测阶段使用 `preload_before_phase` 策略；
- 对不可预测在线请求使用常驻或独立部署；
- 对低频 eval/judge 模型允许 lazy load，但请求入口必须能返回排队状态或触发预热；
- 模型加载时间应进入调度器成本模型，而不是事后观察。

### 4.6 模型隔离与故障域

单卡多模型复用会扩大故障影响面。一个模型 OOM、kernel error 或异常请求可能影响同卡其他模型。

需求结论：

- 同一 RL pipeline 内可信模型优先共驻；
- 不可信租户之间不做 runtime-level multiplexing，应使用 MIG/vGPU/独立 GPU；
- worker 需要 emergency unload / disable model API；
- OOM 前应有 admission guard，避免依赖 CUDA OOM 作为控制机制。

### 4.7 Dynamo discovery 与多 ModelCard 一致性

Dynamo 通过 ModelCard 和 WorkerSet 暴露 worker 能力。多模型单卡 worker 可能同时发布多个 ModelCard。

需求结论：

- 一个 worker pod 可以注册多个 model endpoint；
- 每个 endpoint 的可见性必须能动态开启/关闭；
- admission disabled 时，ModelCard 是否撤回需要明确策略：
  - 短暂 queue pressure：不撤回，只返回 backpressure；
  - 长时间不可服务：撤回 ModelCard，避免 router 继续派发；
  - 阶段性卸载模型：撤回 ModelCard 并释放显存。

### 4.8 Kubernetes 资源模型限制

Kubernetes 默认 GPU 是整卡资源，不理解单卡内多模型分配。

需求结论：

- 第一阶段不修改 Kubernetes scheduler；
- multiplexing worker 仍申请整卡 GPU；
- worker 内部自行管理模型共驻；
- 可通过 CRD status 暴露 `gpu_local_capacity`，供 RL-Scaling controller 决策；
- 后续可考虑 scheduler extender 或 device plugin 扩展，但不作为 MVP 前置条件。

### 4.9 vGPU/MIG/MPS 的适用边界

需求结论：

- MIG 适合硬隔离和可预测容量切分，但不适合频繁阶段变化；
- vGPU 适合虚拟化环境或强租户隔离，但不了解 LLM 请求语义；
- MPS 可作为多进程共享 GPU 的底层手段，但不能替代模型级调度；
- 本需求优先选择 Dynamo/vLLM runtime-level multiplexing，因为它知道 ModelCard、request、KV cache 和 RL phase。

---

## 5. 用户故事与验收标准

### 5.1 Story 1：小模型共驻

作为平台工程师，我希望 reward、embedding、filter 等中小模型可以共驻在一张 GPU 上，从而减少低利用率独占卡。

验收标准：

- 给定模型显存画像，planner 能判断共驻组合是否合法；
- 共驻后不会触发 OOM；
- 每个模型可独立开启/关闭 admission；
- 主模型或高优先级模型延迟不超过设定阈值。

### 5.2 Story 2：policy 关键路径保护

作为 RL 训练负责人，我希望 policy rollout 阶段始终优先于 reward/eval 后台任务，避免资源复用破坏采样吞吐。

验收标准：

- rollout_start 后 policy queue weight 自动提高；
- policy p95 token latency 超阈值时，低优先级模型自动暂停 admission；
- 后台任务恢复必须在 policy pressure 下降后发生。

### 5.3 Story 3：阶段性热加载

作为平台工程师，我希望 eval/judge 模型不长期占用显存，但能在 eval 阶段前被提前加载。

验收标准：

- controller 能根据 eval_start 预测信号提前触发 preload；
- preload 完成后 Dynamo ModelCard 可见；
- eval 结束后模型可卸载并释放显存；
- 加载失败时不会影响 policy worker。

### 5.4 Story 4：超单卡模型处理

作为系统设计者，我希望超过单卡容量的模型不会被错误放入 multiplexing pool，而是进入合理的多卡或独占部署路径。

验收标准：

- planner 能识别 `weights + min_kv_budget > single_gpu_capacity`；
- 此类模型被标记为 `requires_multi_gpu` 或 `exclusive`；
- 系统给出推荐方案：tensor parallel、量化、独立部署或热加载；
- 不会生成不可执行的共驻计划。

### 5.5 Story 5：与 S2/S3 联动

作为调度系统，我希望在单卡复用不足以解决资源压力时，能继续调用已有 S2/S3 原语。

验收标准：

- 当单卡 KV pressure 高且目标 GPU 有容量时，可触发 S3 请求迁移；
- 当 prefill/decode 池比例失衡时，可触发 S2 role switch；
- 当所有热资源不足时，才触发 S1 Kubernetes scaling；
- 决策日志能说明选择顺序和原因。

---

## 6. 推荐方案

### 6.1 总体架构

```text
RL trainer / rollout controller
        │ phase signal
        ▼
RL-Scaling Controller
        ├── S1 Kubernetes replica planner
        ├── S2 PD role switch planner
        ├── S3 request consolidation planner
        └── S4 GPU multiplexing planner
                │ policy
                ▼
Multi-model worker sidecar
        ├── model admission API
        ├── queue weight API
        ├── KV budget API
        ├── preload/unload API
        └── metrics API
                │
                ▼
GPU-local runtime scheduler
        ├── per-model queues
        ├── per-model KV budget
        ├── model registry
        ├── batch scheduler
        └── Dynamo ModelCard publisher
```

### 6.2 决策优先级

推荐采用从细到粗的控制顺序：

1. **先调单卡内部策略**：queue weight、admission、KV budget、max concurrency。
2. **再调请求位置**：通过 S3 迁移长尾或低优先级请求。
3. **再调 worker 角色**：通过 S2 在 prefill/decode 或其他 endpoint 之间切换能力。
4. **最后调 Kubernetes 副本**：通过 S1 扩缩整卡容量。

这样可以把最快、最便宜的动作放在前面，把最慢、最贵的 pod 级伸缩放在最后。

### 6.3 模型放置策略矩阵

| 模型情况 | 推荐策略 | 不推荐策略 | 原因 |
|----------|----------|------------|------|
| 小模型 + 低频 + 可延迟 | 常驻共驻或低优先级 queue | 独占 GPU | 独占浪费高 |
| 中模型 + 阶段性突发 | 阶段前热加载 + 阶段内提高权重 | 长期独占 | RL 阶段可预测 |
| 大模型但量化可接受 | 量化后评估共驻 | 直接共驻 FP16 | 权重显存过大 |
| 超单卡关键模型 | 多卡并行或独占 pool | 单卡 multiplexing | 物理容量不满足 |
| 强隔离/不可信模型 | MIG/vGPU/独立 GPU | runtime 共驻 | 故障和安全边界不足 |
| 长尾 decode 请求 | S3 迁移/合并 | 等待自然完成 | GPU tail waste 高 |

### 6.4 MVP 范围

第一版建议只实现“可信同 pipeline 内的小/中模型复用”，避免一开始就处理所有复杂情况。

MVP 包含：

- 静态模型画像配置；
- per-model admission；
- per-model queue weight；
- per-model max concurrency；
- 简单 KV budget；
- Dynamo 多 ModelCard 注册/撤回；
- RL phase 驱动策略切换；
- 与 S1/S2/S3 的决策顺序集成。

MVP 不包含：

- 自动模型并行切分；
- 跨不可信租户隔离；
- 任意模型动态下载；
- 复杂抢占式 GPU kernel 调度；
- 修改 Kubernetes scheduler。

---

## 7. 预期结果

实现后，系统应得到以下结果：

1. **GPU-hour 降低**

   多个低利用模型可共用一张 GPU，减少独占卡数量。

2. **阶段切换更平滑**

   reward/eval/filter 模型可根据 RL 阶段热加载或调整优先级，不必频繁冷启动 pod。

3. **主模型 SLO 可控**

   policy rollout 关键路径拥有 reserved budget 和最高优先级，后台任务只使用剩余容量。

4. **调度动作更细**

   除了 replica 和 role，controller 还能调 queue、KV budget、admission、model residency。

5. **与现有方案统一**

   S4 multiplexing 和 S1/S2/S3 一起组成分层资源调度系统，而不是替代已有实现。

---

## 8. 度量指标

### 8.1 效率指标

- GPU utilization；
- GPU allocated time vs useful compute time；
- 每阶段 GPU-hour；
- 每模型 tokens/s；
- 每模型 queue idle time；
- 单卡共驻模型数。

### 8.2 质量指标

- policy rollout p95/p99 latency；
- reward scoring throughput；
- eval job completion time；
- 请求失败率；
- OOM 次数；
- ModelCard 注册/撤回收敛时间。

### 8.3 调度指标

- admission reject count；
- queue weight adjustment count；
- model preload/unload latency；
- KV budget pressure；
- S3 migration count；
- S2 role switch count；
- S1 scaling count。

---

## 9. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| 显存估算不准 | OOM 或主模型失败 | 加 emergency reserve、dry-run admission、保守 KV budget |
| 后台模型干扰主模型 | rollout latency 上升 | priority class、SLO guard、自动暂停低优先级 admission |
| 热加载太慢 | 阶段开始时模型不可用 | 基于 RL signal 提前 preload，记录加载时间成本 |
| 多 ModelCard 状态不一致 | router 派发到不可服务 endpoint | ModelCard 与 admission 状态绑定，长时间不可服务时撤回 |
| 过度复用导致调度复杂 | 难以 debug | MVP 限定模型集合，所有策略输出结构化 decision log |
| 超大模型被错误共驻 | 计划不可执行 | placement planner 强制校验 `weights + min_kv_budget` |

---

## 10. Backlog 拆分

### Epic 1：模型画像与放置规划

- 定义 `ModelResourceProfile`：weights、kv、workspace、priority、SLO；
- 实现 single-GPU fit check；
- 输出共驻推荐和拒绝原因；
- 标记 `shared`、`exclusive`、`requires_multi_gpu`、`load_on_demand`。

### Epic 2：Dynamo 多模型 worker 表达

- 一个 worker 发布多个 ModelCard；
- endpoint 级 admission enable/disable；
- ModelCard 注册/撤回与 worker 内状态一致；
- 暴露 active models 和 serving capacity。

### Epic 3：GPU-local scheduler

- per-model queue；
- queue weight；
- max concurrency；
- KV budget；
- priority/SLO guard。

### Epic 4：RL-Scaling controller 集成

- phase-aware policy；
- S1/S2/S3/S4 决策顺序；
- decision log；
- failure fallback。

### Epic 5：测试与验证

- 小模型共驻单测；
- KV budget 压力测试；
- policy SLO 保护测试；
- preload/unload 测试；
- 多阶段 RL E2E；
- GPU-hour 对比报告。

---

## 11. 结论

GPU multiplexing 的需求本质是：在当前 RL-Scaling 已能调度“单模型的 pod、worker role、request/KV”之后，进一步把资源调度粒度下沉到 **单张 GPU 内部的模型、队列、并发和 KV budget**。

合理方案不是简单显存分片，也不是把所有模型都强行放到一张卡上，而是按模型画像分类处理：

- 小模型和低频模型：优先共驻；
- 阶段性模型：热加载和阶段优先级；
- 可量化模型：量化后进入共驻候选；
- 超单卡模型：多卡并行或独占部署；
- 强隔离模型：MIG/vGPU/独立 GPU；
- 长尾请求：继续使用 S3 consolidation；
- prefill/decode 比例失衡：继续使用 S2 role switch；
- 总容量不足：最后使用 S1 Kubernetes scaling。

这样形成的完整策略是：

```text
GPU-local multiplexing for fine-grained efficiency
  + request consolidation for tail cleanup
  + role switch for PD ratio reshaping
  + Kubernetes scaling for total capacity
  = RL-aware multi-model GPU resource scheduling
```

这条路线能把当前“单模型资源调度优化”自然扩展为“多模型、单卡复用、跨阶段协同”的 AI Infra 资源调度系统。