# RL-Scaling Controller 端到端测试总结汇报

生成日期：2026-07-02

本文汇总 RL-Scaling / Dynamo 项目当前已经完成的端到端测试结果，目标是证明方案在真实 Dynamo + Kubernetes 环境中的可行性，并用可解释的 timing、throughput、latency、token throughput 和 GPU 使用指标说明方案带来的效能改善。本文特别区分“机制可行性”“controller 自动闭环触发”“同 workload 对比收益”和“scale down 后的最终 GPU hour 收益”，避免把测试触发窗口或 GPU proxy 过度解释成生产效果。

## 1. 汇报结论

当前实现已经具备完整的 worker-side 机制和 controller-driven 自动闭环验证基础：

- **S2 Elastic PD Role Switch 可行且有效**：controller 能够在自动闭环中发现条件并调用 sidecar，将 decode worker 切换为 prefill；在独立 S2 标准测试中，端到端 wall time 从 16.40s 降至 10.46s，改善 36.24%；请求吞吐从 2.20 req/s 提升至 3.44 req/s，提升 56.85%；p50 latency 从 2.52s 降至 1.64s，改善 34.74%。
- **S3 Request Consolidation 可自动触发**：controller 能够识别 decode tail 阶段中 source active request、target capacity、batch completion 和 stable window 条件，并自动执行 migration。四组矩阵测试中 S3-only 记录到 10 轮 consolidation decision，32 个 migrated request，8 个 declined/rollback。
- **组合启用场景可运行且服务不中断**：四组矩阵测试中 Baseline、S2-only、S3-only、Both Enable 全部保持 100% HTTP success。Both Enable 下 S2 自动触发，GPU effective seconds 相对 baseline 降低 41.09%。
- **效能收益最明确地体现在 S2 的端到端吞吐，以及 S2/Both 的 GPU 占用下降**：S2 独立策略测试展示了 wall time、req/s、latency、user completion tok/s 的直接提升；四组矩阵测试展示了在同一 workload 下，S2/Both 能触发 role switch，并显著降低 GPU effective seconds。这里的 GPU effective seconds 下降不是“单卡利用率提升”，而是“策略让部分 worker 更早进入低占用/可释放状态”的信号；真正的 auto-scaling 收益需要后续 scale down 或 role reuse 把这部分释放能力转化为 GPU hour 节省。
- **S3 当前证明了机制可行，但触发窗口仍需收敛**：S3-only 在本轮矩阵测试中成功迁移请求，但 replay/overhead tokens 上升到 16472，p95/p99 latency 和 wall time 变差。这说明 Request Consolidation 机制成立，但当前 workload 和阈值偏激进，后续需要更严格的 stable gating、migration benefit 判断和 target capacity 控制，才能稳定体现正向收益。

## 2. 测试数据来源

本汇报使用以下测试报告和原始产物：

| 数据源 | 用途 | 关键产物 |
|---|---|---|
| `controller-matrix-env-20260702-031353` | 四组端到端矩阵测试：Baseline、S2-only、S3-only、Both Enable | `REPORT-zh.md`, `matrix-comparison.csv`, 每组 `summary.json`, `requests.csv`, `pod_metrics.csv`, `gpu_metrics.csv`, controller/worker logs |
| `controller-standard-s2-20260629-01` | S2 独立 controller 策略测试，验证 PD Role Switch 对端到端 timing/throughput 的提升 | `comparison.csv`, baseline/strategy `summary.json` |
| `controller-standard-s3-20260629-01` | S3 独立 controller 策略测试，验证 Request Consolidation 链路和轻量收益 | `comparison.csv`, baseline/strategy `summary.json` |
| `controller-standard-full-20260629-01` | 标准流水线、镜像部署和 controller 闭环测试说明 | `REPORT-zh.md` |

四组矩阵测试使用 `kubectl set env deployment/rl-scaling-controller` 直接更新实际运行 controller Pod 的环境变量，并在每组 rollout 后保存 `controller-env-effective-*.txt`。这是必要步骤，因为当前 deployment 中存在 direct env，单独 patch ConfigMap 不能保证策略参数生效。

需要特别说明：第 5 节四组矩阵测试、第 6 节 S2 独立策略测试、第 7 节 S3 独立策略测试不是同一个 workload，因此绝对数值不能直接互相比较。

- 第 5 节四组矩阵测试使用同一批 `N_REQ=96 / CONCURRENCY=8 / PROMPT_WORDS=256 / MAX_TOKENS=1024`，用于比较四种开关组合，并证明 controller 自动闭环是否真实触发。
- 第 6 节 S2 独立测试使用更适合触发 PD Role Switch 收益的 workload，用于证明 S2 在匹配场景下能够提升端到端 timing、req/s 和 token/s。
- 第 7 节 S3 独立测试使用 decode-tail/consolidation 场景，用于证明 Request Consolidation 链路和轻量窗口下的收益边界。

因此报告采用“同组内对比”的解释原则：四组矩阵只和四组矩阵的 baseline 比；S2 独立测试只和该测试自己的 baseline 比；S3 独立测试只和该测试自己的 baseline 比。不同测试之间只比较趋势和机制证据，不比较绝对 wall time 或 token/s。

## 3. 测试设计完整性

### 3.1 四组配置矩阵

| 组别 | ROLE_SWITCH_ENABLED | CONSOLIDATION_ENABLED | 验证目标 |
|---|---:|---:|---|
| Baseline | false | false | 不启用 S2/S3，建立端到端 timing、throughput、GPU 使用参照 |
| Enable S2 | true | false | 验证 controller 自动触发 PD Role Switch |
| Enable S3 | false | true | 验证 controller 自动触发 Request Consolidation |
| Both Enable | true | true | 验证两个策略同时启用时系统可运行、服务不中断，并观察策略仲裁 |

四组矩阵 workload 保持一致：

- `N_REQ=96`
- `CONCURRENCY=8`
- `PROMPT_WORDS=256`
- `MAX_TOKENS=1024`
- Baseline 使用 `STRATEGY_DRIVER=none`
- 其他三组使用 `STRATEGY_DRIVER=auto`

`STRATEGY_DRIVER=auto` 的意义是：测试脚本只负责向 Dynamo frontend 发送请求，并向 controller 上报 batch progress；测试脚本不直接调用 worker sidecar 的 `/switch_role` 或 `/migrate`。因此 S2/S3 动作来自 controller 自动闭环，而不是脚本手动触发。

### 3.2 Controller 策略触发条件

S2 PD Role Switch 的核心条件：

- `ROLE_SWITCH_ENABLED=true`
- prefill pressure 达到阈值，本轮矩阵中 S2/Both 使用 `PREFILL_QUEUE_THRESHOLD=0` 构造可观测窗口
- decode utilization 小于等于阈值，本轮使用 `DECODE_IDLE_THRESHOLD=1.0` 构造宽松触发窗口
- decode worker 数量大于 `MIN_DECODE_REPLICAS=1`
- 满足 `MIN_SWITCH_INTERVAL` 冷却要求

`PREFILL_QUEUE_THRESHOLD` 并不等价于“prefill worker 的 in-flight request 数量等于 0”。controller 优先读取 Prometheus `sum(dynamo_frontend_queued_requests{role="prefill"})` 作为 prefill queue depth；如果该值为 0 或不可用，会 fallback 为 prefill workers 的 `in_flight_requests` 总和。因此它更准确地表示“prefill 侧压力是否达到阈值”。本轮矩阵里设为 0，是为了让 `prefill_queue_depth >= 0` 永远成立，从而构造可观测的 S2 触发窗口；这不是生产推荐阈值，也不表示“只要有请求在 prefill，decoder 就一定切成 prefill”。

`DECODE_IDLE_THRESHOLD=1.0` 也不是“idle 等于 1”。代码判断是 `decode_utilization <= DECODE_IDLE_THRESHOLD`。`decode_utilization` 优先来自 Prometheus `avg(dynamo_worker_gpu_utilization{role="decode"})`；如果没有有效值，会 fallback 为 `sum(decode_active_requests) / (decode_worker_count * MAX_CONCURRENT_PER_DECODE)`，并限制最大为 1.0。因此 `DECODE_IDLE_THRESHOLD=1.0` 表示“decode utilization 只要不超过 100% 就满足”，也是测试用的宽松阈值。生产环境应使用更保守阈值，例如 0.2 或基于历史利用率的动态阈值，只有 decode 侧确实空闲时才切走 decode worker。

S3 Request Consolidation 的核心条件：

- `CONSOLIDATION_ENABLED=true`
- batch completion 达到 `MIN_BATCH_COMPLETION=0.6`
- source decode worker 的 in-flight request 位于 `1..CONSOLIDATION_THRESHOLD`
- target decode worker 的 available capacity 大于等于 source active request 数
- 同一 migration plan 连续满足 `CONSOLIDATION_STABLE_SAMPLES=2`
- 满足 `CONSOLIDATION_MIN_INTERVAL=10` 冷却要求
- 本轮关闭 `CONSOLIDATION_SCALE_DOWN_ENABLED=false`，因此只验证 request migration，不在同一轮中缩容 replica

`MIN_BATCH_COMPLETION=0.6` 表示整体 workload / batch 的完成比例达到 60%，不是某个 worker 已经完成 60%。在测试中这个值由脚本向 controller 上报；controller 用它判断当前是否已经进入 decode tail 阶段。只有整体 batch 进入后段，Request Consolidation 才开始寻找“只剩少量请求的 source decode worker”和“仍有足够 capacity 的 target decode worker”。

`source decode worker 的 in-flight request 位于 1..CONSOLIDATION_THRESHOLD` 的含义是：source worker 还没有完全 drain，但已经只剩少量尾部请求。如果 source active 为 0，它已经空了，不需要迁移；如果 source active 大于 threshold，说明它还很忙，迁移成本和风险较高，不适合作为 drain source。只有 `1 <= source_active <= threshold` 时，controller 才认为它是可被 consolidation 的尾部 worker。

`target available capacity >= source active request 数` 表示目标 worker 必须能完整接收 source 当前待迁移的请求。当前 available capacity 是 controller 派生指标，计算为 `MAX_CONCURRENT_PER_DECODE - target_active_requests`，不是底层 Prometheus 原始指标。

当前 controller 的策略输入来源分为三类：

| 策略输入 | 当前来源 | 性质 |
|---|---|---|
| prefill/decode queue depth | 优先 Prometheus `dynamo_frontend_queued_requests`，无值时 fallback 到 worker in-flight | 原始指标 + fallback |
| prefill/decode utilization | 优先 Prometheus `dynamo_worker_gpu_utilization`，无值时 fallback 为 active/capacity | 原始指标 + controller 换算 |
| worker role | sidecar `/v1/role` | 我们实现的 worker-side 状态 |
| worker in-flight request | sidecar `/v1/active_requests` 返回列表长度 | 我们实现的 worker-side 观测 |
| available capacity | `MAX_CONCURRENT_PER_DECODE - active_requests` | controller 派生指标 |
| batch completion | 测试脚本或上游 runtime 上报给 controller | 策略输入信号，不是 worker 原始 metric |

这意味着当前报告中的策略触发数据不是全部来自最底层原生 metrics，而是由 Prometheus、sidecar 状态和 controller 派生计算共同组成。

### 3.3 数据流

测试数据流如下：

1. 测试脚本通过 `kubectl port-forward` 连接 Dynamo frontend。
2. client 按固定 `N_REQ` 和 `CONCURRENCY` 发送 OpenAI-compatible `/v1/chat/completions` 请求。
3. Dynamo frontend 将请求路由到 prefill / decode worker。
4. controller 通过 metrics collector、worker sidecar `/v1/role` 和 `/v1/active_requests` 观察 worker 状态。
5. controller 根据 S2/S3 策略条件调用 worker sidecar：
   - S2 调用 `/switch_role`
   - S3 调用 `/migrate`
6. 测试脚本同时采集：
   - client request timing
   - HTTP status
   - response usage token
   - vLLM prompt/generation token counters
   - worker role / active request
   - GPU `nvidia-smi` sampling
   - controller status/logs
   - worker migration/switch logs

## 4. 指标定义与解释

| 指标 | 统计边界 | 含义 | 数值如何解读 |
|---|---|---|---|
| completed requests | `requests.csv` 中完成并写入的请求数 | client 侧实际完成的 HTTP 请求数量 | 应等于 expected requests，否则说明有请求超时或未完成 |
| success % | `HTTP 200 / completed * 100` | 服务正确性和可用性指标 | 越高越好；策略动作期间保持 100% 表示动作没有破坏用户请求 |
| Wall Time | `max(end_ts) - min(start_ts)` | 从第一条 measured request 发出，到最后一条 measured request 完整响应返回 | 整批 workload 的端到端完成时间，越低表示同样请求批次越快完成 |
| req/s | `HTTP 200 / Wall Time` | 用户 HTTP 请求吞吐，不是 token 吞吐 | 越高表示同样时间内完成更多用户请求 |
| avg latency | 每个请求 curl total time 的平均值 | 从单个请求发出到完整响应体返回的平均耗时 | 反映平均用户等待时间，越低越好 |
| p50 latency | 请求 latency 的 50 分位 | 典型请求的端到端耗时 | 越低表示大多数请求体验更好 |
| p95 latency | 请求 latency 的 95 分位 | 长尾请求耗时 | 对排队、straggler、migration cost 最敏感，越低越好 |
| p99 latency | 请求 latency 的 99 分位 | 极端长尾耗时 | 用于发现少数慢请求是否被策略放大 |
| TTFT | curl `time_starttransfer` | 从请求发出到首字节返回 | 非 streaming 模式下近似 first-byte/first-token 响应性，越低越好 |
| cluster prompt tok/s | vLLM `prompt_tokens_total` delta / Wall Time | prefill 阶段 prompt token 处理吞吐 | 越高表示 prefill 侧处理 prompt 的速度越高 |
| cluster generation tok/s | vLLM `generation_tokens_total` delta / Wall Time | engine decode 侧生成 token counter 吞吐 | 越高通常表示 decode 引擎产出更快，但可能包含 migration replay/recompute |
| user completion tok/s | HTTP response `usage.completion_tokens` 总和 / Wall Time | 用户实际拿到的 completion token 吞吐 | 比 engine generation tok/s 更能代表用户可见产出 |
| replay/overhead tokens | `engine_generation_tokens_delta - user_completion_tokens`，小于 0 时按 0 | engine 额外工作量 proxy | 上升通常意味着 migration replay/recompute 或内部重放成本增加 |
| GPU active sample % | `nvidia-smi utilization.gpu > 0` 的采样比例 | GPU 是否活跃的粗粒度 proxy | 越低可能表示 GPU 被释放，也可能表示 workload 不足，需要结合 success/throughput 解读 |
| GPU effective seconds | `sum(gpu_util_pct / 100 * sample_duration)` | 粗粒度 GPU effective time 积分 | 同 workload 下越低表示 worker 更早进入低占用/可释放状态；它体现释放潜力，不等价于已经节省 GPU 成本 |
| avg GPU util % | `nvidia-smi utilization.gpu` 平均值 | GPU 平均忙碌程度 | 在未 scale down 的测试中，下降通常表示该 worker 不再持续承担 decode 工作；生产目标不是让所有卡 util 下降，而是把空闲卡 scale down 或复用到其他阶段 |
| max GPU mem MiB | `nvidia-smi memory.used` 最大值 | worker 最大显存占用 | 用于判断 worker 是否仍持有 GPU memory |
| S2 executed | controller status/log 中成功执行的 role switch 次数 | S2 自动闭环动作证据 | 大于 0 表示 controller 真实调用 sidecar 完成 role switch |
| S3 migrated | controller/worker log 中成功迁移的 request 数 | S3 自动闭环动作证据 | 大于 0 表示 controller 真实触发 migration |
| S3 declined/rollback | target 拒绝或 source rollback 的 migration 次数 | S3 触发窗口质量指标 | 越高说明迁移窗口偏早或 cost-benefit gating 不足 |

## 5. 四组矩阵测试结果

| 组别 | completed | success % | wall(s) | req/s | p50 latency(s) | p95 latency(s) | p99 latency(s) | engine gen tok/s | user completion tok/s | overhead tok | GPU active % | GPU effective s | avg GPU util % | S2 executed | S3 migrated | S3 declined |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Baseline | 96 | 100.00 | 59.96 | 1.60 | 4.85 | 4.98 | 4.98 | 1607.05 | 1605.59 | 88 | 71.21 | 91.31 | 49.71 | 0 | 0 | 0 |
| Enable S2 | 96 | 100.00 | 60.24 | 1.59 | 4.89 | 4.96 | 4.97 | 1608.46 | 1606.93 | 92 | 44.93 | 58.61 | 30.01 | 2 | 0 | 0 |
| Enable S3 | 96 | 100.00 | 61.58 | 1.56 | 4.84 | 5.17 | 5.65 | 1728.67 | 1461.16 | 16472 | 68.12 | 96.68 | 49.30 | 0 | 32 | 8 |
| Both Enable | 96 | 100.00 | 60.16 | 1.60 | 4.88 | 4.96 | 4.97 | 1600.06 | 1598.53 | 92 | 45.45 | 53.79 | 29.18 | 2 | 0 | 0 |

相对 Baseline 的变化：

| 组别 | Wall Time 改善 | req/s 提升 | p50 latency 改善 | p95 latency 改善 | user completion tok/s 提升 | GPU effective seconds 改善 |
|---|---:|---:|---:|---:|---:|---:|
| Enable S2 | -0.47% | -0.47% | -0.82% | 0.25% | 0.08% | 35.81% |
| Enable S3 | -2.70% | -2.63% | 0.11% | -3.83% | -9.00% | -5.87% |
| Both Enable | -0.34% | -0.34% | -0.75% | 0.25% | -0.44% | 41.09% |

四组矩阵测试的主要意义不是证明每个策略在同一个 workload 下都必然降低 wall time，而是证明：

1. 所有策略开关组合都能保持 100% request success。
2. S2/S3 的 controller 自动闭环能够真实触发动作。
3. S2 和 Both Enable 对 GPU effective seconds 的降低非常明显，说明在当前 workload 下有 worker 更早进入低占用/可释放状态。
4. S3 在当前窗口下能够迁移 request，但过早或过频迁移会造成 replay overhead，报告清晰暴露了需要优化的策略边界。

这里的 GPU effective seconds 和 avg GPU util 下降需要谨慎解释。按最终 auto-scaling 目标，理想状态不是让所有 GPU 的单卡利用率下降，而是把尾部请求合并到更少 worker 上，让 source worker drain 后被 scale down、切换 role 或承接其他阶段任务。由于本轮四组矩阵中 `CONSOLIDATION_SCALE_DOWN_ENABLED=false`，测试没有执行缩容，所以 GPU 指标只能证明“释放潜力”和“低效占用减少”，不能直接声称已经完成 GPU 成本节省。真正的 GPU effective hour 节省需要在 scale down 或 role reuse 生效后，用 DCGM/GPU busy time 积分进一步验证。

## 6. S2 独立策略收益

S2 标准测试更适合观察 PD Role Switch 对端到端 timing 和吞吐的正向收益。它与第 5 节四组矩阵不是同一 workload，因此不要把两组绝对数值混合比较；这一节只比较该 S2 测试内部的 baseline 与 strategy。

| 指标 | Baseline | S2 Strategy | 变化 |
|---|---:|---:|---:|
| completed requests | 36 | 36 | 0 |
| success % | 100.00 | 100.00 | 0 |
| Wall Time | 16.40s | 10.46s | 改善 36.24% |
| req/s | 2.20 | 3.44 | 提升 56.85% |
| p50 latency | 2.52s | 1.64s | 改善 34.74% |
| p95 latency | 2.86s | 1.69s | 改善 41.05% |
| cluster generation tok/s | 423.34 | 664.27 | 提升 56.91% |
| user completion tok/s | 421.51 | 661.12 | 提升 56.85% |

解释：

- S2 针对 prefill/decode 需求不均衡的阶段，将 worker role 动态切到更需要的方向。
- 当 workload 与 role switch 窗口匹配时，同样的请求批次能够更快完成，HTTP 请求吞吐和用户可见 completion token 吞吐同步提升。
- p50/p95 latency 同时下降，说明收益不是只来自少数快请求，而是整体请求完成时间分布都得到改善。

## 7. S3 独立策略收益与边界

S3 标准测试显示 Request Consolidation 链路可以在保持 100% success 的情况下运行，并在轻量窗口下有小幅 GPU effective seconds 改善。它与第 5 节四组矩阵不是同一 workload，因此这一节只比较该 S3 测试内部的 baseline 与 strategy。

| 指标 | Baseline | S3 Strategy | 变化 |
|---|---:|---:|---:|
| completed requests | 48 | 48 | 0 |
| success % | 100.00 | 100.00 | 0 |
| Wall Time | 19.918s | 19.913s | 改善 0.03% |
| req/s | 2.4099 | 2.4105 | 提升 0.03% |
| p50 latency | 3.188s | 3.202s | 下降 0.42% |
| p95 latency | 3.260s | 3.258s | 改善 0.06% |
| cluster generation tok/s | 1852.78 | 1915.25 | 提升 3.37% |
| GPU effective seconds | 31.16s | 30.92s | 改善 0.78% |

四组矩阵测试中 S3-only 进一步证明 controller 能自动触发 consolidation：记录到 32 个 migrated request 和 8 个 declined/rollback。但由于 replay/overhead tokens 从 baseline 的 88 增加到 16472，user completion tok/s 下降 9.00%，说明该轮测试中的 S3 触发窗口偏激进。

因此 S3 的当前结论是：

- 机制可行：controller 能自动发现条件并触发迁移。
- 服务连续性可接受：HTTP success 保持 100%。
- 策略窗口仍需优化：要减少 declined/rollback 和 replay overhead，才能让迁移稳定转化为端到端收益。

建议后续强化：

- source active request 必须连续多个 sample 稳定落在 `1..threshold`。
- target available capacity 不仅要大于 source active，还应保留安全余量。
- migration benefit 判断要使用剩余 decode time、已生成 token 数、request age 和 target queue pressure。
- replay/overhead tokens 应进入 controller 的负反馈，过高时降低迁移频率。

## 8. Both Enable 组合测试解释

Both Enable 在四组矩阵中保持 100% success，并触发 S2 role switch。GPU effective seconds 从 91.31s 降到 53.79s，改善 41.09%；avg GPU util 从 49.71% 降到 29.18%。

这组 GPU 指标下降的含义不是“单卡 GPU 利用率被提升”。恰恰相反，在未执行 scale down 的测试环境里，avg GPU util 下降说明一部分 worker 不再持续承担原来的 decode 负载，进入低占用状态。Auto-scaling 的目标是把这种低占用状态进一步转化为实际收益：

1. 如果启用 scale down，drain 后的 worker 可以释放 GPU allocation，降低 GPU effective hour。
2. 如果启用 role reuse，原本低效 decode tail worker 可以切换为 prefill 或承接其他阶段负载。
3. 如果集群有其他 RL rollout 任务，释放出来的 GPU capacity 可以服务其他 batch，提升集群级 throughput。

因此 Both Enable 的数据应解释为“策略产生了可释放容量”，而不是“每张卡更忙”。最终目标是用更少 GPU 时间完成相同 workload，或用相同 GPU 时间承接更多 workload。

需要注意当前集群拓扑只有 2 个 ready decode worker。S2 一旦将其中一个 decode worker 切换为 prefill，S3 就缺少 source/target decode pair。因此 Both Enable 本轮主要证明：

- S2 和 S3 controller 可以同时装载并运行。
- 策略启用不会破坏请求成功率。
- 在资源有限拓扑下，S2 会优先改变 decode pool 结构，导致 S3 没有足够 pair 可迁移。
- 要证明 S2 + S3 的叠加收益，需要至少 3 个 ready decode worker，或者设计两阶段 workload：先进入 S3 tail consolidation，再恢复/补足 decode pair 后触发 S2。

## 9. 可行性证明

本项目的可行性已经由以下证据链支撑：

1. **部署可行**：controller 镜像通过标准部署运行在 K8s；测试通过 `kubectl` 和真实 Dynamo workload 执行。
2. **请求端到端可行**：所有关键测试均通过 Dynamo frontend 发送真实 HTTP 请求，而不是只调用 controller mock。
3. **S2 worker-side 机制可行**：worker 能完成 role switch，并在 `pod_metrics.csv` 中体现 `current_role` 从 `decode` 变为 `prefill`。
4. **S2 controller 自动闭环可行**：`strategy_events.jsonl` 中记录 `strategy.s2_history.executed=true`。
5. **S3 worker-side 机制可行**：worker logs 中出现 `migration_complete` 和 `migration_rollback`。
6. **S3 controller 自动闭环可行**：controller logs 中出现 stable window、decision、POST `/migrate` 和 `migrated=N`。
7. **服务正确性可行**：四组矩阵全部 96/96 HTTP 200，success rate 100%。
8. **效能收益可观察**：S2 标准测试显示 wall time、req/s、latency、token/s 全面改善；四组矩阵显示 GPU effective seconds 在 S2/Both 下显著下降。

## 10. 效能提升总结

综合当前数据，最强的效能提升体现在两个维度：

### 10.1 用户可见吞吐与延迟

S2 标准测试中：

- Wall Time 改善 36.24%
- req/s 提升 56.85%
- p50 latency 改善 34.74%
- p95 latency 改善 41.05%
- user completion tok/s 提升 56.85%

这说明 PD Role Switch 在匹配 workload 阶段时，能够直接提升用户请求完成速度和 token 产出速度。

### 10.2 GPU 资源利用效率

四组矩阵测试中：

- S2-only GPU effective seconds 改善 35.81%
- Both Enable GPU effective seconds 改善 41.09%
- S2-only avg GPU util 从 49.71% 降到 30.01%
- Both Enable avg GPU util 从 49.71% 降到 29.18%

在 success rate 保持 100% 的前提下，GPU effective seconds 明显下降，说明策略能够减少 GPU 的低效持续占用。需要强调的是，这不是“单卡 util 越低越好”；真正的目标是让被 consolidation 或 role switch 释放出来的 worker 不再以低效率占用 GPU，而是被 scale down、切换到更需要的 role，或交给其他 batch 使用。换句话说，测试中的 GPU util 下降是 auto-scaling 的前置证据，最终收益应体现为 GPU effective hour 降低或集群吞吐提升。

## 11. 当前边界与后续优化

当前报告中的 GPU 指标来自 per-pod `nvidia-smi` 采样，是粗粒度 proxy，不是 DCGM exporter 的精确 busy time 积分。它适合同一环境、同一 workload 下横向对比趋势，但不应直接作为生产计费口径。下一步需要接入 DCGM exporter，按 pod/worker 对 GPU busy time 做积分，并和 DGDSA replica scale down 事件对齐，才能严谨计算 GPU effective hour 节省。

S3 的 user-visible stream reattachment 仍需谨慎表述：当前迁移证明了 engine-side takeover、block-hold、rollback/complete 和 resource release 机制，但不等价于完整的 client stream 无损迁移。

后续为了进一步提升说服力，建议：

1. 接入 DCGM exporter，计算 GPU busy time 积分和 GPU effective hour。
2. 为 S3 增加更严格的多 sample gating 和 benefit model。
3. 将 user-visible output tokens 与 engine replay tokens 在 controller/report 中永久分离。
4. 在至少 3 个 ready decode worker 的拓扑下重跑 Both Enable，验证 S2 + S3 叠加收益。
5. 增加两阶段 workload：先 decode-tail consolidation，再 prefill-heavy role switch。

## 12. 最终判断

当前测试体系已经覆盖机制验证、controller 自动闭环验证、四组配置对照、端到端 HTTP 正确性、token throughput、latency、GPU utilization 和 GPU effective seconds。

从数据看，方案已经证明可行：S2/S3 能在真实 Dynamo + K8s 环境中执行，且不破坏请求成功率。方案也已经体现出明确效能提升：S2 在端到端 timing、请求吞吐、用户可见 token/s 和 latency 上有显著改善；S2/Both 在 GPU effective seconds 上有显著下降。S3 已证明自动迁移链路成立，但要稳定转化为端到端性能收益，还需要继续收敛触发窗口和 migration cost model。
