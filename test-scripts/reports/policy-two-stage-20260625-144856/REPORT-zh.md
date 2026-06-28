# 两阶段策略驱动端到端测试报告

## 执行摘要

| 阶段 | post 阶段 baseline req/s | post 阶段 strategy req/s | post 阶段 baseline wall(s) | post 阶段 strategy wall(s) | overall baseline wall(s) | overall strategy wall(s) | overall baseline gen tok/s | overall strategy gen tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| s3-tail-drain | 1.259 | 1.386 | 19.058 | 17.318 | 25.096 | 23.572 | 1190.969 | 1269.191 |
| s2-after-drain | 1.934 | 3.144 | 16.543 | 10.179 | 33.112 | 30.239 | 618.723 | 727.676 |

## 这个测试是如何设计的

本次两阶段测试不是只看“一个 batch 的总时间”，而是把策略收益拆成两个可解释的维度：

1. **客户端处理请求的 timing**
   - 通过 `pre` / `post` 两个波次，把同一个场景拆成“策略生效前”和“策略生效后”。
   - `pre` 波次用来记录动作发生前的基线负载。
   - `post` 波次用来观察策略把 topology 改好之后，客户端请求是否更快完成、尾延迟是否更低。

2. **GPU effective hour / GPU 利用效率**
   - 本测试通过 `wall time`、`generation tok/s` 和 pod 级吞吐来近似衡量 GPU 有效工时。
   - 如果在相同或更少的 GPU 占用窗口内完成更多 token 生成，那么就说明 GPU effective hour 更优。
   - `S3` 的作用是尽早 drain decode tail，减少碎片化占用；`S2` 的作用是把空出来的 GPU worker 转成更有价值的 prefill capacity，从而提高后续波次的有效吞吐。

换句话说，这个测试同时验证两件事：

- **timing**：客户端从发起请求到完成请求，是否更快；
- **GPU effective hour**：同样的模型工作量，是否在更短的 GPU 占用时间里完成。

## 阶段说明

- `s3-tail-drain`：只强调 **Request Consolidation**，验证 decode tail 收敛后，后续波次是否更快。
- `s2-after-drain`：先 consolidation，再 role switch，验证“排空 tail + 切换角色”之后，后续波次是否在更高前端压力下仍能更快完成。

## 结果概览

| stage | 关键结论 |
|---|---|
| s3-tail-drain | `post` 阶段 req/s 提升、wall time 缩短，说明 tail drain 后 cluster 更快释放可用容量。 |
| s2-after-drain | `post` 阶段 req/s 大幅提升、p95 latency 显著下降，说明先 drain 再切换角色可以让后续高前端吞吐波次明显受益。 |

## 报告目录

- [s3-tail-drain/REPORT-zh.md](s3-tail-drain/REPORT-zh.md)
- [s2-after-drain/REPORT-zh.md](s2-after-drain/REPORT-zh.md)

## 产物索引

- `topology.csv`
- `experiment_config.csv`
