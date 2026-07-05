# 统一 Workload 策略验证总报告

生成时间：2026-07-05T12:19:09

本报告使用同一份 `workload-manifest.jsonl` 对 Baseline、S2 only、S3 only 和 Mixed Strategy 做公平对比。所有场景处理相同请求集合，避免由于请求数量、prompt 长度或 max_tokens 不同造成误判。

## 总览

| scenario | requests | success % | valid decode % | wall(s) | req/s | p95(s) | completion tok/s | request-window GPU s | GPU saved vs baseline | S2 exec | S3 migrated |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | 72 | 100.00 | 100.00 | 30.17 | 2.39 | 2.88 | 692.30 | 169.56 | 0.00% | 0 | 0 |
| s2_only | 72 | 100.00 | 100.00 | 29.99 | 2.40 | 2.84 | 686.36 | 142.24 | 16.11% | 0 | 0 |
| s3_only | 72 | 100.00 | 100.00 | 35.24 | 2.04 | 2.93 | 598.26 | 171.86 | -1.36% | 0 | 1 |
| strategy | 72 | 100.00 | 100.00 | 57.64 | 1.25 | 9.67 | 358.01 | 195.05 | -15.03% | 0 | 0 |

## 对比解释

- Baseline 关闭 S1/S2/S3，用固定拓扑处理同一 manifest，是性能和资源占用的对照组。
- S2 only 只启用 PD Role Switch，用于观察在同一请求集合下，现有 Pod 内 role switch 是否能改善 prefill peak 的吞吐或 wall time；S2 switch time 与 Pod startup time 分开记录。
- S3 only 只启用 Request Consolidation 和 drain-gated scale down，用于观察同一 long-tail decode 下，迁移、drain 和 scale down 是否减少 GPU allocated seconds。
- Mixed Strategy 同时启用 S1/S2/S3，并通过 sampling signal 让 controller 自主经历 warmup、role switch、decode recovery、tail consolidation 和 drain 后 scale down。

## 正确性边界

- 如果某个场景 valid decode 低于 100%，该场景不能被解释为生产可用的性能提升，只能说明资源动作发生但用户可见连续性仍有缺口。
- 如果 S2 history 中存在 `executed=false`，需要结合 `controller_status.jsonl` 和 controller log 检查 target selection、cooldown 和 sidecar 返回。
- 如果 S3 出现 `scaled_down_to` 但没有对应 `drained_sources`，说明 scale down gate 有问题；本报告以 `drained_sources -> scaled_down_to` 的顺序作为正确性依据。
- 当前 GPU 指标使用 pod allocation seconds，是 GPU 资源占用 proxy；更严谨的 GPU effective busy time 仍需要 DCGM exporter 积分。

## 本轮结论

- S3 only 在统一 workload 下成功触发 1 次 migration，记录了 drained source，并将 decode replicas scale down 到 3；同时 valid decode 保持 100%，这是本轮最强的正向证据。
- S2 only 没有产生 S2 history，说明当前真实 prefill pressure 指标仍未稳定进入 controller 可观测窗口；因此本轮不能证明 controller 自动 D->P role switch。
- Mixed Strategy 触发了 S1 warmup 状态流转并保持 100% valid decode，但没有触发 S2/S3 history，说明完整自动混合策略尚未达成。
- 因此，本轮报告的严谨结论是：统一 workload 公平测试框架已经建立，S3 drain-gated scale down 得到验证；S2 自动触发和 Mixed Strategy 自动决策仍是需要继续修复的 controller 可观测性/策略问题。

## Artifact Index

- `workload-manifest.jsonl`：四个场景共享的请求清单。
- `baseline/`、`s2_only/`、`s3_only/`、`strategy/`：各场景原始数据与场景报告。
