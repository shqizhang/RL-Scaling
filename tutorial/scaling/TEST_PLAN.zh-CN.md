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
Sidecar 通知 worker 切换角色。Worker 必须：
- 接受 Pod 内 sidecar（端口 9091）上的 `POST /switch_role`；
- 执行编排序列 *sleep → reconfig → wake*；
- 从 discovery WorkerSet 中移除 / 重新加入；
- 不丢失/不损坏在飞请求（切换前排空）。

E2E 测试（`test-s2-elastic.sh`）通过 per-pod Prometheus 指标验证
WorkerSet 的收缩/扩展和路由归属。实际的 NIXL/KV 重配置步骤仍为 stub，
等待上游 Rust 补丁——测试验证的是编排逻辑，而非 GPU 层面的内存布局。

### S3 · 请求合并 (Consolidation)
当两个 decode worker 负载不均时，sidecar 的协调式 `POST /migrate` 端点将在飞
请求从源端（D1）迁移到目标端（D2）。每个请求：
- D1 `migrate_out`：快照 prompt + 已生成 token，hold blocks（延迟 abort）；
- D1 内部调用 D2 的 `POST /migrate_in`，携带状态快照；
- D2 `migrate_in`：成本收益检查（`max_replay_tokens=8192`），recompute-prefill；
- 成功时：D1 `migration_complete` abort 已 hold 的请求并释放 block；
- 失败时：D1 `migration_rollback` 释放 hold，请求继续在 D1 上运行。

E2E 测试（`test-s3-consolidation.sh`）通过以下方式证明 per-request KV 一致性：
1. 每次迁移前后记录 D1/D2 的 active request ID 列表；
2. 验证 `left_D1=true`（ID 从 D1 registry 消失）和 `D2_accepted=true`
   （通过 `/migrate` 响应的 `path=recompute`）；
3. 验证 drain 后 D2 的 `generation_tokens_total` 增长；
4. 用超大合成 `migrate_in` 测试成本收益门控。

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

S2 需要 dual-mode decode Pod（`DYNAMO_RL_DUAL_MODE=1`，`DYNAMO_RL_SIDECAR_PORT=9091`）。

| 步骤 | 真实数据来源 | 观察位置 | PASS 条件 |
|---|---|---|---|
| 发现 Pod | `kubectl get pod` + readiness 过滤 | 测试脚本输出 | ≥2 decode pod Ready |
| 基线指标 | 每个 Pod 的 `GET :9090/metrics` | `T0_baseline` | `generation_tokens_total` 已采集 |
| 角色翻转 D→P | `POST :9091/switch_role {"target_role":"prefill"}` | sidecar 响应 | `status=ok`，`switch_time_ms` 非零 |
| WorkerSet 缩小 | Discovery CR diff | 测试脚本 | D1 从 CR 中移除 |
| D1 不再接收流量 | D1 的 `vllm:num_requests_running` | 指标 | 降到 0 |
| 角色翻转 P→D | `POST :9091/switch_role {"target_role":"decode"}` | sidecar 响应 | `status=ok` |
| WorkerSet 扩大 | Discovery CR diff | 测试脚本 | D1 重新加入 CR |
| D1 再次接收流量 | D1 的 `generation_tokens_total` | 指标 | 重新加入后 delta > 0 |
| 无 HTTP 错误 | 所有 streaming 请求 | 测试脚本 | `HTTP_ERRORS == 0` |

### S3 验收矩阵

S3 需要 dual-mode decode Pod 并设置 `DYNAMO_RL_CONNECTOR_ENABLED=1`，decode replicas ≥ 2。

| 步骤 | 真实数据来源 | 观察位置 | PASS 条件 |
|---|---|---|---|
| ≥ 2 个 decode replica，都在服务 | `kubectl get pod` + `vllm:num_requests_running` | 测试脚本 | 负载后两者都 > 0 |
| 迁移前 ID 快照 | D1、D2 的 `GET :9091/v1/active_requests` | 测试脚本 | ID 列表已采集 |
| 触发迁移 | D1 的 `POST :9091/migrate {target_url=D2}` | sidecar 响应 | `status=ok` |
| 请求离开 D1 | D1 迁移前后 `active_requests` 对比 | 测试脚本 | `left_D1=true` |
| D2 已接受 | `/migrate` 响应中 `path=recompute\|connector` | 测试脚本 | `D2_accepted=true` |
| Token 状态保存 | `/migrate` 响应中 `generated_token_count`、`replay_tokens` | 测试报告 | replay = prompt + generated |
| D1 活跃请求减少 | `vllm:num_requests_running` T1→T2 | 指标 | D1 计数下降 |
| D2 生成 token 增长 | `vllm:generation_tokens_total` T1→T3 | 指标 | Δ > 0 |
| 成本收益门控 | 合成超大 `migrate_in`（9000 tokens） | sidecar 响应 | `status=declined` |
| Block hold 时间 | D1 worker 日志：`hold` → `releasing` | `kubectl logs` | hold 持续 < 50ms |

#### 关于"记录每个 KV block ID"
Recompute-prefill 是默认路径。Worker 之间不传输 KV block——D2 重新 prefill
完整的 prompt+generated 序列。"正确性"问题由以下证据回答：
- `left_D1=true`（D1 释放了该请求），
- `D2_accepted=true`（D2 接受并开始解码），
- D2 `generation_tokens_total` 增长（D2 确实在生成 token），
- hold 时间很短（block 仅在 out→in→complete 握手期间被 hold）。

未来的 NIXL D2D 阶段需要 block-id 级别的追踪（KVBM 按 block 发出 `kvbm_*`）。

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

## 5. 运行前准备：部署 dual-mode decode

S2/S3 端到端跑通之前，decode Pod 需要运行 dual-mode 补丁：

```bash
# 在 decode worker 上 apply dual-mode 环境变量 + kv-transfer 配置
IMAGE=ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha> \
  ./test-scripts/apply-dual-mode-decode.sh
```

Decode Pod 需要的环境变量：
- `DYNAMO_RL_DUAL_MODE=1`
- `DYNAMO_RL_SIDECAR_PORT=9091`
- `DYNAMO_RL_CONNECTOR_ENABLED=1`（S3 NIXL 路径，无 block 元数据时回退到 recompute）
- `DYN_SYSTEM_PORT=9090`

验证：
```bash
kubectl -n dynamo-system get pod -l nvidia.com/dynamo-graph-deployment-name=vllm-v1-disagg-router -o wide
# 期望：≥2 个 decode pod Ready，1 个 prefill pod，1 个 frontend
```

---

## 6. 运行顺序与预期产物

```bash
# S2 —— dual-mode decode pod 上做角色翻转
cd test-scripts && bash test-s2-elastic.sh
# 预期：D→P→D 翻转，所有请求 HTTP 200，WorkerSet 收缩/扩展确认

# S3 —— 协调式迁移 + per-request 跟踪
cd test-scripts && bash test-s3-consolidation.sh
# 预期：6/6 MIG_OK，OVERALL=true，REPORT.md 生成在 reports/ 下
```

每次运行后，测试会在 `test-scripts/reports/` 下生成带时间戳的报告，
包含完整证据（ID 列表、per-migration 表格、worker 日志、pass/fail 判定）。

---

# Phase 2 测试计划 — 端到端最优实现 (v3 · fact-corrected)

> 配套设计文档：`RL_Scaling_Unified_Design.md` 中的 **Phase 2** 章节
> (P2.0–P2.5, v3) + `dynamo/RL_SCALING_PYTHON_CHANGES.md`。
>
> v3.5 修正：Phase 2 **不需 Rust 改动 · 不需自写 KVConnector**，按两档交付：
>   - **Phase-2.A** (已交付 · 零风险)：smart recompute-prefill，靠
>     `MigrationPolicy` 带 cost-benefit 闸門 + prefix-cache 命中将迁移代价
>     压到 ~30 ms；`migrate_out` 额外变为携 `src_block_ids` (复用现有
>     `KvbmCacheManager.get_block_ids` PyO3 API)为 Phase-2.B 预留接口。
>   - **Phase-2.B** (协议层已交付 · feature flag 默认关 · 待 GPU 验证)：
>     **复用 vLLM 0.16 自带 `NixlConnector`**；migrate_out 响应携
>     `kv_transfer_params` 字段（vLLM 0.16 schema：`do_remote_prefill`,
>     `remote_engine_id`, `remote_block_ids`, `remote_host`, `remote_port`,
>     `remote_request_id`），migrate_in 把字典注入到
>     `sampling_params.extra_args["kv_transfer_params"]`，由 vLLM
>     `NixlConnectorScheduler.add_new_req_to_recv` 自动处理 → worker
>     `start_load_kv` 中 `_read_blocks` 发起 NIXL READ。
>     `MigrationHandler.connector_enabled=False` 是默认安全闸门，因为源端
>     `abort_request` 当前不延迟释放 block——必须先实现 src-side
>     block-hold (类比 disagg-PD `request_finished -> (True, None)` +
>     `get_finished` 模式) 才可在生产打开。
>
> Phase 1 脚本中那些 "stub 是预期" 的断言在 Phase 2 中被取反，新增
> Phase-2.A 新路径的实际事实验证。

## P2.0 适用前提

**Phase-2.A** 在现有镜像 `dynamo-vllm-runtime:rl-scaling-6e4a559+` 上可运行，
无额外启动参数。与 Phase 1 同一套部署。

**Phase-2.B** 需要：
- worker 启动参数包含 `--kv-transfer-config` 把 `[DynamoConnector,
  NixlConnector]` 串成 `MultiConnector` (即当前 dynamo PD-disagg 配置；不需要
  额外 connector)
- `MigrationHandler` 启动时 `connector_enabled=True` 且 `nixl_meta_provider`
  非空（由 `main.py` 从 `engine.vllm_config.kv_transfer_config.engine_id` /
  `nixl_side_channel_host` / `nixl_side_channel_port` 抽出）
- decode replicas ≥ 2
- **block-hold 机制已实现并 GPU 验证通过**（`MigrationHandler` 不再立即
  `abort_request`，改为 `mark_for_migration`；源端 connector 在 NIXL
  send-completion notification 后才释放 block）

如果 Phase-2.B 任一前提不具备，跳过 §P2.2.B、以 §P2.2.A 为主验收。

## P2.1 S2-v2 验收（真实角色翻转 · 全 Python）

| 步骤 | 真实数据来源 | Grafana / PromQL | PASS 条件 |
|---|---|---|---|
| 翻转后旧角色池实时排空 | `dynamo_frontend_requests_total{worker_id=W,role="<old>"}` | Dynamo *Frontend per-worker RPS* | 翻转后 5s 内增量 = 0 |
| 翻转后新角色池接入 | `dynamo_frontend_requests_total{worker_id=W,role="<new>"}` | 同上 | 翻转后 30s 内有非零增量 |
| `reset_prefix_cache` 被调用 | worker 日志 `[DualMode] reset_prefix_cache invoked` | `kubectl logs` | 每次翻转 +1 |
| NIXL connector handle 被丢弃 | worker 日志 `[DualMode] dropped cached NIXL connector` | `kubectl logs` | 每次翻转 +1 |
| `update_metadata` 被推送到 generate endpoint | worker 日志 `[DualMode] update_metadata pushed disaggregation_mode` | `kubectl logs` | 每次翻转 +1 |
| Phase 1 stub 标记不应出现 | worker 日志 | `kubectl logs` | **不应**有 `stubbed; no Rust reconfig API` |

**回归断言**：把 `test-scripts/test-s2.sh` 中
```
if grep -qiE 'stubbed; no Rust reconfig API' "${RUN_DIR}/worker-flip.log"; then
  green "  NIXL/KV-pool stubs reached as expected"
fi
```
改为
```
if grep -qiE 'stubbed; no Rust reconfig API' "${RUN_DIR}/worker-flip.log"; then
  fail "Phase 2 regression: stub message present, real reconfig not wired"
fi
```

## P2.2.A S3-v2.A 验收（smart recompute-prefill · 已交付 · 零风险）

| 步骤 | 真实数据来源 | PASS 条件 |
|---|---|---|
| `MigrationPolicy` decline 路径生效 | controller 日志 `migrate_in declined for X: <reason>` | 对 too-young/too-old/too-large 请求返回 `status:declined` |
| `MigrationPolicy` accept 路径生效 | migrate_in 响应为 `{status:ok, path:"recompute", replay_tokens:N}` | `replay_tokens == prompt+gen` |
| `migrate_out` 响应携 `src_block_ids` (需 KvbmCacheManager) | migrate_out 响应 JSON | 如启用 KVBM，`src_block_ids` 为非空列表；否则字段缺省 |
| Prefix cache 命中节省 prefill 时间 | dst worker `vllm:gpu_prefix_cache_hit_rate` | 权重 ≥ 0.9 在迁移连发场景下 |
| 迁移后单请求总时间 (recompute prefix-hit) | controller 日志 · prometheus | 在启用 prefix cache 的 7B 模型上 p95 ≤ 50 ms (vs Phase 1 ≈100 ms) |
| MigrationHandler prefix-cache 警告 | worker 启动日志 | 如 enable_prefix_caching=False 必须出现警告 |

**脚本增强**：`test-scripts/test-s3.sh` 现已发送足够老的请求以示 too-young decline 路径；需新增一轮发送中等老的请求验证 accept 路径 + `replay_tokens` 返回与 prefix-hit-rate 上升。

## P2.2.B S3-v2.B 验收（vLLM-native KV-D2D · 待 GPU 验证）

| 步骤 | 真实数据来源 | PASS 条件 |
|---|---|---|
| `MigrationHandler` 以 `connector_enabled=True` 启动 | worker 启动日志 / Python 内省 | `MigrationHandler._connector_enabled is True` |
| `nixl_meta_provider` 返回正确坐标 | worker 启动日志（一次性回显 engine_id/host/port） | host 可 ping 通，port 在 NixlConnector 监听端口范围内 |
| `migrate_out` 响应携 `kv_transfer_params` | controller 接收到的 JSON | 必含 `do_remote_prefill=true`, `remote_engine_id`, `remote_block_ids`(非空), `remote_host`, `remote_port`, `remote_request_id` 全部字段 |
| `migrate_in` 走 connector 路径 | migrate_in 响应 `{status:ok, path:"connector"}` | path 字段 = `connector` |
| dst worker 把 kv_transfer_params 装进 sampling_params | dst worker debug 日志 | request 提交时日志含 `extra_args.kv_transfer_params` |
| `NixlConnectorScheduler.add_new_req_to_recv` 被触发 | dst worker 日志 / nvtx | 当 step 看到 `do_remote_prefill=True` 的 req 时，rid 加入 `reqs_to_recv` |
| `start_load_kv → _read_blocks` 发起 NIXL READ | dst worker 日志 `[NixlConnector] _read_blocks_for_req` 或 nixl agent stats | active_transfers 瞬时 ≥ 1，方向为 READ |
| 真实 D2D 字节传输发生 | nixl agent byte counters / `kvbm_offload_blocks_d2d` | 增量 ≥ `len(remote_block_ids)` × block_size |
| **没有** recompute-prefill 发生 | dst worker `vllm:num_prompt_tokens_total` | connector 路径的迁移不贡献 prompt token 计数 |
| 单请求迁移耗时 (真 D2D) | controller 日志 | NVLink p99 ≤ 15 ms / PCIe p99 ≤ 60 ms |
| Connector fallback 路径生效 | 人为：dst 侧 `connector_enabled=False` 后再 migrate_in | `path:"recompute"` |
| 源端 block-hold 不释放 | 源端 worker 日志 + KVBM block usage gauge | migrate_out 后该 rid 的 block 在 NIXL completion notif 之前不下落（**该测试需在 P6 实现后才有效**） |
| 输出确定性 | greedy + 固定 seed | 与基线 sha256sum byte-equal |

## P2.3 端到端 batch 加速基准

新增脚本 `test-scripts/bench-rl-batch.py`（待实现，列入 todo）：

```
输入: HF dataset 'OpenAssistant/oasst1' 前 256 条 (avg ISL≈400, OSL 0–800)
固定: temperature=0, seed=42, model=Qwen3-0.6B
配置:
  baseline-A: 2x decode worker, no migration, no role switch
  baseline-B: 2x decode worker, role switch enabled, migration disabled
  treatment: 2x decode worker, role switch + migration both enabled
指标:
  - wall-clock for whole batch
  - p50/p95/p99 per-request latency
  - GPU utilization (DCGM)
  - 总 NIXL D2D bytes
报表:
  Markdown 表 + 4 张 PNG（latency CDF, GPU util, throughput, batch time bar）
```

PASS 条件（最终业务目标）：`treatment.wall_clock` ≤ `baseline-A.wall_clock × 0.80`
（即 **batch 处理时间 ↓ 20% 以上**），且各请求输出 sha256 与 baseline-A 一致。

## P2.4 测试运行顺序

```
# 0. 部署 Phase 2 镜像
bash deploy/RL-Scaling/deploy-dynamo.sh --router \
     --image-tag rl-scaling-phase2-<sha> \
     --extra-worker-args "--dual-mode --enable-migration --kv-connector rl-scaling"

# 1. 回归 Phase 1 脚本（验证向下兼容）
bash test-scripts/test-s1.sh
bash test-scripts/test-s2.sh   # 此时 Phase 1 stub 断言会变成"未发现 stub"
bash test-scripts/test-s3.sh

# 2. Phase 2 增强断言版本
PHASE=2 bash test-scripts/test-s2.sh
PHASE=2 bash test-scripts/test-s3.sh

# 3. 端到端 batch 基准
python test-scripts/bench-rl-batch.py \
     --baseline A,B --treatment full \
     --out /tmp/rls-bench-$(date +%Y%m%d-%H%M%S)/
```

## P2.5 当前状态 (cutoff: this commit)

| 任务 | 状态 |
|---|---|
| Phase 1 控制面 (S1+S2 stub+S3 recompute) | ✅ 已部署、smoke 通过 |
| Phase 2 Rust (S2-v2-R1/R2, S3-v2-R1/R2/R3) | ⏳ 待实现 |
| Phase 2 vLLM wrapper (S2-v2-V1, S3-v2-V1/V2) | ⏳ 待实现 |
| Phase 2 测试脚本 `test-s{2,3}.sh` 加 PHASE=2 分支 | ⏳ 待实现 |
| `test-scripts/bench-rl-batch.py` | ⏳ 待实现 |

> 实现顺序建议：先做 S3-v2-R1/R2/R3（risk 最低，已有 transfer_blocks
> 基础设施）→ S3-v2-V1/V2（vLLM connector，是真正的"未知数"，可能需要
> 升级到 vLLM 1.1+）→ S2-v2-R1/R2（小改动）→ S2-v2-V1（KV 池缩放，
> 跟 vLLM 内部 API 强耦合，最容易踩坑）。

