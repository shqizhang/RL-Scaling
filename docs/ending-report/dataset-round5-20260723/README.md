# Round-5 验收数据集(2026-07-23)

本目录是**我认为可用于最终报告的原始数据集合**,以及从中派生的聚合表。
目录由 `test-scripts/build_ending_dataset.py` 生成,可重跑刷新:

```bash
cd RL-Scaling/test-scripts && python build_ending_dataset.py \
  reports/phased-v2-20260723-084824 ../docs/ending-report/dataset-round5-20260723
```

---

## 0. 当前状态:**数据尚未完整**

`provenance.json` 里的 `complete` 字段是权威判定(要求每场景 ≥3 次重复)。

- 已收录 **8 / 15** 个 run(baseline 1、static 2、s2 2、s3 2、mixed 1);
- 套件仍在运行,预计补齐后重跑上面的命令刷新本目录;
- **已收录的 8 个 run 质量全部干净**:100% valid、0 个 HTTP 5xx、0 个超时、
  `business_wall == T_batch`(无 harness 污染)。

在补齐到 15 个 run 且 `check_suite_gates.py` 全绿之前,**不应从本目录取任何
效能数字写进报告**。质量与机制类事实(切换是否发生、耗时分解)不受此限,
因为它们不是场景间比较。

## 1. 收录规则(为什么是这一套件)

只收录**唯一一个使用完整修复栈的套件** `phased-v2-20260723-084824`:

| 构件 | 版本 |
|---|---|
| worker 镜像 | `dynamo-vllm-runtime:rl-scaling-fastswitch-a59ef248e9` |
| controller 镜像 | `rl-scaling-controller:hintretire-45ad86c` |
| dynamo commit | `a59ef248e9`(出站 KV 排空等待) |
| RL-Scaling commit | `45ad86c`(hint 及时退休 + phased v2 harness) |
| worker env | `DYNAMO_RL_CORDON_SETTLE=0.5` |

**不混用多个套件的数据。** 本轮共开跑 8 次,前 7 次每次都在部署栈不同的状态下
运行;把它们的场景拼在一起会让"对照"失去意义(2p2d 与 s2 必须在同一
session、同一镜像、同一轮内交错才可配对比较)。被排除的套件见第 5 节。

## 2. 目录结构

```
provenance.json              构建元数据:来源套件、镜像/commit、质量汇总、是否完整
workload-manifest.jsonl      96 请求的负载清单(固定种子;全场景逐字节复用)
test-design.json             场景定义与轮转顺序
progress.json                套件运行进度快照
aggregate/runs.csv           每个 run 一行:质量、T_batch、GPU·s、S2/S3 机制计数
aggregate/switches.csv       每次角色切换一行:时刻(相对 T0)、耗时、相位窗口边界
aggregate/phase_metrics.csv  每个 run × 每个相位一行:服务窗口、TTFT、分段 GPU·s
runs/<场景>/run-NN/          原始产物(未经任何加工)
    summary.json             该 run 的全部派生指标
    requests.csv             96 行,每请求:phase、TTFT、prefill 等待、worker 归属
    events.json              T0/相位派发/T_end 等事件的时间戳
    controller_status.jsonl  控制器状态采样(≈1s 间隔),含每次决策的评估与跳过原因
    pod_samples.csv          pod 角色/副本采样(GPU 占用积分的输入)
    prom_samples.json        Prometheus 采样(队列深度、KV 占用)
    logs/                    controller.log 与各 worker pod 日志
```

报告里的任何一个数字都能沿 `aggregate/*.csv` → `runs/<场景>/run-NN/summary.json`
→ `requests.csv` / `logs/` 回溯到原始记录。

## 3. 已可确认的机制事实(不依赖数据完整性)

### 3.1 双向切换全部发生,且耗时可分解

`aggregate/switches.csv` 现有 6 次切换。s2_only 的 worker 日志给出逐步分解:

| 场景 / 方向 | 总耗时 | drain+settle | register_mdc | **出站 KV 排空** | 引擎其余 |
|---|---|---|---|---|---|
| s2 r1 D→P | 1049.5 ms | 502.0 | 290.9 | **19.2** | ~237 |
| s2 r1 P→D | 964.1 ms | 501.7 | 329.6 | **10.7** | ~122 |
| s2 r2 D→P | 1135.1 ms | 600.7 | 324.9 | **17.9** | ~192 |
| s2 r2 P→D | 935.6 ms | 501.7 | 325.0 | **9.3** | ~99 |
| mixed r1 D→P | 950.5 ms | — | — | — | — |
| **mixed r1 P→D** | **9095.7 ms** | — | — | **命中 8 s 上界** | — |

> **更正(2026-07-23,由数据推翻的早期判断)**:本节初稿把 mixed run-01 的
> 9.1 s 归因于"S3 正在并发迁移 KV"。**这是错的。** 该 run 的 S3 迁移发生在
> T0+75.4 s,比 P→D 切换(T0+55.5 s)晚约 20 秒,两者不重叠。真实原因见下。

8 次切换中 **7 次落在 912–1135 ms**,1 次 9096 ms。差异的唯一变量是
**切换落点时刻对端 decoder 忙不忙**:

| mixed run | P→D 时刻 | 该时刻 decode 队列深度 | 出站排空 | 切换总耗时 |
|---|---|---|---|---|
| run-01 | T0+55.5 s | **46**(`du=0.72`,B 批刚落地打满单 decoder) | 跑满 8 s 上界 | **9096 ms** |
| run-02 | T0+43.6 s | **9**(`du=0.14`,队列刚清空) | 首轮通过 9 ms | **912 ms** |

同一份代码、同一镜像,唯一差别是落点。run-01 的切换 worker 刚以 prefill 身份为
B 段请求产出 KV,而唯一的 decoder 正深陷 46 个请求的队列,**还没排到去拉取**;
排空等待于是在等另一个 worker 的调度队列。run-02 落在队列的空档,pending 为 0,
一次轮询即通过。

结论:**零丢的代价不是常数,而是"切换落点时刻对端是否有余力拉取"的函数。**
这也解释了套件 5 为什么会挂死 34 个请求(那时根本没有这个等待)。但它同时暴露了
一个**设计缺陷**:把"等对端队列"放在了切换的关键路径上(见 §4.2)。

### 3.2 切换落点

| 场景 / 方向 | 相对 T0 | A 窗口结束 | B 窗口 |
|---|---|---|---|
| s2 r1 D→P | +2.1 s | 55.7 s | 45.0–72.6 s |
| s2 r1 P→D | +38.1 s | 55.7 s | 45.0–72.6 s |
| s2 r2 D→P | +2.9 s | 45.5 s | 45.0–67.9 s |
| s2 r2 P→D | +39.9 s | 45.5 s | 45.0–67.9 s |
| mixed r1 D→P | +2.5 s | 56.5 s | 45.0–70.1 s |
| mixed r1 P→D | +55.5 s | 56.5 s | 45.0–70.1 s |

D→P 稳定落在 T0+2~3 s,即相位边界——符合设计。

## 4. 两个必须由人判断的开放项(我不会自行绕过)

### 4.1 P→D 落在 B 段派发之前(s2_only 两次:+38.1 s、+39.9 s)

gate G3 要求 P→D 落在 `decode_dense` 窗口 `[首次派发, 最后完成]` 内,即
`[45.0, 72.6]`。实测两次都在 +38~40 s,**早于 45 s,因此 G3 会判失败**。

我的看法(供您裁决,证据在 `runs/s2_only/run-01/controller_status.jsonl`):

- 触发是**语义正确**的:进度信号在 +37 s 报告"剩余工作不再是 prompt 密集"
  (prompt 已采样完),控制器随即把 decode 容量还回去,比 B 批到达早约 7 s。
  这正是论文主张的**相位边界主动调整**,而非等队列堆积后被动响应。
- 可疑的是**窗口定义**:A 段窗口按"最后一个 A 响应完成"(+55.7 s)界定,而那个
  时刻被 KV 传输拖长,并不代表 prefill 需求还存在——44 个 prompt 在头几秒内
  就 prefill 完了。按"prefill 需求结束"来界定,+38 s 就在正确的一侧。
- 但**为了让数据通过而改 gate 是不可接受的**。要么按证据重新定义窗口并把理由
  写进报告,要么承认 G3 失败。我倾向前者,但这需要您认可。

### 4.2 mixed 的 P→D 耗时 9.1 s,超出 G4 的 5000 ms 预算

这一条**不是 gate 定义问题,是我的设计缺陷**,应当改代码而不是调预算。

等待本身是必要的(不等就是套件 5 的挂死),但**等待的位置错了**:出站 KV 排空
被放在 cordon 之后的关键路径上,于是"对端队列有多深"直接计入切换耗时。正确的
做法是把它变成**前置条件**:

- 在 cordon **之前**检查出站 pending;非零就**直接拒绝本次切换**(不改动任何
  状态),由控制器在下一拍(1 s 后)重试;
- 切换过程中保留一个**短上界**(约 2 s)作为兜底,拦截 drain 期间新出现的交接;
- 为防饥饿,连续拒绝超过若干拍后回落到当前的有界等待。

预期效果:**每次切换恒定 ~1 s**,切换时刻自动漂移到 fabric 安静的瞬间——正是
run-02 自然发生的情形——而零丢保证不变(永远不在有 pending 出站 KV 时 sleep)。
在此改动落地前,G4 的判定应按"是否有对端未完成拉取"分档报告,而不是简单放宽
预算。

## 5. 被排除的数据及原因

| 套件 | 排除原因 |
|---|---|
| `phased-v2-20260722-224207` | S2 触发链路失效,0 次切换 |
| `phased-v2-20260722-231344` | 5 次切换震荡(hint 永续) |
| `phased-v2-20260722-234217` | P→D 落在 A 窗口(队列量级不可分) |
| `phased-v2-20260723-001058` | frontend fd 耗尽自杀,44×5xx(与被测系统无关) |
| `phased-v2-20260723-003926` | P→D 打断对端 KV 拉取,34 请求超时 |
| `phased-v2-20260723-012439` | 未开跑(镜像核验失败) |
| `phased-v2-20260723-082153` | P→D 完全未触发(hint TTL 陈旧) |
| `reports/FINAL-phased-merged-20260720/` | **上一轮**数据:镜像/协议/harness 均不同(59 请求负载、settle 3.0 s、无出站 KV 排空)。报告中现存的 S3 −44.5%、S1 −21.2% 出自该数据集;本轮补齐后需重新核对是否更新。 |

这些套件的原始数据全部保留在 `test-scripts/reports/` 下未删除,可复核第 5 节的
每一条判断;诊断过程与根因见
[`docs/RESULTS-fastswitch-round5-20260723-zh.md`](../../RESULTS-fastswitch-round5-20260723-zh.md)。
