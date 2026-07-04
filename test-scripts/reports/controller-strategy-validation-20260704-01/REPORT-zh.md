# Controller Strategy 完整验证报告（2026-07-04）

## 1. 测试目标与结论摘要

本轮测试使用标准 CI 镜像 `ghcr.io/shqizhang/rl-scaling-controller:ca629b7` 部署 controller，并确认 Deployment 中已经移除历史 ConfigMap code overlay，运行时从镜像内 `/app/rl-scaling-controller/src` 加载代码。测试覆盖：

1. Baseline：`ROLE_SWITCH_ENABLED=false`，`CONSOLIDATION_ENABLED=false`。
2. 测试脚本 Enable S2。
3. 测试脚本 Enable S3。
4. 测试脚本 Enable Both/BOSS。
5. Controller Auto Strategy：由 controller 自动检测 S3 consolidation/scale down/scale up。
6. 独立 Controller Auto S2：用于验证 prefill-heavy 请求是否能触发 PD Role Switch。

核心结论：

- S3 Request Consolidation 的资源释放路径可验证：机制矩阵中 S3 only 和 Both/BOSS 都完成 decode `4 -> 2 -> 4`，释放约 `0.150 GPU-hour` allocation；低负载窗口 allocated GPU-hours 从 Baseline `0.0171` 降到 S3 `0.0107`，下降约 `37.22%`。
- Controller auto strategy 能自动观察到 S3 consolidation 窗口并触发 migration/scale down/scale up：`s3_executed_pairs=8`，`s3_migrated_requests=8`，观察到 decode replica 降到 2 后又恢复到 4。
- 新增的 S3 drain gate 生效：controller status 中只有 `drained_sources` 非空的成功迁移才触发 `scaled_down_to`；迁移被 declined 的计划记录 `scale_down_blocked_reason=no_fully_migrated_source`，没有缩容。
- S2 自动 PD Role Switch 仍未被真实指标触发：独立 prefill-heavy 测试 `48/48` 成功，但 `s2_history_count=0`。原因不是 role switch sidecar 不可用，而是当前 controller 可观测到的 `prefill_queue_depth`/prefill active request 没有形成触发窗口。
- Request Consolidation 仍存在用户可见 500：auto strategy 中 low-tail 成功率 `83.33%`，high-after 成功率 `87.50%`。这与 S3 migration 成功发生在同一窗口，说明 worker 侧迁移/释放路径可工作，但当前 Dynamo frontend/client streaming 连续性还没有被 migration 机制完整接续。

## 2. 数据与指标口径

### 2.1 测试数据流

所有请求均从测试脚本发起到真实 Dynamo frontend，再由 frontend 路由到 K8s 中的 prefill/decode worker。测试脚本记录 HTTP response、latency、token 数；controller 通过 Prometheus 与 worker sidecar `/v1/role`、`/v1/active_requests` 获取状态，并调用 sidecar `/switch_role` 或 `/migrate` 执行动作。

机制矩阵使用统一 workload：

- high-before：24 requests，concurrency=6，max_tokens=384。
- low-tail：8 requests，concurrency=2，max_tokens=192。
- high-after：24 requests，concurrency=6，max_tokens=384。

Controller auto strategy 使用更长 tail 窗口：

- high-before：24 requests，concurrency=6，max_tokens=512。
- low-tail：24 requests，concurrency=4，max_tokens=768。
- high-after：24 requests，concurrency=6，max_tokens=512。

### 2.2 指标解释

- Wall Time：某个阶段内第一条 measured request 发出，到最后一条 measured response 返回之间的跨度。它衡量这一批用户请求整体完成时间。
- req/s：HTTP 200 成功请求数 / Wall Time。这里是 Dynamo frontend 端到端用户请求吞吐，不是 engine 内部 batch 数。
- p50/p95/p99 latency：单条用户请求端到端 latency 的 50/95/99 分位。p95/p99 主要反映尾延迟。
- user completion tok/s：HTTP 200 响应中 completion tokens 总数 / Wall Time。它代表用户可见输出 token 的吞吐，不包含 migration replay 或内部 engine token。
- allocated GPU-hours：阶段内 ready worker GPU 数量乘以时间再除以 3600，表示该阶段实际占用的 GPU allocation。
- GPU effective busy hours：用 `nvidia-smi` 采样的 GPU utilization 积分估算的忙碌 GPU-hour，是粗粒度 proxy。
- GPU idle hours：allocated GPU-hours - GPU effective busy hours。越低表示空闲 allocation 越少。
- effective-hour utilization：GPU effective busy hours / allocated GPU-hours。该值越高表示已分配 GPU 更少闲置；但在发生 scale down 时，allocated GPU-hours 本身下降也很重要，不能只看 utilization 百分比。
- released GPU-hours：从 decode `4 -> 2` 到恢复 `2 -> 4` 之间释放的 GPU allocation 时间，计算为释放 GPU 数量乘以持续秒数再除以 3600。

## 3. 机制矩阵结果：Baseline / S2 / S3 / Both

| 场景 | high-before success | high-before wall(s) | high-before req/s | high-before p95(s) | low-tail success | low-tail wall(s) | high-after success | high-after wall(s) | released GPU-hours |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline | 100.00% | 13.23 | 1.81 | 3.48 | 100.00% | 10.27 | 100.00% | 13.60 | 0.0000 |
| S2 only | 100.00% | 13.56 | 1.77 | 3.66 | 100.00% | 10.18 | 100.00% | 13.13 | 0.0000 |
| S3 only | 100.00% | 12.90 | 1.86 | 3.38 | 100.00% | 9.67 | 100.00% | 12.66 | 0.1504 |
| Both/BOSS | 100.00% | 12.89 | 1.86 | 3.27 | 100.00% | 9.77 | 100.00% | 13.60 | 0.1502 |

解释：

- Baseline 固定 2P+4D，不释放 GPU，因此 released GPU-hours 为 0。
- S2 only 在这组机制矩阵中只验证 S2 开关不会误触发 replica release，因此 released GPU-hours 也为 0。
- S3 only 和 Both/BOSS 在低负载/长尾窗口触发 release path，完成 decode `4 -> 2`，并在 high-after 前恢复 decode `2 -> 4`。
- S3 only 的 high-before wall time 相比 Baseline 改善约 `2.51%`，high-after wall time 改善约 `6.91%`；Both/BOSS 的 high-before wall time 改善约 `2.57%`。这些差异不应单独作为绝对性能收益结论，因为机制矩阵的主要目标是证明同一 workload 下资源释放逻辑正确。

## 4. GPU Allocation 与资源释放

| 场景 | low allocated GPU-hours | low busy GPU-hours | low idle GPU-hours | low effective util | released GPU-hours |
|---|---:|---:|---:|---:|---:|
| Baseline | 0.0171 | 0.0000 | 0.0171 | 0.00% | 0.0000 |
| S2 only | 0.0170 | 0.0000 | 0.0170 | 0.00% | 0.0000 |
| S3 only | 0.0107 | 0.0000 | 0.0107 | 0.00% | 0.1504 |
| Both/BOSS | 0.0109 | 0.0000 | 0.0109 | 0.00% | 0.1502 |

解释：

- S3 only 相比 Baseline，低负载窗口 allocated GPU-hours 从 `0.0171` 降到 `0.0107`，下降约 `37.22%`。
- Both/BOSS 相比 Baseline，低负载窗口 allocated GPU-hours 从 `0.0171` 降到 `0.0109`，下降约 `36.56%`。
- 这说明 consolidation 的直接收益不是让剩余 GPU 的采样 utilization 必然升高，而是把闲置请求集中后释放 worker allocation。生产场景中，这个释放窗口可以让 GPU 被其他 RL rollout、训练或推理任务复用。
- 本轮 GPU busy hours 由 `nvidia-smi` 粗粒度采样估算，采样窗口较短，部分阶段显示 0。后续若要精确计算 GPU effective hour，应接入 DCGM exporter 并对 GPU busy time 做积分。

## 5. Controller Auto Strategy 结果

| 场景 | S2 executed | S3 executed pairs | migrated requests | scale down observed | scale up observed | low-tail success | high-after success |
|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline auto 对照 | 0 | 0 | 0 | False | True | 100.00% | 100.00% |
| Controller Auto Strategy | 0 | 8 | 8 | True | True | 83.33% | 87.50% |

解释：

- Auto Strategy 的 controller 自动选择了 S3，而不是 S2：`s3_executed_pairs=8`、`s3_migrated_requests=8`，`s2_executed_count=0`。
- `s3_scaled_down_to=3;2;3;2;3;2;2` 表明 controller 多次根据迁移和 drain 结果调整 decode replicas，最终观察到 scale down 到 2。
- auto strategy 的 low-tail GPU effective busy hours 从 Baseline `0.000825` 降到 `0.000272`，idle hours 从 `0.002508` 降到 `0.001950`。这里的改善含义是：controller 释放了部分 GPU allocation，使空闲 GPU 时间减少；不是说单卡 utilization 百分比一定提高。
- auto strategy 出现 500，因此端到端用户成功率下降。这个问题必须作为 correctness blocker 单独修复，不能用 GPU 释放收益掩盖。

## 6. S2 自动 PD Role Switch 验证

独立 S2 auto 测试使用 2P+4D，`ROLE_SWITCH_ENABLED=true`、`CONSOLIDATION_ENABLED=false`，发送 48 条 prefill-heavy 请求，concurrency=12，prompt_words=1600，max_tokens=128。

结果：

- 请求成功率：100.00%。
- wall time：38.76s。
- p95 latency：18.88s。
- `s2_history_count=0`。
- `s2_executed_count=0`。

结论：

- 当前 controller 没有自动触发 PD Role Switch。
- 从代码看，S2 的正式条件是 `prefill_queue_depth >= PREFILL_QUEUE_THRESHOLD`、`decode_utilization <= DECODE_IDLE_THRESHOLD`、`decode_worker_count > MIN_DECODE_REPLICAS`、满足 `MIN_SWITCH_INTERVAL`。
- 当前 `prefill_queue_depth` 先查 Prometheus `dynamo_frontend_queued_requests{role="prefill"}`，若为 0 再用 prefill worker sidecar active request 汇总 fallback。本轮 prefill-heavy 请求没有让这两个来源形成可观测 backlog，因此 S2 没有决策记录。
- 因此当前缺口是 S2 pressure metric 的可观测性，而不是 sidecar `/switch_role` 机制本身。要让生产 controller 自动做 S2，需要把真实 prefill queue、prefill in-flight 或 frontend admission backlog 接入为稳定指标，并在 status/log 中暴露每 tick 的 S2 输入值。

## 7. Request Consolidation 500 与 Scale Down 正确性

### 7.1 500 问题

Auto Strategy 的 `requests.csv` 中有多条 HTTP 500：

- low-tail 阶段 4 条 500，错误为 `HTTP Error 500: Internal Server Error`。
- high-after 阶段 3 条 500。

结合已有代码路径，S3 migration 的当前实现是：source worker 执行 `migrate_out`，target worker 执行 `migrate_in` 并重新 submit request，source 在 `migration_complete` 后 abort 原请求。target 侧会继续生成并 drain/discard 输出，但当前没有把原始 Dynamo frontend/client stream 重新接到 target worker。因此迁移对 worker 资源释放有效，但对用户可见 streaming continuity 仍不完整，容易表现为 `Stream ended before generation completed` 或 HTTP 500。

这意味着：

- S3 资源释放机制可验证。
- S3 对在线用户请求的透明迁移还不能判定为生产可用。
- 后续需要在 Dynamo frontend/request registry 层实现 stream reattach，或者限制 S3 只迁移可重试/非用户可见请求。

### 7.2 Scale Down Drain Gate

本轮部署包含 drain-gated scale down 修复。controller status 显示：

- 迁移 declined 的计划：`executed_pairs=0`、`migrated_requests=0`、`drained_sources=[]`、`scale_down_blocked_reason=no_fully_migrated_source`、`scaled_down_to=null`。
- 成功迁移的计划：`executed_pairs=1/2`、`migrated_requests=1/2`、`drained_sources=[source_worker]`、随后才出现 `scaled_down_to=3` 或 `scaled_down_to=2`。

这验证了新的 scale down 逻辑不再是“controller 检测到 consolidation 就立即缩容”，而是先确认 source worker drain 后才缩容。

## 8. 当前问题与建议

1. S2 自动触发缺少可靠 pressure metric：需要把 prefill queue/in-flight/admission backlog 接入 Prometheus 或 sidecar，并在 controller status 中暴露 `prefill_queue_depth`、`decode_utilization`、worker counts、cooldown 判断。
2. S3 用户可见 500 是 correctness blocker：需要实现 target request 与原 frontend stream 的接续，或先把 consolidation 限制在可重试请求。
3. Auto Strategy 目前会选择 S3 并执行 scale down/up，但还不能证明 S2/S3/S1 的完整生产级顶层策略最优选择。后续应增加明确的 top-level policy：prefill pressure 优先 S2，decode long-tail 优先 S3，整体 capacity 不足时 S1 scale up。
4. GPU effective hour 目前仍是 `nvidia-smi` proxy。生产级报告应接 DCGM exporter，按 pod/GPU 维度积分 busy time、memory、SM occupancy。

## 9. 原始证据路径

- 机制矩阵：`C:\projects\IP\RL-Scaling\test-scripts\reports\strategy-scale-matrix-e2e-20260704-01`
- Controller auto strategy：`C:\projects\IP\RL-Scaling\test-scripts\reports\controller-auto-strategy-e2e-20260704-01`
- Controller auto S2：`C:\projects\IP\RL-Scaling\test-scripts\reports\controller-auto-s2-e2e-20260704-02`
- 失败的本地脚本目录（仅用于排查，不纳入性能对比）：`C:\projects\IP\RL-Scaling\test-scripts\reports\controller-auto-s2-e2e-20260704-01`
