# 快速切换轮(Round 5)测试记录与结果 — 2026-07-23

本文记录 Batch C+D(按 `docs/PLAN-metrics-and-s2s3-optimization-20260722-zh.md`)
的执行过程:部署 hold-during-switch 快速切换镜像,并重跑 5 场景 × 3 重复的
分相位套件。**过程中连续七次开跑、六次主动中止**,每一次中止都定位到一个真实
缺陷并修复。这些中止本身是本轮最有价值的产出:它们把"切换开销由什么构成"
从推测变成了逐项实测,并暴露出一个此前被慢协议掩盖的正确性缺口。

> 数据纪律不变:**任何未通过 `check_suite_gates.py` 全部硬 gate 的套件,其性能
> 数字一律不进报告。** 下文中标注"验收数据"的部分来自通过 gate 的最终套件;
> 标注"过程证据"的部分只用于说明机制与成本构成,不作为效能结论。

---

## 0. 本轮部署的构件

| 构件 | 版本 | 内容 |
|---|---|---|
| worker 镜像 | `dynamo-vllm-runtime:rl-scaling-fastswitch-a59ef248e9` | hold-during-switch 派发器、frontend_ack 观测字段、stale decode-intent 防护、出站 KV 排空等待 |
| controller 镜像 | `rl-scaling-controller:pfclear-c7725cf` | P→D 增加 "prefill 无积压" 前置条件 |
| worker 环境 | `DYNAMO_RL_CORDON_SETTLE=0.5` | 由 3.0s 压到 0.5s(零丢由 hold 窗口保底) |
| 测试驱动 | `test-scripts/run_phased_rollout_5scenario_e2e.py`(v2) | T0 相位信号、剩余工作量信号、A 段纯 prefill 探针、pre-T0 守卫 |
| 一键脚本 | `test-scripts/run-batch-cd.sh` | preflight → 双仓提交 → pyfix 薄镜像 → 部署 → 套件 → gate |

镜像构建走 `deploy/RL-Scaling/Dockerfile.pyfix` 薄覆盖(FROM 当前在跑的 worker
镜像 + 5 个纯 Python 文件),约 2 分钟,替代 ~30 分钟全量重编译。

---

## 1. 七次开跑的时间线与根因

| # | 套件目录 | 结果 | 根因 | 修复 |
|---|---|---|---|---|
| 1 | `phased-v2-20260722-224207` | 中止:**0 次切换** | prefill 队列在本模型上恒为 0;阈值 3 挡住 RL hint(=2);首个进度信号迟到 12s | `98e5554` T0 相位信号 + 阈值 2 + idle 0.05 |
| 2 | `phased-v2-20260722-231344` | 中止:**5 次切换震荡** | 全批 avg_isl 让 prefill hint 永续;A 段输出淹没 decode 队列 | `fe8bdb3` 剩余工作量信号 + A 段纯探针 + dq 阈值 8 |
| 3 | `phased-v2-20260722-234217` | 中止:P→D 落在 A 窗口 | A 段 decode in-flight(44)与 B 段真实压力(46)量级不可分 | `c7725cf` P→D 需 prefill 无积压 |
| 4 | `phased-v2-20260723-001058` | 中止:44×5xx | **与改动无关**:frontend pod 跑了 2 天,fd 耗尽自杀 | 每套 suite 前重启 frontend |
| 5 | `phased-v2-20260723-003926` | 中止:34 次超时 | **P→D 切回时对端正在拉取本机 KV,sleep 释放显存打断传输** | `a59ef248e9` 出站 KV 有界排空等待 |
| 6 | `batch-cd-20260723-012439` | 中止:镜像核验失败 | 上套结束后 worker 缩容到 0,`rollout status` 平凡通过但无 pod | `760c38f` 核验前先 scale 到 1 |
| 7 | 运行中 | — | — | — |

### 1.1 为什么前三次都卡在"触发时机"

这三次暴露的是同一个结构性事实:**在 Qwen3-0.6B 这种小模型上,prefill 侧永远
不会形成可观测的队列积压**。A 段 44 个长 prompt 齐发时,实测
`dynamo_frontend_queued_requests{role="prefill"}` 全程为 0,而 decode 侧队列冲到
44。原审计"真实 burst 会排 40+"说的是 decode 队列,被误当成了 prefill 阈值依据。

因此 D→P 的**唯一** prefill 侧信号是 RL 相位信号派生的 hint
(`ceil(batch_size/64) = ceil(96/64) = 2`)。这正是论文主张的"RL 负载的需求比例
是**事先已知**的,不必等队列堆积后被动反应"——只是此前实现里,这个信号既被
阈值挡住(3 > 2),又迟到了 12 秒(等首个请求完成才发)。

修法在语义上也更忠实于 RL:
- **信号在 T0 发出**:训练循环派发 rollout 时就知道 batch 形状,这是负载自身的
  信号,不是探针残留(pre-T0 守卫仍然拦截任何早于 T0 的切换);
- **信号内容是"剩余工作量"**:A 段采样完后剩余请求变为 decode 形态
  (avg_isl 约 573 < 1024),prefill hint 自然熄灭。这一条不改 controller 就消除了
  震荡——hint 不再永续,D→P 不会在每次 decode 瞬时空闲时重复触发。

### 1.2 第 5 次的发现:旧协议 3.4s 的"意外安全垫"

这是本轮最重要的技术发现。

第 5 次套件的控制面**完全按设计执行**:D→P 在 T0+2.4s 触发(996.8ms),
prefill hint 在 A 段采样完成后熄灭,P→D 在 T0+50.4s 触发(912.9ms)——落在
B 段窗口(始于 +45s)内。但 32 个 B 段请求 + 2 个 C 段请求挂到 600s 超时。

根因:P→D 切回的那一刻,该 worker 刚以 prefill 身份为 B 段前几个 prompt 产出的
KV **正在被对端 decoder 通过 NIXL READ 拉取**。`sleep(level=2)` 直接释放显存,
拉取中的传输被摧毁,646 个块永久 pin(worker 日志:
`Failed to reset prefix cache because some blocks (646) are not freed yet`),
对端请求永远等不到 KV。

**关键洞察:旧的 3.4s quiesce 协议之所以从未暴露这个问题,是因为它的 settle
窗口恰好盖过了典型的拉取时长——那是"意外的安全",不是设计的安全。** 把切换
提速到 1s 后,这层隐含余量消失,缺口才显形。原有的 drain 只等**本地引擎**空闲,
从不等**出站 KV 传输**完成;而 `flush_kv_connector` 的"上来就强制过期 pending
sends"顺序,对一个即将被拉取的 send 同样是破坏性的。

修法(`a59ef248e9`):在 sleep 之前插入**有界(8s)出站 KV 排空等待**——轮询
connector 的 pending-send 表(新增只读 RPC `_count_nixl_pending_sends`)并用
`reset_prefix_cache` 的返回值探测 pinned 块;只有在 8s 内无人拉取的才是真正的
孤儿,才由 flush 兜底强制过期。相位边界切换(无交接在飞)首轮轮询即通过,
成本约 0;有载切换诚实付出传输排空时间,记录在
`timings_ms.kv_outbound_drain` 里。Gate G4 预算相应从 1500ms 调到 5000ms。

### 1.3 两个与被测系统无关的基础设施问题

诚实归类,这两条不应计入方案本身的缺陷:

- **frontend fd 耗尽**(第 4 次):运行了 2 天的 frontend pod 累积 fd 泄漏,在
  T0+27s 爆发 `Too many open files (os error 24)`,停止 accept TCP →
  prefill 路由失败(`endpoint subscriber shutdown`)→ 优雅自杀,带走全部在飞
  请求。已在脚本中固化"每套 suite 前重启 frontend"。
- **控制器日志被截断**(诊断工具缺陷):`capture_logs` 用 `--tail=2600`,而
  controller 每秒约 6 行 httpx 日志,只覆盖最后约 3.5 分钟。长 run 会丢掉自己的
  切换日志行,使 gate 误判为"没有切换"。已提升到 `--tail=20000`,并让
  `check_suite_gates.py` 在日志无果时回退到采样的 controller status
  (权威记录,按首次出现的采样时刻定时,精度约 1s,远细于相位窗口)。

---

## 2. 过程证据:切换开销的逐项分解

10 次成功切换(跨第 2/3/4 次套件,worker 镜像 `fastswitch-09d5bb02c6`,
settle=0.5s)的实测分解:

| 步骤 | 平均耗时 | 占比 | 性质 |
|---|---|---|---|
| drain(排空 + settle 稳定窗口) | 501.6 ms | 53.3% | 负载相关,零丢的固有代价 |
| `register_mdc`(K8s apply 往返) | 308.7 ms | 32.8% | **物理下限**,控制面往返 |
| sleep | 58.2 ms | 6.2% | 引擎核心 |
| wake | 27.2 ms | 2.9% | 引擎核心 |
| cordon(撤 ModelCard) | 16.1 ms | 1.7% | 引擎核心 |
| flush NIXL pending sends | 6.6 ms | 0.7% | 引擎核心 |
| `reconfig_nixl` | 4.8 ms | 0.5% | 引擎核心 |
| `reset_prefix_cache` | 2.3 ms | 0.2% | 引擎核心 |
| **合计** | **941 ms**(884–1005) | | |

对照中期报告的 453ms(轻载、旧协议、无 drain/quiesce)与上一轮的 3.44–3.61s
(settle=3.0s),这组数据把"切换开销"讲清楚了:

- **引擎核心**(sleep+reset+reconfig+wake+cordon+flush)约 115 ms;
- **`register_mdc` 约 309 ms 是控制面往返的物理下限**,与中期报告的 327 ms 一致;
- **drain/settle 是可调的安全余量**:3.0s → 0.5s 使总耗时 3.4s → 0.94s,而
  100% valid 不变(零丢由 hold-during-switch 窗口保底,不再依赖长窗口)。

注:第 5 次套件之后新增的出站 KV 排空等待会让**有载 P→D** 额外付出传输排空
时间(相位边界切换仍约 0)。最终验收数据以通过 gate 的套件为准。

## 3. 过程证据:D→P 确实改善了 prefill burst 的排队时延

`report-indicator.md` 第 4 条要求"体现 Switch 完成后提升了 prefill burst 的
queue timing"。v2 harness 已把 frontend 的 `nvext.timing` 聚合进
`requests.csv`,同套件内 s2_only 与 static_2p2d 的 A 段对比:

| 套件 | 场景 | A 段 TTFT p50 | A 段 TTFT p95 |
|---|---|---|---|
| `20260722-234217` | static_2p2d | 1222 ms | 2575 ms |
| `20260722-234217` | **s2_only** | **837 ms(−31.5%)** | **1761 ms(−31.6%)** |
| `20260723-003926` | static_2p2d | 1410 ms | 2793 ms |
| `20260723-003926` | **s2_only** | **856 ms(−39.3%)** | **1724 ms(−38.3%)** |

两个独立套件的同轮对比一致,方向与幅度稳定。这是 D→P 有效性的直接证据:
把一个 decoder 改造成 prefill 后,prefill burst 的首 token 时延显著下降。

**但必须同时说明的约束**:A 段请求的**总时长**(约 33–35 s)在三个套件里几乎
不随 A 段 `max_tokens`(1 / 8–16 / 64–128)变化。TTFT 只占 0.8–1.4 s,其余
30+ s 是请求在 decode 侧等待 KV 拉取。这与已记录的结论一致:**本集群无 RDMA,
KV 传输是 A 段墙钟的支配项**。因此 D→P 改善的是**排队时延(TTFT)**这一
report-indicator 点名的指标,而不是 A 段墙钟——后者受集群传输能力封顶,
不应作为 S2 的效能主张。

---

## 4. 最终验收(待通过 gate 的套件填入)

<!-- 由 check_suite_gates.py 输出填入:G1 质量、G2 pre-T0 守卫、G3 切换落点、
     G4 切换预算、G5 S3 迁移、G6 tail fidelity、G7 release lead time、
     G8 A 段 TTFT p95(软门)。全绿后再写效能结论。 -->

_套件运行中。gate 全绿前,本节不填任何数字。_

---

## 5. 对最终报告的输入

1. **§4 切换协议**应按两层重写:引擎核心(~115 ms)+ 零丢安全外壳
   (cordon → drain/settle → **出站 KV 排空** → 核心步骤),并附第 2 节的分解表。
   原"pause before unpublish"的顺序约束需改为 cordon-first。
2. **出站 KV 排空**是新增的第四条安全约束,与"reset while asleep"同级:
   *sleep 释放显存,因此不得在对端仍在拉取本机 KV 时进入 sleep*。第 1.2 节的
   实测(646 块 pin、34 请求超时)是这条约束的实验证据。
3. **切换开销的可优化性**要如实陈述:3.4s → 0.94s 已实现;剩余部分中
   `register_mdc` ~309 ms 是控制面物理下限,drain/settle 是可调安全余量,
   出站排空是零丢的固有代价(负载相关)。
4. **S2 的效能主张**应落在 queue timing(TTFT −31%~−39%),而非 A 段墙钟;
   墙钟受无 RDMA 的 KV 传输封顶,这一点已有独立证据(第 3 节)。

## 6. 复现

```bash
cd /c/projects/IP && bash RL-Scaling/test-scripts/run-batch-cd.sh
```

幂等可重跑。中止的套件数据全部保留在
`test-scripts/reports/phased-v2-*/`,可用于复核本文的每一条根因判断。
