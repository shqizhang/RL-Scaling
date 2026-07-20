# 分段(shaped-arrival)性能测试 — 实测结果与逐段深度分析(2026-07-20)

> 目的:用**分段到达、无 gate、逐段测服务时间**的负载,让 D→P / P→D / S3 各自在自己的 regime 里显效,
> 并逐段归因。方案融合了 Codex 的 `PLAN-phased-performance-optimization-and-rdma-validation` 的口径
> (时间账、逐段归因、固定对照规则)与本项目的实测分析。**本轮是完整执行**(实现→校准→跑 5×3→分析),
> 不是纸面方案。套件:`test-scripts/reports/phased-5scenario-20260720-165132/`(15/15,无 abort)。

---

## 0. 方法与关键设计验证

- **负载**:59 请求,3 段靠**请求到达时间**分开(offset 0/22/40s,**不是 gate**):
  - **A_prefill**(32 条,~1200 词长 prompt,短输出)→ 造 prefill 压力、decode 空闲 → **D→P**;
  - **B_decode**(24 条,中 prompt,1200 输出)→ 造 decode 压力、prefill 空闲 → **P→D**;
  - **C_tail**(3 条 ignore_eos,6000 token)→ 长尾 → **S3**。
- 镜像:worker `s2quiesce-1`(切换无损)+ controller `idlerelease-1`(mixed 空闲释放),operator=0。
- 场景:5 个,等拓扑对照 `static_2p2d`,反平衡顺序,3 repeats。
- **关键验证:`business_wall == T_batch`,overhead = 0.00s**(全 15 run)→ **分段但无 gate,墙钟完全等于业务窗口,不再有旧测试那 ~90s 的 harness 污染。** 这条 Codex 提出的原则被实测证实成立。

## 1. 质量门

| 场景 | valid% | timeout | 5xx | T_batch |
|---|---|---|---|---|
| baseline_1p1d | 100.0 | 0 | 0 | 88.1s |
| static_2p2d | 100.0 | 0 | 0 | 69.4s |
| s2_only | **100.0** | 0 | 0 | 72.6s |
| s3_only | 100.0 | 0 | 0 | 72.6s |
| **mixed** | **86.4** | 0 | **24** | 72.8s |

- s2_only **100% valid**(6/6 切换,quiesce 生效)。
- **mixed 86.4%(24×5xx,全部在 B_decode 段)**——见 §5,是一个**新暴露的真实交互 bug**,如实记录。

## 2. 逐段服务时间(核心归因表)

| 场景 | A_prefill | B_decode | C_tail | T_batch |
|---|---:|---:|---:|---:|
| baseline_1p1d | 49.0 | 43.1 | 48.1 | 88.1 |
| **static_2p2d(对照)** | **33.2** | **17.4** | **29.4** | 69.4 |
| s2_only | **29.9** | 18.9 | 32.6 | 72.6 |
| s3_only | 24.2 | 12.3 | 32.6 | 72.6 |
| mixed | 35.1 | 18.1 | 32.8 | 72.8 |

## 3. D→P(看 A_prefill 段)——**方向首次转正**

| 指标(s2_only vs static,配对,n=3) | 差值 | 显著性 |
|---|---|---|
| A_prefill 段服务时间 | **−3.3s(−9.9%)** | t=−0.39,n.s. |
| 机制 | D→P 触发确认:`prefill_queue=2≥1 且 decode_util=0.00≤0.30` → 3P1D,随后 P→D 回切 | 6/6 |

- **关键进展**:在**扁平负载**里 S2 相对对照是 **+12%(更慢)**;换成**分段(prefill-heavy 的 A 段)**后,
  A_prefill 段变成 **−9.9%(更快)**——**D→P 的收益方向第一次被显现出来**,印证了"S2 效能被负载结构遮住、
  不是机制/传输问题"的判断。
- **诚实边界**:n=3 方差大,t=−0.39 **未达显著**;要坐实需更多 repeats。
- **一个代价**:分段重负载下每次切换 **~3.4s**(扁平时 ~0.97s)——因为切换前要 drain 掉在飞的长请求 +
  quiesce 静默确认。正确但更慢;是"无损"的代价。

## 4. P→D(看 B_decode 段)——**未显现**

| 指标(s2_only vs static) | 差值 | 显著性 |
|---|---|---|
| B_decode 段服务时间 | **+1.5s(+8.4%)** | t=+0.37,n.s. |

- P→D 有触发(`decode_queue=3≥2 且 prefill idle`),但 B 段服务时间**没有改善、略微变差**。
- 可能原因:B 段的 decode 压力还不足以让"多加一个 decoder"净赚,且 P→D 的 ~3.4s 切换开销把收益吃掉。
  **这是需要继续优化的点**(调 B 段负载强度 / 降低切换开销 / P→D 提前触发)。

## 5. S3(看 C_tail 段)——**全项目最强、最干净的结果**

| 指标(s3_only vs static,配对,n=3) | 差值 | 显著性 |
|---|---|---|
| **C_tail 段 decode GPU·s** | **−26.1(−44.5%)** | **t=−103.9 极显著** |
| **平均 decode GPU(整轮)** | **−0.44(−22.1%)** | **t=−94.9 极显著** |
| 迁移→缩容 | drained + `min_dec` 2→1(6 次) | 3/3 run |

- **分段把 S3 的 regime 完全隔离(C_tail 段),效应量级和显著性都是全项目最高**:长尾阶段 decode-GPU·s
  直接省 **44.5%**,平均少用 **22%** decode GPU,t≈−100。这比连续负载(−26%)更干净——因为 C 段没有
  其它机制/负载干扰。**S3 的效能在此彻底坐实。**

## 6. Mixed(S2+S3 组合)——机制都触发,但暴露一个真实 bug

| 指标(mixed vs static) | 差值 | 说明 |
|---|---|---|
| valid% | **86.4%(24×5xx)** | ⚠️ **B_decode 段丢请求** |
| 平均 decode GPU | −0.10(−4.8%,t=−4.6) | S3 触发、缩容 2→1 |
| T_batch | +3.5s(+5.0%,t=+22) | S2 churn 略拉长 |
| 机制 | S2 6 切换 + S3 缩容 2→1(6 drained) | 都发生 |

**根因(从 mixed/run-01 controller 日志定位)**:B_decode 段里 S2 的 **P→D 回切**(3P1D→2P2D)刚发生,
S3 立刻对新出现的空 decoder 做 **idle-release**:`cordon 撤 ModelCard → scale 2→1`(相隔 ~5s)。
**S3 的 cordon 没有 S2 那套 quiesce 静默握手**,所以在 cordon 传播的瞬间被路由到该 decoder 的请求被打 500。

- 对照证据:**s2_only 100% valid(P→D 切换本身安全,quiesce 生效);mixed 才丢**——所以丢的是 **S3 的
  release 路径**,不是 S2 的切换。
- **修法**(下一步):把 S2 已用的 **quiesce/settle 握手也加到 S3 cordon-before-release**;或在 B_decode
  的 P→D 窗口内**抑制 S3**(S2/S3 错峰,正是 Codex P1 建议)。

## 7. 阶段性结论

| 机制 | 分段实测结论 |
|---|---|
| **拓扑扩容** | ✅ 2P2D vs 1P1D:T_batch 88.1→69.4s(**−21%**),稳。 |
| **D→P** | 🟡 **方向首次转正**:A_prefill 段 **−9.9%**(扁平时是 +12%);n=3 未显著,需更多 repeats。~3.4s 切换代价。 |
| **P→D** | ❌ 未显现(B 段 +8%,n.s.):需调 B 段强度 / 降切换开销 / 提前回切。 |
| **S3** | ✅✅ **最强**:C_tail decode-GPU **−44.5%**、平均 decode GPU **−22%**,t≈−100,极显著。 |
| **Mixed** | ⚠️ 机制都触发,但 **S3 release cordon 无 quiesce → B 段丢 24 请求**;需给 S3 cordon 加静默握手或 S2/S3 错峰。 |
| **测量口径** | ✅ **business_wall==T_batch(0 污染)**:分段无 gate 设计成立(Codex 原则实测证实)。 |

**总判断**:分段设计达到了目的——**隔离出每个机制的 regime、零 harness 污染、让 D→P 的收益方向首次显现、
给出全项目最干净的 S3 结果**;同时诚实暴露了两个待办:P→D 尚未显效、mixed 的 S3-cordon 丢请求。**下一步
最高优先级是给 S3 cordon 加 quiesce 握手(治 mixed 质量)+ S2/S3 错峰**,再补 repeats 让 D→P 达到显著。

## 8. 与连续(flat)测试对照

| | 连续(163501/204503) | 分段(本轮) |
|---|---|---|
| D→P 方向 | +12%(被长尾淹没,方向错) | **−9.9%(方向对)** |
| S3 decode-GPU | −26%(全窗口) | **−44.5%(C 段隔离,更强)** |
| 归因 | 只有总 makespan,机制混叠 | **逐段可归因** |
| 污染 | 无(已去 gate) | 无(business_wall==T_batch 实证) |
| mixed | +26% churn | +5% + 暴露 S3-cordon 丢请求 bug |

## 9. 复现
```
python test-scripts/run_rollout_batch_e2e.py --workload phased --repeats 3 \
  --suite-dir reports/phased-5scenario-20260720-165132   # 复跑
# 分段数据在各 run 的 summary.json 的 phase_metrics 字段
```
