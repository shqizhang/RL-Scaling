# RL-Scaling Controller Strategy E2E 深度测试总结

生成时间：2026-07-04 20:15

本轮先清理了旧 `test-scripts/reports` 和旧测试脚本，提交清理基线 `6364a79`；随后新增四个独立场景脚本并提交 `13ebd4a`。本报告汇总同一 suite 目录下的四组测试数据：

- `baseline/`：S2/S3 全部关闭。
- `s2_only/`：仅验证 PD Role Switch。
- `s3_only/`：仅验证 Request Consolidation。
- `strategy/`：controller 混合策略路径，覆盖 D->P、prefill scale-up 窗口、P->D、decode tail、S3 consolidation、drain 后 scale down。

## 1. 指标口径

- Wall Time：某个 phase 内第一条 measured request 发出，到最后一条 response 返回的端到端时间。
- req/s：HTTP 200 成功请求数 / Wall Time，表示用户请求吞吐，不是 engine 内部 batch 数。
- p95 latency：单请求端到端 latency 的 95 分位，用于观察尾延迟。
- user completion tok/s：成功 HTTP 响应中的 completion tokens / Wall Time，表示用户可见 token 生成吞吐。
- valid decode：HTTP 200、响应 JSON 可解析、completion_tokens > 0，且 finish_reason 为 `stop` 或 `length`。这是本轮对“最终 decode 结果完整”的可执行校验。
- pod count：`pod_samples.csv` 中每 2 秒采样的 ready prefill/decode worker 数量，反映测试过程中实际运行的 pod 数。
- S2 history：controller `/api/v1/status` 中的 role switch decision 历史，包含 from_role、to_role、worker_url、reason、switch_time_ms。
- S3 history：controller `/api/v1/status` 中的 consolidation decision 历史，包含 source、target、request_count、migrated_requests、declined_requests、drained_sources、scaled_down_to。

## 2. 四组结果总表

| 场景 | phase | requests | success % | valid decode % | wall(s) | req/s | p95(s) | user tok/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline | baseline_wave | 24 | 100.00 | 100.00 | 12.39 | 1.94 | 3.79 | 496.04 |
| S2 only | s2_prefill_heavy_wave | 24 | 100.00 | 100.00 | 20.48 | 1.17 | 13.47 | 149.99 |
| S3 only | s3_head_wave | 24 | 87.50 | 87.50 | 11.26 | 1.86 | 3.23 | 573.84 |
| S3 only | s3_tail_wave | 48 | 91.67 | 91.67 | 19.14 | 2.30 | 4.26 | 954.00 |
| Strategy | strategy_prefill_peak | 24 | 100.00 | 100.00 | 7.95 | 3.02 | 2.78 | 386.53 |
| Strategy | strategy_decode_tail | 48 | 93.75 | 93.75 | 17.93 | 2.51 | 3.95 | 1018.68 |

## 3. Baseline

Baseline 在固定 2P+4D、S2/S3 全关闭下运行，24/24 请求成功，valid decode 100%。这组数据证明当前 Dynamo frontend 到 worker 的基本请求链路健康，也为后续场景提供对照：

- Wall Time：12.39s。
- req/s：1.94。
- p95 latency：3.79s。
- user completion tok/s：496.04。
- S2/S3 history 均为 0，符合预期。

## 4. S2 Only：PD Role Switch

S2 only 使用 worker sidecar 明确执行一次 `decode -> prefill`，再跑 prefill-heavy 请求，最后 cleanup 切回 decode。选择 sidecar 机制测试的原因是：当前 controller 的真实 prefill queue 指标仍不稳定，直接用 sidecar 可以验证 worker 端 PD role switch 机制本身。

关键证据：

- `manual_switch_decode_to_prefill_done`：`status=ok`，`new_role=prefill`，`switch_time_ms=433.58ms`。
- `cleanup_switch_back_decode`：`status=ok`，`new_role=decode`，`switch_time_ms=407.35ms`。
- prefill-heavy wave：24/24 成功，valid decode 100%。
- S3 history 为 0，说明没有混入 Request Consolidation。

解释：

S2 机制本身可用，role switch 后端到端请求仍能完整 decode。该场景的 p95 latency 为 13.47s，高于 Baseline，原因是 workload 不同：S2 用 1200 prompt words 构造 prefill-heavy 压力，而 Baseline 是 256 prompt words。

## 5. S3 Only：Request Consolidation

S3 only 启用 `CONSOLIDATION_ENABLED=true` 和 `CONSOLIDATION_SCALE_DOWN_ENABLED=true`，关闭 S2。脚本通过 head wave + long tail wave 构造 decode 尾部请求分散窗口。

关键证据：

- S3 history count：4。
- S3 executed pairs：4。
- S3 migrated requests：6。
- S3 scaled_down_to：`[3, 2, 3, 2]`。
- S3 drained sources：
  - `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7gzr9b`
  - `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk`

结果解释：

S3 controller 发现 source decoder 上存在少量 tail request，target decoder 有足够 capacity，于是迁移 request，并在 source drain 后触发 scale down。`drained_sources` 与 `scaled_down_to` 同时出现，证明当前 scale-down 不是“只要检测到 consolidation 就缩容”，而是依赖 worker drain 结果。

问题：

S3 only 的 success/valid decode 不是 100%：head wave 87.50%，tail wave 91.67%。这说明 Request Consolidation 触发后仍可能影响用户可见请求。结合已有实现，worker 端 migration 能完成 request 接管和资源释放，但 Dynamo frontend/client stream reattach 仍不完整，导致部分请求出现 HTTP 500 或不完整 response。这是 S3 生产化前必须修复的 correctness blocker。

## 6. Controller Mixed Strategy

Strategy 场景按以下路径构造：

1. 健康 2P+4D 启动。
2. `PREFILL_QUEUE_THRESHOLD=0` 构造 controller 可观测的 D->P 触发窗口。
3. controller 触发 `decode -> prefill`。
4. 脚本记录 prefill scale-up 窗口，并将 prefill deployment 保底到 3。
5. controller 触发 `prefill -> decode`。
6. decoder capacity 恢复到 4D。
7. 关闭 S2，只保留 S3，构造 long-tail decode。
8. S3 迁移并在 source drain 后 scale down。

关键证据：

- S2 history count：13。
- S2 executed count：8。
- controller status 中出现 D->P：
  - worker `http://10.244.0.187:9091`，`decode -> prefill`，`switch_time_ms=532.36ms`。
  - worker `http://10.244.0.99:9091`，`decode -> prefill`，`switch_time_ms=416.34ms`。
- controller status 中出现 P->D：
  - worker `http://10.244.0.187:9091`，`prefill -> decode`，`switch_time_ms=426.66ms`。
  - worker `http://10.244.0.99:9091`，`prefill -> decode`，`switch_time_ms=414.74ms`。
- S3 history count：2。
- S3 executed pairs：4。
- S3 migrated requests：8。
- S3 scaled_down_to：`[3, 2]`。
- S3 drained sources：
  - `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk`
  - `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7nmh8t`

结果解释：

Strategy 场景完成了本轮要求的主要动作链：D->P、P scale-up 窗口、P->D、decode tail、S3 migration、drain 后 scale down。prefill peak 阶段 24/24 成功，valid decode 100%；decode tail 阶段 45/48 成功，valid decode 93.75%。这说明组合策略路径可以驱动资源形态变化并保持大部分请求完整，但 S3 触发窗口仍会带来少量用户可见失败。

重要限制：

本轮为了让 controller 真实写出 S2 history，使用 `PREFILL_QUEUE_THRESHOLD=0` 作为可观测窗口构造。它证明 controller 能执行 S2 决策链路，但不等价于生产阈值。生产测试需要把真实 `prefill_queue_depth` 或 prefill active request 指标接稳，让 threshold 使用业务含义明确的正数。

## 7. 数据有效性与因果关系

Baseline 证明基础请求链路健康；S2 only 证明 PD role switch 机制不破坏最终 decode；S3 only 证明 Request Consolidation 能迁移 request、记录 drained source 并触发 scale down；Strategy 证明 controller 能按阶段串联 S2 和 S3。

最关键的因果链：

- S2：构造 prefill pressure window -> controller/sidecar 执行 role switch -> worker new_role 改变 -> prefill-heavy request 仍 100% valid decode。
- S3：构造 decode tail window -> controller 发现 source/target plan -> migrated_requests 增加 -> drained_sources 记录 source 已 drain -> scaled_down_to 变为 3/2。
- Strategy：先通过 S2 调整 P/D 角色，再恢复 decoder，再通过 S3 consolidation 释放 decode worker。

## 8. 当前问题

1. S2 自动触发仍依赖测试阈值窗口：`PREFILL_QUEUE_THRESHOLD=0` 是测试构造，不是生产策略。需要接入真实 prefill queue / active request 指标。
2. S3 migration 会导致部分请求失败：S3 only 和 Strategy 都出现 success/valid decode 下降。当前 worker 端 migration 和 drain 逻辑可验证，但 frontend/client stream reattach 仍需修复。
3. Strategy 中部分 P->D attempts 失败：controller status 记录了某些 `executed=false` 的 P->D 尝试，说明 role switch target 选择和 cooldown/gating 还需要更严格。
4. GPU effective hour 本轮主要通过 pod allocation 和 pod count 观察，尚未接入 DCGM exporter 的 GPU busy time 积分。

## 9. Artifact Index

- `baseline/REPORT-zh.md`：Baseline 场景报告。
- `s2_only/REPORT-zh.md`：PD Role Switch 场景报告。
- `s3_only/REPORT-zh.md`：Request Consolidation 场景报告。
- `strategy/REPORT-zh.md`：混合策略场景报告。
- 每个场景目录下：
  - `requests.csv`：逐请求 HTTP code、latency、token、finish_reason、content hash、valid_decode。
  - `responses/`：原始 HTTP response。
  - `pod_samples.csv`：实际运行 pod 数采样。
  - `controller_status.jsonl`：controller 原始策略状态。
  - `logs/`：controller 和 worker 日志。

## 10. 总结

本轮测试比之前更完整地覆盖了机制测试和混合策略测试。方案的可行性体现在：S2 可以在 worker 端完成 PD role switch 并保持请求完整；S3 可以迁移 tail requests、等待 source drain 后再 scale down；混合策略可以串联 D->P、P->D、tail consolidation 和 scale down。

但方案距离生产可用仍有两个硬问题：S2 需要真实可观测的 prefill pressure 指标，S3 需要修复 migration 后的用户流连续性。当前测试数据已经把这两个问题和资源调度收益分开呈现：资源动作可行，但 correctness 仍需补强。
