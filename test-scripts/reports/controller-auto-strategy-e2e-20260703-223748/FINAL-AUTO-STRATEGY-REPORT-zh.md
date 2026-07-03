# Controller 顶层自动策略 E2E 测试总结报告

生成时间：2026-07-03 23:00

## 1. 测试目标与结论

本轮测试基于标准 CI 构建镜像 `ghcr.io/shqizhang/rl-scaling-controller:7e2ddf3` 部署 controller，不使用 ConfigMap 代码覆盖。测试目标是验证 controller 在相同 RL signal 与相同 Dynamo frontend workload 下，是否能够自主判断并触发资源策略，并用统一指标对比 Baseline 与 Auto Strategy 的结果。

核心结论：

- 控制面闭环已经跑通：Auto Strategy 在 tail 阶段自动执行 S3 Request Consolidation，记录 `8` 次 S3 executed pairs、`10` 个 migrated requests，并将 decode replicas 从 `4` 降到 `2`；随后收到 recovery signal 后又自动恢复到 `4`。
- 策略 gating 有效：`MIN_BATCH_COMPLETION=0.95` 后，high-before 阶段 Auto Strategy 保持 `100%` success，说明 controller 没有在 batch 早期高负载阶段提前 consolidation。
- 生产正确性未通过：进入 low-tail 后，Auto Strategy 出现 `3` 条 HTTP 500；recovery high-after 又出现 `7` 条 HTTP 500。说明当前 S3 对 live user-visible 请求的迁移/接管仍存在连续性问题，不能把本轮结果解释为生产可用的正向性能提升。
- 资源释放可观测：low-tail 阶段 Baseline 没有 scale down，Auto Strategy 自动从 `4D` 缩到 `2D`。allocated GPU seconds 从 `18.0s` 降到 `11.0s`，减少 `38.89%`；GPU idle hours 从 `0.00370h` 降到 `0.00250h`，减少 `32.56%`。
- 效能收益尚未成立：由于 migrated request 出现 HTTP 500，Auto Strategy 的 low-tail req/s、Token/s、p95 latency 与 recovery high-after 均差于 Baseline。因此本轮只能证明 controller 自动决策与资源释放链路成立，不能证明完整端到端用户侧效能提升。

## 2. 测试设计

两组测试均从相同 topology 开始：

| 角色 | 初始 replicas |
|---|---:|
| Prefill worker | 2 |
| Decode worker | 4 |
| Old prefill/decode deployment | 0 |

两组使用相同 workload：

| Phase | 请求数 | 并发 | max_tokens | 目的 |
|---|---:|---:|---:|---|
| high-before | 36 | 6 | 768 | 验证 batch 早期高负载不应被 S3 干扰 |
| low-tail | 32 | 4 | 1024 | 构造 decode tail，允许 controller 在 batch completion gate 满足后 consolidation |
| high-after | 36 | 6 | 768 | 验证 scale up 后服务是否恢复 |

两组使用相同 controller signals：

| Signal | Progress | 作用 |
|---|---:|---|
| `sampling_progress` | 0.90 | 进入 active/warm-up 语境，但低于 S3 gate |
| `sampling_progress` | 0.95 | 满足 S3 `MIN_BATCH_COMPLETION=0.95`，允许 tail 阶段 consolidation |
| `batch_complete` | n/a | 进入 cool-down |
| `sampling_done` | n/a | 触发 recovery scale up |

Baseline 配置：

- `ROLE_SWITCH_ENABLED=false`
- `CONSOLIDATION_ENABLED=false`
- `CONSOLIDATION_SCALE_DOWN_ENABLED=true`
- `K8S_SCALE_FALLBACK_ENABLED=true`

Auto Strategy 配置：

- `ROLE_SWITCH_ENABLED=true`
- `CONSOLIDATION_ENABLED=true`
- `CONSOLIDATION_SCALE_DOWN_ENABLED=true`
- `K8S_SCALE_FALLBACK_ENABLED=true`
- `MIN_BATCH_COMPLETION=0.95`
- `CONSOLIDATION_THRESHOLD=8`
- `CONSOLIDATION_STABLE_SAMPLES=1`
- `MIN_DECODE_REPLICAS=2`
- `MIN_PREFILL_REPLICAS=2`

## 3. 指标解释

| 指标 | 含义 | 解释方式 |
|---|---|---|
| Success % | HTTP 200 请求数 / 总请求数 | 端到端正确性的第一优先指标。低于 100% 说明策略影响了用户请求。 |
| Wall Time | 一个 phase 内第一条请求开始到最后一条请求结束的时间 | 体现该阶段整体完成时间，包含排队、prefill、decode、网络和客户端等待。 |
| req/s | 成功请求数 / Wall Time | 表示 frontend 端到端成功请求吞吐，不是 engine 内部 batch 速率。 |
| p95 latency | 请求 latency 的 95 分位 | 体现尾延迟，越低越好。 |
| user completion Token/s | 成功请求产生的 completion tokens / Wall Time | 用户可见输出 token 吞吐，不包含 engine 内部 replay 或迁移开销 token。 |
| allocated GPU seconds | phase 内已分配 worker GPU 数量按时间积分 | 衡量资源占用规模。缩容后应下降。 |
| GPU effective busy hours | GPU util% 按采样时间积分后的有效忙碌 GPU 时间 | 表示已分配 GPU 中实际被计算利用的部分。 |
| GPU idle hours | allocated GPU hours - effective busy hours | 表示已分配但空闲的 GPU 时间，越低说明闲置越少。 |
| effective hour utilization | effective busy hours / allocated GPU hours | 表示已分配 GPU 的有效利用比例。若缩容正确且 workload 不中断，该比例应提升或保持稳定。 |

## 4. Controller 自动决策结果

| 场景 | S2 enabled | S3 enabled | S2 executed | S3 executed pairs | migrated requests | scale down | scale up |
|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline | false | false | 0 | 0 | 0 | false | true |
| Auto Strategy | true | true | 0 | 8 | 10 | true | true |

解释：

- 本轮 workload 是 decode-tail 压力窗口，不是 prefill-heavy 窗口，所以 controller 没有选择 S2 PD Role Switch，`s2_executed_count=0` 是符合预期的。
- Auto Strategy 在 `progress=0.95` 后进入 S3 gate，发现 decode tail source/target 后自动执行 consolidation，并触发 Deployment scale fallback。
- Auto Strategy 的 `s3_scaled_down_to` 记录为 `3;2;3;2;3;2;3;2`，表示 controller 多次根据当前 migration/worker state 尝试调整 decode replicas；最终观测到 decode replicas 降到 `2`。

## 5. 端到端请求指标对比

| Phase | 场景 | Success % | Wall Time(s) | req/s | p95 latency(s) | user completion Token/s |
|---|---|---:|---:|---:|---:|---:|
| high-before | Baseline | 100.00 | 26.05 | 1.38 | 4.81 | 1060.96 |
| high-before | Auto Strategy | 100.00 | 24.89 | 1.45 | 4.43 | 1110.60 |
| low-tail | Baseline | 100.00 | 37.10 | 0.86 | 4.83 | 851.48 |
| low-tail | Auto Strategy | 90.63 | 37.61 | 0.77 | 5.10 | 733.02 |
| high-after | Baseline | 100.00 | 25.52 | 1.41 | 4.47 | 1070.65 |
| high-after | Auto Strategy | 80.56 | 25.29 | 1.15 | 5.03 | 810.60 |

因果分析：

- high-before 中 Auto Strategy 没有提前触发 S3，成功率保持 100%，req/s 与 Token/s 略高于 Baseline。这说明收紧后的 batch gate 能避免早期高负载误触发。
- low-tail 中 Auto Strategy 自动触发 S3 并缩容，但 success 降到 90.63%，p95 latency 从 4.83s 升到 5.10s，Token/s 从 851.48 降到 733.02。这说明当前 request migration 对用户可见请求有中断风险。
- high-after 中 controller 已经把 decode replicas 恢复到 4，但 success 仍只有 80.56%，说明 scale up 的 Kubernetes 层面恢复不等价于 Dynamo 数据面完全恢复。后续需要增加 worker readiness / model-card / router membership 的更严格恢复判定。

## 6. GPU 与资源释放对比

low-tail 阶段 GPU 资源数据：

| 场景 | allocated GPU seconds | GPU effective busy hours | GPU idle hours | effective hour utilization |
|---|---:|---:|---:|---:|
| Baseline | 18.0 | 0.00130 | 0.00370 | 25.94% |
| Auto Strategy | 11.0 | 0.00056 | 0.00250 | 18.27% |

解释：

- allocated GPU seconds 从 18.0 降到 11.0，说明 Auto Strategy 的 scale down 确实释放了部分 decode GPU allocation。
- GPU idle hours 从 0.00370h 降到 0.00250h，说明绝对闲置 GPU 时间减少。
- effective hour utilization 从 25.94% 降到 18.27%，这不是正向结果。原因是 S3 迁移导致请求失败，用户可见有效 token 产出下降，剩余 GPU 没有被更高效地使用起来。
- 因此，GPU 资源释放链路成立，但“释放后整体效率提升”尚未成立。正确的生产目标应该是：scale down 发生后 Success 保持 100%，Token/s 基本不下降，GPU idle hours 下降，effective hour utilization 提升或保持稳定。

## 7. 正确性验证

已验证：

- controller 使用标准 CI 镜像部署。
- test driver 没有直接调用 sidecar action endpoint。
- Baseline 在 S2/S3 disabled 时不会触发 S3 history，也不会 scale down decode workers。
- Auto Strategy 在 S2/S3 enabled 时能够基于 controller signal 与 metrics 自动执行 S3，并触发 4D -> 2D scale down。
- Auto Strategy 能在 recovery signal 后触发 2D -> 4D scale up。

未通过：

- Auto Strategy 的 live user-visible request continuity 未通过。证据是 `auto_strategy/requests.csv` 中 low-tail 有 3 条 HTTP 500，high-after 有 7 条 HTTP 500。
- high-after 虽然 Deployment replicas 已恢复到 4，但请求成功率仍未恢复到 100%，说明目前 controller 的 scale up 完成条件只覆盖 K8s ready，不足以证明 Dynamo router/worker 数据面已经完全恢复。

## 8. 后续改进建议

1. S3 request migration 必须补齐用户可见流的连续性验证。当前 evidence 更接近“controller 能触发 migration 与资源释放”，还不是“生产请求可无损迁移”。
2. controller scale up 后需要增加更严格的 readiness gate，例如 worker sidecar healthy、ModelCard 已注册、router membership 已更新、frontend 可路由 smoke test 通过。
3. S3 controller 需要增加更保守的稳定窗口，例如连续多个 sample 满足 source active、target capacity、batch completion，并限制同一窗口内反复 3/2 oscillation。
4. GPU 指标建议接入 DCGM exporter，当前 `nvidia-smi` 采样可证明趋势，但对短窗口 GPU busy 积分仍偏粗粒度。
5. 若要证明正向性能收益，下一轮验收标准应是：Baseline 与 Auto Strategy 均 100% success；Auto Strategy low-tail idle GPU hours 下降；Token/s、req/s、p95 latency 不劣于 Baseline 或劣化在可接受阈值内；high-after 恢复 100% success。

## 9. Artifact Index

| 文件 | 含义 |
|---|---|
| `matrix.csv` | 两组测试的汇总指标与策略执行结果 |
| `events.csv` | controller signal、K8s replicas、scale observed 事件时间线 |
| `gpu_samples.csv` | 原始 GPU utilization/memory samples |
| `baseline/requests.csv` | Baseline 每条 HTTP 请求 timing、token usage、错误信息 |
| `auto_strategy/requests.csv` | Auto Strategy 每条 HTTP 请求 timing、token usage、错误信息 |
| `baseline/summary.json` | Baseline 机器可读汇总 |
| `auto_strategy/summary.json` | Auto Strategy 机器可读汇总 |
| `auto_strategy/logs/controller.log` | controller 自动 S3 决策日志 |

