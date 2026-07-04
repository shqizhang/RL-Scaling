# Controller Mixed Strategy：S2 + S3 自动/半自动闭环

生成时间：2026-07-04T20:11:41

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
| strategy_prefill_peak | 24 | 100.00 | 100.00 | 7.95 | 3.02 | 2.78 | 386.53 |
| strategy_decode_tail | 48 | 93.75 | 93.75 | 17.93 | 2.51 | 3.95 | 1018.68 |

## Controller / Worker 动作

- S2 history count: 13
- S2 executed count: 8
- S3 history count: 2
- S3 executed pairs: 4
- S3 migrated requests: 8
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk', 'vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk', 'vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7nmh8t']
- S3 scaled down to: [3, 2]

## 解释与结论

- 该脚本从低 P/D available 拓扑启动，先构造 prefill pressure，让 controller 有机会触发 D->P role switch。
- 随后记录 prefill scale-up 窗口、decoder 恢复、长尾 decode 和 Request Consolidation scale down。
- 当前为了形成 controller 可观测触发窗口，PREFILL_QUEUE_THRESHOLD=0。报告需要把这一点解释为测试窗口构造，不等同于生产阈值。
- S3 scale down 的正确性以 drained_sources 和 scaled_down_to 的先后关系为准；如果 source 未 drain，应只出现 scale_down_blocked_reason，不应缩容。

## Artifact Index

- `requests.csv`：每条请求的 HTTP code、latency、token、finish_reason、content hash 和 valid_decode 判断。
- `responses/`：每条原始 HTTP response。
- `pod_samples.csv`：测试过程中实际 ready pod 数采样。
- `controller_status.jsonl`：controller `/api/v1/status` 原始采样，包含 S2/S3 history。
- `logs/`：controller 和 worker 日志，可继续排查 KV migration、rollback、500 等问题。
