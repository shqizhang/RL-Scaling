# RL-Scaling 四场景一致性测试策略

## 1. 测试目标

本策略用于验证 RL-Scaling 在 RL rollout / inference batch 场景下，通过 S2 Elastic PD Role Switch 和 S3 Request Consolidation 提升 GPU 资源效率、降低尾部碎片化占用，并在合适 workload 下改善 serving wall time。

本轮测试只跑每个场景一次，目标不是估计方差，而是拿到一组完整、可审计、可复现的 minifact 原始数据：

- `requests.csv`：逐 request wall time、token、finish reason、错误信息。
- `pod_samples.csv`：Ready worker/GPU allocated 原始采样。
- `controller_status.jsonl`：S2/S3 telemetry、history、evaluation。
- `events.csv`：signal、ready、batch start、phase start/done。
- `summary.json`：结构化指标和质量门结果。
- `logs/`：controller 与 worker 日志。

## 2. 核心更正

之前的失败数据不能作为策略结论，原因是测试策略和方案目标不匹配：

1. S2 被配置成高频追热点，导致一个 batch 内发生多次 PD switch。S2 的目标应是阶段性 capacity shaping，而不是频繁迁移。
2. Long-tail workload 过长且 timeout 太短，timeout 成为 wall time 主导因素，掩盖了策略本身的效能。
3. S3 的收益不能只看 client wall time。Request consolidation 可能轻微增加 tail request 的 client latency，但核心收益是让源 decoder drain，并降低 tail 阶段 decode GPU allocated seconds。
4. Baseline minimal 用于证明 1P1D 资源受限下的慢基线；S3 还需要在 2D counterfactual 下计算 tail GPU-second savings，避免把拓扑差异误判为策略收益。

因此，本轮策略采用以下原则：

- Dynamic 场景必须先完成 warmup 并达到 2P2D Ready，再开始 measured batch request。
- Scale-up / Signal-to-Ready / Burst Safety Margin 单独记录，不计入 Serving Wall Time。
- S2 每个 run 最多允许 2 次 switch；超过即判定 S2 churn，性能结论无效。
- 正式性能结论要求 `valid_decode_pct >= 99%`、`timeout_count == 0`、`http_5xx_count == 0`。
- S3 必须报告 tail decode GPU-second counterfactual 和实际 observed tail decode GPU-second。

## 3. 四个场景

| 场景 | 拓扑与策略 | 目的 |
|---|---|---|
| `baseline_minimal` | 固定 1P1D，禁用 S1/S2/S3 | 构造资源受限的大 workload 基线 |
| `s2_only` | 1P1D warmup 到 2P2D，只启用 S2 | 验证 D->P/P->D 动作正确性，观察 prefill peak 是否变快 |
| `s3_only` | 1P1D warmup 到 2P2D，只启用 S3 | 验证 tail consolidation、drain、scale down 与 GPU-second savings |
| `mixed_strategy` | 1P1D warmup 到 2P2D，启用 S2+S3 | 验证 S2 处理 prefill peak、S3 处理 decode tail 的组合收益 |

所有场景复用同一份 `workload-manifest.jsonl`，只允许 request 文本 nonce 不同，request 数量、phase、prompt 长度、max_tokens、arrival/concurrency 必须一致。

## 4. Workload 设计

统一 workload 分三段：

1. `prefill_burst`
   - 80 个长 prompt、短输出 request。
   - 目标：制造 prefill peak，让 S2 D->P 后的 prefill throughput 有可观测提升。
   - 预期：`s2_only.prefill_wall_s < baseline_minimal.prefill_wall_s`。

2. `balanced_decode`
   - 32 个中等 prompt、中等输出 request。
   - 目标：从 prefill-heavy 过渡到 decode-heavy，允许 S2 在需要时回切，但不允许频繁来回切。
   - 预期：S2 switch 总次数在 1-2 次内。

3. `decode_tail`
   - 18 个 short/medium/long tail request，输出长度分布为 16/32/64。
   - 目标：形成非均匀 tail completion，让 S3 有机会把少量 in-flight request consolidate 到目标 decoder，源 decoder drain 后释放 GPU。
   - 预期：S3 有 migration/drain 证据，tail decode GPU-second 低于 2D counterfactual。

## 5. Timing 口径

必须分开记录：

- `T_signal_recv`：controller 收到 trainer signal。
- `T_warmup_start`：warmup/scale-up 开始。
- `T_ready`：目标 2P2D Ready 且 frontend 可路由。
- `T_burst_arrival`：measured batch 第一段 request 到达。
- `Signal-to-Ready = T_ready - T_signal_recv`。
- `Burst Safety Margin = T_burst_arrival - T_ready`。
- `Serving Wall Time = first measured request start -> last measured request end`。

`Signal-to-Ready` 是给客户端 emit signal 的参考签名，不计入 Serving Wall Time。

## 6. 指标定义

### 正确性指标

- `valid_decode_pct`
- `timeout_count`
- `http_5xx_count`
- `finish_reason`
- S2 `executed_count`、switch latency、directions。
- S3 `migrated_requests`、`drained_sources`、`scaled_down_to`。

### 性能指标

- Overall Serving Wall Time。
- Phase wall time：`prefill_burst`、`balanced_decode`、`decode_tail`。
- p50/p95/p99 latency。
- req/s、prompt tok/s、completion tok/s。
- GPU allocated seconds。
- requests/GPU-second。
- tokens/GPU-second。

### S2 效果指标

S2 不允许用频繁 switch 换取偶然收益。判定顺序：

1. 动作发生：`s2_executed_count > 0`。
2. 不 churn：`s2_executed_count <= 2`。
3. 正确性通过：`valid_decode_pct >= 99%` 且无 timeout/5xx。
4. 效果发生：`s2_only.prefill_wall_s` 相比 `baseline_minimal.prefill_wall_s` 改善。
5. 总体观察：报告 `s2_only.wall_s` 相比 baseline 的变化。

### S2 switch timing 解释边界

`switch_time_ms` 来自 worker sidecar `/switch_role` 的返回值，表示单个 worker 内部从接受 switch 到返回 ack 的耗时。该耗时覆盖 worker-side 的 sleep/drain、旧 role unregister、NIXL/cache reset、新 role register、wake 等本地流程。

但 `switch_time_ms` 不等于系统级 capacity ready 时间。它不完整覆盖：

- frontend/router 的 WorkerSet 或 ModelCard watcher 传播时间；
- 新 role endpoint 被 frontend 实际纳入路由池的时间；
- 新 role 第一次请求的冷路径、cache reset 后的 warm path 代价；
- 已经进入旧路由队列的 request 被重新分配或继续等待的时间；
- role switch 后某个 worker 状态不一致导致的 tail request timeout。

因此，报告中可以把 `switch_time_ms` 作为 S2 mechanism latency，但不能用它直接解释或抵消 batch `wall_s`。若 `wall_s` 中出现 120s timeout，即使 `switch_time_ms` 只有 400-500ms，该 run 也不能被解释为 “switch latency 导致的小开销”，而应先定位 request timeout 和 routing readiness。

### S2 正确测试顺序：switch 应进入 preparation window

为了验证 “切换完成后更多 worker 处理 backlog，从而缩短 batch serving wall time”，S2 测试必须把 role switch 从 measured request window 中移出，纳入 preparation window。

推荐执行顺序：

1. trainer signal 到达；
2. scale up 到 2P2D；
3. 提前完成 D->P；
4. 验证 worker `/v1/role` 返回 `prefill`，并验证 frontend/router 已经看到新的 prefill capacity；
5. 再开始 `prefill_burst` measured requests；
6. `prefill_burst` 结束；
7. 提前完成 P->D；
8. 验证 worker `/v1/role` 返回 `decode`，并验证 decode path 可路由、可成功处理 readiness probe；
9. 再开始 `balanced_decode` / `decode_tail` measured requests。

此时需要分别报告：

- `S2 D->P Preparation Time = signal -> D->P ack -> router-visible prefill ready`
- `Prefill Serving Wall Time = prefill_burst first request -> prefill_burst last response`
- `S2 P->D Preparation Time = prefill done -> P->D ack -> router-visible decode ready`
- `Decode Serving Wall Time = decode phase first request -> tail last response`

只有当 preparation 成功、质量门通过、且 prefill serving wall 相比 baseline 改善时，才能把收益归因给 S2。若 switch 发生在 measured request window 内，则该 run 测到的是在线切换扰动，不应作为 “切换后 capacity 提升” 的主要证据。

### S2 实现与测试的严谨性检查项

每轮 S2 正式测试前必须检查以下条件：

- D->P 后，目标 worker 的 sidecar `/v1/role` 已返回 `prefill`。
- P->D 后，目标 worker 的 sidecar `/v1/role` 已返回 `decode`。
- role switch 后至少一次 frontend readiness probe 成功，且 probe 走的是目标 role 所需路径。
- controller history 中 switch action、worker URL、from/to role、reason、`switch_time_ms` 都被记录。
- controller 或 worker telemetry 能证明新 role worker 的 active request / token counter 增长。
- measured serving window 内 `timeout_count == 0`；若出现 timeout，先定位 timeout，不得宣称 S2 性能提升。
- 对比 prefill phase 时，baseline 与 S2 必须使用相同 request manifest；S2 的 scale-up 与 role switch preparation 不计入 prefill serving wall，但必须单独报告。

### S3 效果指标

S3 的主收益是 tail GPU 释放，而不是一定缩短每个 tail request 的 client latency。

对 2P2D dynamic 场景，定义：

```text
tail_decode_gpu_s_counterfactual = decode_tail.wall_s * 2
tail_decode_gpu_s_saved = tail_decode_gpu_s_counterfactual - observed_tail_decode_gpu_s
tail_decode_gpu_s_savings_pct = saved / counterfactual
```

判定顺序：

1. 动作发生：`migrated_requests > 0` 或 `drained_sources > 0`。
2. drain/scale-down 顺序可观测。
3. 正确性通过。
4. tail decode GPU-second savings 为正。
5. 总体观察：报告 wall time 是否持平、改善或有小幅代价。

### Mixed 效果指标

Mixed 的预期是：

- S2 在 prefill peak 阶段提供 prefill capacity。
- S3 在 decode tail 阶段降低 GPU allocated seconds。
- 在同一 workload 下，Mixed 应优于单独策略，至少在综合指标上达到最好：
  - wall time 最好或接近最好；
  - tokens/GPU-second 最好；
  - tail decode GPU-second savings 为正；
  - 正确性质量门通过。

## 7. 场景验收门

| 场景 | 验收条件 |
|---|---|
| baseline_minimal | S2/S3 history 为 0；质量门通过；作为 1P1D 慢基线 |
| s2_only | S2 executed 1-2 次；S3 history 为 0；prefill wall 改善；质量门通过 |
| s3_only | S2 history 为 0；S3 migration/drain 可见；tail GPU-second savings 为正；质量门通过 |
| mixed_strategy | S2 和 S3 证据均可见；无 S2 churn；tail GPU-second savings 为正；质量门通过 |

## 8. 执行顺序

1. 清理无效旧报告。
2. 静态检查脚本和文档口径一致。
3. Readiness gate：验证 controller telemetry/worker sampling 可见。
4. `baseline_minimal/run-01`
5. `s2_only/run-01`
6. `s3_only/run-01`
7. `mixed_strategy/run-01`
8. 生成 suite aggregate 与报告。
9. Review 质量门和策略门；只有通过的 run 才能纳入性能结论。

## 9. 预期结论表达

最终报告必须按以下顺序写结论：

1. 正确性：valid decode、timeout、S2/S3 动作顺序。
2. S2：动作是否发生、switch 是否受控、prefill phase 是否改善、overall wall 如何变化。
3. S3：migration/drain 是否发生、tail GPU-second 是否节省、wall time 是否有代价。
4. Mixed：是否同时拿到 S2 prefill 收益和 S3 tail GPU 收益，是否是综合最佳。
5. 限制：若某个动作未发生、质量门失败或 telemetry 缺口存在，必须明确标注，不能强行归因。

## 10. S3 结果解释边界

S3 Request Consolidation 必须区分两类证据：

1. Client-visible performance evidence
   - 所有 measured request 必须 valid decode。
   - `timeout_count == 0`。
   - migrated request 的 client response 必须能够无损完成。
   - 只有满足这一层，才能把 S3 纳入端到端 batch wall time 正向结论。

2. GPU-side mechanism evidence
   - controller 产生 consolidation plan。
   - sidecar 执行 migration attempt。
   - request 被 migrated 或 source 被 drained。
   - tail decode GPU-second savings 为正。
   - 这一层可以证明 GPU/engine 侧资源释放机制，但不能单独证明用户端无损续流。

如果 S3 只满足 GPU-side mechanism evidence，但 measured client request 出现 timeout，则报告必须写成：

- S3 GPU-side consolidation/drain 机制有证据。
- S3 client-visible correctness 尚未通过。
- 该 run 不能用于“端到端 wall time 改善”结论。

这条边界不能放宽。若论文或答辩需要宣称 S3 对用户端 batch 无损，则必须补齐 frontend stream reattach / response continuity，或将 S3 章节明确限定为 GPU resource release mechanism。

## 11. S3 异常数据分析与后续测试修正

本轮四场景测试中，S3 相关数据出现两个异常：

1. `s3_only` 有 consolidation plan 和 migration attempt，但 `migrated_requests=0`、`drained_sources=[]`。
2. `s3_only` 与 `mixed_strategy` 的 `decode_tail` 均出现 1 个 request timeout，tail wall 被拉到约 134s。

关键数据：

| 场景 | decode_tail wall(s) | timeout | S3 attempts | migrated | declined | drained | timeout request |
|---|---:|---:|---:|---:|---:|---:|---|
| baseline_minimal | 16.62 | 0 | 0 | 0 | 0 | 0 | none |
| s3_only | 134.77 | 1 | 1 | 0 | 1 | 0 | manifest_id=130, max_tokens=64 |
| mixed_strategy | 134.20 | 1 | 0 | 0 | 0 | 0 | manifest_id=130, max_tokens=64 |

这说明异常不能简单归因于 workload 本身。相同 tail workload 在 baseline 中 18/18 成功，而在 dynamic S3/Mixed 场景中有 1 条 tail request timeout。

### 11.1 S3 attempt 不等于 S3 成功

S3 controller 当前迁移逻辑是：

1. controller 从 telemetry 看到 source decoder 上还有少量 in-flight request；
2. 生成 consolidation plan；
3. 调用 source sidecar `/migrate`，并传入 `request_id="*"`；
4. source sidecar 将 `*` 解析成当前 active request；
5. source 执行 `migrate_out`；
6. target 执行 `migrate_in`；
7. 成功后 source `migration_complete`，失败则 `migration_rollback`。

因此，S3 至少有四个层次：

- `plan`：controller 认为有 consolidation 机会；
- `attempt`：controller 调用了 sidecar `/migrate`；
- `migrated`：source/target 协议成功，request 被 target 接管；
- `drained`：source decoder active request 归零，可释放或 scale down。

正式性能结论只能基于 `migrated` 与 `drained`，不能只基于 `attempt`。

### 11.2 `no active requests` 的含义

本轮 `s3_only` controller log 中出现：

```text
S3 consolidation decision ... source_active=1 ... request_count=1
S3 migration stopped ... status=error ... message=no active requests
```

这说明 controller 决策时认为 source 上有 1 个 active request，但 source sidecar 在实际执行 `/migrate` 时，`list_active_request_ids()` 返回为空。

这类异常说明 telemetry 和 worker registry 出现时间差或语义不一致：

- request 可能已经完成，但 controller 还看到旧的 in-flight；
- request 可能仍被 client 等待，但没有出现在 worker active registry；
- source/target worker URL 可能已变化，controller 看到的 worker state 与实际 sidecar 不一致；
- fixed-delay tail signal 发出时机不稳定，request 可能已经接近完成或已经从 registry deregister。

后续测试必须在 S3 attempt 前采集 source worker `/v1/active_requests` 原始快照，并写入报告。没有 active request 快照，就不能解释 S3 attempt 失败原因。

### 11.3 `declined` 的含义

S3 `migrate_in` 有 cost-benefit gate。默认策略要求：

- generated tokens 足够多，太年轻的 request 不迁；
- remaining tokens 足够多，快结束的 request 不迁；
- replay tokens 不超过上限。

如果 signal 太早，request `generated_tokens < min_generated_tokens`，会被判定 “too young”；如果 signal 太晚，`remaining_tokens < min_remaining_tokens`，会被判定 “will finish faster than migrate”。两者都会导致 `declined`。

因此，S3 触发不能只靠固定 `sleep(1s)` 或固定 batch progress。更严谨的策略应该是 telemetry-driven：

1. decode tail 开始后持续采集 `/v1/active_requests`；
2. 选择同时满足 `generated_tokens >= min_generated_tokens` 且 `remaining_tokens >= min_remaining_tokens` 的 request；
3. 再触发 consolidation；
4. 记录 migrate_out/migrate_in 的具体 request_id、generated_tokens、remaining_tokens、decline reason。

### 11.4 tail timeout 的解释边界

本轮 `s3_only` 与 `mixed_strategy` 的 tail timeout 都集中在：

```text
manifest_id=130
max_tokens=64
latency ~= 120s
error=timed out
```

这条 request 把 `decode_tail.wall_s` 从约 16s 拉到约 134s。若仅做诊断性 counterfactual，排除 timeout 后 tail wall 接近 baseline；但正式结论不能排除它，因为用户端 batch 确实没有收到完整响应。

当前可疑方向：

- dynamic 2D topology 下某个 decode worker/route 对 tail request 不稳定；
- S3 attempt 与 source registry/rollback 之间存在竞态；
- migrated 或 attempted request 的 client response continuity 未闭环；
- controller 看到的 active request 与 sidecar registry 不一致；
- `request_id="*"` 无法稳定对应到 client-visible straggler。

因此，S3 timeout 必须优先作为 correctness failure 处理，不能用 tail GPU-second savings 抵消。

### 11.5 Mixed 中 S3 未触发的解释边界

Mixed 场景中 `s3_history_count=0`，说明 S3 没有产生正式 consolidation decision。可能原因包括：

- S2 已经改变 decode/prefill worker state，S3 的 source/target 条件没有满足；
- S2 与 S3 control loop 的顺序、cooldown 或 telemetry 窗口互相干扰；
- tail signal 发出时 active request 分布不满足 decision engine 的 cost-benefit 条件；
- source decoder 没有形成 “少量 straggler 分散在多个 decoder” 的可迁移形态。

因此 Mixed 不能只要求 “S2 和 S3 都 enabled”，还必须证明 S3 在 Mixed 中实际看到 tail fragmentation 并产生 plan。若 `s3_history_count=0`，该 run 不能用于证明 Mixed 策略协同。

### 11.6 后续 S3 测试必须新增的原始数据

每次 S3 正式 run 必须额外保存：

- `active_requests_before_s3.json`：每个 decode worker `/v1/active_requests` 快照。
- `active_requests_after_s3.json`：migration attempt 后快照。
- 每次 migration 的 `request_id`，不得只记录 `*`。
- `generated_tokens`、`max_tokens`、`remaining_tokens`、`prompt_tokens`。
- `migrate_out` response，包括是否有 `src_block_ids`、`kv_transfer_params`。
- `migrate_in` response，包括 `status`、`path`、`decline reason`、`replay_tokens`。
- `migration_complete` 或 `migration_rollback` response。
- source drain poll 过程，而不仅是最终 `drained_sources`。
- target/source worker URL 与 pod name 映射。

只有这些数据齐全，才能区分：

- 没有可迁移请求；
- 请求太年轻；
- 请求快结束；
- source registry 丢失；
- target 拒绝；
- migration 成功但 client continuity 失败；
- drain 成功但 scale down 未触发。

### 11.7 后续 S3 测试建议

S3 后续测试应拆成两类，避免把机制验证和端到端性能混在一起。

#### A. S3 mechanism suite

目标：证明 GPU/engine-side migration、drain、scale-down 机制。

要求：

- 使用 2P2D 或 2P4D 同拓扑 disabled baseline 做 counterfactual；
- 允许单独记录 migrated request 的 client continuity 风险；
- 主要指标是 `migrated_requests`、`drained_sources`、`tail_decode_gpu_s_saved`、`scale_down_release_latency`；
- 必须保存 migration protocol 原始响应。

#### B. S3 client-visible performance suite

目标：证明用户端 batch request 无损、wall time 和 GPU efficiency 改善。

要求：

- `timeout_count == 0`；
- `valid_decode_pct == 100%` 或至少满足质量门；
- migrated request 的 client response 必须正常完成；
- 若当前实现仍是 engine-side takeover + drain-and-discard，而不是 frontend stream reattach，则不得宣称 client-visible S3 成功。

### 11.8 S3 正式验收条件

S3 run 只有同时满足以下条件，才可纳入端到端性能结论：

1. `s3_history_count > 0`；
2. `migration_attempts > 0`；
3. `migrated_requests > 0`；
4. `drained_sources > 0`；
5. `timeout_count == 0`；
6. source drain 发生在 scale down 前；
7. tail decode GPU-second savings 为正；
8. 与同拓扑 disabled baseline 对比，而不是只与 1P1D baseline 对比。

如果只满足 1-4，但不满足 5，则只能写成 GPU-side mechanism evidence，不能写成 client-visible performance evidence。

### 11.9 S3 `gpu_s`、`tail_wall_s` 与 `tail_decode_gpu_s_saved` 的异常解释

本轮 `s3_only` 与 `baseline_minimal` 的关键对比如下：

| 指标 | baseline_minimal | s3_only | 解释 |
|---|---:|---:|---|
| request window wall_s | 88.51 | 185.13 | s3_only 被 1 个 tail timeout 拉长 |
| request window gpu_s | 167.91 | 725.41 | s3_only 以 2P2D/4 workers 运行，且 wall 被 timeout 放大 |
| tail_wall_s | 16.62 | 134.77 | s3_only tail 中 1 个 request 达到 120s timeout |
| tail phase gpu_s | 18.66 | 517.70 | 4 workers 在长 tail window 内持续 allocated |
| timeout_count | 0 | 1 | s3_only 不满足正式质量门 |
| s3_migrated_requests | 0 | 0 | 正式 S3 run 没有成功迁移 request |
| s3_drained_sources | 0 | 0 | 没有 source decoder drain 成功 |
| tail_decode_gpu_s_saved | 7.29 | 10.69 | 该数值在本轮不能作为 S3 成功证据 |

结论：

1. `gpu_s` 是 allocated GPU seconds，不是模型真实 compute seconds。它近似等于 measured window 内 ready GPU worker 数量对时间的积分。因此 `s3_only` 的 `gpu_s` 高，首先来自 2P2D/4 workers 拓扑高于 baseline 1P1D/2 workers，其次来自 tail timeout 把 measured window 拉长。
2. `tail_wall_s` 高不是成功 request migration 的直接成本。本轮正式 `s3_only` 中 `migrated_requests=0`、`drained_sources=[]`，controller log 还出现 `no active requests` 和 `declined`。也就是说，S3 只有 plan/attempt，没有完成 migration/drain。
3. 本轮 tail 被 `manifest_id=130, max_tokens=64` 的 request 拉到约 120s timeout。诊断性地排除该 timeout 后，`s3_only` 的 tail ok window 约为 16.29s，接近 baseline tail 16.62s；但正式报告不能排除 timeout，因为用户端 batch 确实没有完整成功。
4. `tail_decode_gpu_s_saved` 数值越高，通常表示相对于 counterfactual 少占用了更多 decode GPU seconds；但只有在以下前提满足时才成立：同拓扑 baseline/counterfactual 合法、`timeout_count == 0`、`migrated_requests > 0`、`drained_sources > 0`、source release 或 scale down 确实发生。本轮这些前提不满足，因此 10.69 GPU-s 只能视为公式输出，不能视为 S3 performance evidence。
5. 当前 `s3_only` 不能证明 “request migration 成本超过 GPU 节省”。因为 migration 没有成功完成，无法比较 migration cost 与 saved GPU seconds。它只能证明 controller 能产生 S3 plan/attempt，同时暴露出 telemetry 与 worker active registry 不一致、触发时机不准、以及 client-visible timeout 风险。

后续测试策略修正：

1. 增加 `baseline_2p2d_disabled` 或 `baseline_overprovisioned`：与 S3 使用相同 2P2D 拓扑，但禁用 S2/S3。S3 的 tail GPU savings 必须优先和同拓扑 disabled baseline 对比，而不是只和 1P1D baseline 对比。
2. S3 attempt 前必须采集并保存每个 decode worker 的 `/v1/active_requests` 快照，至少包含 `request_id`、`generated_tokens`、`max_tokens`、`remaining_tokens`、worker URL、pod name。
3. S3 不应只按 batch completion pct 或固定 sleep 触发；应在 tail 阶段持续轮询 active requests，只在 request 同时满足 `generated_tokens >= min_generated_tokens` 和 `remaining_tokens >= min_remaining_tokens` 时触发。
4. S3 报告必须区分三类 GPU 指标：`request_window_gpu_s`、`tail_total_gpu_s`、`tail_decode_gpu_s`。S3 的核心收益只用 `tail_decode_gpu_s` 与同拓扑 counterfactual 对比，不把 prefill allocated seconds 混入 decode savings。
5. S3 正式性能 run 的硬门槛是 `timeout_count == 0`、`valid_decode_pct >= 99%`、`migrated_requests > 0`、`drained_sources > 0`。任一失败，只能作为 failure analysis 或 mechanism evidence，不能作为 client-visible performance conclusion。
6. 若当前实现仍然是 engine-side takeover + drain-and-discard，而不是 frontend stream reattach，则 S3 可以报告 GPU-side consolidation/drain/release 证据，但不能宣称 migrated request 的用户端响应无损。

### 11.10 S3 timeout 与 migration failure 的复盘及防失败策略

本轮 `s3_only` 失败不能被解释为 “request migration 成本过高”。更准确的因果链是：

1. controller 决策时看到 `source_active=1`，因此生成 consolidation plan；
2. source sidecar 实际执行 `/migrate` 时返回 `no active requests`，说明 controller telemetry 与 worker active registry 已经不一致；
3. 后续 attempt 被 target 侧 cost-benefit gate 拒绝，日志显示 `remaining_tokens=15 below min_remaining_tokens=32`，说明触发时机过晚，请求已经接近完成；
4. `decode_tail` 中 `manifest_id=130` 最终 client timeout 到约 120s，使 tail wall 和 GPU allocated seconds 被放大；
5. 因为正式 run 中 `migrated_requests=0`、`drained_sources=[]`，所以不能把 timeout 归因于成功迁移，也不能计算 migration cost 是否覆盖 GPU savings。

#### 11.10.1 active request telemetry 与 worker registry 不一致

`source_active=1` 与 `no active requests` 同时出现，表示 controller 看到的是一个过期或语义不同的状态，而 worker sidecar 的实时 registry 中没有可迁移对象。常见原因包括：

- request 在 controller 采样后已经完成并从 registry deregister；
- request 仍在 client 侧等待，但 worker 内部 active registry 已经不再持有该 request；
- controller 使用的 worker URL、pod name 或 role 状态已经变更；
- tail request 生命周期过短，固定 sleep 或 batch completion pct 触发无法稳定命中迁移窗口；
- `request_id="*"` 只能代表 “当前任意 active request”，不能稳定绑定到某个 client-visible straggler。

测试脚本必须把这类情况视为 S3 trigger failure，而不是 S3 action success。若出现 `no active requests`，该 run 不得纳入 S3 性能对比。

#### 11.10.2 触发时机不准

S3 有明确的 cost-benefit 窗口：

- 太早：`generated_tokens` 不足，迁移缺少已生成进度，可能被判定为 too young；
- 太晚：`remaining_tokens` 不足，target 会认为 request 很快结束，迁移不划算；
- 正确窗口：request 已经生成一部分 token，但仍有足够 remaining tokens，迁移后 source drain 和 GPU release 的收益大于迁移成本。

因此，S3 正式测试不得使用固定 `sleep` 或只使用 batch completion pct。下一轮脚本应持续轮询 `/v1/active_requests`，选择满足以下条件的具体 request：

```text
generated_tokens >= min_generated_tokens
remaining_tokens >= min_remaining_tokens
source_active_count <= source_tail_threshold
target_available_capacity >= request_count
```

触发前必须二次确认该 `request_id` 仍存在于 source worker registry；若不存在，则 skip，不计入 migration attempt。

#### 11.10.3 client-visible timeout 的处理

任何 measured request timeout 都是 correctness failure。即使 GPU-side migration/drain 有证据，只要用户端 batch request 没有完整响应，该 run 就不能用于 client-visible performance 结论。

本轮 `manifest_id=130` timeout 的定位边界是：

- 可以确认它把 tail wall 从约 16s 量级拉到约 134s；
- 可以确认正式 S3 run 没有成功 migration/drain；
- 不能确认它就是成功迁移对象，因为没有成功迁移，也缺少 client manifest id 到 worker request id 的强关联；
- 因此它应作为 routing、registry、rollback 或 stream-continuity 风险处理，而不是作为正常 S3 overhead 处理。

下一轮必须记录 request correlation：

- manifest id；
- client request start/end timestamp；
- returned HTTP status / timeout；
- worker request id；
- source pod 与 target pod；
- migration attempt timestamp；
- migrate_out / migrate_in / complete / rollback response；
- client response 是否由同一 request chain 完整返回。

#### 11.10.4 下一轮 S3 脚本的 hard gates

S3 测试脚本必须在每个阶段设置 hard gate，避免一轮无效 run 继续污染最终报告：

1. Readiness gate：2P2D 或目标拓扑 ready，frontend/router 已经看到所有 decode workers。
2. Active-request gate：至少一个 source decoder 有可迁移 request，且该 request 满足 generated/remaining token 条件。
3. Pre-migration gate：用具体 `request_id` 二次确认 source registry 中仍有该 request。
4. Migration gate：`migrate_out` 和 `migrate_in` 必须成功，或明确记录 decline reason 并终止性能统计。
5. Drain gate：source active request 必须归零，`drained_sources` 必须非空。
6. Quality gate：`timeout_count == 0`、`valid_decode_pct >= 99%`、`http_5xx_count == 0`。
7. Comparison gate：必须存在同拓扑 disabled baseline，例如 `baseline_2p2d_disabled` 或 `baseline_overprovisioned`。

任一 gate 失败时，该 run 只能输出 failure analysis，不得输出 “S3 improves performance” 结论。

#### 11.10.5 workload 修正

当前 tail 中大量 request 的 `max_tokens` 为 16/32/64，S3 很容易错过迁移窗口。下一轮 S3 workload 应拆成两类：

- mechanism workload：少量明确长尾 request，例如 96/128/192 `max_tokens`，用于稳定命中 migration window，并验证 migrate/drain/scale-down；
- performance workload：真实混合 tail，但必须先通过 mechanism workload 证明 request correlation、drain 和 client correctness。

S3 触发点建议从 “batch completion 92%” 改为 “decode tail active request token progress window”，例如在目标 request 生成 30%-60% 且 remaining tokens 仍大于阈值时触发。

#### 11.10.6 报告口径修正

报告必须明确区分以下结论：

- `plan`：controller 认为有 consolidation 机会；
- `attempt`：controller 调用了 sidecar；
- `migrated`：source/target 协议成功；
- `drained`：source decoder active request 归零；
- `released`：source GPU worker 被 scale down 或从 tail allocation 中释放；
- `client-valid`：用户端 request 无 timeout、无 5xx、decode 有效。

只有同时达到 `migrated`、`drained`、`released` 和 `client-valid`，才能把 S3 写成端到端性能证据。若只达到 `plan/attempt`，只能写成 controller trigger evidence；若达到 `migrated/drained` 但没有 client-valid，只能写成 GPU-side mechanism evidence。
