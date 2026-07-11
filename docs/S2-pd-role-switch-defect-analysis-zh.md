# S2 / PD Role Switch 实现缺陷分析

日期：2026-07-10

本文记录本轮 Baseline / S2 对比、S2 最小端到端验证尝试中暴露的问题。结论先行：当前 S2 Elastic PD Role Switch 不能只被理解为一个 worker 本地 `/switch_role` 成功返回的问题。它的正确性边界应该覆盖 runtime role、Dynamo discovery / router 可见性、策略之间的互斥、可观测性、失败恢复和测试清理。目前实现与这个目标之间仍有机制缺口，因此之前出现的 wall time 变大、completion TPS 下降、GPU 占用变大，以及 decode tail timeout，不能作为 S2 效能负面结论；它们首先证明 S2 完整端到端机制尚未闭合。

## 1. 我们的目标

S2 的目标不是“worker 能在数百毫秒内返回 `status=ok`”，而是：

1. 在 prefill 压力阶段，把空闲 decode GPU 临时切成 prefill capacity。
2. 在 decode 压力阶段，把此前切成 prefill 的动态 worker 稳定切回 decode。
3. 切换动作发生在 preparation window 内，进入 measured serving window 前，router 已经稳定感知新 role。
4. P->D 后至少能稳定承接长 decode 请求，不出现 timeout。
5. S2 与 S1 scale、S3 consolidation 不互相干扰。
6. 测试报告能明确证明：worker runtime role 正确、router/discovery 可见、请求无 timeout、日志无关键错误。

因此，`switch_time_ms` 只能作为 worker-side action cost；它不能代表系统已 ready，也不能代表 router 已经安全可路由。

## 2. 本轮测试暴露出的现象

### 2.1 四场景 S2 run 中 decode tail timeout

报告路径：

- `test-scripts/reports/strategy-four-scenario-20260710-active-gated-v2/s2_only/run-01/summary.json`
- `test-scripts/reports/strategy-four-scenario-20260710-active-gated-v2/s2_only/run-01/requests.csv`
- `test-scripts/reports/strategy-four-scenario-20260710-active-gated-v2/s2_only/run-01/logs/`

现象：

- S2 执行了两次：`decode->prefill` 和 `prefill->decode`。
- controller 记录的 worker-side switch latency 约为 `432ms` 和 `612ms`。
- `decode_tail` 出现 3 个 timeout，均为 `tail_long max_tokens=48`。
- 前面的短/中 decode 请求能够成功，说明不是整体服务不可用，而是 P->D 后长 decode 路径仍不稳定。

这证明：`/switch_role status=ok` 和短 readiness probe 都不足以证明 S2 完整端到端可用。

### 2.2 Pod label patch 403 是可观测性问题，不是端口 enable 问题

之前 worker 日志中出现：

```text
pod label patch returned HTTP 403
```

原因是 sidecar 在 `/switch_role` 成功后使用 worker Pod 的 ServiceAccount patch 自己的 Pod label：

```text
nvidia.com/dynamo-current-role=<target_role>
```

原 deployment 没有给 worker ServiceAccount `patch pods` 权限，因此 K8s API 返回 403。这不是 `DYNAMO_RL_SIDECAR_PORT=9091` 或端口 enable 失败；sidecar 本身可以运行，失败的是“把 runtime role 写回 Pod label”的 best-effort observability。

本轮已新增 RBAC manifest：

- `deploy/manifests/04-worker-role-label-rbac.yaml`

应用后，D->P snapshot 中 dynamic decode-origin pod 的 `current_role_label` 已成功变为 `prefill`，说明 403 已修复。但这只能修复观测标签，不能单独证明 S2 路由稳定。

### 2.3 Native prefill worker 没有 sidecar，测试和 metrics 模型之前混淆了两类 worker

最小 S2 E2E 初始 runtime role gate 失败时，decode worker 的 `/v1/role` 可以访问：

```text
VllmDecodeWorker ... sidecar_role=decode
```

但 native prefill worker 的 `9091` 不监听：

```text
failed to connect to localhost:9091 ... connection refused
```

这说明当前集群中存在两类 worker：

1. Decode-origin dual-mode worker：有 sidecar，可在 `decode` 和 `prefill` 之间切换。
2. Native prefill worker：提供 prefill capacity，但没有 sidecar，不能作为 P->D switch target。

之前测试和 controller metrics 容易把“native prefill 无 sidecar”误判成 unknown / unhealthy，或者更糟，把它当成可切换 worker。正确模型应该是：

- native prefill 可以计入 prefill capacity；
- 但不能进入 `find_most_idle_worker(..., role="prefill")` 的 P->D 切换候选；
- 只有 switch-capable dynamic worker 才能作为 S2 action target。

### 2.4 S1 scale 与 S2 最小测试互相干扰

一次最小 S2 实验中：

1. 初始 2P2D gate 成功。
2. D->P 成功，snapshot 显示 3P1D。
3. 发送 decode pressure signal 后，controller 返回 `state=warm_up`。
4. 随后 deployment 变为 1P1D，P->D gate 永远无法达到 2P2D。

根因是最小脚本仍设置了：

```text
PRE_WARM_THRESHOLD=0.80
```

这让 S1 state machine 在 S2 测试中参与拓扑调整。S2 的 P->D 验证本来需要固定 2P2D 拓扑，但 S1 scale 介入后，测试目标被改变成 1P1D。这个现象说明 controller 策略层缺少明确的 arbitration：

- S2 测试应该隔离 S1；
- 生产 controller 中 S1/S2/S3 也需要有统一 policy ordering 和互斥规则；
- 否则 S2 的 role switch 可能被 S1 scale 行为抵消或污染。

### 2.5 S2 会留下 residual runtime state，测试必须先清理

因为多次实验中断或失败，dynamic decode-origin worker 可能残留在 `prefill` role：

```json
{"component":"VllmDecodeWorker","sidecar_role":"prefill","current_role_label":"prefill"}
```

后续测试如果只按 deployment replicas 判断“2P2D ready”，会错误开始。最小脚本因此新增了 reset 逻辑：

- 扫描所有 `VllmDecodeWorker` component pod。
- 如果 sidecar role 不是 `decode`，调用 `/switch_role {"target_role":"decode"}`。
- 等待 runtime role 回到 2P2D 后再开始实验。

这暴露出 S2 机制还缺少一个生产级能力：切换动作应具备明确的 state reconciliation / recovery，而不是依赖测试脚本清理残留状态。

### 2.6 Worker 本地 role 状态与 dispatcher 可见 role 存在顺序风险

在 Dynamo worker 侧，`DualModeWorker.switch_role()` 原流程中先调用：

```python
handler.set_disaggregation_mode(target_role)
```

但 `DualModeWorker.current_role` 直到最后成功路径才更新。与此同时，`main.py` 中 role-aware generate dispatcher 读取的是 `dual_mode.current_role`。这意味着在目标 MDC / endpoint 被重新发布期间，可能存在一个短窗口：

- handler 内部 mode 已经是 target role；
- 但 dispatcher 仍认为当前 role 是 previous role；
- router/discovery 又可能已经开始观察到 target endpoint。

这种顺序不一致会放大为 P->D 后的路由不稳定，尤其是长 decode 请求更容易暴露问题。本地代码已调整为：在发布 target MDC 前同步更新 `_current_role`，失败恢复时再回滚。但该 worker 修复需要进入 Dynamo runtime 镜像后才能在集群验证。

### 2.7 Controller completion contract 太弱

之前 controller 在 `switch_role()` 返回后直接用：

```python
decision.executed = decision.result.status == "ok"
```

这意味着：

- 没有确认 `/v1/role == target_role`；
- 没有确认 worker 出现在目标 role 的 discovery / metrics 列表；
- 没有确认 router 已经完成 watch propagation；
- 没有确认一次 long decode probe 通过。

本地代码已增加 post-switch verification loop：`status=ok` 之后继续确认 sidecar role 和 worker discovery membership，失败则不计入 executed，也不启动 debounce。但这仍只覆盖 controller 可见性，不覆盖 frontend/router 的 long decode probe；后者仍应由 E2E test gate 完成。

### 2.8 Metrics collector 原来会把失败伪装成正常

原 metrics 行为存在两个风险：

1. `/v1/role` 读取失败时 fallback 到 static expected role。
2. `/v1/active_requests` 读取失败时返回 0。

这会把“sidecar 不可达 / 状态未知”伪装成“该 worker 是 expected role 且空闲”，直接影响 S2 target selection。对于 S2，这是危险的，因为 P->D target 必须是 switch-capable dynamic worker，而不能是没有 sidecar 的 native prefill。

本地代码已把这些状态改成 `unknown/unhealthy`，并增加 `switch_capable` 概念；native prefill 可作为 capacity，但不可作为 switch target。

## 3. 实现与目标之间的差异

| 目标 | 当前实现 / 原实现 | 差异 |
|---|---|---|
| S2 动作完成后系统已可服务 | worker 返回 `status=ok` 即被 controller 视为 executed | 缺少 router-visible readiness 和长 decode probe |
| P->D 后稳定承接 decode tail | P->D 后只做短 readiness / generic frontend probe | 长 decode 仍出现 timeout |
| role 可观测 | 依赖 Pod label `nvidia.com/dynamo-current-role` | 原 RBAC 不允许 patch；label 不是可靠正确性来源 |
| 区分 native worker 与 dynamic worker | 之前按 static component label 或 fallback role 计数 | native prefill 无 sidecar，不应作为 switch target |
| S2 与 S1/S3 协调 | 策略可同时影响 topology | S1 scale 可在 S2 测试中把 2P2D 缩回 1P1D |
| 失败后可恢复 | 依赖下一次脚本/人工 reset | dynamic worker 可残留在 prefill role |
| worker 内 role 一致性 | handler mode 与 dual_mode.current_role 更新时机不同 | 可能发布 target endpoint 时 dispatcher 仍按旧 role 判断 |
| metrics 可信 | 读取失败 fallback 为 expected role / 0 active | 会掩盖 unknown/unhealthy，导致错误 target selection |

## 4. 实现与实际测试预期结果之间的差异

### 4.1 预期：S2 full-batch 至少不应引入 timeout

实际：

- `decode_tail` 出现 timeout。
- timeout 集中在 tail-long 请求。
- 说明 P->D 后“能处理短请求”和“能稳定处理长 decode”不是一回事。

结论：当前 S2 E2E 不能用来证明效能提升，也不能用来证明效能下降；它是 failure-analysis-only。

### 4.2 预期：2P2D ready 后即可进入 S2

实际：

- static deployment ready 不等于 runtime role ready。
- dynamic decode-origin worker 可残留在 prefill。
- native prefill 没有 sidecar，不能用 `/v1/role` 一视同仁检查。

结论：测试必须使用 runtime role gate，并对 native prefill / dynamic worker 建模。

### 4.3 预期：P->D signal 会触发切回 decode

实际：

- 在 `PRE_WARM_THRESHOLD=0.80` 时，S1 进入 warm_up / scale 行为，干扰 S2。
- deployment 从 2P2D 变成 1P1D，导致 P->D gate 不可能满足。

结论：S2 最小正确性实验必须隔离 S1；生产 controller 必须定义 S1/S2/S3 的优先级和互斥。

### 4.4 预期：日志无错误

实际发现的日志/错误类型：

- 原先存在 Pod label patch 403，已通过 RBAC manifest 修复。
- native prefill port-forward 9091 connection refused，这是部署模型事实，不应作为 worker 错误，但测试需要识别。
- 之前 P->D 时出现 Dynamo discovery metadata 反序列化 warning，说明切换期间 discovery 状态仍可能不稳定。

结论：日志 gate 应区分 benign deployment fact 与真正错误；但 discovery metadata warning 仍应作为 S2 稳定性风险处理。

## 5. 已做的本地修复和验证边界

本轮已在本地工作区完成以下代码/配置修复：

1. `deploy/manifests/04-worker-role-label-rbac.yaml`
   - 给 worker ServiceAccount 增加 patch Pod label 权限。
   - 已在集群应用，D->P 后 label 更新成功。

2. `rl-scaling-controller/src/rl_scaling_controller/metrics_collector.py`
   - sidecar role / active 读取失败不再伪装成 expected role / 0 active。
   - 引入 `healthy` / `health_reason` / `switch_capable`。
   - native prefill 可计入 capacity，但不可作为 switch target。

3. `rl-scaling-controller/src/rl_scaling_controller/role_switch/controller.py`
   - `status=ok` 后增加 post-switch verification。
   - verification 失败则不计 executed、不更新 debounce。

4. `dynamo/components/src/dynamo/vllm/dual_mode.py`
   - 在发布 target MDC 前同步更新 `DualModeWorker._current_role`，降低 dispatcher / handler role 不一致窗口。
   - 失败恢复时回滚 `_current_role`。

5. `test-scripts/rls_strategy_common.py`
   - 增加 runtime role snapshots。
   - 增加 dynamic decode-origin worker reset。
   - 增加 native prefill 无 sidecar 的识别。

6. `test-scripts/run_s2_minimal_e2e.py`
   - 新增最小 S2 E2E 脚本。
   - 目标是只证明：D->P、P->D 后 long decode 无 timeout。

验证边界：

- 本地 `py_compile` 通过。
- `rl-scaling-controller/tests/test_role_switch.py` 通过。
- 集群应用了 RBAC，确认 label patch 403 被消除。
- 但 controller / worker 代码修复尚未进入运行镜像。本机没有 Docker，无法在当前环境构建并推送新 controller / Dynamo runtime 镜像。因此不能声明 controller verification 和 worker `_current_role` 顺序修复已经在集群 E2E 通过。

## 6. 结论

当前 S2 / PD Role Switch 的主要缺陷不是某一个 timeout 参数，而是 completion contract 不完整：

```text
worker-side switch ack
  != runtime role reconciled
  != discovery/router stable
  != long decode serving safe
  != performance-valid S2 run
```

实现距离目标还差三层闭环：

1. Worker 侧：role、handler、dispatcher、MDC/endpoint 发布顺序必须严格一致，并提供失败恢复。
2. Controller 侧：S2 action 必须经过 post-switch verification，且 target selection 必须只选择 switch-capable worker。
3. Test / protocol 侧：必须用 runtime role gate、router-visible readiness、long decode probe 和 zero-timeout gate，而不能依赖 static pod ready 或短请求成功。

因此，当前 Baseline vs S2 的 wall time / TPS / GPU 数据不能用于效能结论。下一次有效 S2 实验必须先完成镜像部署，使本地修复进入集群，然后只跑最小 S2 correctness test：

1. 固定 2P2D，禁用 S1/S3。
2. reset 所有 decode-origin dynamic worker 到 decode。
3. 触发 D->P，确认 runtime 3P1D。
4. 触发 P->D，确认 runtime 2P2D。
5. 执行一组 `max_tokens=48` 或更高的 long decode probe。
6. 要求 timeout=0、HTTP 5xx=0、关键日志错误=0。

只有这个最小正确性测试通过后，才应该重新进入 Baseline vs S2 的性能对比。
