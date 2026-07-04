# Baseline：S2/S3 全部关闭

生成时间：2026-07-04T19:21:36

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
| baseline_wave | 24 | 100.00 | 100.00 | 12.39 | 1.94 | 3.79 | 496.04 |

## Controller / Worker 动作

- S2 history count: 0
- S2 executed count: 0
- S3 history count: 0
- S3 executed pairs: 0
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []

## 解释与结论

- Baseline 固定使用 2P+4D，controller 中 S2/S3 均关闭，用于提供端到端 wall time、吞吐、latency 和 valid decode 的对照。
- 该场景不应出现 S2/S3 history，也不应出现 migration 或 scale down。

## Artifact Index

- `requests.csv`：每条请求的 HTTP code、latency、token、finish_reason、content hash 和 valid_decode 判断。
- `responses/`：每条原始 HTTP response。
- `pod_samples.csv`：测试过程中实际 ready pod 数采样。
- `controller_status.jsonl`：controller `/api/v1/status` 原始采样，包含 S2/S3 history。
- `logs/`：controller 和 worker 日志，可继续排查 KV migration、rollback、500 等问题。
