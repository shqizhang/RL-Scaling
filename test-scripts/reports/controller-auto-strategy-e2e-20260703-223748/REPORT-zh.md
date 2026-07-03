# Controller 自动策略闭环 E2E 测试报告

生成时间：2026-07-03T22:54:08

## 1. 测试目标

本轮测试验证标准 CI 镜像部署后的 controller 是否能够在相同 signal 与 frontend workload 下自主决策。测试脚本只负责配置开关、发送相同 RL-like signals、发送真实 Dynamo frontend 请求并采集数据；脚本不调用 worker sidecar action endpoint，也不直接执行策略 scale down/up。

Baseline 关闭 S2/S3；Auto Strategy 同时开启 S2/S3，并启用当前测试集群需要的 K8s Deployment scale fallback。两组均从 2P+4D 开始，使用相同的 high -> low/tail -> recovery high 流量与相同 controller signal。

## 2. 数据来源与统一口径

- HTTP timing：`<scenario>/requests.csv`，来自 Dynamo frontend `/v1/chat/completions` 的端到端请求。
- Controller 自动决策：`<scenario>/controller_status.jsonl` 与 `<scenario>/logs/controller.log`，包括 state machine state、`s2_history`、`s3_history` 和 controller log line。
- Scale 结果：Kubernetes Deployment replicas / ready worker count，由脚本在关键节点采样并记录到 `events.csv`。
- GPU effective hour：同一个 `nvidia-smi` 采样器、同一个 sample interval 计算，保证 Baseline 与 Auto Strategy 的比较口径一致。

## 3. 指标解释

- Wall Time：某个 phase 内第一条请求开始发送到最后一条请求结束之间的端到端时间，包含排队、prefill、decode、网络与客户端等待。越短表示这一阶段整体完成得越快。
- req/s：成功 HTTP 请求数除以该 phase 的 Wall Time，表示 Dynamo frontend 对用户请求的端到端完成吞吐，不是 engine 内部 token batch 速率。
- p95 latency：该 phase 内所有请求 latency 的 95 分位，表示 95% 请求能在该时间内完成，用于观察尾延迟。
- user completion Token/s：成功请求产生的用户可见 completion tokens 除以 Wall Time，表示端到端用户可见生成吞吐。
- GPU effective busy hours：按 GPU util% 对每次采样积分得到的有效忙碌 GPU 时间，单位为小时；它越高表示分配出去的 GPU 中实际被计算利用的时间越多。
- GPU idle hours：allocated GPU hours - effective busy hours，表示已分配但未被有效利用的 GPU 时间；在可缩容阶段越低越好。
- effective hour utilization：effective busy hours / allocated GPU hours。它衡量已分配 GPU 的有效使用比例；当 scale down 释放闲置 GPU 后，即使总 busy time 下降，该比例也更能反映闲置减少。

## 4. 触发机制与结果

| 场景 | S2 enabled | S3 enabled | 自动 S2 executed | 自动 S3 pairs | migrated requests | scale down observed | scale up observed | scaled down to |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Baseline: S2/S3 Disabled | False | False | 0 | 0 | 0 | False | True |  |
| Controller Auto Strategy: S2/S3 Enabled | True | True | 0 | 8 | 10 | True | True | 3;2;3;2;3;2;3;2 |

## 5. 统一指标对比

| 场景 | high-before success % | high-before wall(s) | high-before req/s | high-before Token/s | low-tail success % | low-tail wall(s) | low-tail req/s | low-tail p95(s) | high-after success % | high-after wall(s) | high-after req/s | low GPU effective h | low GPU idle h | low GPU util % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline: S2/S3 Disabled | 100.00 | 26.05 | 1.38 | 1060.96 | 100.00 | 37.10 | 0.86 | 4.83 | 100.00 | 25.52 | 1.41 | 0.00130 | 0.00370 | 25.94 |
| Controller Auto Strategy: S2/S3 Enabled | 100.00 | 24.89 | 1.45 | 1110.60 | 90.62 | 37.61 | 0.77 | 5.10 | 80.56 | 25.29 | 1.15 | 0.00056 | 0.00250 | 18.27 |

## 6. 因果链路与对比分析

- Baseline 与 Auto Strategy 使用同一拓扑起点、同一 workload、同一 signal 序列和同一 GPU 采样器，因此差异主要来自 S2/S3 controller 开关是否允许策略闭环执行。
- 如果 Auto Strategy 中 `s3_executed_pairs > 0` 且 `scale_down_observed=True`，则因果链路为：controller 接收 progress signal -> batch completion gate 满足 -> metrics collector 发现 decode tail source/target -> S3 controller 记录 decision/history -> controller patch Deployment scale -> ready decode replicas 降低。
- low-tail 阶段 req/s 相对 Baseline 变化 -10.62%；p95 latency 改善 -5.69%。这两个指标说明用户侧吞吐与尾延迟是否在缩容窗口内保持稳定。
- low-tail GPU idle hours：Baseline 0.00370，Auto Strategy 0.00250；GPU effective hour utilization：Baseline 25.94%，Auto Strategy 18.27%。这组数据用于判断资源释放后，已分配 GPU 的闲置比例是否下降。
- recovery high 阶段用于验证 scale up 后服务恢复。Auto Strategy high-after success 为 80.56%，req/s 相对 Baseline 变化 -18.74%。
- 如果 GPU effective busy hours 下降但 idle hours 同时下降，需要结合 replicas 变化解释：这通常表示 controller 释放了部分长期空闲 GPU，系统总 GPU allocation 变小；真正应该关注的是剩余 GPU 的 effective hour utilization 是否提高，以及 high-after 是否能够恢复吞吐。

## 7. Artifact Index

| 文件 | 含义 |
|---|---|
| `matrix.csv` | 每个场景的汇总指标与策略执行结果 |
| `events.csv` | controller signal、K8s replicas、scale observed 事件时间线 |
| `gpu_samples.csv` | 原始 GPU utilization/memory samples |
| `<scenario>/requests.csv` | 每条 HTTP 请求 timing、token usage、错误信息 |
| `<scenario>/controller_status.jsonl` | controller `/api/v1/status` 原始采样 |
| `<scenario>/logs/controller.log` | controller 自动决策日志 |
| `<scenario>/summary.json` | 单场景机器可读汇总 |
