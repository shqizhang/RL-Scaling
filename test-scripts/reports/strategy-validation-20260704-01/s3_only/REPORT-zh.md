# Request Consolidation Only：仅启用 S3

生成时间：2026-07-04T19:48:28

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
| s3_head_wave | 24 | 87.50 | 87.50 | 11.26 | 1.86 | 3.23 | 573.84 |
| s3_tail_wave | 48 | 91.67 | 91.67 | 19.14 | 2.30 | 4.26 | 954.00 |

## Controller / Worker 动作

- S2 history count: 0
- S2 executed count: 0
- S3 history count: 4
- S3 executed pairs: 4
- S3 migrated requests: 6
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7gzr9b', 'vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk', 'vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7gzr9b', 'vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk']
- S3 scaled down to: [3, 2, 3, 2]

## 解释与结论

- 该场景通过 sampling progress 和 tail decode wave 构造 Request Consolidation 触发窗口。
- 重点检查 S3 history 中的 plans、migrated_requests、drained_sources 和 scaled_down_to，以确认迁移后先 drain 再 scale down。
- 如果 requests.csv 中出现 HTTP 500 或 valid_decode 下降，说明当前 S3 对用户可见 stream continuity 仍存在正确性风险。

## Artifact Index

- `requests.csv`：每条请求的 HTTP code、latency、token、finish_reason、content hash 和 valid_decode 判断。
- `responses/`：每条原始 HTTP response。
- `pod_samples.csv`：测试过程中实际 ready pod 数采样。
- `controller_status.jsonl`：controller `/api/v1/status` 原始采样，包含 S2/S3 history。
- `logs/`：controller 和 worker 日志，可继续排查 KV migration、rollback、500 等问题。
