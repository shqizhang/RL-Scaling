# Evaluation Report：RL-Scaling Final Report 学术写作与证据评估

> 评估对象：`final-report.md`、`final-report.lex`，以及 `FINAL-phased-merged-20260720/` 下的合并结果、逐场景摘要与运行日志。  
> 参考材料：`report-indicator.md`、`mid-report.pdf`、`sample-report-From Fault Localization to Fault Correction.pdf`、项目技术文档和当前实现。  
> 评估结论：**这是一份技术内容扎实、工程可复现性较强的项目报告，但若按学术论文标准提交，当前仍属于 Major Revision（需要重大修改）。** 最大问题不是语言，而是若干核心结论与实验实际发生的动作、指标定义和实现边界没有严格对齐。

## 1. 总体评价

报告成功抓住了 RL rollout/inference 的两个真实问题：不同阶段之间的 Prefill/Decode 资源失衡，以及 Decode 长尾阶段的 GPU 碎片化。S2 role switch 和 S3 request consolidation 的动机、机制和安全约束也讲得比较完整。与只展示“功能可用”的工程总结相比，本报告已经进一步提供了固定 workload、重复实验、原始日志和 GPU-seconds 等量化结果，这是明显的进步。

不过，按学术写作的核心要求——**可验证、可复现、定义准确、主张不超过证据**——当前版本仍有几个会影响结论可信度的问题：

1. 主性能实验中的 S3 和 Mixed 三次运行均为 `s3_migrated_requests = 0`，因此 44.5% 的下降证明的是尾段空闲 decoder 提前释放，而不是 active request migration/consolidation 的性能收益。
2. 报告把“allocated GPU time”多处写成 GPU utilization、occupancy 或 busy time，但当前数据并没有测量 SM utilization 或真实计算时间。
3. A/B/C 是按请求发射时间划分的 cohort，实际执行窗口相互重叠，不能称为互不重叠的系统阶段，也不能把 cohort GPU-seconds 简单相加。
4. `business_wall == T_batch` 在测试脚本中是由相同赋值产生的，不是独立测量得到的验证结果。
5. S3 当前没有实现迁移请求的 client stream reattachment，因而不能声称客户端得到“完全连续、唯一的逻辑流”。
6. n=3 的统计分析缺少 p-value、置信区间、效应量和实验顺序控制，超大的 t 值不应被表述为广泛可推广的强证据。

因此，当前报告更准确的定位是：

> **一份机制实现与阶段性性能证据较强的系统研究报告；它证明了 S2/S3 worker-side 机制、S2 的正确性，以及 tail-aware idle decoder reclamation 的资源节省，但尚未充分证明 active S3 migration 的 batch-level 性能收益，也尚未证明生产环境中的端到端客户端无损迁移。**

### 1.1 分项评分（按常见系统论文标准）

| 维度 | 评分（10 分） | 评价 |
|---|---:|---|
| 研究问题与动机 | 8.5 | 问题重要，场景明确，与 RL rollout 的突发和长尾特征相关 |
| 方案设计 | 8.0 | S2/S3 互补，机制与安全约束有深度 |
| 实现完整度 | 7.0 | worker-side 较完整；S3 client stream reattachment 仍缺失 |
| 实验设计 | 6.0 | 有五场景、固定 workload 和重复运行，但 session、顺序、phase 定义存在混杂 |
| 统计严谨性 | 5.0 | n=3 可作 pilot study，但不足以支持强推断，统计报告也不完整 |
| 主张—证据一致性 | 4.5 | S3 归因、GPU 指标术语和 stream continuity 是主要风险 |
| 可复现性 | 8.0 | 原始日志、JSON、脚本和配置保留充分，是明显优点 |
| 写作结构与可读性 | 7.5 | 主线清晰，但工程变更记录与论文正文混合，部分重复和绝对化表述较多 |
| 交付物完整性 | 5.0 | LaTeX 源文件引用的图片、样式和附件在当前目录中不完整，无法确认可独立构建 |
| **综合** | **6.5** | **工程报告较强；学术论文需要重大修改后再提交** |

## 2. 优点在哪里

### 2.1 研究问题选择准确，具有系统研究价值

报告没有把问题简化成普通的 Kubernetes replica scaling，而是区分了三种时间尺度：S1 的容量预热/回收、S2 的 Prefill/Decode role 重分配、S3 的 Decode 长尾整理。这一分层是合理的，因为三种机制解决的资源浪费来源不同：

- S1 解决 batch 到来前后的总体容量问题；
- S2 解决同一批次中 Prefill 和 Decode 需求随时间变化的问题；
- S3 解决 Decode 尾段请求分散导致的 GPU 碎片问题。

这种问题分解使论文具有清楚的研究叙事，而不是一组互不相关的工程功能。

### 2.2 S2/S3 方案具有较好的机制深度

报告对 role switch 的生命周期、ModelCard 注册、NIXL/KV 状态重置、请求 drain，以及 S3 的 block-hold、complete/rollback 协议进行了较细致的说明。尤其是 S3 中“源端在目标端确认接管前继续持有 KV blocks”的不变量，是值得保留的核心设计点。它体现的不是简单 HTTP 调用，而是对迁移失败、超时和回滚条件的系统性考虑。

### 2.3 实验材料保留充分，可复现性优于普通课程报告

`FINAL-phased-merged-20260720/` 中保留了：

- 合并数据 `consolidated-data.json`；
- 五个场景的逐次运行摘要；
- controller、worker 和 workload 日志；
- 固定 workload manifest、请求数和 cohort 发射时间；
- 结果汇总与命令说明。

这使评审者能够从论文结论反查到单次运行，而不是只能接受报告中的汇总表。原始证据链是本项目最应保留的优点之一。

### 2.4 不只报告成功结果，也承认 S2 的负面或不确定结果

报告注意到了 old session 与 new session 的性能漂移，并没有简单地把 S2 的表面延迟变化全部归因于策略。承认 S2 latency 目前 inconclusive，是符合学术诚信的做法。报告也提到了策略收益与输出长度、质量之间可能存在 trade-off，这比只给出“速度提升百分比”更成熟。

### 2.5 已经开始区分资源效率和延迟

使用 allocated GPU-seconds、平均分配 GPU 数量和 batch makespan，比仅用 throughput 更适合研究弹性调度。尤其对于“提前释放资源”类优化，batch latency 不一定下降，但资源暴露时间可以下降。报告意识到这一点，是方案评估设计中的正确方向。

### 2.6 文稿主线和视觉样式已有论文雏形

最终报告采用 Abstract、Introduction、Related Work、Design、Implementation、Evaluation、Limitations、Conclusion 的常见结构，与参考样例和 midterm report 的双栏学术风格基本一致。相关工作对比表、贡献列表、实现图和结果表有助于快速理解论文。整体并不是从零开始重写，而是需要进行证据校准和结构收敛。

## 3. 不足在哪里

以下问题按严重程度排序。Critical 项需要在正式提交前修正，否则评审者可能认为核心结论没有被实验支持。

### 3.1 Critical：S3 的核心性能归因与实际运行不一致

合并数据中，S3-only 和 Mixed 的六次主性能运行都记录为：

| 场景 | Run 1 | Run 2 | Run 3 |
|---|---:|---:|---:|
| S3-only `s3_migrated_requests` | 0 | 0 | 0 |
| Mixed `s3_migrated_requests` | 0 | 0 | 0 |

controller 日志中的 S3 plan 也显示 `source_active: 0`、`request_count: 0`，随后执行的是空闲 decoder drain/scale-down。因此，报告中的 44.5% 可以支持下面这个结论：

> Tail-aware idle decoder reclamation reduced allocated decode GPU-seconds in the C-tail cohort by 44.5%.

但它不能支持：

> Active in-flight request consolidation reduced tail-phase GPU occupancy by 44.5%.

单独的 connector microbenchmark 确实展示了约 188 ms、109 blocks、1688 tokens 的迁移机制，但这属于 mechanism evidence，不是五场景主实验中的 batch-level efficacy evidence。二者必须分开写。

**建议：**要么降低主张，明确 44.5% 来自 empty-worker release；要么重新运行一个能稳定满足 `migrated_requests > 0` 的 S3 A/B 实验，对比 migration enabled/disabled，并报告迁移开销、释放提前量和用户请求结果。

### 3.2 Critical：客户端无损续流的表述超出当前实现

报告把 `previously_emitted_tokens` 解释成“客户端最终收到 exactly one logical stream”，但当前 sidecar 的迁移重提交路径会在目标 engine 上 drain-and-discard；原客户端连接不会自动重新挂接到目标请求。也就是说，现有实现证明了 engine-side takeover、KV/请求状态处理和资源释放机制，但没有证明 transparent client stream handoff。

因此，下面的表述需要删除或改写：

- “客户端收到唯一且连续的逻辑流”；
- “S3 已经实现用户可见的零损失迁移”；
- 用总体 100% valid 证明 migrated-stream continuity。

建议准确写为：

> The current prototype validates engine-side request takeover and resource reclamation. Transparent reattachment of the original client stream remains future work.

### 3.3 Critical：A/B/C 不是互不重叠的系统 phase

workload 在 `t=0` 发射 A，在 `t=22 s` 发射 B，在 `t=40/43/46 s` 发射 C。原始运行中 A 的完成窗口经常超过 22 s，因此 A 与 B 重叠；S2/Mixed 中 B 也可能与 C 重叠。当前 `per_phase_metrics` 使用每个 cohort 内最早开始到最晚结束的窗口，所以这些窗口也可能互相重叠。

这带来三个问题：

1. A/B/C GPU-seconds 不能相加，否则会重复计算重叠时间；
2. 一个 cohort 窗口中的 GPU allocation 也会服务其他 cohort，不能完全归因于该 cohort；
3. “A prefill wall” 实际是 A 请求从发射到全部完成的 end-to-end cohort completion window，不是纯 prefill latency。

**建议：**全文将 A/B/C 称为 request cohorts，而不是 non-overlapping phases。若要做 phase 分析，应使用不重叠的 wall-clock bins，或直接记录 TTFT/prefill latency、TPOT/decode time、in-flight request 数、每 worker active sequences 和 replica step trace。

### 3.4 Critical：GPU utilization/occupancy 的指标名称不准确

当前 `decode_gpu_s` 来源于 `spec_decode_allocated_seconds`，`avg_decode_gpus = decode_gpu_s / T_batch`。它们描述的是 **allocated/provisioned decode GPU exposure**，而不是 GPU SM utilization、真实 busy time、计算时间或能耗。

报告虽然定义了 `U_GPU = T_compute / T_allocated`，但并没有独立测得 `T_compute`。因此，以下词语应系统替换：

- GPU utilization → allocated GPU exposure / allocation efficiency；
- GPU occupancy → allocated decode GPU count；
- busy GPU-seconds → allocated GPU-seconds。

如果希望研究真实利用率，应增加 DCGM/NVML 指标，例如 SM active、tensor active、memory bandwidth、HBM usage、power，以及按 pod/worker 对齐的采样时间线。

### 3.5 Major：`business_wall == T_batch` 不是独立实验证据

在合并测试使用的脚本中，`business_wall_s` 直接赋值为 `t_batch`，同时 `overhead_vs_tbatch_s` 被设为 0。因此，两者相等说明它们使用相同的边界定义，而不是通过两套独立计时证明“完全没有 harness/gate contamination”。

更准确的说法是：

> The reported business wall and T_batch share the same request-boundary definition, which excludes explicit pre-run gate waits by construction.

如果要独立验证，应分别记录 process wall、gate wait、setup/teardown、request-active wall，并在时间线上展示四者关系。

### 3.6 Major：S1 结果混合了容量基线和弹性策略效果

1P1D 与 static 2P2D 的比较证明了更多 Prefill/Decode 容量可以减少 makespan，但不等价于证明 S1 autoscaling policy 的收益。它没有独立测量 T_batch 内的 signal-to-ready、scale-up latency、warm-up GPU cost、scale-down completion 和稳定性。

建议把这一结果命名为 **capacity/topology baseline**。S1 policy 应单独做事件驱动实验：记录 trainer signal、DGDSA patch、pod ready、ModelCard ready、first request served、scale-down requested 和 GPU released 的时间戳。

### 3.7 Major：控制器和 S2 生命周期图与当前代码不完全一致

报告把控制器描述成单一的 `IDLE → WARM_UP → REBALANCE → CONSOLIDATE → DRAIN` 状态机。当前实现更接近：S3、S2、S1 三个控制模块按顺序在统一 loop 中决策，其中 S1 自身的状态是 `IDLE → WARM_UP → ACTIVE → COOL_DOWN`。因此，现有图会让读者误以为 S2/S3 是 S1 状态机里的串行状态。

S2 图中的执行顺序也较旧。当前实现重点是先 cordon/unregister，再 flush/drain/quiesce，然后 sleep、清理/重配 NIXL/KV、设置新 role、register/wake 和发布 endpoint/event。建议直接根据当前代码重绘，不要用概念性八步图替代真实顺序。

### 3.8 Major：统计报告不足以支持强推断

每个场景只有三次运行。n=3 可以作为系统原型的 pilot evaluation，但报告 t-test 时至少应给出：

- mean ± SD；
- paired difference 的 95% CI；
- `t(df=2)=...` 和 p-value；
- effect size；
- 配对依据、运行顺序和异常值规则。

当前非常大的 t 值主要来自固定 workload 下近乎确定性的 replica-count 差异，不代表对不同模型、种子和负载具有同样强的外部有效性。实验顺序也没有充分随机化或 counterbalance；new-session 中 static 总在 S2 之前，Mixed 的位置也固定，仍可能受 cache、温度、集群噪声和时间漂移影响。

建议至少增加到 5–10 个独立重复，改变随机种子，采用 randomized block/interleaved order，并用 paired dot plot 或 box/violin plot 展示原始点，而不是只给均值和 t 值。

### 3.9 Major：跨 session 比较仍是核心混杂因素

S2 和 Mixed 来自 new session，而部分 baseline、static 和 S3 来自 old session。static A cohort 从约 33.2 s 漂移到约 23.4 s，变化约 30%。报告在正文中承认这一点是优点，但 Abstract 和结论仍容易让读者把不同 session 的数字直接放在一起理解。

建议在 Abstract 的结果句中直接注明：S2 latency remains inconclusive under a blocked two-session design。更理想的做法是在同一健康 session 内 interleave 五场景，或者至少在每个 session 内放置共同 anchor baseline 并只做 session 内配对。

### 3.10 Major：外部有效性有限，生产投影过强

当前实验是单节点 4 GPU、Qwen3-0.6B、59 个合成请求、单一 workload manifest，且通过 `ignore_eos` 制造长尾。它适合做受控机制验证，但不能直接代表大模型、多节点、真实 GRPO trainer 或生产 RL trace。

公式 `((D-1)/D)·f` 更适合作为理想条件下的 analytical upper bound，而不是生产收益预测。实际收益还取决于目标 worker 容量、KV bytes、RDMA/NIXL 带宽、路由偏斜、模型大小、迁移并发、stream continuity 和网络拓扑。

建议新增独立的 Threats to Validity 小节，分为 internal、construct、external 和 conclusion validity。

### 3.11 Major：新颖性与相关工作表述需要更多证据

“de facto mainstream”“first to combine”等表述需要可靠引用或更谨慎的限定。建议将绝对化的新颖性改为：

> To the best of our knowledge, we are not aware of prior work that evaluates this particular combination of in-place PD role switching and tail-aware decoder reclamation for RL rollout workloads.

同时补齐参考文献的作者、会议/期刊、年份、DOI/URL；对于软件和在线文档，给出版本与访问日期。

### 3.12 Minor：工程记录与学术正文混合，交付物不够自包含

`final-report.md` 开头的 Part 0 更像 revision log 或 author checklist，适合放在 companion document 或 appendix，不应出现在正式论文正文之前。正文中也有少量重复解释和“证明”“保证”“完全”等绝对措辞，可压缩并改为与证据等级匹配的语言。

另外，当前 `final-report.lex` 使用非标准扩展名，并引用了当前目录中未找到的图片、`preamble.tex`、样式文件和 `meeting-minutes.pdf`。这使得论文 artifact 无法在干净环境中独立构建和复核。正式交付前应提供：

- 标准 `final-report.tex`；
- 所有图片和表格源文件；
- bibliography；
- 样式/宏文件或明确的模板依赖；
- 一条可复现的 build command；
- 编译后的 PDF，并做逐页视觉检查。

## 4. 核心主张审计与建议改写

| 当前或隐含主张 | 证据判断 | 建议写法 |
|---|---|---|
| S3 consolidation 将尾段 GPU occupancy 降低 44.5% | **不充分**：主性能运行迁移数为 0 | Tail-aware idle decoder reclamation reduced allocated C-tail decode GPU-seconds by 44.5% |
| S3 为客户端提供 exactly one logical stream | **当前实现不支持** | Engine-side takeover is implemented; transparent client-stream reattachment remains future work |
| A/B/C 是互不重叠的 Prefill/Decode/Tail 阶段 | **不成立**：cohort completion windows 重叠 | A/B/C are request cohorts launched at controlled offsets; their execution windows may overlap |
| GPU utilization/occupancy 得到提升 | **指标不匹配** | Allocated decode GPU exposure and allocation efficiency improved |
| business wall 与 T_batch 相等证明无测试开销污染 | **由定义成立** | Both values share the same request-boundary definition and exclude explicit gate waits by construction |
| 2P2D 对 1P1D 的收益证明 S1 autoscaling 有效 | **只证明容量差异** | The comparison establishes a capacity/topology baseline; S1 policy latency is evaluated separately |
| S2 使延迟提升/下降 | **跨 session 混杂，结论不确定** | S2 correctness was validated, while its latency effect remains inconclusive in the current two-session pilot |
| 生产环境 S3 收益会更强 | **假设性推断** | The analytical model suggests a potential upper bound under stated capacity and transfer assumptions |
| 100% valid 证明迁移过程无损 | **不足**：性能套件迁移数为 0 | All workload requests passed the general validity gate; migrated-client continuity was not evaluated |

## 5. 如果由我改进：推荐的论文结构

建议将报告收敛为以下结构，使每一节只承担一种职责。

### 5.1 Abstract

用五句话完成：问题、观察、方案、实验、边界。不要在摘要中出现没有被主实验支持的 active migration 性能结论。

### 5.2 Introduction

1. 真实 RL rollout 的 burst、phase imbalance 和 long tail；
2. 固定 PD deployment 为什么浪费 allocated GPU time；
3. 三个 research questions：
   - RQ1：增加/预热容量如何改变 makespan，代价是什么？
   - RQ2：in-place role switch 是否正确、开销多大、何时有净收益？
   - RQ3：尾段 reclamation 能节省多少 allocated GPU-seconds；active migration 是否进一步增加收益？
4. 三条严格限定的贡献。

### 5.3 Background and Related Work

只保留理解方案必需的 Dynamo、disaggregated serving、KV transfer 和 RL rollout 特征。相关工作按 autoscaling、PD disaggregation、KV migration、RL serving 四类组织，并明确本工作的差异。

### 5.4 Design

把控制架构画成 observation → ordered policies → action clients：先 S3、再 S2、再 S1，而不是虚构成一个线性状态机。分别给出：

- S1 capacity control；
- S2 cordon/drain/reconfigure/register lifecycle；
- S3 empty release 与 active migration 两条路径；
- safety invariants 和 failure handling；
- 当前不支持的 client stream reattachment。

### 5.5 Implementation

以 controller、worker sidecar、Dynamo integration、observability 四个模块组织。给出真正用到的 API、关键状态和日志字段，但减少逐文件罗列。图中状态名必须与代码一致。

### 5.6 Evaluation Methodology

先明确 workload 是 overlapping cohorts，不是互斥 phase。然后说明：

- hardware/software versions；
- model、请求分布、seed 和发射时间；
- 五个场景和每个策略实际允许执行的动作；
- 指标的数学定义，特别是 allocated GPU-seconds；
- session blocking、随机化、重复次数和统计方法；
- correctness gate；
- mechanism microbenchmark 与 batch-level experiment 的区别。

### 5.7 Results：按 Research Question 组织

- RQ1：capacity/topology baseline；
- RQ2：S2 correctness、switch latency 与 net latency；
- RQ3a：empty decoder reclamation；
- RQ3b：active migration efficacy；若尚无数据，明确标为 open question；
- RQ4：Mixed coordination；
- Ablation：recompute vs NIXL/RDMA、不同长尾比例、不同 decoder 数和迁移请求数。

每个小节采用固定格式：结论一句 → 数据 → 机制解释 → 限制。这样可以避免先讲强结论、几页后才补 caveat。

### 5.8 Discussion and Threats to Validity

集中讨论质量—效率 trade-off、session drift、合成负载、单节点小模型、allocated vs actual utilization，以及 client continuity 边界。

### 5.9 Conclusion

只总结已经证明的内容：机制可行、S2 correctness、容量基线、尾段空闲 GPU 回收。把 active migration 的性能、RDMA 放大效应和生产推广明确列为下一阶段目标。

## 6. 具体实验与图表改进建议

### 6.1 下一轮最重要的实验

1. **Deterministic S3 migration A/B**：制造每个 source decoder 至少 1–N 个 active long-tail request，设置断言 `migrated_requests > 0`，否则该 run 判为 strategy-not-exercised，而不是成功样本。
2. **Empty release 与 migration 分离**：Baseline、empty-only、recompute migration、NIXL/RDMA migration 四组，避免把不同机制的收益混在一起。
3. **S2 break-even curve**：改变 role switch 后剩余 Prefill 工作量，测出何时 switch cost 小于新增 prefill capacity 带来的收益。
4. **Session 内随机化五场景**：每个 block 都有 static anchor，随机排列策略，至少 5–10 repeats 和多个 workload seeds。
5. **真实 GPU telemetry**：将 DCGM/NVML 指标与 controller action、replica count、in-flight requests 对齐。
6. **真实 RL workload**：至少增加一个来自 GRPO/PPO rollout 的 trace replay；如果使用 DPO，需要解释为何它在本文中产生在线 rollout workload。
7. **Client continuity test**：若目标是无损迁移，必须从客户端记录 request ID、token prefix、重复/缺失 token、终止原因和端到端 stream completion。
8. **RDMA/NIXL 对照**：报告 KV bytes、block 数、源/目标 GPU、传输带宽、迁移 latency、recompute latency 和释放提前量，而不仅是 path 字段。

### 6.2 建议新增或重画的图

- **Workload timeline**：准确画出 A/B/C cohort 发射与实际重叠，不再画成三个完全分离的矩形。
- **Controller architecture**：S3 → S2 → S1 的 ordered policy loop，共享 worker observation 和 sidecar/DGDSA action layer。
- **S2 sequence diagram**：cordon/unregister、drain/quiesce、sleep/reconfigure、register/wake，标注失败点和 rollback/abort。
- **S3 两路径图**：empty decoder release 与 active request migration 分开。
- **Raw paired results**：每次运行的点、配对线和置信区间，避免只有柱状均值。
- **Replica/action trace**：横轴为时间，叠加 allocated replicas、active requests、S2/S3 action marker 和 cohort release。
- **Mechanism vs efficacy evidence map**：明确 188 ms connector microbenchmark 支持什么，五场景 batch experiment 支持什么。

### 6.3 推荐的结果表字段

每次运行至少报告：session、seed、run order、scenario、T_batch、request validity、output tokens、TTFT/TPOT、allocated P/D GPU-seconds、actual SM activity、S2 attempt/success/latency、S3 planned/migrated/failed/rolled-back/empty-released、migration bytes/blocks/path、scale-down complete timestamp。

## 7. 可直接替换的摘要示例

> Reinforcement-learning rollout workloads are bursty and long-tailed, causing fixed prefill/decode deployments to retain GPUs after useful parallelism has declined. We present an RL-aware scaling prototype for NVIDIA Dynamo that combines capacity pre-warming, in-place prefill/decode role switching, and tail-aware decoder reclamation with an engine-side request-migration protocol. On a controlled 59-request synthetic workload running Qwen3-0.6B on four GPUs, a 2P2D capacity baseline reduced batch makespan by 21.2% relative to 1P1D. Tail-aware release of idle decoders reduced allocated decode GPU-seconds in the tail cohort by 44.5% and the average allocated decoder count by 22.1%, while all workload requests passed the general validity gate. S2 role switching completed correctly, but its net latency effect remains inconclusive because the pilot used two performance sessions with measurable drift. A separate connector microbenchmark demonstrates engine-side KV/request takeover, whereas the batch-level S3 runs exercised empty-decoder release rather than active migration, and transparent client-stream reattachment remains future work. These results establish the feasibility of RL-phase-aware resource reclamation while identifying the experiments required to quantify active migration and production-scale benefits.

## 8. 八分钟英文汇报 Guideline

### 8.1 汇报目标

八分钟内不应复述整篇报告，而要回答四个问题：

1. Why does fixed Prefill/Decode allocation waste GPUs in RL rollout?
2. Why were S1, S2, and S3 selected, and how do they complement one another?
3. What was actually implemented and tested?
4. Which conclusions are supported, which remain inconclusive, and what is the next decisive experiment?

### 8.2 时间与主题安排

下表对应的正文约 1,100 个英文口语词；按每分钟 135–140 词并包含短暂停顿，时长约为 8 分钟。

| 时间 | 主题 | 建议幻灯片 | 核心信息 |
|---|---|---:|---|
| 0:00–0:45 | Motivation | 1 | RL rollout 的 burst、phase imbalance、long tail |
| 0:45–1:35 | Research gap | 2 | 普通 replica scaling 不能解决固定 PD role 和尾段碎片 |
| 1:35–2:35 | Solution selection | 3 | S1/S2/S3 对应三种时间尺度 |
| 2:35–3:45 | Implementation | 4 | controller loop、S2 lifecycle、S3 safety protocol |
| 3:45–4:40 | Methodology | 5 | 59 requests、五场景、三次运行、指标和 cohort 边界 |
| 4:40–6:20 | Results | 6 | 21.2%、44.5%、S2 inconclusive、migration microbenchmark |
| 6:20–7:15 | Limitations | 7 | migrated=0、stream continuity、session drift、allocated≠utilization |
| 7:15–8:00 | Conclusion and next step | 8 | 已证明什么；下一轮 deterministic migration/RDMA 测试 |

### 8.3 演讲表达原则

- 先给结论，再解释机制；每页只保留一个 takeaway。
- 明确区分 **capacity baseline**、**mechanism validation** 和 **performance efficacy**。
- 统一使用 “allocated GPU-seconds”，不要说成 physical GPU utilization。
- 主动说明限制，这不会削弱汇报，反而体现研究可信度。
- 结果页同时给绝对值、相对变化和实验条件。
- 最后一页给出一个可证伪的下一步目标：active migration 必须在每次运行中真实发生，并与 empty-release、recompute 和 RDMA/NIXL 路径对照。

## 9. Eight-Minute English Presentation Script

### Slide 1 — Motivation: Why RL Rollout Wastes GPUs (0:00–0:45)

Good afternoon. Today I will present our work on RL-aware GPU scaling for NVIDIA Dynamo.

The starting observation is simple: reinforcement-learning rollout is not a steady online-serving workload. A batch arrives as a burst. It creates an early prompt-processing peak, then a decode-dominant interval, and finally a long tail with only a few unfinished sequences. If we keep a fixed prefill/decode deployment throughout this lifecycle, some GPUs remain allocated even when their useful parallelism has disappeared.

Our goal is therefore not only to reduce latency. It is to reduce allocated GPU time while preserving request correctness and making resource release happen earlier.

### Slide 2 — Research Gap (0:45–1:35)

Conventional autoscaling changes the number of replicas. That is necessary, but it does not solve two finer-grained problems.

First, a worker created for decode cannot automatically help when prefill becomes the bottleneck, even if that worker has spare capacity. Second, during the decode tail, a small number of requests may be spread across several decoders, so the cluster cannot release any of them early.

This leads to three research questions. How much does additional capacity change batch completion time? Can an existing GPU safely change its prefill/decode role without restarting the pod? And can tail-aware reclamation reduce allocated decoder time, with or without moving active requests?

### Slide 3 — Why We Selected S1, S2, and S3 (1:35–2:35)

We selected three complementary mechanisms operating at different time scales.

S1 is rollout scale-up and scale-down. It reacts to the trainer lifecycle and controls total capacity. In this report, the one-prefiller, one-decoder versus two-prefiller, two-decoder comparison should be understood as a capacity baseline, not yet as a complete measurement of S1 policy latency.

S2 is elastic role switching. It reuses an existing GPU by changing a decode worker into a prefill worker, or the reverse. This avoids pod cold start when the resource need shifts between phases.

S3 is tail-aware decoder reclamation. It first releases decoders that are already empty. When active requests must be consolidated, it provides a migration protocol that transfers request and KV state before releasing the source.

Together, S1 controls quantity, S2 controls role, and S3 controls tail fragmentation.

### Slide 4 — System and Implementation (2:35–3:45)

The controller observes worker roles, active requests, available capacity, and policy thresholds. Its control loop evaluates S3, then S2, and finally the S1 state machine, and sends actions through worker sidecars or the Kubernetes scaling interface.

For S2, ordering is critical. The worker is first cordoned and unpublished so that it receives no new traffic. It then drains or quiesces outstanding work, flushes transfer operations, enters sleep, resets role-specific KV and NIXL state, registers the new role, wakes up, and republishes its endpoint. Logs and role events expose each transition.

For S3, the key safety invariant is block hold. The source retains its KV blocks until the destination confirms takeover. A successful migration ends with completion and source cleanup; a failure triggers rollback. We also implemented a connector path and a recompute fallback.

One boundary is important: the current prototype validates engine-side takeover, but it does not yet reattach the original client streaming connection to the migrated request.

### Slide 5 — Evaluation Methodology (3:45–4:40)

We evaluated five configurations: a 1P1D baseline, static 2P2D, S2-only, S3-only, and a mixed strategy. The controlled workload contains 59 requests using Qwen3-0.6B on four GPUs. Request cohorts A, B, and C are launched at fixed offsets, and each configuration is repeated three times.

We report batch makespan, request validity, output volume, allocated prefill and decode GPU-seconds, role-switch timing, and S3 action counters.

I emphasize two methodological details. The cohorts can overlap in real execution, so they are not pure non-overlapping system phases. Also, allocated GPU-seconds measure provisioned resource exposure; they are not the same as hardware SM utilization.

Because the campaign used two performance sessions with measurable drift, we treat these results as a controlled pilot rather than a production-scale benchmark.

### Slide 6 — Main Results (4:40–6:20)

The first result is the capacity baseline. Static 2P2D reduced batch makespan by 21.2 percent compared with 1P1D. This confirms that additional capacity improves completion time under this workload, although it also consumes more allocated GPU time.

Second, S2 completed role transitions correctly, and loaded switching was approximately 3.4 seconds in the evaluated run. All workload requests passed the general validity gate. However, the net latency effect is inconclusive because the static anchor changed by about 30 percent between the old and new sessions. We therefore do not claim a reliable S2 latency improvement from this dataset.

Third, S3-only reduced allocated decode GPU-seconds in the C-tail cohort by 44.5 percent and reduced the average allocated decoder count by 22.1 percent relative to the matched static baseline. This is the strongest resource-reclamation result.

But the attribution must be precise. In all three S3 performance runs, the migrated-request counter was zero. The controller found an already empty decoder and released it. Therefore, this result demonstrates tail-aware idle decoder reclamation, not the batch-level benefit of active request migration.

A separate connector microbenchmark did exercise migration: it transferred state for 109 blocks and 1,688 tokens in about 188 milliseconds. That validates the mechanism path, but it does not yet quantify end-to-end workload benefit.

Finally, the mixed strategy maintained 100 percent general request validity, but its resource saving was more conservative because S2 and S3 coordination reduced the available reclamation opportunity.

### Slide 7 — Limitations and Lessons (6:20–7:15)

There are four main limitations.

First, active migration did not occur in the main S3 performance runs. Second, transparent client-stream continuation is not implemented. Third, three repetitions and two sessions are not enough for strong statistical generalization. Fourth, the experiment uses one small model, one synthetic workload, and one four-GPU node.

These limitations also give us a clearer lesson: system papers must separate mechanism validation from performance efficacy. A successful migration trace proves that the path works. A reduction in allocated GPU-seconds proves resource reclamation. We should combine those claims only when the same controlled experiment actually exercises both.

### Slide 8 — Conclusion and Next Step (7:15–8:00)

To conclude, this work establishes a practical architecture for RL-phase-aware capacity control, in-place role switching, and tail-aware decoder reclamation in Dynamo.

The current evidence supports three conclusions: additional capacity reduces makespan; S2 can perform a correct in-place role transition; and early release of an idle tail decoder can substantially reduce allocated decode GPU time.

The next decisive experiment is a deterministic S3 study in which every run migrates active long-tail requests. We will compare empty release, recompute migration, and NIXL over RDMA, while recording migration bytes, latency, release time, hardware utilization, and client-visible token continuity. We will randomize scenario order, use more seeds and repetitions, and replay a real RL rollout trace.

That experiment will tell us not only whether migration works, but when it produces a measurable end-to-end benefit. Thank you.

## 10. 最终修改优先级

在有限时间内，建议按以下顺序修改：

1. 立即修正 S3 44.5% 的归因和 client stream continuity 表述；
2. 全文统一 allocated GPU-seconds 的术语，并把 A/B/C 改为 overlapping cohorts；
3. 修正 controller 与 S2 sequence 图，使其与当前代码一致；
4. 在 Abstract 和 Conclusion 中显式写出 S2 session confound 与 S3 migrated=0；
5. 补 Threats to Validity、完整统计信息和 raw-point figures；
6. 清理 Part 0 工程日志，修复 LaTeX/PDF artifact 的缺失依赖；
7. 再执行 deterministic active-migration、RDMA/NIXL 和 client-continuity 实验。

完成前四项后，报告的学术可信度会明显提升；完成后续实验后，才适合把 active S3 consolidation 和生产级收益作为论文的核心实证贡献。
