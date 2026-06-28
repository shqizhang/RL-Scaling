# 阶段报告：s2-after-drain

## 这一阶段在测什么

这个阶段验证的是 **S3 Request Consolidation + S2 PD Role Switch** 的组合效果。

### 指标含义

- `pre`：策略动作发生前的第一波请求。
- `post`：完成 consolidation 并切换角色后的第二波请求。
- `req/s`：每秒完成请求数，越高越好。
- `wall time (s)`：该波次从第一个请求到最后一个请求的总耗时，越低越好。
- `p95 latency (s)`：尾部请求延迟，越低说明 tail 请求体验更好。
- `overall generation tok/s`：全场景 token 吞吐，越高说明 GPU 工时更有效。

### 为什么这样设计能验证 timing

这个阶段不是只看“策略动作本身用了多久”，而是看 **策略动作之后，客户端的后续请求是否更快完成**。设计上分成两波：

1. `pre` 波次：先让 decode 侧出现 tail requests，并记录基线压力；
2. 在这之后先做 consolidation，再把被排空的 source worker 切成 prefill；
3. `post` 波次：在新的 topology 上再打一波请求，观察 timing 是否改善。

这样可以把“动作成本”与“动作收益”分离开：

- `pre` 的下降或变差，反映的是策略在准备阶段付出的成本；
- `post` 的提升，反映的是新 topology 对后续客户端请求的真实收益。

### 为什么这样设计能验证 GPU effective hour

S2 的价值在于把已经不再承担 decode tail 的 worker，重新用于 prefill。这样同样数量的 GPU，不是空转等待，而是被重新分配到更有价值的阶段。

GPU effective hour 的判断思路是：

- 如果 `post` 波次在更短时间内完成更多请求和更多 token，说明同样的 GPU 占用时间产生了更多有效产出；
- 如果 `overall wall time` 缩短，同时 `overall generation tok/s` 提升，说明 GPU 的有效利用效率更高；
- 这就对应于“用更少的 GPU 时间完成更多客户端请求”。

所以，这个阶段是通过 **后续波次更快完成 + token 吞吐更高** 来证明 GPU effective hour 的改善。

## 结果解读

| metric | baseline | strategy | strategy vs baseline |
|---|---:|---:|---:|
| pre req/s | 1.457 | 1.239 | -14.977% |
| pre wall time (s) | 16.474 | 19.376 | -17.616% |
| pre p95 latency (s) | 4.326 | 4.802 | -11.003% |
| post req/s | 1.934 | 3.144 | 62.514% |
| post wall time (s) | 16.543 | 10.179 | 38.467% |
| post p95 latency (s) | 4.267 | 2.559 | 40.031% |
| overall wall time (s) | 33.112 | 30.239 | 8.677% |
| overall generation tok/s | 618.723 | 727.676 | 17.609% |

### 观察到的效果

- `pre` 阶段 strategy 变差，这不是失败，而是因为它在这里承担了 consolidation 和 role switch 的动作成本。
- `post` 阶段 `req/s` 从 `1.934` 提升到 `3.144`，说明新 topology 对后续请求的吞吐明显更强。
- `post wall time` 从 `16.543s` 降到 `10.179s`，说明第二波请求在策略完成后更快结束。
- `post p95 latency` 从 `4.267s` 降到 `2.559s`，说明不仅平均吞吐提升，尾部请求也明显变快。
- `overall generation tok/s` 从 `618.723` 提升到 `727.676`，说明相同 GPU 工时产生了更多有效 token。

### 策略证据

- Baseline events: `{"phase_boundary": 1}`
- Strategy events: `{"request_consolidation": 1, "role_switch": 1}`

这意味着 baseline 没有进行任何 scaling 动作；strategy 则先做 consolidation，再做 role switch，因此能够解释为什么 `post` 波次显著受益。

## 结论

这个阶段最能说明 PD Role Switch 的价值：先用 S3 清掉 decode tail，再用 S2 把释放出来的 worker 转成 prefill。这样后续面对更高前端吞吐时，系统可以更快完成请求、降低尾延迟，并提升 GPU effective hour。

## 产物索引

- `baseline/REPORT.md`
- `strategy/REPORT.md`
