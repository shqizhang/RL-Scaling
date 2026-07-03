# S2/S3 策略矩阵与 Scale Up/Down 端到端测试报告

生成时间：2026-07-03T18:05:28

## 1. 测试目标与边界

本报告覆盖 Baseline、S2 only、S3 only、Both Enable 四组配置，使用相同的 high -> low/tail -> high recovery 流量形态，验证顶层策略在不同开关下是否触发 GPU worker 的 scale down 和 scale up，并量化 HTTP timing、吞吐、GPU effective-hour utilization 与释放的 GPU allocation。

当前集群中的生产 controller 还没有把 S2/S3/S1 编排成一个完整的 targeted autoscaling 闭环。本轮测试采用测试级 top-level strategy driver：请求仍然通过真实 Dynamo frontend，worker 扩缩容仍然通过真实 Kubernetes Deployment，策略判断和动作证据记录在 `events.csv`、`matrix.csv` 和本报告中。

## 2. 四组测试数据与触发逻辑

| 组别 | S2 | S3 | 测试数据 | Scale Down/Up 触发逻辑 |
|---|---:|---:|---|---|
| Baseline | False | False | high(48 req, concurrency=6, max_tokens=768) -> low/tail(12 req, concurrency=2, max_tokens=384) -> high recovery(48 req)；S2/S3 全部关闭，固定 2P+4D，用作端到端 timing、吞吐和 GPU allocation 对照。 | 不触发；Baseline 是固定资源对照，S2 only 只验证 role-reuse 资格，不释放 replica。 |
| Enable S2 Only | True | False | high(48 req, concurrency=6, max_tokens=768) -> low/tail(12 req, concurrency=2, max_tokens=384) -> high recovery(48 req)；只开启 S2 资格验证，不执行 replica 释放，用于证明 S2 单独不会被误解为 scale-down。 | 不触发；Baseline 是固定资源对照，S2 only 只验证 role-reuse 资格，不释放 replica。 |
| Enable S3 Only | False | True | high(48 req, concurrency=6, max_tokens=768) -> low/tail(12 req, concurrency=2, max_tokens=384) -> high recovery(48 req)；低负载/长尾窗口触发 Request Consolidation 后的 decode 4->2 释放，并在恢复高负载前 2->4。 | 低负载/长尾窗口出现且 S3 enabled，触发 decode 4->2；恢复高负载前触发 decode 2->4。 |
| Both Enable | True | True | high(48 req, concurrency=6, max_tokens=768) -> low/tail(12 req, concurrency=2, max_tokens=384) -> high recovery(48 req)；S2 与 S3 同时开启，由顶层策略在低负载/长尾窗口选择 S3 release path，并在高负载恢复前 scale up。 | 低负载/长尾窗口出现且 S3 enabled，触发 decode 4->2；恢复高负载前触发 decode 2->4。 |

## 3. 指标解释

- Wall Time：某个阶段内第一条 measured request 发出，到最后一条 measured response 返回之间的时间跨度。它体现这一批用户请求整体完成所需时间。
- req/s：HTTP 200 成功请求数 / Wall Time。这里的 req/s 是 Dynamo frontend 端到端用户请求吞吐，不是 engine 内部 batch request 数。
- p50/p95/p99 latency：单条用户请求端到端 latency 的 50/95/99 分位数，越高说明尾延迟越明显。
- user completion tok/s：HTTP 响应中的 completion tokens / Wall Time。它衡量用户可见输出 token 的生成吞吐，不包含 migration replay 或内部 engine token。
- allocated GPU-hours：测试阶段内 Kubernetes 目标拓扑中的 ready worker GPU 数量 * 阶段 Wall Time / 3600。它衡量这一阶段实际占用的 GPU allocation。
- GPU effective busy hours：allocated GPU-hours * `nvidia-smi` 平均 GPU utilization，是 GPU effective hour 的粗粒度 proxy。
- GPU effective-hour utilization：GPU effective busy hours / allocated GPU-hours。越高表示已分配 GPU 的闲置越少；scale down 释放空闲 GPU 后，低负载窗口的 allocation 会下降。
- released GPU-hours：S3/Both 场景中 decode 4->2 到 2->4 之间释放的 GPU allocation 时间，计算为释放 GPU 数量 * 持续秒数 / 3600。

## 4. 四组矩阵结果

| 组别 | high before success % | high before wall(s) | high before req/s | high before p95(s) | low success % | high after success % | high after wall(s) | high after req/s | high after p95(s) | released GPU-hours | high util % | low util % | after util % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline | 100.00 | 33.28 | 1.44 | 4.53 | 100.00 | 100.00 | 32.60 | 1.47 | 4.26 | 0.0000 | 31.58 | 2.62 | 46.94 |
| Enable S2 Only | 100.00 | 33.50 | 1.43 | 4.46 | 100.00 | 100.00 | 34.07 | 1.41 | 4.54 | 0.0000 | 31.92 | 0.00 | 39.19 |
| Enable S3 Only | 100.00 | 33.43 | 1.44 | 4.70 | 100.00 | 100.00 | 33.41 | 1.44 | 5.31 | 0.1602 | 22.88 | 0.00 | 49.56 |
| Both Enable | 100.00 | 33.58 | 1.43 | 4.38 | 100.00 | 100.00 | 33.94 | 1.41 | 5.02 | 0.1599 | 24.75 | 12.62 | 14.75 |

## 5. GPU Effective Hour 与资源释放

| 组别 | low allocated GPU-hours | low busy GPU-hours | low idle GPU-hours | low effective util % | high-after allocated GPU-hours | high-after busy GPU-hours | high-after idle GPU-hours | released GPU-hours |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline | 0.0305 | 0.0008 | 0.0297 | 2.62 | 0.0543 | 0.0255 | 0.0288 | 0.0000 |
| Enable S2 Only | 0.0294 | 0.0000 | 0.0294 | 0.00 | 0.0568 | 0.0223 | 0.0345 | 0.0000 |
| Enable S3 Only | 0.0189 | 0.0000 | 0.0189 | 0.00 | 0.0557 | 0.0276 | 0.0281 | 0.1602 |
| Both Enable | 0.0196 | 0.0025 | 0.0172 | 12.62 | 0.0566 | 0.0083 | 0.0482 | 0.1599 |

## 6. Scale Down 与 Scale Up 正确性验证

Scale down 的正确性通过三类证据验证：`events.csv` 中存在 `scale_down_ready`，Kubernetes ready worker count 从 2P+4D 变成 2P+2D，且 `released_gpu_hours` 大于 0。Scale up 的正确性通过 `scale_up_ready`、ready worker count 恢复到 2P+4D，以及 high recovery 阶段 HTTP success 和吞吐恢复来验证。

Baseline 与 S2 only 不触发 scale down/up，因此 `released_gpu_hours` 必须为 0。S3 only 与 Both Enable 必须触发 decode replica 释放，并在恢复高负载前扩回 4 个 decode worker。

## 7. 结论

这组矩阵的核心验证点是：相同 workload 下，策略开关会决定是否释放 GPU allocation；释放后仍能在高负载恢复前 scale up，避免牺牲后续高负载阶段的可用性。S3/Both 场景能够展示真实 GPU 资源释放窗口，S2 only 在本测试中作为 role-reuse 资格验证，不单独声明 replica release。

原始证据目录：`C:\projects\IP\RL-Scaling\test-scripts\reports\strategy-scale-matrix-e2e-20260703-174215`
