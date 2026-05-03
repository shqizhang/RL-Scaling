# RL-Scaling 测试计划 — S1 / S2 / S3

> 配套文档：`RL_Scaling_Unified_Design.md` 与 `DEPLOYMENT_PIPELINE.md`。
> 范围：如何在已部署的集群上 *证明* 每个场景的实现是功能正确的，
> 每次运行前 / 中 / 后需要记录哪些数据，以及在 Grafana 上去哪里观察。

---

## 0. 当前集群基线

| 组件 | 命名空间 | 镜像 | 备注 |
|---|---|---|---|
| RL-Scaling Controller | `dynamo` | `ghcr.io/shqizhang/rl-scaling-controller:d5794b7` | FastAPI 监听 `:8080` |
| Frontend (KV Router) | `dynamo-system` | `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-6e4a559` | Service `vllm-v1-disagg-router-frontend:8000` |
| Prefill Worker (DGDSA, replicas=1) | `dynamo-system` | 同上 | `vllm-v1-disagg-router-vllmprefillworker-...` |
| Decode Worker (DGDSA, replicas=1) | `dynamo-system` | 同上 | `vllm-v1-disagg-router-vllmdecodeworker-...` |
| Prometheus | `monitoring` | `kube-prometheus-stack-84.1.0` | `prometheus-kube-prometheus-prometheus:9090` |
| Grafana | `monitoring` | bundled | NodePort `30030`（默认账号 admin/prom-operator） |

冒烟测试已通过：响应中包含 `prefill_worker_id` + `decode_worker_id`，TTFT ≈ 100 ms。

---

## 1. 测试目标 — 每个场景的"正确"定义

### S1 · Rollout 驱动的扩缩容
Controller **必须** 根据 RL 信号驱动 DGDSA 走完
`idle → warm_up → active → cool_down → idle`，并且 K8s 侧必须跟随：
- DGDSA `.spec.replicas` 在 `warm_up` 时增长，在 `idle` 时归 0。
- 进入 `active` 之前 Worker Pod 已 Ready。
- 回到 `idle` 后 GPU 已被释放，本地 KV indexer 已清空。

这是 **最易观察** 的场景：每一步在 K8s 层面都有可断言的不变量。

### S2 · 弹性角色切换 (P ↔ D)
Controller 通知一个 worker 切换角色。Worker 必须：
- 接受 `POST /switch_role`（worker 必须以 `--dual-mode` 启动才会注册此端点）；
- 执行编排序列 *sleep → reconfig → wake*；
- 切换完成后 handler (`get_disaggregation_mode()`) 报告新角色；
- 不丢失/不损坏在飞请求（由 `sleep(level=2)` 排空）。

⚠️ **已知 stub：** `components/src/dynamo/vllm/dual_mode.py` 中的
`_reconfig_nixl()` 和 `_reconfig_kv_pool()` 仅打印一条 warning 即返回，
对应的 Rust API 尚未实现。因此 **"切换之后 worker 真的开始以新角色服务请求"**
只能从 *逻辑层面* 观察（handler 字段 + publish event），而无法通过 vLLM 的
路由变化观察到。测试断言中会显式标注这一点。

### S3 · 请求合并 (Consolidation)
当两个 decode worker 负载不均时，controller 选择 `(source, target)` 对，
对每个请求调用 `migrate_one("*")`，并缩减 DGDSA。每个请求：
- source 调用 `RequestTracker.abort_request()`（engine 丢弃该请求）；
- target 收到 **重新提交的 prompt = `prompt_tokens + generated_tokens`**（recompute-prefill）；
- 生成继续，客户端不感知错误；
- 在 greedy + 固定 seed 下，最终输出与基线 byte-equal。

⚠️ **不发生 KV block 传输**。recompute-prefill 是有意为之的回退方案
（参见设计文档 S3 可行性说明）。**因此我们不追踪迁移过程中的具体 KV block ID
—— 没有任何 block 可以追踪**。验证方式改为：
1. 比较迁移后输出与基线输出的 hash（正确性）；
2. 确认 `frontend.dynamo_frontend_model_migration_total` 计数器递增；
3. 确认 `kvbm_*` block 层计数器在迁移窗口内 **没有** 出现 D2H/D2D 变化
   （负向断言 —— 因为我们不搬 block，这些计数器就 *不应该* 动）。

---

## 2. 需要记录什么（前 / 中 / 后）

每次运行都把产物落到带时间戳的目录
`/tmp/rls-test/<scenario>-<YYYYmmdd-HHMMSS>/`：

### 前置快照 (`pre.json`)
```bash
kubectl -n dynamo-system get dgd,dgdsa -o json
kubectl -n dynamo-system get pods -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
curl -s http://<controller>:8080/api/v1/status                          # 状态机快照
curl -s http://<frontend>:8000/metrics > pre-frontend.metrics
for w in $(kubectl -n dynamo-system get pod -l ...); do
  kubectl -n dynamo-system exec "$w" -- curl -s 127.0.0.1:9090/metrics > pre-$w.metrics
done
```

### 运行期事件日志 (`events.log`)
- 每次 controller 状态转移记一行（`kubectl logs deploy/rl-scaling-controller -f`）；
- 每次 migrate / role-flip 请求记一行（按 `[DualMode]` / `migration` 关键字过滤 worker 日志）。

### 后置快照 (`post.json`, `post-*.metrics`) — 与前置一致。

### 运行总结 (`summary.md`)
对照 §3 的每条验收标准，标注 PASS / FAIL，附上支撑该结论的指标值，以及带
`from`/`to` 参数的 Grafana panel 链接。

---

## 3. 验收标准 + 在 Grafana 上的观察方式

Grafana 入口：`http://<node>:30030`；预置仪表盘文件位于
`grafana_dashboards/`，已作为 ConfigMap 加载（`grafana-disagg-dashboard`、
`grafana-dynamo-dashboard`、`grafana-operator-dashboard`、
`grafana-planner-dashboard`）。KVBM 仪表盘 (`kvbm.json`) 也已部署，但只有当
worker 启用 `--enable-kvbm` 时才会有数据；S3 中我们用它做 **负向断言**
（recompute-prefill 期间 block 层计数器应保持平稳）。

### S1 验收矩阵

| 步骤 | 真实数据来源 | Grafana 位置 | PASS 条件 |
|---|---|---|---|
| `idle → warm_up` | controller `/api/v1/status` | curl + 日志 | POST `sampling_progress=0.85` 后 ≤ 5s 内 `state` 切换 |
| DGDSA replicas 增长 | `kubectl get dgdsa -w` | Operator 仪表盘 **DGDSA replicas** 面板（PromQL `kube_customresource_dynamographdeploymentscalingadapter_spec_replicas`，若未导出则用 kubectl） | `prefill+decode` 在进入 `active` 之前增长 |
| Worker Pod Ready | `kube_pod_status_ready{condition="true"}` | Disagg 仪表盘 **Worker pod state** | 新 Pod 达到 `Ready=1` |
| GPU 已分配 | `nvidia_gpu_num_devices` (DCGM) 或 `kube_pod_container_resource_requests{resource="nvidia_com_gpu"}` | Dynamo 仪表盘 **GPU allocation** | `Σ requested gpu` 与 replicas 匹配 |
| `active` 期间推理可用 | `dynamo_frontend_requests_total` | Dynamo 仪表盘 **Frontend RPS** | 发送压测时计数器递增 |
| KV indexer 非空 | `dynamo_component_kv_cache_events_applied{event_type="stored"}` | Disagg 仪表盘 **KV events** | 推理期间 rate > 0 |
| `cool_down → idle` | controller `/api/v1/status` | 日志 | `batch_complete` + cooldown 宽限期后切换 |
| GPU 释放 | 同 Dynamo 面板 | | 回落到基线 |
| KV indexer 排空 | `dynamo_component_kv_cache_events_applied{event_type="cleared"|"removed"}` rate = 0；若启用 KVBM，则 `kvbm_inflight_immutable` 归 0 | KVBM 仪表盘 | 回到 `idle` 后保持平稳 |

### S2 验收矩阵

S2 需要 worker 以 `--dual-mode --initial-role decode` 启动。当前部署的是普通
disagg-router prefill/decode worker，**没有** dual-mode worker。运行 S2 前
需要重新部署，或修改 DGD 中 worker 的 `command:`，详见 §5。

| 步骤 | 真实数据来源 | Grafana 位置 | PASS 条件 |
|---|---|---|---|
| Worker 报告角色 | `GET 127.0.0.1:9090/role`（**新端点**，详见 §6） | 直接 curl | 响应 `{"role":"decode"}` |
| Controller 已开启角色切换 | `GET /api/v1/status`（**新字段**，详见 §6） | curl | `role_switch_enabled=true` |
| 切换请求返回 `ok` | `POST 127.0.0.1:9090/switch_role`（已实现） | 响应体 | `status=ok`，`switch_time_ms` 非零 |
| 切换期间 worker 排空 | 日志依次出现 `[DualMode] sleep(level=2)` 和 `wake_up` | `kubectl logs` | 两行按顺序出现 |
| 新角色已落盘 | 切换后再次 `GET /role` | curl | 返回新角色 |
| 发布 `WorkerRoleChanged` 事件 | `_emit_role_changed` 日志行 | 日志 | 每次切换出现一次 |
| **Stub 提示** | NIXL/KV-pool reconfig | 日志 | 出现 warning（`stubbed; no Rust reconfig API yet`）—— 这是 *预期的*，我们只断言"stub 被走到了" |

S2 在 Grafana 上没有现成面板可以显示 `worker_type` 翻转。我们依赖
(a) controller 日志；(b) worker `/role` 端点。
（新增一个 `dynamo_worker_current_role{role=}` Gauge 是后续可做的改进。）

### S3 验收矩阵

S3 需要 decode worker 启用 `--enable-migration`，且 decode replicas ≥ 2。

| 步骤 | 真实数据来源 | Grafana 位置 | PASS 条件 |
|---|---|---|---|
| ≥ 2 个 decode replica，且都在服务 | `kubectl get dgdsa` + 每个 Pod 的 `vllm:num_requests_running` | Disagg 仪表盘 **inflight per worker** | 二者都 > 0 且不均衡 |
| 触发迁移 | controller 日志 `consolidation tick: source=...` | 日志 | 每个计划好的 pair 一行 |
| 源端请求被中止 | source 的 `vllm:num_requests_running` 跌到 0 | 仪表盘 | 阶跃下降到 0 |
| 目的端收到重发的 prompt | target 日志 `migrate_in: replay_prompt_len=…` | 日志 | length = `prompt + previously_generated` |
| **输出正确性** | 固定 seed + greedy 下，迁移后的输出与基线 byte-compare | 完成文本的 `sha256sum` | 摘要相同 |
| **未发生 KV 传输** | `kvbm_offload_blocks_d2d`、`kvbm_offload_blocks_d2h`、`kvbm_onboard_blocks_*` | KVBM 仪表盘 | 迁移窗口内计数器不增长 |
| Frontend 迁移计数器递增 | `dynamo_frontend_model_migration_total{migration_type="ongoing_request"}` | Dynamo 仪表盘 **Frontend migrations** | `Δ ≥ migrated_requests` |
| DGDSA 缩容 | `kubectl get dgdsa -w` | Operator 仪表盘 | decode replicas 递减 |
| 源 Pod 终止 | `kube_pod_status_phase{phase="Succeeded"\|"Failed"}` | Disagg 仪表盘 | source pod 消失 |

#### 关于"记录每个 KV block ID"
不适用 —— recompute-prefill 是当前选定的回退方案，不在 worker 之间搬动任何
KV block。"正确性"问题归结为：
- 目的端 engine 产生的续写，是否与"从头开始服务该请求"的输出一致？
- 客户端是否没看到任何错误 / 断连？

这正是上面第 5 项（输出正确性）和第 6 项（无 KV 传输）所验证的内容。
未来 S3-v2 切换到 NIXL D2D 真实搬 block 之后，才需要 block-id 级别的追踪
（KVBM 已经按 block 发出 `kvbm_*` 计数，但 block ID 当前不在 metric label
里，需要追加 tracing/event 日志才能逐 block 还原）。

---

## 4. 运行期间需要打开的 Grafana 仪表盘

四个并排打开：

1. **Disagg 仪表盘** (`grafana-disagg-dashboard`)：每个 worker 的 inflight、TTFT、ITL、KV-events 速率。
2. **Dynamo 仪表盘** (`grafana-dynamo-dashboard`)：frontend RPS、队列深度、迁移计数器、模型配置 gauge。
3. **Operator 仪表盘** (`grafana-operator-dashboard`)：DGD/DGDSA replica 数、scaling 事件。
4. **KVBM 仪表盘** (`kvbm.json`)：每层缓存命中率、block offload/onboard 计数器（S3 recompute-prefill 期间应保持平稳）。

时间范围设为 "Last 15 minutes"，刷新 5s。运行结束后，把面板时间范围拷贝到
`summary.md` 中归档。

---

## 5. S2/S3 运行前需要做的部署变更

S2/S3 端到端跑通之前，DGD 需要在 worker 上加上以下参数后重新 apply：

```yaml
VllmDecodeWorker:
  args:
    - --model
    - ${MODEL_NAME}
    - --disaggregation-mode
    - decode
    - --dual-mode                # 新增（用于 S2）
    - --enable-migration         # 新增（用于 S3）
  resources: { limits: { gpu: "2" } }   # S3 需要 2 个 decode replica
```

这是 *部署期* 的变更。修改 `manifests/dgd-vllm-disagg-router.yaml` 后用
`deploy-dynamo.sh --router` 重新部署（覆盖式清理已经就绪 ——
脚本会先卸载现有栈）。

---

## 6. 测试脚本现状与待修复差异

当前 `test-scripts/test-s{1,2,3}.sh` 引用了一些 controller 并未实现的 HTTP
端点。具体差异：

| 脚本 | 引用 | 状态 | 处理方式 |
|---|---|---|---|
| test-s1 | `GET /api/v1/status.role_switch_enabled` | 不存在 | S1 用不到 —— 移除 |
| test-s1 | `dynamo_kvbm_state{}` 指标 | 名字错；KVBM 用 `kvbm_*` + 每层计数器 | 改为 `dynamo_component_kv_cache_events_applied`（参见 design-docs/router-design.md） |
| test-s2 | `GET 127.0.0.1:9090/v1/role` | 未实现 | 在 worker 上加一个 `/role` GET（一行代码） |
| test-s2 | controller `GET /api/v1/events?type=...` | 未实现 | 改为抓取 controller 日志 |
| test-s2 | `POST /api/v1/debug/generate` | 未实现 | 删除 —— 走真实 frontend `/v1/completions` |
| test-s2 | `NAMESPACE=dynamo` 默认值 | 错（worker 在 `dynamo-system`） | 默认值改为 `dynamo-system` |
| test-s3 | `POST /api/v1/admin/consolidation/tick` | 未实现 | 改为 `signals/sampling_done` + 紧循环触发；或扩展 controller 暴露 admin tick（推荐） |
| test-s3 | `dynamo-component=decode` label selector | 错；实际 label 是 `nvidia.com/dynamo-component-type=worker` | 更新 selector |
| test-s3 | `--pin-worker-index` 字段挂在 `/api/v1/debug/generate` | 端点不存在 | 改用 frontend 的 `--worker-id` 扩展；或拆分独立的 decode service 来做 pin |

脚本修复 commit 的验收标准：
- 所有脚本的默认值与已部署集群一致（namespace、label selector、镜像 tag）。
- 不再引用任何 controller 不存在的端点。
- 每个脚本会在 `/tmp/rls-test/<scenario>-<ts>/` 写出 `summary.md`，按
  §3 的矩阵逐行 PASS/FAIL。

这些修改会与 §5 的 DGD 变更一并落地。

---

## 7. 运行顺序与预期产物

```bash
# S1 —— 先跑，仅验证 K8s + DGDSA 扩缩容
bash test-scripts/test-s1.sh
# 预期：5 个编号 "blue" 段全绿，"S1 PASSED"

# 然后用 --dual-mode --enable-migration 重新部署（§5）
bash deploy/RL-Scaling/deploy-dynamo.sh --router

# S2 —— 单个 dual-mode decode pod 上做角色翻转
TARGET_POD=$(kubectl -n dynamo-system get pod -l ...vllmdecodeworker -o jsonpath='{.items[0].metadata.name}')
TARGET_POD=$TARGET_POD NAMESPACE=dynamo-system bash test-scripts/test-s2.sh
# 预期：handler.disaggregation_mode 翻转，/role 报告新角色，stub log warning 出现

# S3 —— 不均衡负载 + consolidation tick
NAMESPACE=dynamo-system DGD_NAME=vllm-v1-disagg-router bash test-scripts/test-s3.sh
# 预期：source decode pod 排空 + DGDSA 缩容；输出 sha 与基线一致；kvbm_* 计数器保持平稳
```

每次运行结束，归档运行目录，并在顶层 `tutorial/scaling/test-runs.md` 账本中
追加一行（日期、镜像 SHA、场景、结果、`summary.md` 链接）。
