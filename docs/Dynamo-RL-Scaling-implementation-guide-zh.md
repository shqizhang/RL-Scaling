# Dynamo RL-Scaling 实现方案代码导读

> 本文档用于解释当前代码库中 RL-Scaling 方案是如何基于 Dynamo / vLLM 原有能力扩展出来的，以及每个实现方案对应的核心代码位置、关键逻辑和交互关系。
>
> 范围覆盖 S1 Auto Scaling、S2 Elastic Role Switch、S3 Request Consolidation。重点展开 S2/S3，因为它们是当前在 Dynamo runtime 上新增能力最多的部分。

---

## 1. 我们当前的目标

RL 推理/训练流水线的请求模式具有明显阶段性：

1. rollout / sampling 前期会出现大量 prompt prefill；
2. 随后进入较长 decode 阶段；
3. batch 尾部会出现少量长尾 decode request 占住 GPU；
4. batch 结束后又希望快速释放 GPU，供训练或下一轮 rollout 使用。

因此，当前方案的目标不是简单做 Kubernetes HPA，而是在 Dynamo disaggregated serving 的基础上实现更贴近 RL workload 的三类弹性能力：

| 层级 | 名称 | 目标 | 核心思想 |
|------|------|------|----------|
| S1 | Rollout-driven Auto Scaling | 根据 RL signal 扩缩 prefill/decode WorkerSet | controller patch DynamoGraphDeploymentScalingAdapter replicas |
| S2 | Elastic Role Switch | 不重启 pod，将 idle decode/prefill worker 原地切换角色 | worker sidecar 调用 vLLM sleep/wake、切换 ModelCard、重置 KV/NIXL 状态 |
| S3 | Request Consolidation | 将 decode tail request 从 source worker 迁移到 target worker | source `migrate_out`，target `migrate_in`，成功后 source abort/free，失败则 rollback |

最终目标是让系统在不同 RL 阶段做到：

- prompt burst 时增加 prefill 能力；
- decode backlog 时增加 decode 能力；
- decode tail 时迁移长尾请求并释放空闲 GPU；
- batch 完成后安全 scale down；
- 所有动作都和 Dynamo 的 router、ModelCard、WorkerSet、vLLM engine 状态保持一致。

---

## 2. 目前已有的 Dynamo 能力

当前方案能够落地，是因为 Dynamo 已经具备以下基础能力。

### 2.1 Disaggregated Serving 架构

Dynamo vLLM worker 已经区分 prefill / decode 角色，并通过 endpoint + ModelDeploymentCard 让 frontend router 发现 worker。

相关代码主要在：

- `dynamo/components/src/dynamo/vllm/main.py`
- `dynamo/components/src/dynamo/vllm/handlers.py`

Dynamo 的 routing 不是直接依赖 pod 名字，而是依赖 endpoint discovery / ModelCard。也就是说，如果一个 worker 能够在运行时注销旧角色 ModelCard、注册新角色 ModelCard，router 就有机会把它纳入新的 WorkerSet。

这是 S2 Elastic Role Switch 的关键基础。

### 2.2 vLLM Engine Sleep / Wake 能力

Dynamo worker handler 已经暴露 engine route：

```python
runtime.register_engine_route("sleep", handler.sleep)
runtime.register_engine_route("wake_up", handler.wake_up)
```

位置：`dynamo/components/src/dynamo/vllm/main.py`

这让 worker 可以在不杀 pod 的情况下暂停 engine、释放或整理 KV 状态，然后再 wake up。S2 利用这一点实现 role flip 前后的 quiesce / resume。

### 2.3 vLLM Token Generation Stream

`BaseWorkerHandler.generate_tokens()` 本来就是 vLLM 请求生成的主路径。我们在这个路径上增加 request registry hook，就能记录 in-flight request 的 prompt tokens、sampling params 和已经生成的 tokens。

位置：`dynamo/components/src/dynamo/vllm/handlers.py`

关键新增逻辑：

```python
registry = getattr(self, "request_registry", None)
if registry is not None:
    prompt_tokens_for_reg = list(getattr(prompt, "prompt_token_ids", []) or [])
    sp_dict = {}
    for k in ("temperature", "top_p", "top_k", "max_tokens", "min_tokens",
              "presence_penalty", "frequency_penalty", "repetition_penalty",
              "stop", "stop_token_ids", "seed", "n"):
        v = getattr(sampling_params, k, None)
        if v is not None:
            sp_dict[k] = v
    registry.register(request_id, prompt_tokens_for_reg, sp_dict, stop_conditions={})
```

生成过程中继续记录新增 token：

```python
new_token_ids = output.token_ids[num_output_tokens_so_far:]
if registry is not None and new_token_ids:
    registry.record_tokens(request_id, new_token_ids)
```

这是 S3 request migration 能够重建请求状态的基础。

### 2.4 DynamoGraphDeploymentScalingAdapter

RL-Scaling controller 通过 Kubernetes CRD `DynamoGraphDeploymentScalingAdapter` 扩缩 Dynamo WorkerSet。

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/dgdsa_client.py`

核心逻辑：

```python
body = {"spec": {"replicas": int(replicas)}}
self._api.patch_namespaced_custom_object_scale(
    group=self.GROUP,
    version=self.VERSION,
    namespace=self.namespace,
    plural=self.PLURAL,
    name=self._name(service),
    body=body,
)
```

这就是 S1 Auto Scaling 与 S3 migration 后 scale down 的 Kubernetes 控制面入口。

---

## 3. 我们增加了哪些核心代码及其所在位置

### 3.1 RL-Scaling Controller 侧

| 文件 | 作用 |
|------|------|
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/config.py` | 统一读取 S1/S2/S3 环境变量和阈值 |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/state_machine.py` | S1 rollout-driven scaling 状态机 |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/capacity_planner.py` | 根据 batch meta 计算 prefill/decode 目标副本数 |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/dgdsa_client.py` | patch DynamoGraphDeploymentScalingAdapter replicas |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/metrics_collector.py` | 抽象 cluster metrics 和 worker states |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/controller.py` | S2 策略：判断何时切角色，并执行 sidecar `/switch_role` |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/dual_mode_client.py` | S2 HTTP client：调用 worker sidecar |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/decision_engine.py` | S3 策略：选择 source/target worker pair |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/controller.py` | S3 controller：执行 migration 并 patch scale down |
| `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/migration_client.py` | S3 HTTP client：调用 worker sidecar `/migrate` |

### 3.2 Dynamo vLLM Runtime 侧

| 文件 | 作用 |
|------|------|
| `dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py` | 新增 in-process HTTP sidecar，暴露 S2/S3 runtime API |
| `dynamo/components/src/dynamo/vllm/dual_mode.py` | S2 worker runtime：执行 prefill/decode role flip |
| `dynamo/components/src/dynamo/vllm/migration.py` | S3 worker runtime：migrate_out / migrate_in / complete / rollback |
| `dynamo/components/src/dynamo/vllm/handlers.py` | 在 generate_tokens 中记录 in-flight request state |
| `dynamo/components/src/dynamo/vllm/main.py` | 启动 sidecar、创建 registry/tracker/migration handler、安装 dual-mode dispatcher |

---

## 4. S1：Rollout-Driven Auto Scaling 实现逻辑

S1 是当前 Auto Scaling 的基础层。它响应 RL signal，并通过 DGDSA 调整 prefill/decode replicas。

### 4.1 状态机目标

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/state_machine.py`

状态包括：

```text
IDLE -> WARM_UP -> ACTIVE -> COOL_DOWN -> IDLE
```

含义：

- `IDLE`：没有 GPU 或等待 RL signal；
- `WARM_UP`：已经 patch replicas，等待 worker Ready；
- `ACTIVE`：worker Ready 并开始服务；
- `COOL_DOWN`：batch 完成，等待 cooldown 和 drain；
- 回到 `IDLE` 时 prefill/decode 都 scale to zero。

### 4.2 预热触发

```python
def on_sampling_progress(self, progress: float, batch_meta: Mapping[str, int]) -> State:
    if self.state != State.IDLE:
        return self.state
    if progress < self.config.pre_warm_threshold:
        return self.state
    target = self.planner.compute(batch_meta)
    self._scale_to(target)
    self.transition_to(State.WARM_UP)
    return self.state
```

逻辑解释：

1. RL sampling progress 达到阈值；
2. capacity planner 根据 batch meta 计算 prefill/decode replicas；
3. patch DGDSA；
4. 状态从 `IDLE` 进入 `WARM_UP`。

### 4.3 Batch 完成后的安全降容

```python
elif self.state == State.COOL_DOWN:
    cooldown_done = self.time_in_state >= self.config.cooldown_seconds
    inflight = await self._inflight_total()
    drain_done = inflight == 0
    drain_forced = self.time_in_state >= self.config.drain_timeout_seconds
    if cooldown_done and (drain_done or drain_forced):
        self.dgdsa.patch("prefill", 0)
        self.dgdsa.patch("decode", 0)
        self.current_target = None
        self.transition_to(State.IDLE)
```

一致性考虑：

- 不在 batch 刚完成时立刻杀 worker；
- 先等 cooldown；
- 再确认没有 in-flight request；
- 如果长时间不 drain，则按 `drain_timeout_seconds` 强制推进。

---

## 5. S2：Elastic Role Switch 实现逻辑

### 5.1 S2 解决的问题

Dynamo 原生 prefill/decode worker 的角色通常由部署时决定。如果 RL workload 在不同阶段出现 prefill/decode 压力切换，传统做法需要重新扩缩 pod：

```text
delete old role pod -> create new role pod -> load model -> register -> serve
```

这会产生较高冷启动成本。

S2 的目标是：

```text
不重启 pod、不重新加载模型，在同一个 vLLM worker 内原地切换 prefill/decode role。
```

### 5.2 Controller 策略：什么时候切

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/controller.py`

核心判断：

```python
if (
    cluster.prefill_queue_depth >= self.config.prefill_queue_threshold
    and cluster.decode_utilization <= self.config.decode_idle_threshold
    and cluster.decode_worker_count > self.config.min_decode_replicas
):
    target = find_most_idle_worker(decode_workers, role="decode")
    return RoleSwitchDecision(
        worker_url=target.addr,
        from_role="decode",
        to_role="prefill",
        reason=(
            f"prefill_queue={cluster.prefill_queue_depth}>={self.config.prefill_queue_threshold} "
            f"and decode_util={cluster.decode_utilization:.2f}<={self.config.decode_idle_threshold:.2f}"
        ),
    )
```

反向判断：

```python
if (
    cluster.decode_queue_depth >= self.config.decode_queue_threshold
    and cluster.prefill_utilization <= self.config.prefill_idle_threshold
    and cluster.prefill_worker_count > self.config.min_prefill_replicas
):
    target = find_most_idle_worker(prefill_workers, role="prefill")
    return RoleSwitchDecision(
        worker_url=target.addr,
        from_role="prefill",
        to_role="decode",
        reason=(
            f"decode_queue={cluster.decode_queue_depth}>={self.config.decode_queue_threshold} "
            f"and prefill_util={cluster.prefill_utilization:.2f}<={self.config.prefill_idle_threshold:.2f}"
        ),
    )
```

策略含义：

- prefill queue 高、decode idle：把最空闲 decode worker 切成 prefill；
- decode queue 高、prefill idle：把最空闲 prefill worker 切成 decode；
- 不低于 `min_decode_replicas` / `min_prefill_replicas`；
- 通过 `MIN_SWITCH_INTERVAL` 防抖，避免频繁来回切。

执行入口：

```python
decision.result = self.client.switch_role(decision.worker_url, decision.to_role)
decision.executed = decision.result.status == "ok"
```

HTTP client 调用的是 worker sidecar：

```python
url = worker_url.rstrip("/") + "/switch_role"
resp = self._client.post(url, json={"target_role": target_role})
```

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/dual_mode_client.py`

### 5.3 Worker Runtime：怎么切

位置：`dynamo/components/src/dynamo/vllm/dual_mode.py`

`DualModeWorker.switch_role()` 是 S2 的核心实现。它不是只改一个变量，而是做完整 runtime orchestration。

完整步骤：

1. 获取 worker 内部 lock，避免并发切换；
2. 调 `handler.sleep(level=2)`，暂停 engine、drain in-flight、从 discovery 移除当前 endpoint instance；
3. 注销旧角色 ModelDeploymentCard；
4. 重置 NIXL connector cache；
5. 重置 prefix cache / KV pool；
6. 修改 handler 当前 disaggregation mode；
7. 注册新角色 ModelDeploymentCard；
8. 调 `handler.wake_up()`；
9. 注册新角色 endpoint instance；
10. patch pod label / publisher event，用于观测。

核心代码：

```python
sleep_resp = await self._handler.sleep({"level": 2})

if self._reregistrar is not None:
    await self._reregistrar.unregister(previous_role)

await self._reconfig_nixl(target_role)
await self._reconfig_kv_pool(target_role)

self._handler.set_disaggregation_mode(target_role)

if self._reregistrar is not None:
    await self._reregistrar.register(target_role)

wake_resp = await self._handler.wake_up({})

await self._emit_role_changed(previous_role, target_role)
self._current_role = target_role
```

返回值包含 timing：

```python
return {
    "status": "ok",
    "new_role": target_role,
    "switch_time_ms": total_ms,
    "timings_ms": timings,
}
```

这就是测试脚本中能看到 `sleep`、`unregister_mdc`、`reconfig_nixl`、`reset_prefix_cache`、`register_mdc`、`wake` 的原因。

### 5.4 与 Dynamo Router 如何保持一致

S2 一致性的核心是：

```text
不是只改 worker 内部角色，而是同步更新 Dynamo discovery / ModelCard。
```

`DualModeWorker` 通过 `Reregistrar` 回调对旧角色 unregister、对新角色 register：

```python
class Reregistrar(Protocol):
    async def register(self, role: str) -> None: ...
    async def unregister(self, role: str) -> None: ...
    def get_endpoint(self, role: str): ...
```

`Reregistrar` 的具体实现由 `main.py` 在 endpoint、model type、engine config 都可见的位置创建。

位置：`dynamo/components/src/dynamo/vllm/main.py`

```python
if _dual_mode_enabled:
    _eps = {"decode": generate_endpoint}
    _mts = {"decode": parse_endpoint_types(config.endpoint_types)}
    if _dual_partner_endpoint is not None:
        _eps["prefill"] = _dual_partner_endpoint
        _mts["prefill"] = ModelType.Prefill
    _reregistrar = VllmReregistrar(
        config=config,
        engine_client=engine_client,
        vllm_config=vllm_config,
        endpoints_by_role=_eps,
        model_types_by_role=_mts,
    )
```

这样 router 的 WorkerSet 能看到角色变化：

- decode -> prefill：旧 decode ModelCard 消失，新 prefill ModelCard 出现；
- prefill -> decode：旧 prefill ModelCard 消失，新 decode ModelCard 出现。

### 5.5 Role-Aware Generate Dispatcher

Dynamo runtime 中还有一个关键细节：同一个进程同时支持 decode endpoint 和 partner-prefill endpoint 时，需要避免 TCP handler 覆盖问题。

位置：`dynamo/components/src/dynamo/vllm/main.py`

新增的 dispatcher：

```python
async def _generate_dispatch(request, context):
    dm = getattr(handler, "_rl_dual_mode", None)
    if (
        partner_prefill_handler is not None
        and dm is not None
        and getattr(dm, "current_role", "decode") == "prefill"
    ):
        async for chunk in _partner_prefill_generate(request, context):
            yield chunk
        return
    async for chunk in handler.generate(request, context):
        yield chunk
```

含义：

- 当前 role 是 decode：请求走原始 decode handler；
- 当前 role 是 prefill：请求走 partner prefill handler；
- endpoint transport 仍然复用同一个 generate handler，但内部按当前 role dispatch。

这保证了 role switch 后，router 发来的新角色请求能在 worker 内部走正确处理逻辑。

---

## 6. S3：Request Consolidation 实现逻辑

### 6.1 S3 解决的问题

RL rollout 的 decode tail 阶段常见情况是：

```text
D1 只剩 1-3 个长尾请求
D2 还有空闲容量
但 D1 整张 GPU 因为这几个请求不能释放
```

如果等待 D1 自然完成，GPU 会被长尾请求拖住。S3 的目标是迁移这些尾部请求：

```text
D1 migrate_out -> D2 migrate_in -> D1 migration_complete -> D1 可释放 / scale down
```

### 6.2 Controller 策略：什么时候迁移

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/decision_engine.py`

核心判断：

```python
if not self.config.consolidation_enabled:
    return []
if batch_completion_pct < self.config.min_batch_completion_pct:
    return []
if len(decode_workers) <= self.config.min_decode_replicas:
    return []
```

然后按 in-flight request 数排序：

```python
sorted_workers = sorted(decode_workers, key=lambda w: w.in_flight_requests)
i, j = 0, len(sorted_workers) - 1
```

前端 `i` 指向最适合 drain 的 source，后端 `j` 指向最适合接收的 target。

核心门控：

```python
if src.in_flight_requests <= 0:
    i += 1
    continue
if src.in_flight_requests > self.config.consolidation_threshold:
    break
if tgt.available_capacity < src.in_flight_requests:
    j -= 1
    continue
if not self._is_worth_migrating(src, src.in_flight_requests):
    i += 1
    continue
```

成本收益判断：

```python
def _is_worth_migrating(self, source: WorkerState, request_count: int) -> bool:
    if source.estimated_remaining_time <= 0:
        return False
    return self._migration_time_seconds(request_count) < (source.estimated_remaining_time * 0.5)
```

含义：

- batch 还没进入 tail 时不迁移；
- decode worker 数不超过保底时不迁移；
- source 请求太多时不迁移；
- target 容量不足时不迁移；
- 迁移成本不小于收益时不迁移。

### 6.3 Controller 执行 Migration

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/controller.py`

核心代码：

```python
for pair in plans:
    for _ in range(pair.request_count):
        self.client.migrate_one(
            source_url=pair.source.addr,
            target_url=pair.target.addr,
            request_id="*",
        )
    decision.executed_pairs += 1

current = self.dgdsa.get_replicas("decode")
new_count = max(self.config.min_decode_replicas, current - decision.executed_pairs)
if new_count != current:
    self.dgdsa.patch("decode", new_count)
```

这里 `request_id="*"` 很重要：controller 只知道 source 有多少 in-flight request，但不一定知道具体 request id。Dynamo sidecar 的 `/migrate_out` 支持 `"*"`，会在 source worker 内部选择一个最适合迁移的 request。

### 6.4 Worker Runtime：如何记录 In-Flight Request

位置：`dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py`

新增 `InProcessRequestRegistry`：

```python
class InProcessRequestRegistry:
    def __init__(self) -> None:
        self._snapshots: dict[str, _RequestSnapshot] = {}

    def register(self, request_id: str, prompt_tokens: Iterable[int], sampling_params_dict: dict, stop_conditions: Optional[dict] = None) -> None:
        self._snapshots[request_id] = _RequestSnapshot(
            request_id=request_id,
            prompt_tokens=list(prompt_tokens),
            sampling_params_dict=dict(sampling_params_dict or {}),
            stop_conditions=dict(stop_conditions or {}),
        )

    def record_tokens(self, request_id: str, new_token_ids: Iterable[int]) -> None:
        snap = self._snapshots.get(request_id)
        if snap is None:
            return
        snap.generated_tokens.extend(int(t) for t in new_token_ids)

    def active_ids(self) -> list[str]:
        return list(self._snapshots.keys())
```

这个 registry 是 S3 的本地事实来源：

- `migrate_out` 从里面读取 prompt/generated/sampling params；
- `/v1/active_requests` 从里面列出 active request；
- request 完成或 abort 后 deregister。

### 6.5 Worker Runtime：migrate_out

位置：`dynamo/components/src/dynamo/vllm/migration.py`

`migrate_out` 做四件事：

1. 校验 request id；
2. 如果 request id 是 `"*"`，选择最适合迁移的 active request；
3. 读取 request state；
4. 构造可发送给 destination 的迁移 payload。

关键代码：

```python
if request_id == "*":
    ids = [
        rid
        for rid in await self._tracker.list_active_request_ids()
        if rid not in self._pending_migrations
    ]
    if not ids:
        return {"status": "error", "message": "no active requests"}
    request_id = await self._pick_most_progressed(ids)

state = await self._tracker.get_request_state(request_id)
if state is None:
    return {"status": "error", "message": f"unknown request_id {request_id!r}"}
```

选择 most-progressed request：

```python
async def _pick_most_progressed(self, ids: list[str]) -> str:
    best_id = ids[0]
    best_gen = -1
    for rid in ids:
        state = await self._tracker.get_request_state(rid)
        gen = len(state.get("generated_tokens") or [])
        if gen > best_gen:
            best_gen = gen
            best_id = rid
    return best_id
```

这样做的原因是：已经生成越多 token，迁移后越能节省 source 继续占用的时间。

### 6.6 Phase 2.A：Recompute-Prefill Migration

如果没有 NIXL KV transfer，S3 仍然可以通过 recompute-prefill 实现迁移。

目标端收到 payload 后，将 `prompt_tokens + generated_tokens` 拼成新的 replay prompt：

```python
replay_prompt = list(body["prompt_tokens"]) + list(body["generated_tokens"])
```

然后重新 submit 到目标 engine：

```python
payload = {
    "prompt_tokens": replay_prompt,
    "sampling_params": body["sampling_params"],
    "stop_conditions": body.get("stop_conditions", {}),
    "previously_emitted_tokens": list(body["generated_tokens"]),
}
await self._tracker.submit_request(request_id, payload)
return {
    "status": "ok",
    "request_id": request_id,
    "path": "recompute",
    "replay_tokens": len(replay_prompt),
}
```

它牺牲了一次额外 prefill，但能把长尾 request 从 source worker 转移出去。

### 6.7 Phase 2.B：NIXL KV Transfer Migration

如果 `DYNAMO_RL_CONNECTOR_ENABLED=1`，且 source 能拿到 KVBM block ids 与 NIXL coordinates，则走 connector path。

source 侧 `migrate_out` 构造 `kv_transfer_params`：

```python
response["kv_transfer_params"] = {
    "do_remote_prefill": True,
    "do_remote_decode": False,
    "remote_engine_id": nixl_coords["engine_id"],
    "remote_block_ids": list(src_block_ids),
    "remote_host": nixl_coords["host"],
    "remote_port": int(nixl_coords["port"]),
    "remote_request_id": request_id,
}
```

destination 侧 `migrate_in` 检测到 `kv_transfer_params` 后走 connector：

```python
if self._connector_enabled and kv_transfer_params:
    payload = {
        "prompt_tokens": replay_prompt,
        "sampling_params": body["sampling_params"],
        "stop_conditions": body.get("stop_conditions", {}),
        "previously_emitted_tokens": list(body["generated_tokens"]),
        "kv_transfer_params": dict(kv_transfer_params),
        "migration_meta": {
            "path": "connector",
            "src_block_ids": list(kv_transfer_params.get("remote_block_ids") or []),
        },
    }
    await self._tracker.submit_request(request_id, payload)
    return {
        "status": "ok",
        "request_id": request_id,
        "path": "connector",
        "replay_tokens": len(replay_prompt),
    }
```

connector path 的意义是：目标 worker 不需要完全 recompute 源端已经产生的 KV cache，而是通过 NIXL 读取源端物理 KV blocks。

### 6.8 Block-Hold、Complete、Rollback 一致性

S3 最大的风险是：source 过早 abort，而 destination 又拒绝迁移，导致请求丢失。

当前实现通过 block-hold protocol 避免这个问题。

当 connector enabled 时，`migrate_out` 不立刻 abort source，而是 hold：

```python
use_block_hold = self._connector_enabled
if use_block_hold:
    self._pending_migrations[request_id] = time.monotonic()
else:
    await self._tracker.abort_request(request_id)
```

如果 destination 成功接收，调用 `migration_complete`：

```python
ts = self._pending_migrations.pop(request_id, None)
await self._tracker.abort_request(request_id)
return {"status": "ok", "request_id": request_id}
```

如果 destination declined 或 unreachable，调用 `migration_rollback`：

```python
ts = self._pending_migrations.pop(request_id, None)
return {"status": "ok", "request_id": request_id, "hold_ms": hold_ms}
```

rollback 不 abort source，请求继续在 source 上跑。

这就是 S3 的一致性核心：

```text
migrate_out 只准备迁移
migrate_in 成功后才 complete
migrate_in 失败则 rollback
```

### 6.9 Coordinated `/migrate` Endpoint

位置：`dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py`

为了简化 controller/test 调用，sidecar 暴露了 coordinated endpoint：

```text
POST /migrate
```

它内部执行完整三阶段：

```python
out_result = await migration_handler.migrate_out(body)
if out_result.get("status") != "ok":
    return web.json_response(out_result)

async with session.post(target_migrate_in, json=out_result) as resp:
    in_result = await resp.json()

if in_result.get("status") == "ok":
    mc = await migration_handler.migration_complete({"request_id": real_rid})
    return web.json_response({
        "status": "ok",
        "request_id": real_rid,
        "migrate_out": out_result,
        "migrate_in": in_result,
        "migration_complete": mc,
    })
else:
    rb = await migration_handler.migration_rollback({"request_id": real_rid})
    return web.json_response({
        "status": in_result.get("status", "error"),
        "request_id": real_rid,
        "migrate_out": out_result,
        "migrate_in": in_result,
        "rolled_back": rb.get("status") == "ok",
    })
```

controller 的 `MigrationClient` 只需要调用 source sidecar 的 `/migrate`，不需要自己编排 complete/rollback。

---

## 7. 核心代码实现：Controller 与 Runtime 如何连接

### 7.1 Worker Sidecar 是连接层

位置：`dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py`

暴露的 API：

```text
GET  /healthz
GET  /v1/role
POST /switch_role
POST /migrate_out
POST /migrate_in
POST /migration_complete
POST /migration_rollback
POST /migrate
GET  /v1/active_requests
```

对应能力：

| API | 调用方 | 被调用逻辑 | 用途 |
|-----|--------|------------|------|
| `/switch_role` | S2 controller / test | `DualModeWorker.switch_role()` | 原地切换 worker role |
| `/migrate_out` | S3 sidecar / test | `MigrationHandler.migrate_out()` | 从 source 导出 request state |
| `/migrate_in` | source coordinated endpoint | `MigrationHandler.migrate_in()` | 在 destination 接收 request |
| `/migration_complete` | source coordinated endpoint | `MigrationHandler.migration_complete()` | 成功后 abort source，释放 blocks |
| `/migration_rollback` | source coordinated endpoint | `MigrationHandler.migration_rollback()` | 失败后释放 hold，source 继续 |
| `/migrate` | S3 controller / test | migrate_out + remote migrate_in + complete/rollback | 一键协调迁移 |
| `/v1/active_requests` | test/debug | registry.active_ids() | 观察 in-flight request |

### 7.2 Sidecar 在 Dynamo Worker 启动时注入

位置：`dynamo/components/src/dynamo/vllm/main.py`

核心代码：

```python
registry = InProcessRequestRegistry()
handler.request_registry = registry

dual_mode = DualModeWorker(
    handler,
    initial_role=initial_role,
    reregistrar=_reregistrar,
)
handler._rl_dual_mode = dual_mode

tracker = EngineRequestTracker(
    engine_client=engine_client,
    registry=registry,
    submit_request_callback=make_submit_request_callback(engine_client),
)

migration_handler = MigrationHandler(
    tracker,
    policy=MigrationPolicy(),
    engine=engine_client,
    block_index=RequestBlockIndex(kvbm_cm),
    nixl_meta_provider=make_nixl_meta_provider(vllm_config),
    connector_enabled=connector_enabled,
)

sidecar_runner, _site = await start_sidecar(
    dual_mode_worker=dual_mode,
    migration_handler=migration_handler,
    initial_role=initial_role,
    registry=registry,
)
```

这段代码把三类对象接起来：

```text
vLLM handler / engine
  -> registry / tracker
  -> DualModeWorker / MigrationHandler
  -> aiohttp sidecar
  -> RL-Scaling controller
```

### 7.3 Controller 配置入口

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/config.py`

S2/S3 关键环境变量：

```python
role_switch_enabled: bool = field(default_factory=lambda: _env_bool("ROLE_SWITCH_ENABLED", False))
prefill_queue_threshold: int = field(default_factory=lambda: _env_int("PREFILL_QUEUE_THRESHOLD", 10))
decode_queue_threshold: int = field(default_factory=lambda: _env_int("DECODE_QUEUE_THRESHOLD", 10))
decode_idle_threshold: float = field(default_factory=lambda: _env_float("DECODE_IDLE_THRESHOLD", 0.2))
prefill_idle_threshold: float = field(default_factory=lambda: _env_float("PREFILL_IDLE_THRESHOLD", 0.2))
min_switch_interval_seconds: float = field(default_factory=lambda: _env_float("MIN_SWITCH_INTERVAL", 30.0))

consolidation_enabled: bool = field(default_factory=lambda: _env_bool("CONSOLIDATION_ENABLED", False))
consolidation_threshold: int = field(default_factory=lambda: _env_int("CONSOLIDATION_THRESHOLD", 3))
min_batch_completion_pct: float = field(default_factory=lambda: _env_float("MIN_BATCH_COMPLETION", 0.6))
per_request_migration_overhead: float = field(default_factory=lambda: _env_float("PER_REQUEST_MIGRATION_OVERHEAD", 0.5))
```

### 7.4 当前主循环状态

位置：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/main.py`

当前 `main.py` 背景循环主要执行 S1 state machine：

```python
async def _control_loop(sm: ScalingStateMachine, interval: float) -> None:
    while True:
        try:
            await sm.control_loop_tick()
        except Exception:
            logger.exception("control_loop tick failed")
        await asyncio.sleep(interval)
```

也就是说，代码库中已经有 S2/S3 controller 模块和 Dynamo runtime 能力，但主进程是否把 S2/S3 controller 串入统一 loop，需要作为后续实现复核重点。

理想的统一循环应类似：

```python
while True:
    await consolidation_controller.control_loop_tick()
    await role_switch_controller.evaluate_and_execute()
    await scaling_state_machine.control_loop_tick()
    await asyncio.sleep(interval)
```

推荐顺序是 S3 -> S2 -> S1：

1. 先迁移 decode tail，释放局部资源；
2. 再判断是否需要 prefill/decode role switch；
3. 最后再做 Kubernetes-level scale up/down。

---

## 8. 三个方案如何环环相扣

### 8.1 S1 与 Dynamo CRD 的关系

```text
RL signal
  -> ScalingStateMachine
  -> CapacityPlanner
  -> DGDSAClient.patch(prefill/decode replicas)
  -> Dynamo operator reconciles WorkerSet
  -> worker pod starts / stops
  -> ModelCard updates
  -> frontend router sees capacity changes
```

S1 改变的是 pod 数量，是最外层、最重的扩缩容。

### 8.2 S2 与 Dynamo Discovery 的关系

```text
metrics show imbalance
  -> ElasticRoleSwitchController decides role flip
  -> DualModeClient POST /switch_role
  -> worker sidecar
  -> DualModeWorker.sleep/unregister/reconfig/register/wake
  -> old role ModelCard removed
  -> new role ModelCard published
  -> frontend router rebuilds WorkerSet
  -> new role traffic reaches same pod
```

S2 不改变 pod 数量，而是改变现有 pod 在 Dynamo discovery 中呈现的角色。

### 8.3 S3 与 vLLM Request Lifecycle 的关系

```text
batch enters tail
  -> ConsolidationDecisionEngine picks source/target
  -> MigrationClient POST source /migrate
  -> source migrate_out reads InProcessRequestRegistry
  -> destination migrate_in resubmits request
  -> source migration_complete aborts old request
  -> source active request count decreases
  -> controller patches decode replicas down if source drained
```

S3 不改变请求语义，而是改变 in-flight decode request 所在 worker。

### 8.4 一致性关系总结

| 风险 | 对应机制 |
|------|----------|
| role switch 后 router 还把旧角色流量发给该 worker | unregister old MDC + register new MDC |
| role switch 时旧 KV cache 污染新角色 | sleep 后 reset_prefix_cache |
| NIXL connector 跨角色 stale handle | `_reconfig_nixl()` 清空 cached connector |
| migrate source abort 太早导致请求丢失 | block-hold + complete/rollback |
| destination 拒绝迁移 | rollback，source request 继续运行 |
| source 长时间 hold 不释放 | stale migration sweeper force-abort |
| controller 频繁 role flip | `MIN_SWITCH_INTERVAL` 防抖 |
| consolidation 把 decode worker 降到 0 | `MIN_DECODE_REPLICAS` 保底 |

---

## 9. 当前实现能力与边界

### 9.1 已经增加的能力

当前代码库已经增加了以下关键能力：

1. RL signal 驱动的 prefill/decode replicas 扩缩容；
2. 运行时 worker sidecar，允许 controller 用 HTTP 控制 worker；
3. dual-mode worker，可以原地切换 prefill/decode role；
4. role switch 期间的 sleep/wake、ModelCard unregister/register、KV reset、NIXL reset；
5. in-flight request registry，可以记录 prompt/generated tokens；
6. request migration handler，可以 migrate_out / migrate_in / complete / rollback；
7. recompute-prefill migration path；
8. NIXL connector migration path；
9. coordinated `/migrate` endpoint；
10. controller 侧 S2/S3 策略模块和单元可测结构。

### 9.2 当前边界和需要后续复核的点

1. `main.py` 当前主循环主要执行 S1 state machine，S2/S3 controller 是否纳入生产 loop 需要继续实现或复核；
2. `PrometheusMetricsCollector.get_decode_worker_states()` 当前骨架实现返回空列表，真实策略触发需要补齐 worker-level discovery/metrics；
3. S3 migrated-in request 当前主要通过 migration response 和 token counter 证明 accepted，request 与原 client stream 的无缝续接仍属于更后续阶段；
4. NIXL path 依赖 KVBM block ids、NIXL metadata、connector enabled 配置都可用，否则自动 fallback 到 recompute；
5. S2 role switch 的正确性依赖 `DYNAMO_RL_DUAL_MODE=1` 和 partner endpoint 注册，否则只能做到 in-process role flag 变化。

---

## 10. 推荐学习路径

如果要深入学习代码，建议按这个顺序阅读：

1. S1 controller 状态机：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/state_machine.py`
2. S1 Kubernetes patch：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/dgdsa_client.py`
3. S2 controller 策略：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/controller.py`
4. S2 worker runtime：`dynamo/components/src/dynamo/vllm/dual_mode.py`
5. sidecar API：`dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py`
6. S3 request registry hook：`dynamo/components/src/dynamo/vllm/handlers.py`
7. S3 migration runtime：`dynamo/components/src/dynamo/vllm/migration.py`
8. Dynamo startup wiring：`dynamo/components/src/dynamo/vllm/main.py`
9. S3 controller 策略：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/decision_engine.py`
10. S3 controller 执行：`RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/consolidation/controller.py`

---

## 11. 一句话总结

当前方案是在 Dynamo 已有 disaggregated serving、ModelCard discovery、vLLM sleep/wake、Kubernetes DGDSA scaling 的基础上，增加了一层 RL-aware control plane 和 worker-side runtime API：

```text
S1 负责改 replicas
S2 负责改 worker role
S3 负责改 request placement
```

三者共同目标是让 GPU 资源在 RL workload 的 prefill、decode、tail 和 cooldown 阶段都能更快、更细粒度地重新分配，同时通过 ModelCard 更新、KV reset、NIXL reset、block-hold、rollback 等机制保证和 Dynamo / vLLM 原有逻辑保持一致。
