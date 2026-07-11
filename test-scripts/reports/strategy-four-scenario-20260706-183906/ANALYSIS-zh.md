# 四场景一致性测试结果分析

生成时间：2026-07-06 19:16

本轮最终原始数据目录：

`C:\projects\IP\RL-Scaling\test-scripts\reports\strategy-four-scenario-20260706-183906`

## 1. 结论摘要

本轮测试没有达到“策略优于 baseline minimal”的预期，不能作为正向性能结论用于答辩。

可以确认的事实：

- Readiness gate 通过，controller/worker telemetry 可采集。
- Baseline minimal 质量门通过：130/130 request 全部 valid decode，无 timeout。
- S2 动作发生且受控：`decode->prefill` 和 `prefill->decode` 各 1 次，总计 2 次，没有高频 PD switch。
- S3 controller 能产生 consolidation plan / attempt；在 canary 中曾观测到 `migrated=1, drained=1`，说明 GPU-side consolidation 机制可触发。

未满足的目标：

- S2 only、S3 only、Mixed 均出现 1 个 tail request timeout，质量门失败。
- S2 only 的 prefill wall 没有改善，反而从 baseline 的 49.57s 增加到 52.83s。
- S3 only 和 Mixed 在最终正式 run 中没有成功 migration/drain 证据，只有 attempt/decline 或无迁移。
- Baseline minimal 仍是 wall time 和 tokens/GPU-second 最优场景。

因此，本轮只能作为“问题定位数据”，不能作为“最终方案性能提升数据”。

## 2. 核心数据

| scenario | performance_valid | wall(s) | valid decode % | timeout | prefill wall(s) | tail wall(s) | GPU-s | tokens/GPU-s | S2 exec | S3 attempts | S3 migrated | S3 drained |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | true | 88.51 | 100.00 | 0 | 49.57 | 16.62 | 167.91 | 99.48 | 0 | 0 | 0 | 0 |
| s2_only | false | 212.54 | 99.23 | 1 | 52.83 | 134.26 | 827.46 | 20.11 | 2 | 0 | 0 | 0 |
| s3_only | false | 185.13 | 99.23 | 1 | 30.55 | 134.77 | 725.41 | 22.94 | 0 | 1 | 0 | 0 |
| mixed_strategy | false | 208.14 | 99.23 | 1 | 49.07 | 134.20 | 828.94 | 20.07 | 2 | 0 | 0 | 0 |

## 3. S2 分析

S2 这次至少修正了上一轮最大的问题：没有再出现 6 次 PD switch。

观测结果：

- `s2_executed_count = 2`
- directions: `decode->prefill`, `prefill->decode`
- S3 history 为 0，场景隔离正确

但效能没有体现：

- baseline `prefill_burst.wall_s = 49.57s`
- s2_only `prefill_burst.wall_s = 52.83s`
- S2 prefill wall improvement = -6.59%

解释：

1. S2 动作正确发生，但没有转化为 prefill phase 吞吐提升。
2. Dynamic topology 引入了额外 GPU allocated seconds，且 tail 阶段出现 1 个 timeout，导致整体 wall time 被拉长。
3. S2 当前更像“机制正确性通过”，但还不是“效能证明通过”。

下一步需要检查：

- D->P 后 frontend 是否真实把 prefill load 路由到新增 prefill worker。
- role switch 后 worker 是否完成 ModelCard/CR 更新并被 router 及时感知。
- 第二个 dynamic decode worker 是否存在偶发 tail request hang；baseline 1D 不出现 timeout，而 dynamic 2D 场景出现 1 个 timeout。

## 4. S3 分析

S3 当前最大问题不是 workload，而是 migration/drain 成功率和 client continuity。

正式 run：

- s3_only: `migration_attempts=1, migrated=0, declined=1, drained=0`
- mixed_strategy: `migration_attempts=0, migrated=0, drained=0`

canary 中曾出现：

- `migration_attempts=2`
- `migrated=1`
- `declined=1`
- `drained=1`
- tail decode GPU-second savings 约 51.7%
- 同时有 1 个 migrated/tail request timeout

这说明 S3 GPU-side consolidation/drain 可以触发，但 client-side response continuity 仍然没有闭环。也就是说，当前 S3 更适合作为 GPU/engine 侧机制验证，不能直接声称对用户端 batch request 完全无损。

下一步需要检查：

- sidecar `/migrate` declined 的具体原因，尤其是 request 是否已经接近完成、block-hold 是否失败、connector metadata 是否缺失。
- migrated request 是否仍由原 client stream 等待；若迁移后由 engine drain-and-discard，则正式 client correctness 必然出现 timeout 或缺失响应。
- 如果论文结论要包含 client-visible S3，需要补 frontend stream reattach 或明确把 S3 指标限定为 GPU-side resource release。

## 5. Mixed 分析

Mixed 没有达到最佳性能。

原因：

- S2 虽然执行了 2 次，但 prefill phase 没有提升。
- S3 在 mixed 中没有 migration/drain 成功证据。
- dynamic topology 中 tail request 仍有 1 个 timeout。
- GPU allocated seconds 明显高于 baseline，tokens/GPU-second 下降。

因此，Mixed 当前不是“组合策略最佳”，而是暴露了两个问题叠加：

1. S2 动作正确但收益未显现。
2. S3 自动闭环不稳定，且 client continuity 未证明。

## 6. 对测试策略的更正建议

保留当前脚本的质量门，不应为了得到好看的数字放宽：

- `valid_decode_pct >= 99%`
- `timeout_count == 0`
- S2 switch count <= 2
- S3 必须有 migrated/drained 证据

但后续测试应拆成两层：

1. Client-visible performance suite
   - 要求 timeout=0。
   - S3 只有在 stream continuity 补齐后才能纳入。
   - 当前可先用于 Baseline 与 S2 的 wall-time/throughput 验证。

2. GPU-side S3 mechanism suite
   - 允许把 migrated request 作为 engine-side takeover 证据单独记录。
   - 不把 migrated request 的 client timeout 计入“无损用户请求”结论。
   - 主指标是 tail decode GPU-second savings、drained source count、scale-down release latency。

## 7. 下一步最短修复路径

1. 定位 dynamic 2D tail timeout
   - 同一 workload 下 baseline 1D 无 timeout，dynamic 场景有 1 个 tail timeout。
   - 需要检查新增 decode pod 的 worker log、router log、request registry。

2. 验证 S2 D->P 是否真正提升 prefill capacity
   - 读取 D->P 后 worker role label、ModelCard、router target。
   - 比较每个 prefill worker 的 active request/token 采样，而不只看总 wall time。

3. 修复或界定 S3 client continuity
   - 若目标是用户端无损，需要实现 frontend stream reattach。
   - 若目标是 GPU-side drain，需要在论文中明确 S3 不纳入 client-visible correctness，单独作为 resource release 机制。

4. 重新跑四场景
   - 只有当 dynamic 2D tail timeout 消失，并且 S3 migration/drain 成功稳定后，才能期待 Mixed 成为最佳。
