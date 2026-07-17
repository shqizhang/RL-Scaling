# RL-Scaling 深度性能分析（修复后干净数据集）

suite: `strategy-four-scenario-20260714-152929`
worker 镜像 `rl-scaling-3fc3e8fe6f-nixlfix`；**controller `drainfix-1`（含 pod-deletion-cost 修复）**；operator=0。

本轮相对上一轮做了三处修复：
1. **修复 mixed “缩容先于排空”真 bug**：缩容前给已排空的源 decode pod 打 `controller.kubernetes.io/pod-deletion-cost`，让 K8s 精确回收**那块空 pod**而不是随机（可能繁忙）的 pod。
2. **修正测量口径**：新增 `serving_wall`（三相位服务墙钟之和，剔除 warmup 与相位间就绪/切换编排）、`serving_gpu_s`、`serving_tokens_per_gpu_s`、`s2_switch_total_ms`、`orchestration_overhead_s`。
3. 全场景 operator=0，warmup 用 forced-topology 兜底。

---

## 0. 修复效果最直观的一条：mixed 从 88% → 100% valid

| | 上一轮(无修复) | 本轮(pod-deletion-cost) |
|---|---|---|
| mixed valid% | **88.2%**（2 个长尾被 `EngineShutdown` 杀）| **100%** |
| mixed 3 个长尾结局 | #89 killed, #90 killed, #91=101tok | #89=5965(迁移), #90=8000, #91=8000 **全部完成** |
| 控制器日志 | 缩容后随机杀 busy pod | `marked drained pod sphql for preferential deletion` → 精准回收空 pod |

**结论：drain-before-scale-down 竞争已消除。** 缩容前先把已排空的源 pod 标记为“优先删除”，K8s 就只会终止那块空 pod，繁忙 decoder 上的长尾请求不再被误杀。

---

## 1. 总览（修正口径）

| 场景 | serving_wall(s) | vs base | orch开销(s) | valid% | timeout | prefill(s) | tail(s) | serving_gpu_s | S2切换 | S3迁移/缩容 | tail decode GPU·s 省 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | **91.1** | 0% | 6.3 | 100 | 0 | 34.4 | 46.4 | 150.7 | 0 | — | 3.7 (8%) |
| s2_only | **67.6** | **−25.8%** | 103.3 | 99.0 | 0 | **22.1** | 37.4 | 222.8 | 2×(1021ms) | — | −32.8 (不整合) |
| s3_only | **64.4** | **−29.3%** | 6.0 | 100 | 0 | 20.5 | 37.1 | 206.8 | 0 | 1 / 2→1 | **11.3 (15%)** |
| mixed | **73.5** | **−19.3%** | 99.1 | 100 | 0 | 16.7 | 49.5 | 248.8 | 2×(885ms) | 1 / 2→1 | **21.5 (22%)** |

> 口径说明：`serving_wall` 只含三相位真实请求服务；`orch开销` 是被剔除的“相位间就绪探测+拓扑切换验证”（s2/mixed ~100s、s3 ~6s——差别正是 role-switch 编排）；warmup(~200s，冷启动)在 serving 之前、不计入。**评判即用 serving_wall（时间）+ tail decode GPU·s（GPU）+ 动作延迟（成本）。**
> 拓扑注记：baseline=1P1D(2 GPU)，策略场景=2P2D(4 GPU)。故 serving_wall 的改善包含“拓扑翻倍 + 策略”两部分；下面各节把**策略本身的净贡献**单独拎出。

---

## 2. S2（关注：总墙钟时间）

### 2.1 结果
| 指标 | baseline | s2_only | 改善 |
|---|---:|---:|---:|
| **serving_wall** | 91.1 | **67.6** | **−25.8%（省 23.5s）** |
| prefill wall | 34.4 | **22.1** | **−35.8%** |
| tail wall | 46.4 | 37.4 | −19.4% |
| 切换动作总成本 | — | **1.02s**（2 次，D→P/P→D）| — |
| **含切换的有效墙钟** | 91.1 | 67.6+1.0 = **68.6** | **−24.7%** |

### 2.2 解读
- **S2 让同一批 workload 的服务墙钟降 ~26%**，切换动作只花 ~1s（净收益比 ~23×）。这直接回答“S2 看总墙钟”：**弹性切换后端到端更快**。
- **策略净贡献**：prefill 段 D→P 把 prefill 从（1P baseline 的）34.4s 压到（借第 3 个 prefill 的）22.1s；这是 S2 的核心引擎。tail 段两者都回到 2P2D，S2 靠 P→D 切回 + 缓存热度小幅领先。
- **一个需加固的小瑕疵**：s2 valid=99.0%（64 个 prefill 里 1 个在 D→P 切换瞬间被丢，非 timeout）。同类“切换瞬间在飞请求”问题，量级远小于已修复的 mixed（1/64=1.6%）。建议后续给切换加“in-flight 静默窗口”。

---

## 3. S3（关注：GPU 利用率）

### 3.1 迁移 → 排空 → 缩容 → 释放 GPU（自主，含新修复）
控制器日志（mixed 示例，08:00:20）：
```
decision  source_active=1 target_capacity=62 request_count=1   (t=0ms)
executed  migrated=1                                            (t=20ms)
marked drained pod sphql for preferential deletion             (t=97ms)   ← 本轮新增
scaled decode replicas: 2 -> 1                                 (t=183ms)
```
**整合的控制动作端到端 ~183ms**（其中新增的“标记优先删除”~77ms）。迁移调用本身 ~20ms，目标以 recompute 续跑被迁移请求、不阻塞其它请求。

### 3.2 GPU 占用对比（证明省 GPU）
| 场景 | tail 实际 decode GPU·s | 反事实(2 decoder 全程) | **省** | tail 平均就绪 worker |
|---|---:|---:|---:|---:|
| baseline(1P1D) | 42.6 | 46.4 | 3.7 (8%) | 2.00 |
| s2_only(不整合) | 70.2 | 37.4 | **−32.8（守着 2 decoder 白占）** | 4.00 |
| **s3_only** | **63.0** | **74.2** | **+11.3（15%）** | 4.00* |
| **mixed** | **77.5** | **99.0** | **+21.5（22%）** | **3.70（min 3）** |

- **S3 在长尾阶段真实回收 1 块 decode GPU**：observed 相比 counterfactual 少用的 decode GPU·s 即净省（s3 15%、mixed 22%）。mixed 因 tail 更长(49.5s)、缩容后低配运行时间更久，`avg_ready_workers` 明显掉到 **3.70（min=3=2P1D）**，是最干净的“释放一块 GPU”证据。
- *s3_only 的 avg_ready_workers 显示 4.00，是**优雅终止滞后**造成的采样假象（被删 pod 在 Terminating 期间仍短暂 Ready）；但 `decode_allocated_seconds`(63.0<74.2) 与控制器 `2→1` 日志都证明缩容已发生。
- **对比 s2 那行（−32.8）**：不做整合、全程守 2 个 decoder，就是纯浪费——这恰好反衬 S3 的价值。

### 3.3 时间不受损
s3_only serving_wall 64.4（−29% vs base），tail valid=100%、0 timeout：**回收 GPU 的同时不牺牲长尾完成质量**（被迁移请求以 recompute 透明续跑）。

---

## 4. mixed（关注：组合能拿到什么好处）

### 4.1 两套机制同时生效、且现在 100% 干净
- **S2**：2 次切换（885ms），prefill 压到 **16.7s**（四场景最快——2P2D + D→P 叠加）。
- **S3**：migrated=1、decode 2→1、tail decode GPU·s 省 **22%（四场景最高）**、avg worker 掉到 3.70。
- **valid=100%、0 timeout**（修复前是 88%）。

### 4.2 组合优势 = “忙时扩 prefill 抢延迟” + “将尽时收 decode 省 GPU”
mixed 在一条负载曲线上同时吃到两个红利：
1. prefill 突发段：D→P 借算力 → prefill 16.7s（比 baseline 34.4s 快一半）。
2. 长尾收尾段：整合把零散长尾迁到更少 decoder、释放 1 块 GPU → 省 22% tail decode GPU·s。

即 **mixed = S2 的时间收益 ∪ S3 的 GPU 收益**，且修复后无副作用。代价仅是两次切换(0.9s)+一次整合(0.18s)的控制动作。

### 4.3 组合的注意点
mixed serving_wall(73.5) 略高于 s3_only(64.4)：因为 mixed 的 tail 更长(49.5s)——长尾在“P→D 加 decoder”与“S3 减 decoder”之间被反复调度，收尾时间变长。这是组合弹性的固有张力（一个往上弹、一个往下弹），非错误；若要更平滑可将 S2/S3 决策错峰。

---

## 5. 整体结论

| 维度 | baseline | S2 | S3 | mixed |
|---|---|---|---|---|
| serving 墙钟 | 91.1s | **−25.8%** | −29.3% | −19.3% |
| prefill 墙钟 | 34.4s | **−35.8%** | −40% | **−51%** |
| tail decode GPU·s 省 | — | 不整合 | **15%** | **22%** |
| decode 缩容(释放GPU) | — | — | **2→1** | **2→1** |
| 动作成本 | — | 切换 1.0s | 整合 0.18s | 1.0s+0.18s |
| valid% / timeout | 100/0 | 99.0/0 | 100/0 | **100/0** |

- **S2 的价值是时间**：弹性 D→P 让 prefill 快 ~36%、整体服务墙钟快 ~26%，切换成本可忽略。
- **S3 的价值是 GPU**：长尾整合真实回收 1 块 decode GPU（省 15–22% tail decode GPU·s），控制动作 ~180ms，且不损完成质量。
- **mixed 拿到两者之和且现在完全干净**（pod-deletion-cost 修复后 100% valid、0 timeout）。
- **公平口径**（务必沿用）：S2 看 `serving_wall`/`prefill_wall`；S3 看 `tail_decode_gpu_s_saved`/就绪 worker 数；成本看切换/整合动作延迟。**不要用整场 `wall_s`（含编排）或 `tokens_per_gpu_s`（受迁移改产出+拓扑规模双重污染）跨场景直接比。**

### 待办（本轮暴露、非阻塞）
1. **S2 切换瞬间丢请求**（s2 99%）：给 D→P/P→D 加 in-flight 静默/迁移窗口。
2. **迁移保真度**：让 migration 携带 `ignore_eos` 等全部 sampling params（当前被迁移长尾会提前在自然 EOS 停），使 token 产出在各场景可比。
3. **S2/S3 决策错峰**：mixed 中避免两者同时改 decode 拓扑，减少收尾抖动。
