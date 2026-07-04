# PD Role Switch Only：仅启用 S2

生成时间：2026-07-04T19:36:40

## 指标解释

- Wall Time：该 phase 第一条请求发出到最后一条响应返回的端到端时间。
- req/s：HTTP 200 成功请求数 / Wall Time，表示用户请求吞吐。
- p95 latency：该 phase 单请求端到端 latency 的 95 分位。
- user completion tok/s：成功响应中的 completion tokens / Wall Time，表示用户可见生成吞吐。
- valid decode：HTTP 200、响应 JSON 可解析、completion_tokens > 0 且 finish_reason 为 stop 或 length 的请求数。
- pod count：`pod_samples.csv` 中采样的 ready prefill/decode worker 数量，用于还原每个阶段实际运行的 pod 数。
- S3 migrated requests：controller status 中 S3 history 记录的 migrated_requests，用于确认哪些 source/target worker 执行了 request/KV 接管。

## Phase 结果

| phase | requests | success % | valid decode % | wall(s) | req/s | p95(s) | user tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| s2_prefill_heavy_wave | 24 | 100.00 | 100.00 | 20.48 | 1.17 | 13.47 | 149.99 |

## Controller / Worker 动作

- S2 history count: 0
- S2 executed count: 0
- S3 history count: 0
- S3 executed pairs: 0
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []

## 解释与结论

- 默认模式下脚本手动调用目标 decode worker sidecar 的 /switch_role，将其切为 prefill，以验证 worker 端 PD role switch 机制和切换后的端到端 decode 完整性。
- 可选 --use-controller-auto 会把 PREFILL_QUEUE_THRESHOLD 设置为 0，用于测试 controller S2 自动触发链路；该模式应在报告中与真实压力触发分开解释。
- 该场景不启用 Request Consolidation，不应出现 S3 migration 或 scale down。

## Artifact Index

- `requests.csv`：每条请求的 HTTP code、latency、token、finish_reason、content hash 和 valid_decode 判断。
- `responses/`：每条原始 HTTP response。
- `pod_samples.csv`：测试过程中实际 ready pod 数采样。
- `controller_status.jsonl`：controller `/api/v1/status` 原始采样，包含 S2/S3 history。
- `logs/`：controller 和 worker 日志，可继续排查 KV migration、rollback、500 等问题。
