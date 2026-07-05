# baseline Pressure Window E2E

生成时间：2026-07-05T16:50:29

## 数据与指标

本场景使用统一 pressure manifest：96 条超长 prompt prefill-pressure 请求、48 条 decode-head 请求、24 条受控 decode-tail 请求。

- Wall Time：第一条请求发出到最后一条响应完成的端到端时间。
- req/s：HTTP 200 成功请求数 / Wall Time。
- prompt tok/s：成功请求 prompt_tokens / Wall Time，主要反映 prefill 压力。
- completion tok/s：成功请求 completion_tokens / Wall Time，主要反映 decode 生成吞吐。
- valid decode：HTTP 200、JSON 可解析、completion_tokens > 0、finish_reason 为 stop 或 length。
- request-window GPU seconds：请求窗口内 ready worker GPU 数量对时间积分。

## 总体结果

- requests: 96
- success / valid decode: 100.00% / 100.00%
- wall time: 35.22s
- req/s: 2.73
- p95 latency: 3.16s
- prompt tok/s: 9641.38
- completion tok/s: 568.90
- request-window GPU seconds: 198.14

## S2 观测窗口

- evaluation count: 0
- max prefill_queue_depth: 0
- max decode_queue_depth: 0
- max prefill_worker_active: 0
- max decode_worker_active: 0
- selected actions: []
- top skip reasons: []

## S3 动作

- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
