# strategy

生成时间：2026-07-05T12:19:09

## 测试数据

本场景使用 suite 根目录下同一份 `workload-manifest.jsonl`。所有场景的请求数量、prompt 长度分布、max_tokens 分布、phase 顺序和并发度保持一致。

- `prefill_peak`：24 条长 prompt、短 decode 请求，用于制造 prefill 压力。
- `decode_head`：24 条中等 prompt、中等 decode 请求，用于形成正常 decode batch。
- `decode_tail`：24 条短 prompt、长 decode 请求，用于制造长尾 decode 和 Request Consolidation 触发窗口。

## 指标解释

- Wall Time：该 phase 第一条请求发出到最后一条响应返回的端到端时间；total 行表示整个 manifest 从第一条请求到最后一条响应完成。
- req/s：HTTP 200 成功请求数除以 Wall Time，表示用户可见请求吞吐，不是 engine 内部 batch 数。
- p50/p95/p99 latency：单请求端到端耗时分位数，用于观察平均体验和长尾延迟。
- prompt tok/s：成功请求的 prompt_tokens 除以 Wall Time，主要反映 prefill 处理吞吐。
- completion tok/s：成功请求的 completion_tokens 除以 Wall Time，主要反映用户可见 decode 生成吞吐。
- valid decode：HTTP 200、JSON 可解析、completion_tokens > 0，且 finish_reason 为 `stop` 或 `length` 的请求数。
- Request-window GPU allocated seconds：从该场景第一条请求发出到最后一条响应完成期间，ready worker GPU 数量对时间积分；主性能对比使用这个口径。
- Full-scenario GPU allocated seconds：包含 setup、signal、observe、cooldown 的资源占用，用于分析 scale down 和测试动作成本。
- S2 switch_time_ms：已有 Pod 内部从 prefill/decode 切到另一个 role 的时间，不包含新 Pod 创建、image pull、model load 或 Kubernetes scheduling。
- S1 startup/warmup：由 sampling signal 触发 scale target 到 Pod Ready 的时间，应与 S2 switch_time_ms 分开解释。
- S3 migrated_requests：controller 记录的迁移请求数；`drained_sources` 出现后再 `scaled_down_to` 才说明 scale down 受 drain gate 保护。

## 结果

| phase | requests | success % | valid decode % | wall(s) | req/s | p50(s) | p95(s) | p99(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_peak | 24 | 100.00 | 100.00 | 6.89 | 3.49 | 2.20 | 2.51 | 2.51 | 12383.25 | 446.10 |
| decode_head | 24 | 100.00 | 100.00 | 15.32 | 1.57 | 2.91 | 9.67 | 9.68 | 1263.09 | 556.17 |
| decode_tail | 24 | 100.00 | 100.00 | 19.56 | 1.23 | 5.10 | 7.65 | 8.52 | 528.71 | 462.42 |
| total | 72 | 100.00 | 100.00 | 57.64 | 1.25 | 2.91 | 9.67 | 9.67 | 1994.41 | 358.01 |

## 资源占用

- Request-window GPU allocated seconds: 195.05
- Request-window prefill allocated seconds: 48.76
- Request-window decode allocated seconds: 146.29
- Full-scenario GPU allocated seconds: 1684.01
- Avg ready workers: 4.00
- Min/Max ready workers: 4 / 4

## Controller / Worker 动作

- S2 history count: 0
- S2 executed count: 0
- S3 history count: 0
- S3 executed pairs: 0
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []

## 分析

- Mixed Strategy ?? S1/S2/S3??? sampling progress / done / complete signal ?? controller ????
- ?? S1 state ????? valid decode 100%?? S2/S3 history ?? 0????? mixed ??????????

## Artifacts

- `requests.csv`：逐请求 latency、HTTP code、token、finish_reason、content hash 和 valid_decode。
- `responses/`：原始 HTTP response。
- `pod_samples.csv`：测试期间 ready pod 数量采样，用于计算 GPU allocated seconds。
- `controller_status.jsonl`：controller status 轮询数据，包含 S1 state、S2 history 和 S3 history。
- `events.csv`：测试脚本记录的 signal、phase 边界和拓扑变化。
- `logs/`：controller 与 worker 日志，用于追踪 migration、KV transfer、rollback、500 错误等。
