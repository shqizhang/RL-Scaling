# 最终合并数据集 — 逐方案效用与性能深度分析(2026-07-20)

> 数据集:`test-scripts/reports/FINAL-phased-merged-20260720/`(含各 run 原始日志)。
> 构成(**workload manifest 已校验:5 个来源 1 份唯一 manifest,字节一致**):
> - **同 session A(旧,phased-5scenario-165132,交错反平衡)**:`baseline_1p1d` / `static_2p2d` / `s3_only`;
> - **同 session B(新,phased-fix-213359,修复后)**:`static_2p2d(new)` / `s2_only` / `mixed`。
> 优化点:①S3 cordon settle(治 mixed 丢请求)②S2/S3 错峰。**只重跑了 S2/mixed(+ 新 session 的 static),
> 未重跑全部**,以省时。分析时**每个机制对自己 session 的 control**,并如实标注一处跨/内 session 混淆。

---

## 0. 质量门(全部通过)

| 场景 | valid% | 5xx | timeout |
|---|---|---|---|
| baseline / static / s3_only(旧) | 100.0 | 0 | 0 |
| static(新)/ **s2_only(修复)** / **mixed(修复)** | 100.0 | **0** | 0 |

**mixed 从 86.4%(24×5xx)→ 100%(0×5xx),3/3 稳定。** 修复见 §4。

---

## 1. ⚠️ 一个必须先说的测量混淆(诚实前提)

同样的 workload、同样的 config 下,`static_2p2d` 的 **A_prefill 段服务时间:旧 session 33.2s vs 新 session 23.4s,漂移 9.7s(30%)**。原因:新 session 的 static 是**在 s2/mixed 之后单独连跑的**(集群更热),不是交错反平衡。

**后果**:A/B 段的墙钟对 **session/顺序**极敏感,漂移量(~10s)≥ D→P/P→D 的效应量(~3–15s)。因此:

- **拓扑效应、S3 效用**用**旧 session 内交错反平衡**的对照 → **干净可信**;
- **S2 的 D→P/P→D 墙钟**只能用新 session 的 static(顺序混淆)→ **不可作强结论**(见 §3)。

---

## 2. ✅【干净】拓扑扩容 + S3 效用(旧 session,交错反平衡)

| 比较(配对,n=3) | 差值 | 显著性 |
|---|---|---|
| **拓扑** static vs baseline:T_batch | **−18.7s(−21.3%)** | t=−9.98 ✅ |
| **S3** s3 vs static:**C_tail 段 decode GPU·s** | **−26.1(−44.5%)** | **t=−103.9** ✅✅ |
| **S3** s3 vs static:**平均 decode GPU** | **−0.44(−22.1%)** | **t=−94.9** ✅✅ |

- **拓扑弹性扩容**:2P2D 比 1P1D 快 **21%**(makespan),稳。
- **S3 是全项目最强、最干净的效用**:分段把 S3 的 regime 隔离在 C_tail,**长尾 decode-GPU·s 省 44.5%、平均少用
  22% decode GPU**,t≈−100。**S3 的性能收益彻底坐实。**

---

## 3. 🟡 S2 的 D→P / P→D(新 session,顺序混淆,不可强结论)

| 比较(s2_only vs static_new,配对) | 差值 | 说明 |
|---|---|---|
| D→P:A_prefill 段 | +14.4s(+61.5%) | ⚠️ 顺序混淆:new-static 更热;且含 ~3.4s×切换开销 |
| P→D:B_decode 段 | +10.8s(+84.3%) | 同上 |

- **符号在两个 session 间翻转**:旧 phased suite 里 s2 的 A 段是 **−9.9%(更快)**,新 session 是 **+61.5%(更慢)**。
  漂移(9.7s)+ 切换开销(~3.4s/次)已经**盖过** D→P 本身的效应。
- **诚实结论**:**在本集群 n=3 下,D→P/P→D 的墙钟收益无法可信测量**——不是"证明了变差",而是"信噪比不足以下结论"。
  要坐实需要**全 5 场景交错反平衡 + 更多 repeats**(本轮为省时未做)。
- S2 已被稳固证明的仍是:**无损(100% valid)、亚秒~数秒级角色切换**;重负载下切换 ~3.4s(drain 长请求 + quiesce 代价)。

---

## 4. ✅ Mixed 修复:质量归零丢请求,但有 GPU 回收代价(真实权衡)

**根因**(上一轮 phased 定位):B_decode 段 S2 的 P→D 刚重建一个空 decoder,S3 立刻 idle-release,而 **cordon 撤
ModelCard 没等路由感知就删 pod** → 传播窗口内被路由的请求 500(24 个,全在 B 段)。s2_only 100% valid 反证:丢的是
**S3 release 路径**,非 S2 切换。

**修复**:①`consolidation_cordon_settle`(cordon 后 settle 1.5s 再复核+缩容,对齐 S2 的 quiesce)②S2/S3 错峰
(`STABLE_SAMPLES 1→3`)。

| mixed 指标 | 修复前(旧 phased) | **修复后(新)** |
|---|---|---|
| **valid%** | 86.4%(24×5xx) | **100.0%(0×5xx)** ✅ |
| 平均 decode GPU | 1.85 | **1.93** ⚠️ |
| `min_dec`(逐 run) | 1/1/1 | **2/2/1** ⚠️ |
| vs static(新)平均 decode GPU | — | −0.07(−3.6%,t=−5.3) |

- ✅ **24 个丢请求彻底归零,3/3 稳定** —— 组合策略现在**既能触发、又无副作用**。
- ⚠️ **代价**:错峰让 S3 更保守(3 个 run 里只有 1 个完成 2→1 缩容),**平均 decode GPU 从 1.85 回升到 1.93,GPU
  回收量减半**。这是**"正确性 vs GPU 效率"的真实权衡**,如实记录,不粉饰。
- **改进建议**:很可能**只靠 cordon settle 就足以修质量**,而 `STABLE_SAMPLES=3` 的错峰过于保守;下一步把它调回
  1–2、单靠 settle,应能同时保住"100% valid + 更多 GPU 回收"。(本轮为省时未再拆分验证。)

---

## 5. 逐方案效用与性能结论

| 方案 | 效用/性能结论 | 证据强度 |
|---|---|---|
| **S1 拓扑扩容** | ✅ 2P2D vs 1P1D:makespan **−21%** | 干净,t=−10 |
| **S2 角色切换** | ✅ **正确性+无损**(100% valid,亚秒~数秒切换);D→P/P→D 的**墙钟收益本集群 n=3 下测不动**(信噪比不足,非机制缺陷) | 质量强;墙钟不可结论 |
| **S3 请求整合** | ✅✅ **最强**:C_tail decode-GPU **−44.5%**、平均 decode GPU **−22%** | 干净,t≈−100 |
| **Mixed(S2+S3)** | ✅ 修复后 **100% valid、机制可组合无副作用**;⚠️ 错峰使 GPU 回收减半(1.93 vs 1.85),存在"质量 vs 效率"权衡 | 质量强;GPU 权衡明确 |
| **测量方法** | ✅ **business_wall==T_batch(0 污染)**;⚠️ A/B 段墙钟对 session/顺序敏感(static 漂移 9.7s),单机制墙钟归因需交错反平衡 | — |

**总判断**:本轮把三步优化都做了并**实测验证了 mixed 修复(丢请求归零)**;**S3 的效用最强最干净(−44.5% 尾段
GPU),拓扑扩容 −21% 稳**;而 **S2 的墙钟收益在此规模/方差下无法可信测量**——这是诚实的边界,不是失败。同时暴露了
**mixed 修复的 GPU 回收代价**和**分段单机制墙钟归因需要交错对照**这两个方法学要点。

---

## 6. 下一步(按数据得出的优先级,均可选)
1. **拆分验证 mixed 修复**:`CONSOLIDATION_STABLE_SAMPLES` 调回 1–2(单靠 cordon settle),看能否同时保住 100% valid + 恢复 GPU 回收(1.85 档)。
2. **若要 D→P/P→D 的可信墙钟数字**:跑一轮**全 5 场景交错反平衡 + ≥5 repeats**(消除 session/顺序漂移)。
3. RDMA:**仍不建议**(前已实测传输 2.9 GB/s,非堵点)。

## 复现
```
python test-scripts/aggregate_final_dataset.py reports/FINAL-phased-merged-20260720 \
  baseline_1p1d=reports/phased-5scenario-20260720-165132 \
  static_2p2d=reports/phased-5scenario-20260720-165132 \
  s3_only=reports/phased-5scenario-20260720-165132 \
  s2_only=reports/phased-fix-s2mixed-20260720-213359 \
  mixed=reports/phased-fix-s2mixed-20260720-213359
```
