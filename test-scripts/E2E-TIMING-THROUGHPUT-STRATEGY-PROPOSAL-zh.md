# RL-Scaling S2/S3 端到端 Timing、吞吐与策略触发测试 Proposal

> 范围：分析 `test-scripts` 目录下现有 S2/S3 E2E 脚本，并提出下一阶段测试策略。
>
> 目标：新增一个能同时覆盖 Timing、吞吐、策略触发、S2 Role Switch 与 S3 Request Consolidation 的端到端验证方案，并明确当前实现与测试证据的差距。

---

## 1. 当前测试文件与覆盖范围

`test-scripts` 目录当前有三个核心 E2E 脚本：

| 文件 | 场景 | 当前证明的能力 | 当前不足 |
|------|------|----------------|----------|
| `test-s2-elastic.sh` | S2 Elastic PD Role Switch | decode worker 可以通过 sidecar 切到 prefill，再切回 decode；CR/ModelCard 变化可被 Dynamo 感知；切换期间持续负载 HTTP 错误可控 | 直接调用 sidecar，不验证 controller 策略是否自动触发；吞吐只看请求 latency 与 token counter delta，缺少窗口化 tokens/s 和 role-level throughput |
| `test-s3-consolidation.sh` | S3 Request Consolidation 默认路径 | D1 的 active request 可迁移到 D2；D1 active 数下降；D2 token counter 增长；oversize migrate_in 会 declined | 直接调用 sidecar `/migrate`，不验证 controller 策略触发；D2 接收证据部分依赖 migrate response，缺少统一的 token continuity 与吞吐窗口分析 |
| `test-s3-nixl-migration.sh` | S3 Phase 2.B NIXL KV Transfer | 验证 `kv_transfer_params`、`src_block_ids`、`path=connector`，证明走 NIXL 而非 recompute | PASS 注释中有 `PASS_TOKENS_AFTER` / `PASS_TIMING`，但最终 verdict 未纳入；缺少 recompute baseline 对照和吞吐/latency 统一报告 |

现有脚本适合证明“worker-side mechanism 可用”，但还不足以证明“controller 策略闭环在真实负载下会自动选择正确动作，并且改善 Timing/吞吐指标”。

---

## 2. 当前 S2 脚本测试思路分析

### 2.1 测试目标

`test-s2-elastic.sh` 的目标是证明一个 dual-mode decode worker 可以：

1. 从 decode role 切换为 prefill role；
2. 从 Dynamo `DynamoWorkerMetadata` / ModelCard 中移除 decode 可见性；
3. 在 prefill role 下真实处理 prompt tokens；
4. 再切回 decode role；
5. 重新获得 decode ModelCard；
6. 在 decode role 下真实生成 generation tokens；
7. 切换期间持续请求不出现明显服务中断。

### 2.2 当前证据链

该脚本已经采集了比较扎实的证据：

- **Switch timing**：客户端 wall time 与 server `switch_time_ms`；
- **分段 timing**：sidecar response 中包含 `sleep`、`unregister_mdc`、`reconfig_nixl`、`reset_prefix_cache`、`register_mdc`、`wake`；
- **Router awareness**：切换后 CR 中 `backend/generate` ModelCard 消失，切回后恢复；
- **Prefill correctness**：target pod 的 `vllm:prompt_tokens_total` 增长；
- **Decode correctness**：target pod 的 `vllm:generation_tokens_total` 增长；
- **持续负载影响**：背景负载记录 HTTP code、latency，并计算 p50/p99。

示例历史报告显示 decode -> prefill 约 453 ms，prefill -> decode 约 428 ms；持续负载 58/58 HTTP 200，p50 约 65 ms，p99 约 105 ms。

### 2.3 当前不足

1. **不是 controller-driven**

   脚本直接调用 `POST /switch_role`。这证明 sidecar 和 worker 逻辑正确，但不能证明 controller 在策略条件满足时会自动触发。

2. **缺少吞吐窗口对比**

   当前只记录 token counter delta，没有按时间窗口计算：

   ```text
   pre-switch tokens/s
   during-switch tokens/s
   post-switch prefill tokens/s
   post-revert decode tokens/s
   ```

3. **缺少 role-level capacity 指标**

   需要在报告中明确切换前后 prefill pool / decode pool 的有效 worker 数、queue depth、utilization。

4. **负载模型偏轻**

   当前背景负载默认 `2 RPS`、短 `max_tokens`，适合 smoke test，但不足以评估吞吐改善或策略收益。

---

## 3. 当前 S3 脚本测试思路分析

### 3.1 `test-s3-consolidation.sh`

该脚本验证默认 request consolidation 路径：

1. 提交一批长请求；
2. 等待请求分布到两个 decode worker；
3. 对 D1 发起 `/migrate {request_id:"*", target_url:D2}`；
4. 每次迁移前后记录 D1/D2 active request ids；
5. 验证 request id 离开 D1；
6. 验证 D2 通过 `migrate_in` 接收；
7. 验证 D1 active 数下降；
8. 验证 D2 `generation_tokens_total` 增长；
9. 通过 synthetic oversize 请求验证成本收益门控会 declined。

该脚本的核心思想是“把 tail request 从低负载 source drain 到有 spare capacity 的 target”，从而释放 source worker。

### 3.2 `test-s3-nixl-migration.sh`

该脚本验证 Phase 2.B NIXL connector 路径：

1. 检查 source/destination 的 NIXL metadata；
2. 提交长请求并等待 decode 开始；
3. 调 `migrate_out`，要求拿到 `kv_transfer_params` 和 `src_block_ids`；
4. 调目标 `migrate_in`，要求 `path=connector`；
5. 调 `migration_complete` 释放源端 block；
6. 检查 response 完整性。

它的证据重点是“真实 KV block 被 NIXL 拉取”，不是只走 recompute-prefill。

### 3.3 当前不足

1. **不是 controller-driven**

   两个 S3 脚本都直接调用 sidecar，不验证 `ConsolidationController` 何时自动触发。

2. **Timing 证据不完整**

   `test-s3-nixl-migration.sh` 记录了 `migration_time_ms`，但缺少：

   - migrate_out latency；
   - migrate_in latency；
   - complete/rollback latency；
   - end-to-end request completion latency；
   - recompute baseline 对照；
   - migration 对 destination throughput 的影响窗口。

3. **PASS 条件与注释不一致**

   脚本注释里定义了 `PASS_TOKENS_AFTER` 和 `PASS_TIMING`，但最终 verdict 只检查 `PASS_KV_TRANSFER`、`PASS_BLOCK_IDS`、`PASS_CONNECTOR_PATH`、`PASS_TOKENS_BEFORE`、`PASS_COMPLETE`、`PASS_MIG_OK`。

4. **D2 接收证据仍偏间接**

   当前 consolidation 脚本承认 migrated-in requests 不进入 D2 的 `InProcessRequestRegistry`，所以用 `migrate_in.status=ok` / `path=recompute|connector` 证明 D2 accepted。这个证据可用，但若要证明吞吐收益，还需要更强的 destination token progress / client stream continuity 指标。

---

## 4. 策略触发条件：什么时候 Switch Role，什么时候 Consolidation

### 4.1 S2 Role Switch 策略触发条件

当前 controller 代码中，S2 有两个方向。

#### Decode -> Prefill

当 prefill 侧成为瓶颈，而 decode 侧空闲时触发：

```text
ROLE_SWITCH_ENABLED == true
prefill_queue_depth >= PREFILL_QUEUE_THRESHOLD
decode_utilization <= DECODE_IDLE_THRESHOLD
decode_worker_count > MIN_DECODE_REPLICAS
now - last_switch_time >= MIN_SWITCH_INTERVAL
```

默认阈值：

```text
PREFILL_QUEUE_THRESHOLD = 10
DECODE_IDLE_THRESHOLD = 0.2
MIN_DECODE_REPLICAS = 1
MIN_SWITCH_INTERVAL = 30s
```

语义解释：

> 当前 prompt/prefill 排队严重，但 decode pool 利用率低，且 decode 副本数高于保底值。此时把最 idle 的 decode worker 切成 prefill，以加速 prompt 阶段。

#### Prefill -> Decode

当 decode 侧成为瓶颈，而 prefill 侧空闲时触发：

```text
ROLE_SWITCH_ENABLED == true
decode_queue_depth >= DECODE_QUEUE_THRESHOLD
prefill_utilization <= PREFILL_IDLE_THRESHOLD
prefill_worker_count > MIN_PREFILL_REPLICAS
now - last_switch_time >= MIN_SWITCH_INTERVAL
```

默认阈值：

```text
DECODE_QUEUE_THRESHOLD = 10
PREFILL_IDLE_THRESHOLD = 0.2
MIN_PREFILL_REPLICAS = 1
MIN_SWITCH_INTERVAL = 30s
```

语义解释：

> 当前长 decode 阶段堆积，而 prefill 已不忙，且 prefill 副本数高于保底值。此时把最 idle 的 prefill worker 切回 decode，以增加 decode capacity。

### 4.2 S3 Request Consolidation 策略触发条件

当前 consolidation decision engine 的触发条件是：

```text
CONSOLIDATION_ENABLED == true
batch_completion_pct >= MIN_BATCH_COMPLETION
len(decode_workers) > MIN_DECODE_REPLICAS
source.in_flight_requests > 0
source.in_flight_requests <= CONSOLIDATION_THRESHOLD
target.available_capacity >= source.in_flight_requests
estimated_migration_time < source.estimated_remaining_time * 0.5
source/target 不互相冲突
```

默认阈值：

```text
MIN_BATCH_COMPLETION = 0.6
CONSOLIDATION_THRESHOLD = 3
PER_REQUEST_MIGRATION_OVERHEAD = 0.5s
MIN_DECODE_REPLICAS = 1
```

语义解释：

> 当 batch 已经过半，部分 decoder 只剩少量 in-flight 长尾请求，而其他 decoder 还有足够容量时，迁移这些尾部请求到目标 decoder，随后 source decoder 可以被 drain、scale down 或切换角色。

### 4.3 策略选择优先级建议

建议将 S2/S3 触发放在统一决策顺序中：

1. **S3 consolidation 优先处理 decode tail**

   如果 batch 已进入 tail，source decoder 只剩少量请求，优先迁移请求。这样可以释放整张 GPU 或为后续 role switch 创造条件。

2. **S2 role switch 处理跨阶段池比例失衡**

   如果不是 tail，而是 prefill/decode 队列明显失衡，则触发 role switch。

3. **S1 Kubernetes scaling 作为最后手段**

   如果本地迁移和角色切换都不能解决总容量不足，再扩缩 pod。

推荐逻辑：

```text
if decode_tail_fragmented and migration_benefit_positive:
    trigger S3 consolidation
elif prefill_backlogged and decode_idle:
    trigger S2 decode -> prefill
elif decode_backlogged and prefill_idle:
    trigger S2 prefill -> decode
else:
    stay / S1 scale if total capacity is insufficient
```

---

## 5. 下一阶段 E2E 验证目标

用户需求可以转化为一个新的统一 E2E：

> 在真实 Kubernetes + Dynamo + vLLM 集群上，构造 RL-like phase workload，验证 controller 在不同阶段自动触发 S2/S3，并采集 timing、throughput、latency、token progress 和服务连续性指标。

建议新增脚本：

```text
test-s2-s3-policy-e2e.sh
```

或扩展为：

```text
test-rl-scaling-policy-e2e.sh
```

### 5.1 必须采集的 Timing 指标

#### S2 Timing

- client wall time；
- server `switch_time_ms`；
- `sleep`；
- `unregister_mdc`；
- `reset_prefix_cache`；
- `register_mdc`；
- `wake`；
- CR convergence time：ModelCard 变化从请求发出到 CR 可观测的时间；
- router convergence time：切换后新请求不再打到旧角色的时间。

#### S3 Timing

- `migrate_out_ms`；
- `migrate_in_ms`；
- `migration_complete_ms`；
- coordinated `/migrate` total wall time；
- request drain time：source active request 降到 0 的时间；
- destination token resume time：migrate_in 成功后 destination token counter 开始增长的时间；
- recompute baseline latency；
- connector path latency。

### 5.2 必须采集的吞吐指标

按时间窗口采集，而不是只看最终 delta：

```text
window_start,window_end,role,pod,prompt_tokens_delta,generation_tokens_delta,prompt_tps,generation_tps,num_requests_running,queue_depth
```

至少要覆盖：

- pre-action baseline；
- action window；
- post-action stabilization；
- drain/tail window；
- final completion window。

建议报告指标：

- request throughput：requests/s；
- prompt throughput：prompt tokens/s；
- decode throughput：generation tokens/s；
- TTFT p50/p95/p99；
- total latency p50/p95/p99；
- error rate；
- per-pod token distribution；
- source/destination active request count 曲线。

### 5.3 必须采集的策略触发证据

新的 E2E 不应该只调用 sidecar，而应该证明 controller 根据策略触发。

报告中至少需要保存：

```text
decision_ts
decision_type: role_switch | consolidation | no_op
trigger_metrics:
  prefill_queue_depth
  decode_queue_depth
  prefill_utilization
  decode_utilization
  batch_completion_pct
  source_in_flight
  target_available_capacity
  estimated_remaining_time
  estimated_migration_time
thresholds:
  prefill_queue_threshold
  decode_idle_threshold
  consolidation_threshold
  min_batch_completion_pct
chosen_action:
  worker_url / source / target / role
result:
  status / latency / error
```

---

## 6. 推荐测试场景设计

### 6.1 Scenario A：触发 Decode -> Prefill Role Switch

目标：证明 prefill backlog + decode idle 时，controller 会自动把 decode worker 切成 prefill。

负载构造：

- 大量长 prompt、短 output；
- `max_tokens` 较小；
- prompt 长度大，制造 prefill pressure；
- decode 生成很短，decode utilization 保持低。

预期触发：

```text
prefill_queue_depth >= threshold
decode_utilization <= idle_threshold
decode_worker_count > min_decode_replicas
```

验收标准：

- controller decision log 出现 `decode->prefill`；
- target worker CR 中 decode ModelCard 消失；
- target prompt_tokens_total 增长；
- prefill queue depth 下降或 prompt_tps 上升；
- switch timing 小于目标阈值，例如 p95 < 1s；
- 持续负载 error rate 低于 1%。

### 6.2 Scenario B：触发 Prefill -> Decode Role Switch

目标：证明 decode backlog + prefill idle 时，controller 会自动把 prefill worker 切成 decode。

负载构造：

- prompt 较短；
- `max_tokens` 很大；
- 多个并发长 decode；
- prefill 很快结束，decode queue/running 持续高。

预期触发：

```text
decode_queue_depth >= threshold
prefill_utilization <= idle_threshold
prefill_worker_count > min_prefill_replicas
```

验收标准：

- controller decision log 出现 `prefill->decode`；
- target decode ModelCard 出现；
- generation_tokens_total 增长；
- decode throughput 提升；
- p99 latency 不显著恶化；
- no 5xx。

### 6.3 Scenario C：触发 Request Consolidation

目标：证明 batch tail 阶段 source decoder 只剩少量长尾请求时，controller 会自动迁移请求并释放 source。

负载构造：

- 固定 batch 长请求；
- 让请求长度具有差异，形成 tail；
- 等待 batch completion >= 60%；
- 确保某个 source decoder `in_flight_requests <= 3`；
- 目标 decoder 有 spare capacity。

预期触发：

```text
batch_completion_pct >= min_batch_completion_pct
source.in_flight_requests <= consolidation_threshold
target.available_capacity >= source.in_flight_requests
migration_time < remaining_time * 0.5
```

验收标准：

- controller decision log 出现 `consolidation`；
- 至少一次 migration `status=ok`；
- source active request count 下降；
- destination token counter 增长；
- source 可被 scale down 或标记 drainable；
- migration total wall time 小于剩余运行时间 50%；
- migrated client response 完整，无 5xx，无 truncation。

---

## 7. 当前实现还没达到的地方

### 7.1 E2E 没有走 controller 策略闭环

现有测试策略文档明确说明 S2/S3 脚本直接使用 sidecar。这是合理的 mechanism test，但不是 policy E2E。

缺口：

- 无法证明 `ROLE_SWITCH_ENABLED` 打开后 controller 会触发；
- 无法证明 `CONSOLIDATION_ENABLED` 打开后 controller 会触发；
- 无法证明触发原因、阈值、metrics 与行动结果一致。

建议：新增 controller-driven E2E，保留现有 sidecar E2E 作为机制层测试。

### 7.2 controller S2/S3 与主循环集成需要复核

当前 `main.py` 主循环主要调用 state machine tick；S2/S3 controller 是否接入主 loop 是关键差距。若未接入，即使策略模块和 sidecar 都正确，也不会自动触发。

建议：

- 在 controller runtime 中显式初始化 `ElasticRoleSwitchController` 和 `ConsolidationController`；
- 每个 control loop tick 按顺序调用 S3/S2/S1；
- 输出结构化 decision log；
- 暴露 `/debug/decisions` 或 Prometheus counter。

### 7.3 metrics collector 对 worker states 的支持不足

S2/S3 都依赖 `get_decode_worker_states()`，但现有 collector 默认可能返回空列表。没有 worker-level states，controller 无法选择 most-idle worker，也无法规划 consolidation pair。

建议补齐：

- worker addr；
- role；
- in_flight_requests；
- available_capacity；
- estimated_remaining_time；
- prompt/generation token rates；
- sidecar URL；
- current ModelCard role。

### 7.4 吞吐指标不够系统

现有脚本有 token counter delta，但缺少窗口化吞吐和对照组。

建议新增统一采样器：

```text
sample_metrics every 1s:
  pod, role, prompt_tokens_total, generation_tokens_total,
  num_requests_running, queue_depth, gpu_util, mem_used
```

自动计算：

```text
tokens/s = delta(counter) / delta(time)
```

### 7.5 Timing pass/fail 阈值没有统一定义

建议定义初始门槛：

| 指标 | 建议初始阈值 | 说明 |
|------|--------------|------|
| S2 switch server p95 | < 1000 ms | 当前历史约 430-450 ms，可先给 1s |
| S2 router convergence | < 2000 ms | CR watch 与 router 收敛 |
| S3 coordinated migration p95 | < 1000 ms | 具体依赖 NIXL/recompute path |
| S3 NIXL migrate_in | < recompute baseline 50% | 证明 connector path 有收益 |
| sustained load error rate | < 1% | 或 0 non-200 for smoke |
| TTFT p99 regression | < 20% | 与 baseline 相比 |
| generation tokens/s regression | < 10% | 与 baseline 相比 |

### 7.6 S3 NIXL verdict 缺少 PASS_TIMING / PASS_TOKENS_AFTER

建议修复 `test-s3-nixl-migration.sh`：

- 记录 destination `generation_tokens_total` before/after；
- 计算 `PASS_TOKENS_AFTER`；
- 构造 recompute baseline 或估算 replay cost；
- 将 `PASS_TIMING` 纳入最终 verdict；
- 报告中输出 connector vs recompute latency 对比。

---

## 8. Proposal：新增统一 E2E 脚本

### 8.1 文件建议

新增：

```text
test-scripts/test-policy-driven-s2-s3-e2e.sh
```

输出目录：

```text
test-scripts/reports/policy-driven-s2-s3-${TS}/
```

### 8.2 脚本阶段

```text
Phase 0: 环境检查
  - 至少 2 decode、1 prefill、1 frontend
  - controller running
  - ROLE_SWITCH_ENABLED / CONSOLIDATION_ENABLED 确认
  - Prometheus / sidecar / metrics 可访问

Phase 1: Baseline
  - 运行稳态负载 60s
  - 采集 request latency、TTFT、tokens/s、running requests

Phase 2: Prefill pressure
  - 长 prompt 短 output
  - 等待 controller 触发 decode->prefill
  - 采集 switch timing 与 throughput 变化

Phase 3: Decode pressure
  - 短 prompt 长 output
  - 等待 controller 触发 prefill->decode
  - 采集 decode throughput 与 latency

Phase 4: Tail consolidation
  - 固定 batch + 长尾请求
  - 等待 batch_completion >= threshold
  - 等待 controller 触发 consolidation
  - 采集 migration timing、source drain、destination progress

Phase 5: Report
  - 输出 timing table
  - 输出 throughput window table
  - 输出 decision log table
  - 输出 pass/fail verdict
```

### 8.3 关键输出文件

```text
REPORT.md
decisions.jsonl
metrics-1s.csv
requests.csv
switches.csv
migrations.csv
cr-before-after/*.json
controller.log
pod-logs/*.log
```

### 8.4 REPORT.md 必备章节

1. Environment and config；
2. Baseline throughput；
3. Strategy trigger evidence；
4. S2 timing and throughput impact；
5. S3 migration timing and throughput impact；
6. Client-visible latency and errors；
7. Pass/fail table；
8. Gaps / warnings。

---

## 9. Definition of Done

新的测试策略完成时，应满足：

1. Sidecar mechanism tests 仍然通过：

   ```text
   bash test-s2-elastic.sh
   bash test-s3-consolidation.sh
   bash test-s3-nixl-migration.sh
   ```

2. 新增 controller-driven E2E 可以证明：

   - 至少一次 S2 role switch 由 controller 自动触发；
   - 至少一次 S3 consolidation 由 controller 自动触发；
   - 每次触发都有 metrics + threshold + decision + result 证据；
   - Timing 指标满足阈值；
   - 吞吐指标有 baseline/action/post 对比；
   - 客户端无明显错误或 token truncation。

3. 报告能回答三个问题：

   ```text
   为什么触发？
   触发花了多久？
   触发后吞吐/latency/资源释放是否变好？
   ```

---

## 10. 结论

当前 `test-scripts` 已经很好地证明了 S2/S3 的 worker-side 能力：

- S2 能在约 400-500 ms 完成 role switch，并保持负载可用；
- S3 能迁移 in-flight request，NIXL 路径能证明真实 KV block transfer；
- 报告中已有 CR、token counter、active request、migration response、logs 等证据。

但下一阶段要满足“Timing + 吞吐 + 策略触发”的需求，必须从 mechanism E2E 升级到 policy-driven E2E：

```text
现有：直接调用 sidecar，证明动作能做
目标：制造负载和指标，让 controller 自动判断何时做，并证明做了以后性能/资源状态改善
```

建议保留现有三个脚本作为机制层回归测试，同时新增 `test-policy-driven-s2-s3-e2e.sh`，把 S2/S3 放进同一 RL-like 工作负载中，统一采集 timing、throughput、latency、decision log 和 pass/fail verdict。这样才能完整证明当前策略在端到端系统中的可行性与收益。