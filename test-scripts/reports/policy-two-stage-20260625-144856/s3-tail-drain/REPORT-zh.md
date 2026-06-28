# 阶段报告：s3-tail-drain

## 这一阶段在测什么

这个阶段专门验证 **S3 Request Consolidation** 在 decode tail 场景下的效果。

### 指标含义

- `pre`：策略动作发生前的第一波请求，代表基线压力。
- `post`：策略动作后发出的第二波请求，代表策略生效后的真实效果。
- `req/s`：该波次每秒完成的请求数，越高说明前端请求排得越快。
- `wall time (s)`：该波次从第一个请求开始到最后一个请求完成的总耗时，越低越好。
- `p95 latency (s)`：单请求尾延迟，越低说明尾部体验越好。
- `overall generation tok/s`：整个场景的生成 token 吞吐，越高说明 decode 侧更有效率。

### 为什么这样设计能验证 timing

如果只看单批次总时间，很容易把“动作成本”与“动作收益”混在一起。因此这里把 workload 分成两波：

1. `pre` 波次先打满系统，让 source decode worker 出现 tail request。
2. 在 `post` 波次之前执行 consolidation，让 tail request 尽可能被迁移到更合适的 target。
3. 比较 `post` 波次的 req/s、wall time 和 p95 latency。

这样就能直接看出：**同样来自客户端的请求，在策略生效后是否更快完成**。

### 为什么这样设计能验证 GPU effective hour

S3 的目标不是单纯把某个请求变快，而是尽快把碎片化的 decode 尾部合并掉，让 GPU 尽快恢复成更高效的服务状态。这个效果体现在：

- `post wall time` 变短：说明这批工作在更短的 GPU 占用窗口内完成；
- `overall generation tok/s` 提升：说明同样的 GPU 工时产出了更多有效 token；
- `post req/s` 提升：说明 GPU 被更高效地用于处理更多请求。

因此，这个阶段是通过 **更短的处理时间 + 更高的 token 吞吐** 来验证 GPU effective hour 改善的。

## 结果解读

| metric | baseline | strategy | strategy vs baseline |
|---|---:|---:|---:|
| pre req/s | 1.251 | 1.248 | -0.215% |
| pre wall time (s) | 19.190 | 19.231 | -0.216% |
| pre p95 latency (s) | 4.906 | 4.852 | 1.114% |
| post req/s | 1.259 | 1.386 | 10.046% |
| post wall time (s) | 19.058 | 17.318 | 9.129% |
| post p95 latency (s) | 4.553 | 4.588 | -0.767% |
| overall wall time (s) | 25.096 | 23.572 | 6.075% |
| overall generation tok/s | 1190.969 | 1269.191 | 6.568% |

### 观察到的效果

- `pre` 阶段两边非常接近，说明策略动作之前，系统还处在同一个基线压力下。
- `post` 阶段 `req/s` 从 `1.259` 提升到 `1.386`，说明 consolidation 之后，第二波请求被更快处理。
- `post wall time` 从 `19.058s` 降到 `17.318s`，说明 decode tail 被收敛后，后续请求完成得更早。
- `overall generation tok/s` 从 `1190.969` 提升到 `1269.191`，说明 GPU 的有效工时被更充分地转化为 token 产出。
- `post p95 latency` 基本持平，说明 S3 在这个阶段主要优化的是 **吞吐和排空效率**，不是每个请求的单点极限延迟。

### 策略证据

- Baseline events: `{"phase_boundary": 1}`
- Strategy events: `{"request_consolidation": 1}`

这表示 baseline 只经过了阶段边界，没有策略动作；strategy 则真正执行了一次 request consolidation。

## 结论

这个阶段证明了：S3 不一定要让每个请求都更快，但它可以通过缩短 decode tail 的存在时间，让 GPU 更快回到可用状态，并在 `post` 波次里表现为更高的吞吐和更短的总处理时间。

## 产物索引

- `baseline/REPORT.md`
- `strategy/REPORT.md`
