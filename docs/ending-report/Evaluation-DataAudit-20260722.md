# Data Audit：final-report.md 技术方案与数据结论核查（2026-07-22）

> 方法：不依赖任何中间报告，直接用 `FINAL-phased-merged-20260720/` 的
> `aggregate-summary.json`、`events.json`、`controller.log`、`requests.csv`、
> `pod_samples.csv`、`prom_samples.json` 逐条复算 final-report.md 的数字与叙述，
> 并对照当前代码（`dual_mode.py`、`handlers.py`、`state_machine.py`、
> `consolidation/controller.py`）。与 `Evaluation-Report.md`（写作评审）互补；
> 其 Critical 3.1/3.2/3.3/3.4/3.7 本次全部经原始日志证实，下文不重复展开，
> 只列本次新发现或需要修正其表述的部分。

---

## 1. 先说可信的部分：主表数字全部可复现

用 6×3 个 run 的 summary 重算，final-report Part 7.4/7.5 的数值均与原始数据一致：

- T_batch 均值：baseline 88.1 / static-old 69.4 / s3 72.6 / static-new 69.4 / s2 70.9 / mixed 73.6 ✓
- 分段 wall：static-old A 33.2、B 17.4、C 29.4；s3 A 24.2、B 12.3、C 32.6；
  static-new A 23.4、B 12.8；s2 A 37.9、B 23.5、C 30.9；mixed A 37.7、B 23.5、C 33.6 ✓
- 统计量：static vs baseline t=−9.98；s3 vs static C-tail decode-GPU·s −26.1（−44.5%）
  t=−103.9；avg decode GPU −0.44（−22.1%）t=−94.9；whole-run −25.7（−18.5%）✓
- 质量门：18/18 run 全部 100% valid、0 timeout、0 5xx ✓

结论：**没有数字造假问题；问题全部在归因和机制叙述层。**

---

## 2. Critical：与原始日志矛盾的技术叙述（必须改）

### 2.1 S2 切换时刻与报告叙述不符（新发现，最重要）

报告 §7.5 写 "Two switches fire per run — D→P during phase A, P→D during phase B"。
controller.log 实际时刻（相对 T0）：

| run | D→P 完成 | P→D 完成 | P→D 触发原因 |
|---|---|---|---|
| s2 run-01 | **T0 − 26 s** | +38.6 s（B 段） | decode_queue=56 |
| s2 run-02 | **T0 − 8 s** | +55.6 s（**C 段**） | decode_queue=3 |
| s2 run-03 | **T0 − 8 s** | +55.8 s（**C 段**） | decode_queue=3 |
| mixed ×3 | T0 − 9 ~ −8 s | +52 ~ +56 s（**C 段**） | decode_queue=3 |

三个事实与报告相反：

1. **D→P 在 6/6 个 run 中发生在 T0 之前**，触发原因是
   `prefill_queue=2>=1`——来源是 prewarm/readiness 探针流量，不是 A 段 burst。
   阈值 1 太敏感，把探针噪声当成了 burst 信号。
2. **P→D 在 5/6 个 run 中发生在 C 段**（decode_queue=3 = 三条 straggler），
   不是 B 段。整个 B 段几乎都在 3P1D 下运行。
3. §7.5 说 s2 的 A 段 +14.4 s "carries ~6.8 s of two switch overheads" ——
   **错误**：D→P 在窗口外完成，A 段内切换开销为 0；P→D 的 ~3.5 s 落在 B/C 段。

由此 S2 结果的正确解读不是"被 session 噪声淹没"，而是：
**D→P 被探针噪声提前触发、P→D 回切过晚，导致 decode 需求为主的 A/B 段
长期处于 3P1D（decode 只剩 1 个），A +14.5 s、B +10.7 s 是同 session 内
3 个 run 一致复现（run 间方差 < 1 s）的真实机制代价，是触发校准缺陷，
不是测量噪声。** session drift 只影响与 static-old 的跨 session 对比。

修改建议：§7.5 S2 段改写为——(a) 陈述实际触发时刻和原因；(b) 承认本轮
D→P 触发被 pre-T0 探针污染，属阈值校准缺陷（PREFILL_QUEUE_THRESHOLD=1）；
(c) 把 A/B 变慢归因为 "role 切换方向与阶段需求错配时的真实代价"，这反而是
支持"需要正确相位信号"论点的有力证据；(d) 删除 6.8 s 切换开销的错误归因。

### 2.2 S3 的 44.5% 来自空源释放，且释放发生在 C 段开始之前（证实 + 补充时序）

`s3_migrated_requests = 0`（s3_only、mixed 全部 6 run）已由 Evaluation-Report 3.1
指出。本次补充关键时序：s3_only run-01 中 S3 决策在 completion=0.949（56/59，
即 A+B 全部完成、C 尚未发射）时触发，`source_active=0, request_count=0`，
**在 C_tail 发射前 4 s 就完成了 cordon + 2→1**。C 段从第一秒起就在 1 decoder
上运行——没有任何"tail 期把分散请求合并"的动作发生。

连带两处叙述错误：

- §7.5 "p95 latency also improves (32.3 → 23.6) because consolidation clears the
  scattered tail faster" ——**归因错误**。C 段 wall 实际从 29.4 s **变长**到
  32.6 s（3 条 straggler 挤在 1 GPU 上）；p95 改善来自 old-session 内 s3 的
  A/B 段恰好比 static-old 快（24.2 vs 33.2，正是报告自己承认的 session 漂移），
  与 consolidation 无关。
- §7.5 未提及 S3 的代价：T_batch +3.2 s（+4.6% vs static-old）、C wall +3.2 s。
  应明示这是"用 ~4.6% makespan 换 18.5% decode GPU-s"的 trade-off——这个
  trade-off 本身是好结果，藏起来反而减分。

修改建议：全文把本轮 S3 效果命名为 **tail-aware idle decoder reclamation
（empty-source release）**；44.5%/−22% 数字保留但改名；迁移协议（Part 5）
作为 mechanism 证据引用 midterm 与 `phased-5scenario-20260720-validated/s3_only`
（真实 POST /migrate 成功的那次），并注明主性能数据集中 migration 未被触发的
原因（B→C 之间存在 4 s 空档 + completion gate 0.92 恰在空档内满足 + router
把 3 条 straggler 路由到同一 decoder）。

### 2.3 mixed "only 1 of 3 runs completed the 2→1 scale-down" 与日志矛盾（新发现）

controller.log 显示 mixed **3/3 个 run 都执行了** "scaled decode replicas: 2 -> 1"
（分别在 T0+61 s / +61 s / +61 s 附近），`min_spec_decode_replicas=[2,2,1]` 只是
1 s 粒度 pod sampler 在业务窗口内是否采到 spec=1 的差异（RESULTS 文档 §5 脚注
早已警告过这种 sampler 缺口）。正确叙述是：**3/3 执行了缩容，但因 S2/S3 desync
（STABLE_SAMPLES）把动作推迟到 T0+61 s（T_end≈+74 s），窗口内平均只降到 1.84。**

另一个应写进报告的日志证据：mixed 中 P→D（+52~56 s，C 段）恢复出一个空 decoder，
S3 在 5–9 s 后就把它 cordon + 释放——一次完整的 **S2/S3 churn 环**（切入 ~3.5 s
+ settle，随即释放），这是 "mixed 需要动作仲裁" 的最直接证据，比现在的抽象描述
有力得多。

### 2.4 控制器状态机描述与代码不符（证实）

`state_machine.py` 实际为 `IDLE → WARM_UP → ACTIVE → COOL_DOWN`（S1），S2/S3 是
统一 control loop 中按 S3→S2→S1 顺序独立决策的模块。§6.1 的
`IDLE → WARM_UP → REBALANCE → CONSOLIDATE → DRAIN` 是虚构的，直接按代码改。

### 2.5 迁移 fidelity：两个 bug 已修复但未被本数据集验证（新信息）

KB-03 §6 的两个缺陷在当前代码中**已修复**：`handlers.py::_sampling_params_to_dict`
改为全量字段快照（含 `ignore_eos`，docstring 明确记录旧 bug）；
`_extract_prompt_token_ids` 处理 TypedDict（修复 `prompt_tokens=[]`）。
但 merged 数据集 0 次迁移，修复**未被端到端验证**。写法应为
"fixed in the current build, not yet exercised in the reported runs"。
§5 "gives the client exactly one logical stream" 仍超出实现
（engine-side takeover ≠ client SSE reattach，见 Evaluation-Report 3.2），必须改。

### 2.6 workload 表的 token 数是错的（新发现）

§7.1 表与 requests.csv 实测：

| Phase | 报告 ISL | 实测 prompt_tokens 均值（范围） |
|---|---|---|
| A | ≈1560 | **4227**（3737–4759） |
| B | ≈585 | **1617**（1328–1999） |
| C | ~50 words | 288（279–300） |

words→tokens 的换算低估了近 3 倍（随机词表 ≈3.5 tok/word）。`batch_meta`
的 `avg_isl=1085` 同样失真。直接改用实测值，并说明 avg_isl 是 harness 估算值。

### 2.7 小项

- `s2_switch_total_ms` 在 summary.json 中恒为 0.0（聚合 bug），切换耗时只存在于
  controller.log。报告引用的 "3.44–3.57 s" 实际全量范围是 **3.41–3.61 s**
  （mixed run-02 为 3613 ms）。修 harness 聚合，把 switch/migration 事件写入
  events.json（当前 events.json 只有 6 条 phase 事件，机制动作全部缺失）。
- §7.5 mixed "(phase-C decode-GPU 2.00 → 1.84; vs new static −0.07, t = −5.3)"
  混用了两个口径：phase-C 差是 −0.16（t=−5.2），−0.07 是 whole-run 平均
  decode GPU（1.93 vs 2.00）。拆开写。
- s3_only 的 `s3_drained_source_count=2` 实为同一空源事件的重复计数
  （日志中缩容后决策循环每秒重复输出 executed migrated=0），叙述时不要当作
  "两个源被 drain"。同时建议给 consolidation controller 加去重/静默逻辑。

---

## 3. 现有 metrics 能否支撑 report-indicator.md 要求的分析？

对照 indicator 逐项：

| indicator 要求 | 现有数据 | 判定 |
|---|---|---|
| 2P2D static 的 T_batch、分段 timing、GPU nums | summary 完整、可复现 | ✅ |
| S2：A 段内 D→P timing、B 段内 P→D timing | 切换时刻/耗时只在 controller.log；且实际时刻不在 indicator 设想的阶段内（§2.1） | ⚠️ 数据在，但结论方向与设想相反 |
| S2：切换后 prefill/decode **queue timing** 提升 | **无法支撑**：requests.csv 无 TTFT；prom_samples 只有 frontend 聚合 queue 深度、~5 s 粒度 20 个采样、无 per-role 序列 | ❌ 缺关键字段 |
| 分段 prefill/decode_GPU_nums | pod sampler 按 Deployment 计数，**role-blind**：s2 的 A 段 avg prefill GPUs 仍记 2.0（实际 3 个 prefill 在服务）、decode 仍记 2.0（实际 1 个）。`current_role_label` 列有部分数据但采样不全 | ❌ 对 S2 场景失真 |
| S3：C 段 decode timing + GPU 占用下降 | decode-GPU·s、avg decode GPUs、C wall 齐全 | ✅（但须按 §2.2 改名归因） |
| mixed 合计效能 | 数据齐全，叙述需按 §2.3 修正 | ⚠️ |
| 59 请求 → 生产 RL batch 外推 | §7.6 公式只能作 analytical upper bound（Evaluation-Report 3.10 同判） | ⚠️ 降格表述 |
| 统计严谨性 | n=3；t≈−100 来自近确定性 replica 计数差（方差≈0 的离散分配量），配对无依据；S2 结论跨 session | ⚠️ 报 mean±SD+95%CI+effect size，t 值降权 |

**总判定：现有数据足以严谨支撑三条结论——(1) 拓扑弹性 −21.2% makespan；
(2) 空闲 decoder 回收省 18.5% whole-run / 44.5% tail decode-GPU·s，代价
+4.6% T_batch；(3) 全场景 100% valid 的机制正确性。
不能支撑的三条——S2 的 queue-time/wall-time 收益（方向为负且触发被污染）、
migration 的性能收益（0 次触发）、真实 GPU 利用率（allocation-based）。**

## 4. 若要把缺口补上（按性价比排序）

1. **harness 加 TTFT**（stream 首 chunk 时间戳写入 requests.csv）→ 直接得到
   per-request queue+prefill 时延，S2 的 queue timing 论证才成立。半天工作量。
2. **role-aware GPU 归因**：pod sampler 按 `nvidia.com/dynamo-current-role`
   label（或 sidecar /v1/role 轮询）计数，替代 Deployment 计数；同时修
   `s2_switch_total_ms` 聚合并把 S2/S3 动作写入 events.json。
3. **修 S2 触发校准后重跑 s2_only**：T0 前冻结 S2（或探针流量不计入 queue
   指标）、PREFILL_QUEUE_THRESHOLD 恢复合理值；否则 S2 场景测的是"错误触发
   的代价"而非"正确触发的收益"。
4. **deterministic migration run**：把 C 段提前到 B 未排空时（如 +30 s）或
   强制 2+1 straggler 分布，使 `migrated>0`，并做 migration on/off A/B——
   这是让 Part 5 协议从 mechanism 证据升级为 efficacy 证据的唯一途径。
5. 同 session interleave、每场景 ≥5 repeats，报 median/CI。

## 5. 一句话结论

数字都对，故事讲错了三处：S2 的切换根本不在报告声称的阶段里发生（触发校准
缺陷，同 session 数据其实是干净的负结果）；S3 的收益来自空源释放而非迁移
（且释放先于 tail 开始）；mixed 的缩容 3/3 都执行了只是太晚。按 §2 改写后，
报告的可信度反而更高——因为三条硬结论（拓扑 −21%、回收 44.5% tail GPU·s、
100% valid）全部经得起原始日志复算。
