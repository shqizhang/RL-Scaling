# Mixed Strategy Path E2E 补充测试报告

生成时间：2026-07-05T13:56:30

## 测试目标

本测试专门修正上一轮 Strategy Mix 的脚本构造问题。上一轮在请求前直接发送 `sampling_progress=0.85`，S1 先把 prefill 扩到 5 个副本，导致 D->P role switch 没有触发窗口。本轮改为 staged path：

1. 先关闭 S1 pre-warm 触发，只启用 S2/S3 controller。
2. 使用真实 prefill-heavy 请求制造 prefill active/queue 压力，观察 controller 是否先执行 D->P。
3. 若 D->P 后仍需要更多 prefill capacity，再发送 S1 sampling signal，让 controller scale up prefill。
4. 进入 decode 阶段后观察 P->D。
5. 进入 decode tail 后观察 S3 Request Consolidation、drain 和 scale down。

## 指标口径

- Wall Time：每个 phase 第一条请求发出到最后一条响应返回的端到端时间。
- req/s：HTTP 200 成功请求数 / Wall Time。
- prompt tok/s：成功请求的 prompt tokens / Wall Time，主要对应 prefill 吞吐。
- completion tok/s：成功请求的 completion tokens / Wall Time，主要对应 decode 吞吐。
- valid decode：HTTP 200、JSON 可解析、completion_tokens > 0、finish_reason 为 stop 或 length。
- S2 switch_time_ms：已有 Pod 内部 role switch 耗时，不包含新 Pod 启动和模型加载。
- S1 warmup：sampling signal 后 Kubernetes scale target 到 ready pod 的过程，和 S2 switch time 分开解释。
- S3 migrated_requests / drained_sources / scaled_down_to：分别验证迁移、源 worker drain 和 drain 后缩容。

## Phase 结果

| phase | requests | success % | valid decode % | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_pressure | 64 | 100.00 | 100.00 | 12.61 | 5.08 | 3.51 | 38707.49 | 487.24 |
| decode_recovery | 48 | 100.00 | 100.00 | 12.85 | 3.73 | 3.47 | 2981.69 | 1513.64 |
| decode_tail | 24 | 87.50 | 87.50 | 252.71 | 0.08 | 240.01 | 35.90 | 45.80 |
| total | 136 | 97.79 | 97.79 | 337.29 | 0.39 | 4.54 | 1587.62 | 110.20 |

## Controller 动作汇总

- S2 history count: 0
- S2 executed count: 0
- S3 history count: 1
- S3 executed pairs: 1
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7bqs5r']
- S3 scaled down to: [3]

## GPU 资源占用

- Request-window GPU allocated seconds: 1697.15
- Full-scenario GPU allocated seconds: 3502.38
- Avg ready workers during request window: 5.11
- Min/Max ready workers during request window: 4 / 6

## 策略链路分析

- D->P role switch was not observed; this means prefill pressure still did not enter controller S2 metrics window.
- P->D role switch was not observed; decode pressure did not trigger controller S2 reverse switch.
- S3 consolidation observed with migrated requests.

## Artifacts

- `workload-manifest.jsonl`：本补充测试使用的 staged mixed workload。
- `events.csv`：记录 controller env 切换、signals、phase 边界和是否观察到 S2/S3。
- `controller_status.jsonl`：controller status 原始采样。
- `pod_samples.csv`：ready pod 数量采样。
- `requests.csv` / `responses/`：逐请求结果和原始响应，用于验证 decode 完整性。
- `logs/`：controller 和 worker 日志，用于追踪 sidecar、migration、drain 和 scale patch。
