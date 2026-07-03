# Scale Up / Scale Down 端到端测试报告

生成时间：2026-07-03T13:16:55

## 1. 测试目标

本轮测试验证在 GPU 条件满足时，Dynamo worker 拓扑可以从 2P+4D 缩到 2P+2D 释放 GPU，再扩回 2P+4D 承接高负载。报告同时区分 GPU allocation 与 GPU effective-hour utilization：前者表示占用多少 GPU 时间，后者表示这些 GPU 时间中有多少真正忙于计算。

## 2. 部署与动作

- 服务器条件：gpu14 节点有 8 张 NVIDIA GeForce RTX 3090，本轮测试最高使用 6 个 Dynamo worker GPU。
- 初始健康拓扑：prefill=1，decode=2。
- 测试拓扑：2 Prefill + 4 Decode。
- Scale down：decode 4 -> 2，prefill 保持 2；Dynamo worker GPU allocation 从 6 张降到 4 张。
- Scale up：decode 2 -> 4，prefill 保持 2；Dynamo worker GPU allocation 从 4 张恢复到 6 张。
- scale down 窗口释放 GPU：171.54 GPU-seconds，即 0.0476 GPU-hours。

## 3. 指标解释

- Wall Time：一组 measured HTTP 请求中，第一条请求发出到最后一条响应返回的时间。
- req/s：HTTP 200 请求数 / Wall Time，表示用户请求吞吐。
- p50/p95/p99 latency：单请求端到端耗时的 50/95/99 分位。
- user completion tok/s：HTTP response 中用户实际获得的 completion tokens / Wall Time。
- allocated GPU-hours：ready worker GPU 数量按时间积分，代表被占用的 GPU 资源量。
- GPU effective busy hours：`gpu_util_pct / 100 * sample_duration` 的积分，代表实际忙碌 GPU 时间。
- GPU effective-hour utilization：GPU effective busy hours / allocated GPU-hours。这个值越高，表示已分配 GPU 中闲置比例越低，资源使用越有效。

## 4. HTTP 负载结果

| phase | requests | success % | wall(s) | req/s | p50 latency(s) | p95 latency(s) | p99 latency(s) | user completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| high_before_scale_down | 48 | 100.00 | 27.91 | 1.72 | 3.34 | 4.16 | 4.77 | 880.68 |
| low_after_scale_down | 12 | 100.00 | 14.56 | 0.82 | 2.39 | 2.53 | 2.61 | 210.92 |
| high_after_scale_up | 48 | 100.00 | 27.97 | 1.72 | 3.36 | 3.89 | 4.15 | 878.78 |

Scale up 后的高负载阶段与 scale down 前基本对齐：success 仍为 100%，Wall Time 从 27.91s 变为 27.97s，user completion tok/s 从 880.68 变为 878.78，说明 decode worker 从 2 个扩回 4 个后，系统恢复了承接高负载的能力。

## 5. GPU Effective-Hour 结果

| phase/window | allocated GPU-hours | busy/effective GPU-hours | idle GPU-hours | effective-hour utilization % | avg GPU util % | max GPU mem MiB |
|---|---:|---:|---:|---:|---:|---:|
| high_before_scale_down | 0.0067 | 0.0016 | 0.0050 | 24.75 | 18.56 | 22590.00 |
| low_after_scale_down | 0.0022 | 0.0000 | 0.0022 | 0.00 | 0.00 | 22590.00 |
| scale_down_hold | 0.0089 | 0.0000 | 0.0089 | 0.00 | 0.00 | 22590.00 |
| scaled_down_total_window | 0.0167 | 0.0000 | 0.0167 | 0.00 | 0.00 | 22590.00 |
| high_after_scale_up | 0.0067 | 0.0017 | 0.0050 | 25.50 | 19.12 | 22590.00 |

高负载阶段的 GPU effective-hour utilization 约为 25%，表示在本测试采样窗口中，已分配 GPU 时间里约四分之一处于有效忙碌状态。scale down hold 窗口没有业务请求，因此 effective-hour utilization 为 0；这不是性能退化，而是说明如果不缩容，这些 GPU 时间会成为纯 idle allocation。通过 decode 4 -> 2，本轮在 scale down 窗口直接释放了 2 张 GPU 的 allocation。

## 6. Scale Down 释放资源说明

本轮 scale down 将 decode worker 从 4 个降到 2 个，释放 2 张 GPU。释放窗口持续 85.77 秒，折算为 0.0476 GPU-hours 的 allocation 节省。这个值是资源占用时间的节省；是否转化为生产成本下降，取决于集群调度器是否把这 2 张 GPU 分配给其他任务，或云平台是否按释放后的 GPU allocation 计费。

## 7. 结论

本轮测试证明当前部署能够执行可观测的 scale down 和 scale up：scale down 阶段释放 decode GPU allocation，scale up 阶段恢复到 2P+4D 并重新承接高负载。GPU effective-hour utilization 用来解释释放前后已分配 GPU 的有效使用比例：在相同成功率前提下，该比例越高说明闲置越少；allocated GPU-hours 越低说明资源占用越少。

注意：本脚本使用 Kubernetes deployment scale 作为资源动作，验证真实 pod/GPU allocation 的释放与恢复；它不是最终生产版 controller 全自动策略闭环。生产级闭环还需要把 S2/S3 产生的 idle worker、DCGM busy-time、DGDSA targeted scale down 和 scale-up gating 合并到 controller policy 中。
