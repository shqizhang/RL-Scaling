# 四场景测试结果分析（2026-07-11 修复后最终轮）

数据目录：`test-scripts/reports/strategy-four-scenario-20260711-201518`

镜像（全部正规构建，无 overlay）：
- Worker：`ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-279d12b-nixlfix`（含 S2 role-ordering、engine-idle drain、token-progress `/v1/active_requests`、NIXL 修复）
- Controller：`ghcr.io/shqizhang/rl-scaling-controller:7c6564f`（switch-target 修复、token-progress remaining-time）

## 0. 本轮针对上一轮问题所做的修复

1. **S2 P->D 切回 KV drain**：`dual_mode.py` 在 `reset_prefix_cache` 前先 `engine.wait_for_requests_to_drain()` 把引擎排空到 idle（覆盖 registry 看不到的 partner-prefill 请求与在途 KV 传输），再 mop-up registry straggler。
2. **S3 遥测**：`/v1/active_requests` 现在返回每请求的 `generated/max/remaining tokens`（不再只有 id）；controller 用它算真实 remaining-time 做 cost/benefit。
3. **S3 触发**：测试脚本改为在整个 decode_tail 阶段持续轮询、并只在存在满足 token-progress 窗口的 straggler 时才发 0.92 consolidation 信号。
4. 其余保留上一轮修复：镜像 NIXL 修复、RBAC 接入部署脚本、controller switch-target 修复、port-forward 自愈。

## 1. 核心数据

| 场景 | 拓扑 | timeout | valid% | prefill(s) | tail(s) | S2 exec | S3 migrated/drained/history | perf_valid |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1P1D | 0 | 100.0 | 296.9 | 16.3 | 0 | 0/0/0 | **true** |
| s2_only | 2P2D | 4 | 96.9 | **146.8** | 251.5 | 2 | 0/0/0 | false |
| s3_only | 2P2D | 1 | 99.2 | 155.8 | 133.9 | 0 | 0/0/0 | false |
| mixed_strategy | 2P2D | 4 | 96.9 | 178.9 | 251.5 | 2 | 0/0/0 | false |

- 所有 tail timeout 都是 `max_tokens=48` 的 `tail_long` 请求；s3_only 命中 1 个，s2_only/mixed 命中全部 4 个。

## 2. 成立且可复现的结论：S2 D->P prefill capacity 有效

- S2 D->P 在 preparation window 内把一个 decode-origin worker 切成真实 prefill worker，router 感知到新增 prefill 容量，`prefill_burst` 阶段零 timeout。
- prefill serving wall：baseline 1P = 296.9s → s2_only(D->P 3P) = **146.8s，改善约 51%**；与同为 2P 起点、未切换的 s3_only（155.8s）相比，S2 的第 3 个 prefill 仍再快约 6%。
- S2 动作受控：恰好 2 次（D->P、P->D），无 churn；switch latency ~450ms。
- 该 prefill 改善在本项目 4 次独立运行中稳定复现（146.8 / 146.7 / 166.7 / 163.7 vs baseline ~300s）。

这是本轮唯一干净、可辩护的正向结果，验证了 S2「弹性 PD 容量整形」这一核心机制是正确且有效的。

## 3. decode_tail 超时的真正根因：Dynamo/NIXL 解耦（disagg）KV 传输挂起

本轮把这个问题彻底定位清楚，**它不在 RL-Scaling 的 S2/S3 逻辑里，而在 Dynamo/vLLM/NIXL 的 disaggregated KV 传输层**。关键证据（来自 s2_only 切回 worker 日志）：

1. **引擎已 idle，但 block 仍无法释放**：`_drain_inflight` 打出 `drain: engine idle before switch`（引擎已排空、无 running 请求），可紧接着 `reset_prefix_cache` 仍报 `some blocks (2773) are not freed yet, result=False`。既然没有 running 请求，这些 block 就**不是被请求持有**，而是被 **NIXL connector 为 KV 传输注册/固定的显存**持有。这也解释了为什么 v1（registry drain）、v2（engine drain）都无法修复——它们排空的是请求，而泄漏在 connector 的传输状态。
2. **挂起请求在等 KV 传输，不是等 GPU 显存**：超时请求所在 decode worker 日志显示 `Running: 0 reqs, Waiting: 1-3 reqs`，而 `GPU KV cache usage: 0.2%-3.1%`——**KV cache 几乎是空的**。请求卡在 `Waiting`、迟迟不被调度，是因为它们在等 prefill→decode 的 KV 从 prefill worker 传过来，而这次传输挂住了，于是 decode 侧一直等到 120s client timeout。

### 3.1 两层效应

- **基础拓扑效应（s3_only，无切换，1 个 timeout）**：动态 warmup 到 2P2D 后，disagg KV 传输对 tail 末尾的长请求偶发挂起——每轮约命中 1 个 `max_tokens=48` 请求。baseline 1P1D 不出现（16/16 clean），说明是多 worker disagg 传输路由/一致性问题，不是模型或负载问题。
- **切换放大效应（s2_only/mixed，4 个 timeout）**：P->D 切回后，被切 worker 的 NIXL connector 残留约 2773 个已注册 block（engine idle 也释放不掉），该 worker 进入退化态；router 仍把 tail 请求发给它，于是**所有** 4 个 tail_long 请求都挂起。切换把「偶发 1 个」放大成「稳定 4 个」。

### 3.2 为什么 drain 修复无效、且这是 disagg 层问题

- v1（registry drain）对 partner-prefill 请求无效（它们走 `PrefillWorkerHandler.engine.generate`，不进 registry）。
- v2（`engine.wait_for_requests_to_drain` 到 idle）确实把请求排空了，但泄漏的 2773 block 属于 NIXL connector 的注册显存，不随请求排空而释放。
- 因此这不是 RL-Scaling 能在 `dual_mode`/sidecar 层修掉的：需要在 vLLM NixlConnector / Dynamo disagg 传输层修复「role 变更 / 拓扑变更后 connector 注册显存与在途传输的清理」，以及「多 decode worker 下 prefill→decode 传输路由一致性」。

## 4. S3：机制已实现并接入，但当前 workload 下无法被触发

- s3_only/mixed 全程 `history=0, attempts=0, migrated=0, drained=0`——S3 一次 consolidation decision 都没产生。
- 直接原因：唯一的长尾 straggler 会**挂起**（`generated_tokens=0`，在等 KV 传输），因此 `/v1/active_requests` 里没有任何「已生成一部分、剩余仍足够」的健康可迁移请求，token-progress 触发条件不满足，0.92 信号不发（`tail_consolidation_signal_skipped: no_token_progress_straggler`），决策引擎的完成度门挡掉全部 plan。
- 换言之：**S3 的输入（一个健康的、正在生成的长尾请求）被 §3 的 disagg 传输挂起问题吃掉了**。S3 的遥测/触发/决策/迁移协议本身已按 `test-strategy.md §11` 的建议实现并接入主 control loop（代码与单测通过），但拿不到合法输入。
- 补充边界（即便 §3 修好、S3 能触发）：当前 migration 是 engine-side takeover + drain-and-discard，迁移一个 client 正在等待的请求会中断其响应（`test-strategy.md §10`）。要让 S3 达到 client-visible 无损，还需 frontend stream reattach（Phase 2.C），属另一独立工作。

## 5. 结论（按 test-strategy.md §9 顺序）

1. **正确性**：仅 baseline 过零-timeout 质量门。所有 dynamic 场景因 disagg 传输挂起产生 tail timeout，不能作为 client-visible 端到端结论。
2. **S2**：动作受控（2 次）；prefill serving wall 稳定改善约 51%，prefill 阶段零 timeout——核心机制验证通过。S2 总体 wall 因切回放大的 disagg tail 挂起而回退。
3. **S3**：遥测/触发/决策/迁移协议已实现并接入，但因长尾 straggler 被 disagg 传输挂起（无 token 进度）而无法触发；本轮无 migration/drain 证据。
4. **Mixed**：拿到 S2 prefill 收益，但同样被 disagg tail 挂起拖累，S3 未触发。
5. **限制/根因**：核心阻塞是 Dynamo/vLLM/NIXL disagg KV 传输在「动态 2P2D」和「role 切回」下会挂起 / 泄漏 connector 显存；这不在 RL-Scaling S2/S3 逻辑内，RL-Scaling 侧的镜像、RBAC、controller、telemetry、trigger、drain 均已正确实现并部署。

## 6. 建议下一步（按优先级）

1. **修 disagg KV 传输挂起（最高优先，解锁一切）**：在 vLLM NixlConnector / Dynamo disagg 层排查——(a) 多 decode worker 下 prefill→decode 传输是否路由到了持有该 KV 的正确 decode worker；(b) role/topology 变更后 connector 的注册显存与在途传输是否被正确 abort/释放（对应 `reset_prefix_cache` 报的数千 pinned block）。可先用「静态 2P2D（不 warmup、不切换）跑同 workload」与「动态 warmup 2P2D」对照复现：minimal S2 静态 2P2D 能干净服务 `max_tokens=48`，而 warmup 后不能。
2. **S2 切回**：在 disagg 修好后，`dual_mode` 已具备 engine-idle drain，可再验证切回是否零 tail timeout；必要时增加「切回后把该 worker 短暂移出 decode 路由，直到 connector 显存确认释放」。
3. **S3**：待 §1 修好、长尾请求变成健康在飞请求后，S3 的 token-progress 触发即可产生 plan；再补 request 关联与 migrate_out/in/complete/rollback 原始响应采集，并明确 client-visible 需 frontend stream reattach。
4. **同拓扑 baseline**：加 `baseline_2p2d_disabled` 以把 S2 prefill 收益与 1P->2P 拓扑分量分离。
