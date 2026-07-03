# RL-Scaling on Dynamo 技术方案与架构梳理

> 本文档整合 `docs/` 目录中除 Tech Report 外的方案、deep dive、S2/S3 设计、controller 策略和端到端请求链路说明。原始 Tech Report 中英文版本仍保留，本文作为当前项目的中文主方案文档。

---

## 1. 项目目标与问题边界

RL rollout / sampling 推理负载与普通在线推理不同，通常具有明显阶段性：

1. rollout 前期会出现大量 prompt prefill；
2. 随后进入较长 decode 阶段；
3. batch 尾部会出现少量长尾 decode request 分散占住多个 GPU；
4. batch 完成后，希望尽快释放 GPU 给训练或下一轮 rollout。

因此本项目的目标不是简单做 Kubernetes HPA，而是在 NVIDIA Dynamo disaggregated serving 的基础上实现 RL-aware GPU 调度和 autoscaling：

| 层级 | 名称 | 作用对象 | 核心目标 |
|---|---|---|---|
| S1 | Rollout-driven Auto Scaling | Kubernetes / DGDSA replicas | 根据 RL signal 预热和回收 prefill / decode 副本 |
| S2 | Elastic PD Role Switch | 单个 vLLM worker 的 prefill / decode role | 不重启 pod，原地把闲置角色容量转给瓶颈角色 |
| S3 | Request Consolidation | decode worker 上的 in-flight requests | 在 decode tail 阶段收拢长尾请求，释放 source worker |

三者共同服务于一个目标：减少 GPU 在 RL 推理阶段的空闲、碎片化占用和尾部等待时间，提高 GPU effective hour、端到端 batch 完成效率和资源回收速度。

---

## 2. 仓库与关键代码位置

项目由两个子项目组成：

| 目录 | 职责 |
|---|---|
| `dynamo/` | Dynamo fork，包含 vLLM worker-side runtime 扩展：sidecar、role switch、migration、request registry、NIXL/KVBM 接入 |
| `RL-Scaling/` | 新增控制面、SDK、部署脚本、测试脚本、报告和方案文档 |

核心代码映射如下：

| 能力 | 关键文件 |
|---|---|
| S1 状态机 | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/state_machine.py` |
| S1 容量规划 | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/capacity_planner.py` |
| S1 DGDSA patch | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/dgdsa_client.py` |
| Controller 配置 | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/config.py` |
| Controller 主循环 | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/main.py` |
| Worker metrics / discovery | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/metrics_collector.py` |
| S2 controller | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/controller.py` |
| S2 sidecar client | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/dual_mode_client.py` |
| S3 decision engine | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/decision_engine.py` |
| S3 controller | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/controller.py` |
| S3 migration client | `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/migration_client.py` |
| Worker sidecar | `dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py` |
| S2 worker runtime | `dynamo/components/src/dynamo/vllm/dual_mode.py` |
| S3 worker runtime | `dynamo/components/src/dynamo/vllm/migration.py` |
| Request registry hooks | `dynamo/components/src/dynamo/vllm/handlers.py` |
| Dynamo startup wiring | `dynamo/components/src/dynamo/vllm/main.py` |

---

## 3. Dynamo 基础架构

### 3.1 部署视图

在 Kubernetes 中，一个 DynamoGraphDeployment 通常包含：

```text
Client
  -> Frontend (:8000, Rust OpenAI API)
  -> Preprocessor / Backend pipeline
  -> PrefillRouter
  -> Prefill Worker(s)
  -> NIXL KV transfer
  -> Decode Worker(s)
  -> HTTP/SSE response
```

每个 worker pod 内部同时包含：

```text
Dynamo runtime / discovery
  -> Python vLLM handler
  -> vLLM engine + prefix cache + KVBM + NixlConnector
  -> RL-Scaling sidecar (:9091)
       /switch_role
       /migrate
       /migrate_out
       /migrate_in
       /migration_complete
       /migration_rollback
       /v1/role
       /v1/active_requests
```

### 3.2 Discovery 与 WorkerSet

当前部署使用 `DYN_DISCOVERY_BACKEND=kubernetes`，不是 etcd discovery。每个 worker pod 拥有一个以自身 pod 名称命名的 `DynamoWorkerMetadata` CR。该 CR 中的 `.spec.data.endpoints`、`.spec.data.event_channels`、`.spec.data.model_cards` 是 frontend 构建 WorkerSet 的事实来源。

重要结论：

- 一个 decode pod 是否在 chat WorkerSet 中，不由 Service 轮询决定，而由其 `DynamoWorkerMetadata` 中是否存在 `backend/generate` ModelCard 决定。
- 一个 prefill pod 是否能被 PrefillRouter 选择，由其 CR 中是否存在 `prefill/generate` ModelCard 决定。
- S2 role switch 的关键不是改 pod label，而是撤回旧角色 ModelCard 并发布新角色 ModelCard。
- `kv_metrics` 等指标只能在 WorkerSet 成员之间辅助路由；CR membership 是路由候选集的权威来源。

### 3.3 Frontend 请求路径

以 `/v1/chat/completions` 为例，端到端路径如下：

1. HTTP server 接收 OpenAI chat request。
2. Preprocessor 应用 chat template 并 tokenization。
3. PrefillRouter 选择 prefill worker，执行 prefill-only 请求。
4. Prefill worker 通过 NixlConnector 产出 `kv_transfer_params`。
5. PrefillRouter 将 `kv_transfer_params` 注入 decode request。
6. Decode KvRouter 选择 decode worker。
7. Decode worker 通过 NIXL READ 拉取远端 KV blocks，进入逐 token decode。
8. Backend detokenize token stream，返回 JSON 或 SSE。

在这个链路中，`nvext.worker_id`、Prometheus counters、worker logs、DWMD CR diff 可以共同证明请求实际经过了哪个 prefill / decode worker。

### 3.4 KvRouter 与 Prefix Cache

Dynamo 的 KvRouter 通过 token block hash、RadixTree / concurrent indexer 和 worker 负载信息选择 worker。对首次请求，KV overlap 通常为 0，路由退化为负载均衡；对相似 system prompt 或多轮对话，已有 prefix cache 会让请求倾向于命中缓存更好的 worker。

这解释了 S2 测试中的一个现象：worker 切回 decode 后，其 prefix cache 被 reset，后续请求分布不会严格 50/50，而会受 cache warmth 与负载共同影响。这是预期行为，不是路由错误。

---

## 4. S1：Rollout-driven Auto Scaling

S1 是最外层、最粗粒度的 autoscaling。它根据 RL training / rollout 阶段发出的 signal 调整 DynamoGraphDeploymentScalingAdapter replicas。

### 4.1 状态机

S1 状态机为：

```text
IDLE -> WARM_UP -> ACTIVE -> COOL_DOWN -> IDLE
```

状态含义：

| 状态 | 含义 |
|---|---|
| `IDLE` | 当前没有服务中的 rollout capacity |
| `WARM_UP` | 已 patch replicas，等待 prefill / decode worker Ready |
| `ACTIVE` | worker Ready 并可服务 |
| `COOL_DOWN` | batch 完成后等待 cooldown 和 request drain |

### 4.2 触发与回收

当 `sampling_progress >= PRE_WARM_THRESHOLD` 时，controller 根据 batch meta 计算目标 prefill / decode replicas，并 patch DGDSA。

当 batch 完成后，状态机进入 `COOL_DOWN`。它不会立刻 scale down，而是等待：

- `COOLDOWN_SECONDS` 到达；
- in-flight requests drain 到 0；
- 或 `DRAIN_TIMEOUT_SECONDS` 到达后强制推进。

这样能避免 batch 刚结束时直接杀掉仍在输出的请求。

### 4.3 容量规划

容量规划由 `CapacityPlanner` 完成，核心输入包括：

- batch size；
- avg input sequence length；
- total prompt tokens；
- `SINGLE_PREFILL_TPS`；
- `TARGET_PREFILL_SECONDS`；
- `MAX_CONCURRENT_PER_DECODE`；
- `MAX_GPUS`；
- `MIN_PREFILL_REPLICAS` / `MIN_DECODE_REPLICAS`。

S1 负责 pod 数量级别的容量变化，S2/S3 负责在现有 pod 内做更细粒度的角色和请求位置调整。

---

## 5. S2：Elastic PD Role Switch

### 5.1 S2 要解决的问题

Dynamo 原生 prefill / decode worker 的角色通常在部署时确定。如果 prefill 突然成为瓶颈，而 decode 侧有空闲 GPU，传统做法需要：

```text
scale down decode -> scale up prefill -> load model -> register -> serve
```

S2 的目标是在不重启 pod、不重新加载模型的情况下，将已有 worker 在 `decode` 与 `prefill` 之间原地切换。

### 5.2 Controller 触发条件

S2 默认关闭，由 `ROLE_SWITCH_ENABLED=true` 启用。

decode -> prefill 的条件：

```text
prefill_queue_depth >= PREFILL_QUEUE_THRESHOLD
AND decode_utilization <= DECODE_IDLE_THRESHOLD
AND decode_worker_count > MIN_DECODE_REPLICAS
AND 距离上次切换 >= MIN_SWITCH_INTERVAL
```

prefill -> decode 的条件：

```text
decode_queue_depth >= DECODE_QUEUE_THRESHOLD
AND prefill_utilization <= PREFILL_IDLE_THRESHOLD
AND prefill_worker_count > MIN_PREFILL_REPLICAS
AND 距离上次切换 >= MIN_SWITCH_INTERVAL
```

默认阈值：

| 配置 | 默认值 | 含义 |
|---|---:|---|
| `ROLE_SWITCH_ENABLED` | `false` | 是否启用自动 role switch |
| `PREFILL_QUEUE_THRESHOLD` | `10` | prefill backlog 达到多少视为拥塞 |
| `DECODE_QUEUE_THRESHOLD` | `10` | decode backlog 达到多少视为拥塞 |
| `DECODE_IDLE_THRESHOLD` | `0.2` | decode 利用率低于多少视为空闲 |
| `PREFILL_IDLE_THRESHOLD` | `0.2` | prefill 利用率低于多少视为空闲 |
| `MIN_DECODE_REPLICAS` | `1` | decode 最小保底副本数 |
| `MIN_PREFILL_REPLICAS` | `1` | prefill 最小保底副本数 |
| `MIN_SWITCH_INTERVAL` | `30.0s` | 两次切换最小间隔 |

Controller 会在候选角色池中选择 `in_flight_requests` 最少的 worker，降低对活跃流量的扰动。controller 决定“选谁切”，worker sidecar 决定“如何安全切”。

### 5.3 Worker 侧切换协议

`DualModeWorker.switch_role(target_role)` 在 worker 内部异步锁下执行：

1. `sleep(level=2)`：暂停 engine，释放 decode KV 状态，拒绝新提交；
2. `unregister_mdc`：从 DWMD CR 移除旧角色 ModelCard；
3. `reconfig_nixl`：清理 cached NIXL connector，使新角色首次使用时 lazy init；
4. `reset_prefix_cache`：在 engine sleep 窗口内清空 prefix cache，避免命中已释放 block；
5. `set_disaggregation_mode`：更新 handler 当前角色；
6. `register_mdc`：向 DWMD CR 发布新角色 ModelCard；
7. `wake`：恢复 engine；
8. `emit_role_changed`：记录事件并 best-effort patch pod label。

关键顺序约束：

- 先撤回旧 ModelCard，再发布新 ModelCard，保证 frontend WorkerSet 最终收敛到真实角色。
- `reset_prefix_cache` 必须发生在 sleep 与 wake 之间，否则新请求可能命中指向已释放 KV blocks 的陈旧 prefix cache。
- NIXL connector 需要在角色切换后重建，避免跨角色 stale handle。

### 5.4 Partner Prefill 与 role-aware dispatcher

当 `DYNAMO_RL_DUAL_PARTNER_PREFILL=1` 且 worker 以 `kv_role=kv_both` 启动时，decode worker 切换为 prefill 后可以作为一级 prefill worker 服务流量。

为了支持同一进程中 decode endpoint 与 partner-prefill endpoint 共存，Dynamo worker 使用 role-aware generate dispatcher：

```text
current_role == decode  -> 原始 decode handler
current_role == prefill -> partner prefill handler
```

同时 `_partner_prefill_generate` 会合并 vLLM 多 chunk 输出，把最终 chunk 上的 `kv_transfer_params` 提前到 frontend router 能读取的位置，解决 Rust router 只从首个 chunk 读取 disaggregated params 的问题。

### 5.5 S2 正确性证明方式

S2 测试需要分层证明：

| 证明层 | 观测方式 | 证明内容 |
|---|---|---|
| Router 输入 | `DynamoWorkerMetadata` CR diff | `backend/generate` ModelCard 在 d->p 后消失，在 p->d 后恢复 |
| Router 输出 | per-pod token counters / nvext worker id | 流量不再打到已撤回角色的 worker |
| 用户可见面 | 前端 HTTP status / latency | 切换过程中持续请求仍成功 |
| Worker 状态 | `/v1/role` 与 sidecar response | worker 当前 role 与操作结果一致 |

历史机制测试显示 role switch 的服务端耗时主要由 K8s CR apply / register_mdc 决定，单节点环境下约数百毫秒量级。

---

## 6. S3：Request Consolidation

### 6.1 S3 要解决的问题

decode tail 阶段常见现象：

```text
D1: 1-3 个长尾请求
D2: 有可用容量
D3: 1-2 个长尾请求
```

如果等待每个 worker 自然完成，多个 GPU 会因少量请求被长时间占住。S3 的目标是将 source worker 上的小尾巴请求迁移到 target worker，使 source 尽快 drain，随后可缩容或用于 S2 role switch。

### 6.2 Controller 触发条件

S3 默认关闭，由 `CONSOLIDATION_ENABLED=true` 启用。

触发条件：

```text
batch_completion_pct >= MIN_BATCH_COMPLETION
AND len(decode_workers) > MIN_DECODE_REPLICAS
AND source.in_flight_requests > 0
AND source.in_flight_requests <= CONSOLIDATION_THRESHOLD
AND target.available_capacity >= source.in_flight_requests
AND migration_cost < source.estimated_remaining_time * 0.5
AND 连续命中 stable window
AND 距离上次 consolidation >= CONSOLIDATION_MIN_INTERVAL
```

默认阈值：

| 配置 | 默认值 | 含义 |
|---|---:|---|
| `CONSOLIDATION_ENABLED` | `false` | 是否启用 S3 |
| `MIN_BATCH_COMPLETION` | `0.6` | batch 完成度达到多少后允许尾部收敛 |
| `CONSOLIDATION_THRESHOLD` | `3` | source 最大 in-flight requests |
| `PER_REQUEST_MIGRATION_OVERHEAD` | `0.5s` | 每个请求迁移成本估算 |
| `CONSOLIDATION_STABLE_SAMPLES` | `2` | 连续多少个 sample 满足才执行 |
| `CONSOLIDATION_MIN_INTERVAL` | `10.0s` | 两次 consolidation 最小间隔 |
| `CONSOLIDATION_SCALE_DOWN_ENABLED` | `true` | 迁移成功后是否 patch decode replicas |

### 6.3 Source / Target 配对

`ConsolidationDecisionEngine` 使用 two-pointer 策略：

1. 按 `in_flight_requests` 升序排列 decode workers；
2. 左侧低负载 worker 作为 source 候选；
3. 右侧高可用容量 worker 作为 target 候选；
4. source 必须是“小尾巴”：`0 < in_flight <= threshold`；
5. target 必须有足够 `available_capacity`；
6. 迁移收益必须高于估计成本。

这种策略复杂度低，能避免在所有 worker pair 上做组合爆炸。

### 6.4 Worker 侧 request registry

S3 依赖 worker 内的 `InProcessRequestRegistry`。请求处理路径在以下时刻更新 registry：

```text
register      请求提交时记录 prompt_tokens / sampling_params
record_tokens 每个流式 token delta 产生时追加 generated_tokens
deregister    请求完成、错误或 abort 时移除
```

`GET /v1/active_requests` 返回当前活跃 request id 列表。`migrate_out` 支持 `request_id="*"`，会在 source worker 内部选择 `generated_tokens` 最多的请求。选择进度最远的请求，目的是最大化每次迁移释放的尾部占用价值。

### 6.5 迁移协议

推荐通过 coordinated endpoint：

```text
POST source_sidecar /migrate
```

它内部执行：

```text
1. source /migrate_out
2. target /migrate_in
3a. target ok       -> source /migration_complete
3b. target declined -> source /migration_rollback
```

`migrate_out` 返回：

```jsonc
{
  "status": "ok",
  "request_id": "...",
  "prompt_tokens": [1, 2, 3],
  "generated_tokens": [4, 5, 6],
  "sampling_params": {},
  "stop_conditions": {},
  "src_block_ids": [10, 11],
  "kv_transfer_params": {
    "do_remote_prefill": true,
    "remote_engine_id": "...",
    "remote_block_ids": [10, 11],
    "remote_host": "...",
    "remote_port": 12345,
    "remote_request_id": "..."
  }
}
```

### 6.6 Phase 2.A：Recompute-Prefill

这是默认安全路径。当 connector 未启用，或 KVBM block IDs / NIXL coordinates 不可用时，目标端将：

```text
replay_prompt = prompt_tokens + generated_tokens
```

作为新的长 prompt 做一次 prefill，然后从原请求已经生成的位置继续 decode。这样数学上等价于请求从一开始就在 target worker 上运行，只是多付出一次 prefill 成本。启用 prefix cache 时，重放成本通常只来自未缓存后缀，远低于从头重新生成全部 token。

### 6.7 Phase 2.B：NIXL Pull + Block-Hold

当 `DYNAMO_RL_CONNECTOR_ENABLED=1` 且 KVBM block IDs 与 NIXL metadata 可用时，S3 可以走 connector path。这里的传输机制是 vLLM / Dynamo 的 NixlConnector 使用 NIXL READ 拉取 KV blocks，不是 NCCL collective。目标端将 `kv_transfer_params` 注入 `sampling_params.extra_args`，由 vLLM NixlConnectorScheduler 发起 NIXL READ，从 source GPU blocks 拉取 KV。

需要特别区分两个概念：实现中 `migrate_in` 仍会构造 `replay_prompt = prompt_tokens + generated_tokens`，这是为了让目标请求具备完整的逻辑上下文，并用于 cost gate 与请求语义恢复；但在 connector path 中，只要 `kv_transfer_params` 生效，目标端并不是重新计算 source 已经产生的 KV，而是通过 NIXL 从 source GPU blocks 拉取这些 KV。只有在 connector 关闭、KVBM/NIXL 元数据缺失，或 connector 提交失败时，才 fallback 到 Phase 2.A 的 recompute-prefill。

为了避免 source 过早 abort 导致 block 被释放或复用，当前实现使用三阶段 block-hold 协议：

1. `migrate_out`：source 记录 pending migration，不立即 abort；
2. `migrate_in`：target 注入 `kv_transfer_params` 并提交请求；
3. `migration_complete`：target 成功后，source abort 原请求并释放 blocks；
4. `migration_rollback`：target declined / error 时，source 取消 pending，原请求继续在 source 上运行。

后台 sweeper 会在 `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` 后清理过期 pending migration，避免 block 泄漏。

### 6.8 成本收益门控

目标端 `MigrationHandler._should_migrate` 使用 `MigrationPolicy`：

| 配置 | 默认值 | 含义 |
|---|---:|---|
| `max_replay_tokens` | `8192` | replay prompt 过长时拒绝 |
| `min_generated_tokens` | `16` | 生成太少时迁移收益不足 |
| `min_remaining_tokens` | `32` | 剩余太少时不值得迁移 |

被拒绝的迁移返回 `status=declined` 和 reason。controller / orchestrator 必须把 declined 当作“不迁移，让 source 原地完成或 rollback”的正常结果，而不是 silent failure。

### 6.9 S3 正确性证明方式

S3 测试需要证明：

| 证明点 | 观测方式 |
|---|---|
| source 上确实有可迁移请求 | `/v1/active_requests`、`num_requests_running` |
| migration 协议成功 | `/migrate` response 中 `migrate_out`、`migrate_in`、`migration_complete` 均为 ok |
| request 离开 source | source active request count / registry snapshot 下降 |
| target 接管 | target generation tokens 增长，或 migration response 显示 accepted |
| source GPU 可释放 | source `num_requests_running` 下降到更低甚至 0 |
| 成本门控有效 | 合成 oversized migrate body 被 declined |
| 失败可回滚 | declined / error 时 source pending migration 被 rollback |

---

## 7. Controller 自动闭环

当前 `rl_scaling_controller/main.py` 已将 S3、S2、S1 串入统一后台 control loop。每个 tick 的顺序是：

```text
1. S3 ConsolidationController.control_loop_tick()
2. S2 ElasticRoleSwitchController.evaluate_and_execute()
3. S1 ScalingStateMachine.control_loop_tick()
```

采用这个顺序的原因：

- 先做 S3：如果 decode tail 已经碎片化，先迁移尾部请求可以释放 source worker，也为后续 role switch 创造更低成本的候选；
- 再做 S2：根据 prefill / decode 压力不均衡，把闲置角色转给瓶颈角色；
- 最后做 S1：S1 是副本级生命周期控制，粒度更粗，放在局部优化之后。

`PrometheusMetricsCollector` 当前会：

1. 读取 Prometheus 中的队列和利用率指标；
2. 通过 K8s label selector 发现 prefill / decode worker pods；
3. 访问 worker sidecar `/v1/role` 获取当前角色；
4. 访问 `/v1/active_requests` 获取 active request 数；
5. 用 `MAX_CONCURRENT_PER_DECODE - active` 估算 available capacity；
6. 在 Prometheus 队列指标为空时，用 worker active requests 作为 fallback。

这意味着 controller 自动闭环已经具备基本 metric -> decision -> sidecar action 链路。需要注意的是，`estimated_remaining_time` 当前仍是启发式估计，GPU effective hour 仍主要依赖测试脚本采集与报告计算，而不是 controller 内部精确积分。

---

## 8. 配置汇总

### 8.1 Controller 环境变量

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `DYNAMO_NAMESPACE` | `dynamo-system` | Dynamo 部署 namespace |
| `DGD_NAME` | `vllm-v1-disagg-router` | DynamoGraphDeployment 名称 |
| `PROMETHEUS_URL` | `http://prometheus-kube-prometheus-prometheus.monitoring:9090` | Prometheus 地址 |
| `WORKER_SIDECAR_PORT` | `9091` | worker sidecar 端口 |
| `PRE_WARM_THRESHOLD` | `0.8` | S1 预热阈值 |
| `COOLDOWN_SECONDS` | `30` | cooldown 时间 |
| `DRAIN_TIMEOUT_SECONDS` | `60` | drain 超时 |
| `CONTROL_LOOP_INTERVAL` | `5.0` | controller tick 间隔 |
| `SINGLE_PREFILL_TPS` | `50000` | 单 prefill worker 估算吞吐 |
| `MAX_CONCURRENT_PER_DECODE` | `64` | 单 decode worker 最大并发估计 |
| `TARGET_PREFILL_SECONDS` | `5.0` | 目标 prefill 时间 |
| `MAX_GPUS` | `8` | 容量规划 GPU 上限 |
| `MIN_PREFILL_REPLICAS` | `1` | prefill 保底 |
| `MIN_DECODE_REPLICAS` | `1` | decode 保底 |
| `ROLE_SWITCH_ENABLED` | `false` | 启用 S2 |
| `PREFILL_QUEUE_THRESHOLD` | `10` | prefill queue 阈值 |
| `DECODE_QUEUE_THRESHOLD` | `10` | decode queue 阈值 |
| `DECODE_IDLE_THRESHOLD` | `0.2` | decode idle 阈值 |
| `PREFILL_IDLE_THRESHOLD` | `0.2` | prefill idle 阈值 |
| `MIN_SWITCH_INTERVAL` | `30.0` | S2 最小切换间隔 |
| `CONSOLIDATION_ENABLED` | `false` | 启用 S3 |
| `CONSOLIDATION_THRESHOLD` | `3` | S3 source 最大 in-flight |
| `MIN_BATCH_COMPLETION` | `0.6` | S3 batch 完成度阈值 |
| `PER_REQUEST_MIGRATION_OVERHEAD` | `0.5` | 迁移成本估算 |
| `CONSOLIDATION_SCALE_DOWN_ENABLED` | `true` | S3 后是否缩容 |
| `CONSOLIDATION_STABLE_SAMPLES` | `2` | S3 稳定样本数 |
| `CONSOLIDATION_MIN_INTERVAL` | `10.0` | S3 最小动作间隔 |

### 8.2 Worker 环境变量

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `DYNAMO_RL_SIDECAR_PORT` | `9091` | sidecar 端口 |
| `DYNAMO_RL_SIDECAR_DISABLED` | unset | 设为 `1` 禁用 sidecar |
| `DYNAMO_RL_DUAL_MODE` | unset | 设为 `1` 启用 S2 dual mode |
| `DYNAMO_RL_DUAL_PARTNER_PREFILL` | unset | 设为 `1` 允许 decode worker 切成真实 prefill |
| `DYNAMO_RL_CONNECTOR_ENABLED` | unset | 设为 `1` 启用 S3 connector path |
| `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` | `10.0` | pending migration hold 超时 |

---

## 9. 测试策略与报告口径

### 9.1 Baseline

Baseline 应使用相同模型、相同请求数据、相同副本规模和相同 cluster 状态，但关闭策略：

```text
ROLE_SWITCH_ENABLED=false
CONSOLIDATION_ENABLED=false
```

Baseline 衡量没有 S2/S3 干预时的端到端 wall time、req/s、latency、generation tok/s、GPU utilization、GPU active time 等指标。

### 9.2 S2 测试窗口

S2 应分别构造 prefill-heavy 和 decode-heavy 窗口：

- prefill-heavy：短时间大量长 prompt / prefill 压力，decode 利用率相对低；
- decode-heavy：decode backlog 明显，prefill 利用率低。

报告需要展示：

- 触发前的 queue depth / utilization；
- controller decision reason；
- 被选中 worker 的 active request 数；
- `/switch_role` response 和 timing；
- CR ModelCard diff；
- 切换前后 prefill / decode worker set；
- HTTP 成功率与 latency 变化；
- GPU 利用率与 active time 变化。

### 9.3 S3 测试窗口

S3 应构造 batch tail：

- pre wave 让请求分散到多个 decode worker；
- post/tail wave 保持少量长请求仍在 source 上；
- `batch_completion_pct >= MIN_BATCH_COMPLETION`；
- source active request 连续多个 samples 处于 `1..CONSOLIDATION_THRESHOLD`；
- target available capacity 持续大于等于 source active request。

报告需要展示：

- 每个 sample 的 source active / target capacity；
- stable samples 如何满足；
- migration attempts / ok / declined / rollback；
- source active request 下降；
- target generation tokens 增长；
- scale down 是否发生；
- p50/p95/p99 latency 是否受影响；
- GPU busy time 或 GPU effective hour proxy 的变化。

### 9.4 指标含义

| 指标 | 含义 |
|---|---|
| `req/s` | 前端完成的 HTTP request 数除以测试 wall time；是用户请求吞吐，不是 pod 内部 RPC 吞吐 |
| `wall time` | 从测试脚本开始发出 workload 请求，到所有请求完成或达到停止条件的挂钟时间 |
| `avg latency` | 每个 HTTP 请求从发出到完成的平均耗时 |
| `p50 latency` | 50% 请求耗时不超过该值，也就是中位延迟 |
| `p95 / p99 latency` | 95% / 99% 请求耗时不超过该值，用于观察长尾 |
| `generation tok/s` | 成功请求产生的可见 completion tokens 除以 wall time |
| `prompt tok/s` | prompt tokens 处理量除以 wall time，主要体现 prefill 压力 |
| `active requests` | worker sidecar registry 中正在处理的请求数 |
| `available capacity` | controller 用 `MAX_CONCURRENT_PER_DECODE - active` 估算出的剩余并发容量 |
| `GPU utilization / busy` | `nvidia-smi` 或 DCGM 采集的 GPU 忙碌程度 |
| `GPU active time` | GPU busy 指标随时间积分的近似值，用于估算 GPU effective hour |
| `switch_time_ms` | worker sidecar 内部 S2 切换服务端耗时 |
| `migration latency` | 一次 S3 `/migrate` 从 source migrate_out 到 complete / rollback 的耗时 |

### 9.5 当前保留报告

当前仓库只保留最新标准报告：

| 目录 | 含义 |
|---|---|
| `test-scripts/reports/controller-standard-full-20260629-01` | controller 自动闭环 full 测试 |
| `test-scripts/reports/controller-standard-s2-20260629-01` | S2 策略 / sidecar 链路测试 |
| `test-scripts/reports/controller-standard-s3-20260629-01` | S3 策略 / sidecar 链路测试 |

---

## 10. 正确性、不变量与边界

### 10.1 已有能力

当前实现已经具备：

1. RL signal -> controller -> DGDSA replicas 的 S1 扩缩容；
2. worker sidecar HTTP 控制面；
3. dual-mode worker 原地 prefill / decode role switch；
4. role switch 期间 sleep / unregister / NIXL reset / prefix cache reset / register / wake；
5. in-flight request registry；
6. request migration 的 migrate_out / migrate_in / complete / rollback；
7. recompute-prefill 安全路径；
8. NIXL connector path 与 block-hold 协议；
9. controller S2/S3 自动闭环主循环；
10. S3 stable samples 和 min interval gating。

### 10.2 运行不变量

| 不变量 | 保障机制 |
|---|---|
| Router 不把旧角色流量打到已切换 worker | 旧角色 ModelCard 先 unregister |
| 新角色只在 worker 状态一致后暴露 | prefix cache reset 与 NIXL reset 完成后 register 新 ModelCard |
| prefix cache 不引用已释放 blocks | sleep 窗口中执行 `reset_prefix_cache` |
| 迁移不会因 target declined 静默丢请求 | complete / rollback 协议 |
| connector path 不读已释放 blocks | block-hold 到 migration_complete |
| controller 不把某角色切到 0 | `MIN_PREFILL_REPLICAS` / `MIN_DECODE_REPLICAS` |
| S2 不频繁抖动 | `MIN_SWITCH_INTERVAL` |
| S3 不因单次噪声触发 | `CONSOLIDATION_STABLE_SAMPLES` |

### 10.3 当前边界

仍需谨慎说明的边界：

- `estimated_remaining_time` 当前仍是启发式值，不是精确剩余 GPU 时间；
- GPU effective hour 当前报告主要基于 `nvidia-smi` / Prometheus proxy，更严谨方案应接 DCGM exporter 并做 busy time 积分；
- S3 migrated-in request 的 engine-side takeover 与资源释放已经可验证，但完整 client stream reattachment / user-visible zero-gap handoff 仍需要更强的端到端语义测试；
- connector path 依赖 KVBM block ids、NIXL metadata、connector enabled 三者同时可用，否则会 fallback 到 recompute；
- 多节点集群中，K8s API、跨 pod HTTP 和 NIXL side channel 的 RTT 会改变 timing，需要独立测量。

---

## 11. 推荐阅读顺序

新工程师建议按以下顺序阅读代码：

1. `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/config.py`
2. `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/main.py`
3. `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/state_machine.py`
4. `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/metrics_collector.py`
5. `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/controller.py`
6. `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/decision_engine.py`
7. `dynamo/components/src/dynamo/vllm/main.py`
8. `dynamo/components/src/dynamo/vllm/dual_mode.py`
9. `dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py`
10. `dynamo/components/src/dynamo/vllm/migration.py`
11. `dynamo/components/src/dynamo/vllm/handlers.py`
12. `dynamo/lib/runtime/src/discovery/kube.rs`

---

## 12. 总结

RL-Scaling on Dynamo 可以概括为：

```text
S1 改 replicas
S2 改 worker role
S3 改 request placement
```

S1 负责外层生命周期，S2 负责角色容量重分配，S3 负责尾部请求收敛。三者通过 controller metrics、K8s discovery、Dynamo ModelCard、worker sidecar、vLLM engine、KVBM/NIXL 形成闭环。技术正确性的核心不是某一个 HTTP API，而是每次动作都同时维护：

- controller 的策略选择正确；
- Dynamo discovery 的 WorkerSet 视图正确；
- worker 内部 engine / prefix cache / NIXL 状态正确；
- request registry 与 migration 协议正确；
- 用户可见的请求成功率、延迟和 token 输出可解释。

在这个基础上，后续性能验证应继续围绕 baseline vs S2 vs S3 vs full controller 闭环展开，并把 HTTP timing、token throughput 与 GPU busy time / effective hour 统一到同一份报告口径中。
