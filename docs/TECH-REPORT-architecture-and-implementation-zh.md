# RL-Scaling on Dynamo — 技术实现报告 (Technical Implementation Report)

> 日期：2026-05-10。镜像：`ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-f817b8e5d5`。
> 范围：深入探讨 (a) 针对运行中 decode pod 的弹性 PD 角色切换机制，
> (b) Dynamo 前端路由如何端到端感知角色切换，以及
> (c) 在途请求合并 / KV 迁移协议。
> 配套规格文档：[S2-elastic-pd-switch.md](S2-elastic-pd-switch.md)、
> [S3-request-consolidation.md](S3-request-consolidation.md)。

---

## 1. 系统架构 (System Architecture)

### 1.1 分层视图（部署形态）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes API server (kube-apiserver)               │
│                                                                              │
│  CRDs: DynamoGraphDeployment, DynamoComponentDeployment,                     │
│        DynamoWorkerMetadata  (≡ runtime registration record, 1-per-pod)      │
└────────────▲─────────────────────────────────────────────▲───────────────────┘
             │  apply / watch                              │  apply / watch
             │                                             │
┌────────────┴─────────────┐                  ┌────────────┴───────────────────┐
│  Frontend pod            │                  │  Worker pod (decode | prefill) │
│  ─────────────           │                  │  ─────────────                 │
│  ┌─────────────────────┐ │                  │  ┌──────────────────────────┐  │
│  │ ModelWatcher (Rust) │ │  list/watch      │  │ Dynamo runtime (Rust)    │  │
│  │  -> WorkerSet       │◄┼── DynamoWorker   │  │  - registers Endpoint /  │  │
│  │  -> KvRouter        │ │   Metadata       │  │    ModelCard / EventCh.  │  │
│  │  -> PrefillRouter   │ │                  │  │  - apply_cr to own DWMD  │  │
│  └────────┬────────────┘ │                  │  └────────────┬─────────────┘  │
│           │              │                  │               │                │
│  HTTP 8000 (chat/comp)   │                  │  TCP 4222 NATS subjects        │
│           │              │                  │               │                │
└───────────┼──────────────┘                  │  ┌────────────┴─────────────┐  │
            │                                 │  │ vLLM 0.16 engine         │  │
            │ KV-aware route                  │  │  + NixlConnector (kv_both)│ │
            │                                 │  │  + PrefixCache + KVBM    │  │
            ▼                                 │  └────────────┬─────────────┘  │
   ┌────────────────────────────────┐         │               │                │
   │ chosen worker: TCP <pod-ip>:port│────────┼─ generate ────┘                │
   └────────────────────────────────┘         │                                │
                                              │  ┌──────────────────────────┐  │
                                              │  │ RL-Scaling sidecar       │  │
                                              │  │  aiohttp :9091           │  │
                                              │  │  /switch_role            │  │
                                              │  │  /migrate_out /in        │  │
                                              │  │  /v1/active_requests     │  │
                                              │  └──────────────────────────┘  │
                                              └────────────────────────────────┘

                   ┌──────────────────────────┐
                   │ NATS (dynamo-platform)   │   event plane: kv_metrics,
                   │  port 4222               │   role_changed, kvbm signals
                   └──────────────────────────┘
```

在继续阅读本报告之前，读者必须内化以下关键事实：

- **发现机制基于 K8s CRD**，而非 etcd。每个 worker pod 拥有一个以自身命名的 `DynamoWorkerMetadata`（DWMD）自定义资源；其 `.spec.data.{endpoints, event_channels, model_cards}` 就是运行时注册记录。前端的 `ModelWatcher` 通过 list+watch 这些 CR 来重建其 `WorkerSet`。
- **每个 worker pod 有两个 HTTP 端口**：`:9090` 是 Dynamo 系统端口（Prometheus 指标、内部端点）；**`:9091` 是 RL-Scaling sidecar**（唯一暴露 `/switch_role`、`/migrate_*`、`/v1/active_requests` 的端口）。
- **vLLM 0.16 在每个 pod 上以 `kv_role=kv_both`** 和 `NixlConnector` 启用的方式一次性构建，因此引擎同时具备 prefill 和 decode 能力。角色切换是一种*注册*和*引擎状态*操作——不会重建引擎。

### 1.2 Pod 内部架构

```
                        ┌────────────────────────────────────────────────┐
                        │                Worker pod                      │
                        │                                                │
   K8s API ─── apply/   │   ┌──────────────────┐   register/             │
              watch     │   │  Dynamo runtime  │   unregister            │
                        │   │  (Rust)          │◄────────┐               │
                        │   │  discovery::kube │         │               │
                        │   └─────▲────────────┘         │               │
                        │         │ DiscoveryMetadata    │               │
                        │         │                      │               │
                        │   ┌─────┴────────────┐    ┌────┴──────────┐    │
                        │   │ EngineHandler    │    │ VllmReregistrar    │
                        │   │ (Python)         │    │ (Python)          │
                        │   │  - generate()    │    │  endpoints_by_role│
                        │   │  - sleep()/wake()│    │  {decode:...,     │
                        │   │  - request_      │    │   prefill:...}    │
                        │   │    registry      │    └────▲──────────────┘
                        │   └─────▲────────────┘         │              │
                        │         │                      │              │
                        │   ┌─────┴────────────┐         │              │
                        │   │  vLLM Engine     │         │              │
                        │   │   + Prefix cache │         │              │
                        │   │   + KVBM (NIXL)  │         │              │
                        │   └─────▲────────────┘         │              │
                        │         │                      │              │
                        │   ┌─────┴───────────────────┐  │              │
                        │   │ DualModeWorker          │──┘              │
                        │   │  switch_role(target)    │                 │
                        │   │  8-step orchestration   │                 │
                        │   └─────▲───────────────────┘                 │
                        │         │ HTTP                                │
                        │   ┌─────┴───────────────────┐                 │
                        │   │ rl_scaling_sidecar      │                 │
                        │   │  aiohttp :9091          │                 │
                        │   │  /switch_role           │                 │
                        │   │  /migrate_in /out       │                 │
                        │   │  /v1/active_requests    │                 │
                        │   └─────────────────────────┘                 │
                        │                                                │
                        └────────────────────────────────────────────────┘
```

划定各模块边界的文件：

| 模块 | 文件 |
|-----|------|
| Dynamo runtime / discovery::kube | [lib/runtime/src/discovery/kube.rs](../../dynamo/lib/runtime/src/discovery/kube.rs) |
| EngineHandler (sleep / wake / generate) | [components/src/dynamo/vllm/handlers.py](../../dynamo/components/src/dynamo/vllm/handlers.py) |
| VllmReregistrar | [components/src/dynamo/vllm/main.py](../../dynamo/components/src/dynamo/vllm/main.py) (L590-670) |
| DualModeWorker（8 步编排） | [components/src/dynamo/vllm/dual_mode.py](../../dynamo/components/src/dynamo/vllm/dual_mode.py) |
| MigrationHandler | [components/src/dynamo/vllm/migration.py](../../dynamo/components/src/dynamo/vllm/migration.py) |
| RL-Scaling sidecar (aiohttp :9091) | [components/src/dynamo/vllm/rl_scaling_sidecar.py](../../dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py) |

---

## 2. 涉及的 Kubernetes 原理 (Kubernetes Principles in Play)

### 2.1 DynamoWorkerMetadata CR 作为发现基底

环境变量 `DYN_DISCOVERY_BACKEND=kubernetes`（由 operator 在每个 worker pod 上设置）选择 `DiscoveryBackend::Kubernetes`。[distributed.rs L131-145](../../dynamo/lib/runtime/src/distributed.rs) 中的 Rust 路径构造了一个 `KubeDiscovery` 客户端，其行为如下：

1. **注册时**，调用 `DiscoveryMetadata::register_endpoint(instance)` 将新的 `DiscoveryInstance::{Endpoint | Model | EventChannel}` 合并到以 `<namespace>/<component>/<endpoint>/<inst>` 为键的内存 `BTreeMap` 中，然后通过 `apply_cr()` 对 pod 自身的 DWMD CR 执行 strategic-merge-patch。
2. **注销时**，从 map 中移除键并重新 apply。
3. **在前端侧**，一个 watcher informer 流式获取命名空间内的 DWMD 事件；`ModelWatcher` 将所有 DWMD 中 `spec.data.model_cards` 的并集转换为聊天 WorkerSet，将 `spec.data.endpoints[".../backend/generate/<id>"]` 转换为 RPC 目标，将 `spec.data.event_channels` 转换为 NATS 订阅。

具体而言，一个健康的 decoder pod 的 CR 包含：

```
spec.data:
  endpoints:
    dynamo-system-vllm-v1-disagg-router-f5d52951/backend/generate/<inst>: {Endpoint}
    dynamo-system-vllm-v1-disagg-router-f5d52951/backend/clear_kv_blocks/<inst>: {Endpoint}
  event_channels:
    dynamo-system-vllm-v1-disagg-router-f5d52951//kv_metrics/<inst>: {EventChannel, kind: Nats}
  model_cards:
    dynamo-system-vllm-v1-disagg-router-f5d52951/backend/generate/<inst>: {card_json: {...}}
```

该 CR 是判断"此 pod 是否在聊天池中"的**唯一可观测真相来源**。这正是 S2 测试直接断言的内容（`PASS_CR_D2P`）。

### 2.2 Owner references 和生命周期

每个 DWMD 都有一个指向其 Pod 的 `ownerReference`，设置 `controller: true, blockOwnerDeletion: false`。当 pod 被删除时，K8s 垃圾回收器会删除该 CR；在此之前，worker 是唯一的写入者。这一点很重要，因为角色切换会在 pod 仍在运行时修改 CR——没有 operator/controller 与我们的更新冲突。

### 2.3 Service 与 CR：路由路径被绕过

一种朴素的 K8s 部署方式会将 decoder 放在 Service 后面做轮询。我们**不**使用这条路径处理聊天流量。前端从 DWMD 中读取每个 pod 的 `endpoints[].transport.tcp = <pod_ip>:<port>/<instance_id>/<endpoint>` 并直接连接。因此，将一个 pod 从聊天池中撤出等价于"从该 pod 的 CR 中移除 `model_cards` 条目"——Service 无关紧要。

---

## 3. PD 角色切换——热交换机制 (PD Role Switch — The Hot-Swap Mechanism)

### 3.1 目标重述

我们希望一个 decoder pod `D_i` 能按需离开聊天 WorkerSet（`switch_role -> prefill`），释放其 decode KV 状态，之后可选地回来（`switch_role -> decode`），且所有这些对存活 pod 上的在途聊天流量完全透明。

### 3.2 为何在 vLLM 0.16 中这很困难

vLLM 的 `kv_transfer_config` 在**引擎构建时即固定**。你无法在运行时重新配置 NixlConnector。我们的解决方案是在启动引擎时一次性使用 `--kv-transfer-config NixlConnector kv_both`，使同一引擎同时具备两种角色的元数据。于是"角色切换"纯粹变成了：

1. 注册变更（在 CR 中发布哪个 `ModelCard`），以及
2. 引擎状态循环（sleep -> 重置 prefix cache -> wake），使引擎静默并丢弃在新角色下会不一致的瞬态状态。

### 3.3 八步编排

`DualModeWorker.switch_role(target_role)`（位于 [dual_mode.py](../../dynamo/components/src/dynamo/vllm/dual_mode.py)）在每个 worker 的异步锁下执行以下步骤；每步计时，每步耗时（ms）记录在 JSON 响应的 `timings_ms` 中：

```
                            time
   ─────────────────────────────────────────────────────────────────────►

   ┌──────────┐
1. │  sleep   │   handlers.sleep():
   │ (level=2)│     - registry.pause_generation() : reject new submits
   └─────┬────┘     - engine.sleep(2)             : free GPU KV
         │
   ┌─────▼─────────┐
2. │ unregister_mdc│   reregistrar.unregister(role=current):
   │               │     - remove ModelCard for *current* role from DWMD
   └─────┬─────────┘     - kube apply (or no-op if role has no endpoints)
         │
   ┌─────▼────────┐
3. │ reconfig_nixl│   handler._nixl_connector = None
   │              │     - force lazy re-init on next use
   └─────┬────────┘
         │
   ┌─────▼─────────────────┐
4. │ reset_prefix_cache    │   engine.reset_prefix_cache()  (engine asleep)
   │                       │     - clears prefix-pool index that points
   │                       │       to about-to-be-recycled blocks
   └─────┬─────────────────┘
         │
   ┌─────▼───────────────────┐
5. │ set_disaggregation_mode │   handler.current_role = target_role
   └─────┬───────────────────┘
         │
   ┌─────▼─────────┐
6. │  register_mdc │   reregistrar.register(role=target):
   │               │     - if endpoints_by_role[target] is empty -> no-op
   │               │     - else publish ModelCard for new role into DWMD
   └─────┬─────────┘     - kube apply
         │
   ┌─────▼────┐
7. │  wake    │   handlers.wake_up():
   │          │     - engine.wake_up()
   └─────┬────┘     - registry.resume_generation()
         │
   ┌─────▼──────────────┐
8. │ emit_role_changed  │   sidecar event:
   │                    │     - patch self pod label
   │                    │       nvidia.com/dynamo-current-role=<target>
   └────────────────────┘
```

**关键顺序约束**

- *(1) 在 (2) 之前*：中止在途请求比仅仅注销更强，因为注销只能阻止*新的*路由——已有的推理生成仍会继续向已休眠的引擎发请求并导致崩溃。
- *(2) 在 (4) 之前*：先移除 ModelCard 意味着前端在我们操作 prefix cache 之前就停止向我们路由。虽然 watcher 是最终一致的（约数百毫秒），但注销尽早启动了计时器。
- *(4) 在休眠窗口内*（sleep(2) 和 wake 之间）：vLLM 的 prefix cache 持有对 KV block 的引用。`sleep(2)` 将这些 block 归还给 GPU 分配器。如果我们在 `wake_up` *之后*调用 `reset_prefix_cache`，一个新接纳的请求可能命中一个指向已被另一个请求占用的 block 的陈旧缓存条目。在引擎暂停时做重置操作从调度器角度看是原子的。
- *(6) 在 (4) 之后*：只有在引擎处于一致的目标角色状态后，我们才发布新的 ModelCard；此时路由器发来的流量将到达一个可唤醒的引擎。

### 3.4 实测开销（ms）

|                          | decode -> prefill | prefill -> decode |
|--------------------------|------------------:|------------------:|
| sleep                    | 55.4              | 87.1              |
| unregister_mdc           | 8.0               | 10.2              |
| reconfig_nixl            | 0.1               | 0.2               |
| reset_prefix_cache       | 2.5               | 2.5               |
| register_mdc             | 296.4             | 290.1             |
| wake                     | 25.6              | 28.3              |
| **服务端总计**            | **388.1**         | **418.4**         |
| 客户端挂钟时间             | 433.3             | 457.6             |

启用 partner-prefill（§3.6）后，两个方向都会发布一个新的 `ModelCard`（d->p 方向发布 prefill MDC；p->d 方向发布 decode MDC），因此两个方向的往返都包含 `register_mdc` 开销（在我们的单节点集群中约 290ms）。早期未启用 partner-prefill 的构建版本具有不对称的开销特征，因为 `prefill` 角色没有 MDC 需要发布。

### 3.5 KV / prefix cache 一致性

`engine.sleep(level=2)` 将 GPU KV cache 页释放回分配器；引擎保留权重但不保留激活值或 KV block。prefix cache 是这些 block 的索引。如果不调用 `reset_prefix_cache`，索引会变成隐患：

```
  sleep 前:    prefix_cache[hash("system: you are...")] -> block #42
  sleep(2):    block #42 归还到空闲池
  wake_up:     分配器将 block #42 分配给新请求 "X"
  下次聊天:    prefix 查找 -> block #42 -> 将 "X" 的 token 当作缓存命中
               提供给新请求。错误。
```

因此编排**必须**在休眠窗口内重置 prefix cache。开销很小（这里 1-4 ms），因为这纯粹是一次内存哈希表刷新。

### 3.6 Partner-prefill：切换后的 pod 如何实际提供 prefill 服务

当 `DYNAMO_RL_DUAL_PARTNER_PREFILL=1` 时，`switch_role -> prefill` 后的 pod 成为一个**一等 prefill worker**，前端的 `PrefillRouter` 会将流量分派给它。验证探测显示，在聊天 WorkerSet 已撤出目标的情况下，30 次聊天探测使目标上的 `vllm:prompt_tokens_total` 增长了 1249（S2 测试 PASS_PREFILL_SERVING）。

要使端到端正常工作，需要两个非显而易见的修复：

**(a) 多 chunk 合并（commit `a82816c3d6`）。**
vLLM 0.16 的 `NixlConnector.request_finished()`（[nixl_connector.py L780-855]）仅在请求的**最后一个** `RequestOutput` chunk 上发布 `kv_transfer_params`。Dynamo 的 Rust `PrefillRouter::execute_prefill`（[lib/llm/src/kv_router/prefill_router.rs L376-465]）仅从**第一个** chunk 读取 `first_output.data.disaggregated_params`。字段缺失 -> `NoDisaggregatedParams` -> HTTP 500。封装函数 `_partner_prefill_generate` 消费整个流，捕获观察到的最后一个 `kv_transfer_params`，并产出一个合并后的 chunk，使路由器在 chunk #1 上就能看到该字段。

**(b) 单 TCP slot 分发器（commit `fe78f1b652`）。**
Dynamo 的 `SharedTcpServer`（[lib/runtime/src/pipeline/network/ingress/shared_tcp_endpoint.rs]）使用 `DashMap` 以 `endpoint_path = format!("{instance_id:x}/{endpoint_name}")` 为键存储 handler。`instance_id` 是 `endpoint.drt().connection_id()`（[component/endpoint.rs L72]），它是**进程级别的**：同一 DistributedRuntime 中的每个 endpoint 看到相同的 `cid`。

朴素的 partner-prefill 注册会在同一进程中调用 `generate_endpoint.serve_endpoint(handler.generate, ...)` 和 `_dual_partner_endpoint.serve_endpoint(_partner_prefill_generate, ...)`。两者都注册在 TCP 键 `{cid:x}/generate` 上。第二次 `handlers.insert(...)` 通过 `DashMap` 静默覆盖了第一次。MDC `TransportType`（在 `component/endpoint.rs` 中构建）也仅编码 `host:port/{cid:x}/{endpoint_name}`——因此发布到发现层的 prefill `ModelCard` 指向与 decode card 相同的 TCP slot。切换后，来自 `PrefillRouter` 的 prefill 流量到达了错误的 handler——通常是普通的 decode handler，它不理解 `kv_transfer_params` 并在每个 chunk 上产生 `disaggregated_params=None` -> HTTP 500。

修复方案：每个 `(cid, endpoint_name)` 只注册**一个** TCP handler，在请求时分发：

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

`_dual_partner_endpoint` Endpoint 对象仍然会被构造（`VllmReregistrar.register('prefill')` 需要它通过 `register_vllm_model` 发布 prefill MDC），但不会对其调用 `serve_endpoint`；发布的 prefill MDC 的 transport URL 指向 `{cid:x}/generate`，正好由分发器处理。

DualMode 在 `DualModeWorker.switch_role` 内部于步骤 (3) `unregister_mdc` 和步骤 (6) `register_mdc` 之间翻转 `current_role`，因此当新 MDC 变得可观测时，分发器就能正确路由。

当 partner-prefill 被禁用（`DYNAMO_RL_DUAL_PARTNER_PREFILL` 未设置）时，注册的 handler 是普通的 `handler.generate`，pod 的行为与早期 S2 构建版本一致（仅 decode 池弹性）。

---

## 4. 路由器 PD 感知——端到端正确性证明 (Router PD-Awareness)

### 4.1 传播链

```
   ┌─────────────────────────────┐
   │  POST /switch_role (target) │
   │  on pod D_i sidecar :9091   │
   └──────────────┬──────────────┘
                  │
                  ▼  step 2 unregister_mdc  /  step 6 register_mdc
   ┌──────────────────────────────┐
   │  VllmReregistrar             │
   │   .unregister(role=current)  │
   │   .register(role=target)     │
   └──────────────┬───────────────┘
                  │
                  ▼
   ┌────────────────────────────────────┐
   │  Dynamo runtime discovery::kube    │
   │   DiscoveryMetadata::register_/    │
   │   unregister_endpoint              │
   │   apply_cr()                       │
   └──────────────┬─────────────────────┘
                  │  kube PATCH
                  ▼
   ┌────────────────────────────────────┐
   │  kube-apiserver                    │
   │   DynamoWorkerMetadata <pod_name>  │
   │     .spec.data.model_cards <- new  │
   └──────────────┬─────────────────────┘
                  │  watch event
                  ▼
   ┌────────────────────────────────────┐
   │  Frontend ModelWatcher             │
   │   recompute WorkerSet              │
   │   notify KvRouter / PrefillRouter  │
   └──────────────┬─────────────────────┘
                  │
                  ▼
   ┌────────────────────────────────────┐
   │  Next /v1/chat/completions:        │
   │   target NOT in candidate set      │
   │   route -> survivor                │
   └────────────────────────────────────┘
```

### 4.2 两个互补证明，缺一不可

仅发送聊天探测并观察"好的，没有请求落到目标上"是不够的。那只能证明*行为*，而且对 KvRouter 的启发式策略（负载、prefix 局部性）敏感。路径 A 增加了一个**直接**断言：

| 证明 | 目标 | 方式 |
|-------|--------|-----|
| **CR 差异**（路由器输入） | `kubectl get dynamoworkermetadata <target> -o json` | 统计匹配 `*/backend/generate/*` 的 `model_cards` 键数。必须为 1 -> 0 -> 1。 |
| **逐 pod 归属**（路由器输出） | 每个 pod 上 `vllm:prompt_tokens_total` 的 Prometheus 增量 | 提交 30 次聊天；统计哪个 pod 的计数器增长了。prefill 阶段目标必须为 0/30，恢复后目标必须 >0。 |
| **无错误持续负载**（无 SLO 违规） | `/v1/chat/completions` HTTP 状态码直方图 | 在切换+恢复期间以 2 RPS 持续 30 秒。错误 <= 2/57。 |

这是分层论证：输入变了（CR），输出变了（聊天归属），用户可见面保持完好（无错误负载）。S2 测试强制执行所有三项。

### 4.3 KvRouter 启发式策略（为何恢复后的分布是 19/11 而非 15/15）

当目标重新加入聊天池时，其 **prefix cache 为空**（我们在步骤 4 中重置了它）。KvRouter 偏好将新 prompt 路由到低缓存热度的 worker 以在池中平衡复用，因此恢复后的 30 次探测分布为 19（目标）/ 11（对等节点），而非完美的 15/15。这是正确的、预期的路由器行为，不是偶发抖动。

### 4.4 多副本 DP 感知（当前状态）

KvRouter 通过 `kv_metrics` 事件（`event_channels` 中的逐 pod NATS 主题）发布路由决策；每个 pod 发布其 KV 利用率，路由器使用该信号**加上**来自 CR 的 WorkerSet 成员关系来选择。当一个 pod 从 `model_cards` 中移除时，它也会在其 `kv_metrics` 被考虑之前就从候选列表中移除——因此一致性保证是：**CR 成员关系是权威的；指标仅在成员之间作为平局仲裁**。一个刚从池中移除的 pod，其事件会立即被忽略。

---

## 5. 请求合并——迁移 pod 上的活跃请求 (Request Consolidation)

### 5.1 为何需要此功能

S2 可以干净地将一个 pod 从聊天池中移除，但它会**中止该 pod 上正在运行的所有请求**。这对长补全来说是不可接受的：一个已生成 2000 token、prompt 为 1500 token 的请求代表用户已经支付的数分钟 GPU 时间。

S3 的职责：在触发 S2（或缩容）之前，将在途的长请求排空到对等 decoder 上，使源 pod 可以在不丢失用户可见工作的情况下降至零运行请求。

### 5.2 两条路径

```
                  source (TARGET)                    destination (PEER)
                  ───────────────                    ──────────────────

   ┌─────────────────────────┐
   │ POST /migrate_out       │
   │  body: {request_id:"*"} │
   └──────────┬──────────────┘
              │
              ▼
   ┌─────────────────────────┐
   │ pick most-progressed rid│
   │ from in-process registry│
   └──────────┬──────────────┘
              │
              ▼
   ┌─────────────────────────┐
   │ block_index.lookup(rid) │   ── grab src_block_ids BEFORE abort
   └──────────┬──────────────┘      (KVBM frees on abort)
              │
              ▼
   ┌─────────────────────────┐
   │ tracker.abort_request   │
   │  (engine releases KV)   │
   └──────────┬──────────────┘
              │
              ▼
   ┌──────────────────────────────────────────┐
   │ response = {                             │
   │   prompt_tokens, generated_tokens,       │
   │   sampling_params, stop_conditions,      │
   │   src_block_ids,                         │   ── always when KVBM avail
   │   kv_transfer_params: {                  │   ── only if connector_enabled
   │     remote_engine_id, remote_block_ids,  │      AND nixl_coords avail
   │     remote_host, remote_port,            │
   │     remote_request_id,                   │
   │     do_remote_prefill: true              │
   │   }                                      │
   │ }                                        │
   └──────────┬───────────────────────────────┘
              │  HTTP body fed verbatim
              ▼
                            ┌─────────────────────────┐
                            │ POST /migrate_in        │
                            │  body: <above>          │
                            └──────────┬──────────────┘
                                       │
                                       ▼
                            ┌──────────────────────────┐
                            │ _should_migrate gate     │
                            │  - replay_total <= 8192  │
                            │  - generated >= 16       │
                            │  - remaining >= 32       │
                            │ else status=declined     │
                            └──────────┬───────────────┘
                                       │
                          ┌────────────┴─────────────┐
                          │                          │
              connector_enabled              default (recompute)
                AND kv_transfer_params
                          │                          │
                          ▼                          ▼
            ┌──────────────────────┐    ┌────────────────────────┐
            │ Phase-2.B            │    │ Phase-2.A              │
            │  submit with         │    │  submit with           │
            │  kv_transfer_params  │    │  prompt_tokens =       │
            │  -> NixlConnector    │    │   old_prompt +         │
            │  start_load_kv       │    │   old_generated        │
            │  -> NIXL READ from   │    │  -> standard prefill   │
            │     src GPU blocks   │    │     on PEER            │
            └──────────┬───────────┘    └──────────┬─────────────┘
                       │                           │
                       └────────────┬──────────────┘
                                    ▼
                       ┌──────────────────────────────┐
                       │ resume generation on PEER    │
                       │ stream remaining tokens to   │
                       │ user; previously_emitted_    │
                       │ tokens prevents double-emit  │
                       └──────────────────────────────┘
```

### 5.3 Phase-2.A（重计算 prefill）——安全默认路径

为何可行：
- vLLM 的 prefill 经过高度优化；启用 prefix cache 后，重放开销主要取决于**未缓存的后缀**（`generated_tokens` 部分在 PEER 上是全新的，因此需要为这些 token 支付全额开销；原始 prompt 通常是系统+用户模板，PEER 可能已从先前请求中缓存了）。
- 无跨 pod KV 传输意味着没有竞争窗口；源在 `tracker.abort_request` 中原子地释放其 block，目标将迁移视为普通的新请求。

权衡：
- 目标需要支付"未缓存后缀 prefill"开销——在 Qwen3-0.6B 上对几千 token 的重放通常为 100-300 ms；比让请求重新开始便宜数个数量级。

### 5.4 Phase-2.B（NIXL connector 拉取）——三阶段 block-hold 协议

线协议已完整实现：`migrate_out` 已经以 vLLM 0.16 的 NixlConnector 在 decode 侧期望的格式返回 `kv_transfer_params`（`do_remote_prefill: true`、`remote_engine_id`、`remote_block_ids`、`remote_host`、`remote_port`、`remote_request_id`——与 Dynamo 正常 disagg PD 路径在 `handlers.py:1577` 中产生的字典相同）。目标侧的 `MigrationHandler.migrate_in` 会将其直接传给一次提交，该提交的 `sampling_params.extra_args["kv_transfer_params"]` 已被设置，PEER 上的 `MultiConnector(DynamoConnector + NixlConnector)` 链将在下一个调度步骤中发出异步 NIXL READ。

源侧 block-hold 协议已实现为三阶段握手，以防止 abort/free 竞态：

1. **`migrate_out`** —— 当 `connector_enabled=True` 且 KVBM block ID 和 NIXL
   坐标全部可用时，源端延迟 `abort_request`，将 `request_id` 记录在
   `_pending_migrations` 中。block 保持固定。
2. **`migrate_in`** —— 目标端注入 `kv_transfer_params` 并提交请求。NIXL READ
   从源端固定的 block 拉取 KV。
3. **`/migration_complete`** —— 编排器在 `migrate_in` 成功后在源端调用此接口。
   源端终止原始请求并释放 block。

后台清扫任务在 `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` 秒（默认 10 秒）后强制终止
持有的迁移，防止编排器未能调用 `/migration_complete` 时造成 block 泄漏。

Phase 2.B 通过 `DYNAMO_RL_CONNECTOR_ENABLED=1`（环境变量，默认关闭）启用。
当任何前提条件缺失（无 KVBM、无 NIXL 坐标）时，`migrate_out` 回退到立即终止
（Phase 2.A 行为），`/migration_complete` 变为无害的空操作。

### 5.5 成本收益门控

```python
MigrationPolicy(
    max_replay_tokens   = 8192,   # recompute prefill too expensive
    min_generated_tokens= 16,     # too young to benefit
    min_remaining_tokens= 32,     # would finish faster than migrate
)
# connector_enabled 通过 DYNAMO_RL_CONNECTOR_ENABLED 环境变量控制
```

`migrate_in` 在调度重放**之前**运行门控检查。被拒绝的请求响应 `{status: "declined", reason: "..."}`。S3 测试通过一个合成的 9000 token body 明确验证此行为并观察到：

```
{"status": "declined",
 "reason": "replay_total=9050 exceeds max_replay_tokens=8192
            (recompute prefill too expensive)",
 "request_id": "synthetic-overbudget"}
```

注意：门控运行在接收端，因此在通配符迁移场景下，门控触发时源端已经**中止了其副本**。这是正确行为，因为源端的意图是排空——拒绝目标端的重放并不撤销该意图。（对于合成测试，我们手动构造 body，因此不会发生源端中止。）

### 5.6 进程内注册表——`request_id="*"` 的工作原理

decoder 侧维护一个 `InProcessRequestRegistry`，由请求处理器在三个时间点更新（[handlers.py L1255-1350](../../dynamo/components/src/dynamo/vllm/handlers.py)）：

```
generate(prompt, sampling_params, request_id, ...):
    registry.register(request_id, prompt_token_ids, sp_dict)   # on submit
    async for delta in engine.generate(...):
        registry.record_tokens(request_id, delta.token_ids)     # streaming
    finally:
        registry.deregister(request_id)                         # done/abort
```

这就是通配符迁移的工作原理：`migrate_out` 调用 `tracker.list_active_request_ids()` -> `_pick_most_progressed(ids)`，后者拉取每个条目的 `len(generated_tokens)` 并选择最大的那个。选择进度最远的条目可以最大化每次迁移调用的"已保存工作量"。

`GET /v1/active_requests` 直接返回此列表（目前不含 `generated_tokens`；仅返回 ID），让 operator/controller 可以驱动自定义排空循环：

```bash
while [[ $(curl -s .../v1/active_requests | jq length) -gt 0 ]]; do
   r=$(curl -s -X POST .../migrate_out -d '{"request_id":"*"}')
   curl -s -X POST <peer>/migrate_in -d "$r"
done
# now safe to /switch_role or kubectl delete pod
```

---

## 6. 端到端正确性——测试证明了什么 (End-to-End Correctness)

### 6.1 S2 端到端流程

```
   t = 0     pre-state                         CR.model_cards = 1   ✓
   t = 5s    /switch_role -> prefill           CR.model_cards = 0   ✓ (PASS_CR_D2P)
                                               server 230 ms
   t = 7s    30 chat probes                    target hits = 0/30   ✓ (PASS_PROBE)
                                               peer hits = 30/30
   t = 27s   /switch_role -> decode            CR.model_cards = 1   ✓ (PASS_CR_P2D)
                                               server 480 ms
   t = 29s   30 chat probes                    target hits = 19/30  ✓ (PASS_PROBE)
                                               peer hits = 11/30
   throughout: 2 RPS sustained load            57/57 = 100% 200 OK  ✓ (PASS_LOAD)
                                               p99 = 0.585 s
```

### 6.2 S3 端到端流程

```
   t=0  T0_pre snapshot                        TGT runs 0,  PEER 0
   t=1  submit 24 streaming chats max=3500
   t=9  T1 snapshot                            TGT runs 5,  PEER 5
                                               TGT gen_tot 41002, PEER 42775
   t=10 migrate_out / migrate_in #1            ok, recompute, replay=1726
   t=11 migrate_out / migrate_in #2            ok, recompute, replay=1933
   t=11 migrate_out / migrate_in #3            ok, recompute, replay=2190
   t=12 TGT now drained                        TGT runs 0   ✓ (PASS_GPU_RELEASE)
                                               peer continued advancing
   t=14 T2 snapshot                            TGT 0, PEER 0
   t=14 synthetic 9k-token migrate_in          status=declined ✓ (PASS_DECLINE)
   t=16 T3 drained snapshot                    PEER gen_tot 44710  ✓ (PASS_DST_TAKEOVER)
                                               (Δ = 1935 vs TGT Δ = 1077)
```

### 6.3 尚未测试的内容

- **在真实排空工作流中组合 S3 后执行 S2**：手动序列可以工作，但我们没有单个测试执行"通过 S3 排空 -> 通过 S2 切换 -> 验证零 token 丢失"。这应该在后续集成测试中完成。
- **Phase-2.B（NIXL 拉取）**：三阶段 block-hold 协议已实现，并在 S3 测试中
  得到验证（当 KVBM 不可用时回退到 recompute；详见 S3 文档 §5）。
- **多节点**：所有测量均为单主机回环；多节点 K8s 会按比例增加 `register_mdc` 和 HTTP RTT 开销。

---

## 7. 运行不变量和故障模式 (Operational Invariants and Failure Modes)

| 不变量 | 如何保证 |
|-----------|-------------------|
| 每个 pod 只有一个 DWMD 写入者 | DWMD 名称 == pod 名称；仅 pod 内的 runtime 调用 `apply_cr`。 |
| ModelCard 撤回先于引擎休眠效果影响路由 | `unregister_mdc` 是步骤 2，在 `reset_prefix_cache`/`wake` 之前。 |
| prefix cache 不会从已释放的 block 提供服务 | `reset_prefix_cache` 是步骤 4，在 `sleep` 和 `wake` 之间。 |
| migrate_out 对每个请求最多执行一次 | `tracker.abort_request` 是同步的；Phase 2.A 中响应返回前注册表条目已被移除；Phase 2.B 中请求保持在 `_pending_migrations` 中直到 `/migration_complete`。 |
| migrate_in 不会复活源端仍持有的请求 | Phase 2.A：源端在返回前已中止。Phase 2.B：源端持有 block 直到 `/migration_complete`；请求存活但不再产生新 token。 |
| 成本收益门控绝不静默丢弃工作 | `migrate_in` 返回带原因的 `status=declined`；operator/controller **必须**将 declined 视为"让请求在原地完成"（注意：仅当 migrate_out 调用是真实的而非合成的时，源端才已中止）。 |
| 重复调用切换具有幂等性 | `switch_role` 重新读取 `current_role`；切换到相同角色是一个空操作，除了无操作的 register/unregister kube apply。 |

故障模式：
- **kube-apiserver 响应慢** -> `register_mdc` 步骤膨胀；切换的其余部分不受影响。前端的 watcher 只是晚些看到新状态。不会有流量到达仍在休眠的引擎，因为步骤 2 中的 unregister 已经完成。
- **NATS 分区** -> `kv_metrics` 事件停止，但路由成员关系（CR 驱动）不受影响。KvRouter 回退到最后已知的指标，继续遵循 WorkerSet。
- **Sidecar 在切换过程中崩溃** -> 每个 worker 的异步锁是进程内的，因此崩溃会使引擎处于休眠状态且旧角色的 ModelCard 已被移除。Pod 重启时重新运行初始注册，恢复 decode 角色的 ModelCard。无需清理 CR——新 pod 的 CR 有新的 `instance_id`。

---

## 8. 代码阅读顺序（新工程师指南）(Code Reading Order)

1. [components/src/dynamo/vllm/main.py](../../dynamo/components/src/dynamo/vllm/main.py)
   §dual-mode init（L820-870, L1108-1145）——了解 `DualModeWorker`、`MigrationHandler`、`VllmReregistrar`、`InProcessRequestRegistry` 如何接入 worker。
2. [components/src/dynamo/vllm/dual_mode.py](../../dynamo/components/src/dynamo/vllm/dual_mode.py)
   `switch_role`——八步编排的完整流程。
3. [components/src/dynamo/vllm/handlers.py](../../dynamo/components/src/dynamo/vllm/handlers.py)
   §sleep/wake_up（L353-427）和 §generate registry hooks（L1255-L1350）。
4. [components/src/dynamo/vllm/migration.py](../../dynamo/components/src/dynamo/vllm/migration.py)
   `migrate_out` / `migrate_in` / `_should_migrate` / `_pick_most_progressed`。
5. [components/src/dynamo/vllm/rl_scaling_sidecar.py](../../dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py)
   `build_app`——`:9091` 上的 HTTP 接口形态。
6. [lib/runtime/src/discovery/kube.rs](../../dynamo/lib/runtime/src/discovery/kube.rs)
   `register_endpoint` / `unregister_endpoint` / `apply_cr`。
7. [test-scripts/test-s2-elastic.sh](../test-scripts/test-s2-elastic.sh)
   和 [test-scripts/test-s3-consolidation.sh](../test-scripts/test-s3-consolidation.sh)
   ——可复现的 E2E 测试。

---

## 9. 术语表 (Glossary)

| 术语 | 含义 |
|------|---------|
| DWMD | `DynamoWorkerMetadata` CR；每个 pod 的运行时注册记录。 |
| ModelCard | DWMD `.spec.data.model_cards` 中的 `card_json` blob。其存在 == "此 pod 在此 endpoint 上提供此模型服务"。 |
| KVBM | KV Block Manager；追踪 vLLM block 所有权以便通过 NIXL 导出。 |
| NIXL | NVIDIA 的 RDMA 式块传输协议，由 NixlConnector 使用。 |
| `kv_role=kv_both` | vLLM 引擎配置，为 prefill（发送方）和 decode（接收方）两种角色预构建 NIXL 状态。 |
| `instance_id` | 14 字符十六进制；每进程随机 ID。Pod 重启时变更。 |
| Phase 2.A / 2.B | 重计算 prefill（安全路径）与 NIXL 拉取（门控路径）的迁移方案。 |
| 成本收益门控 | `MigrationPolicy` 中在 `migrate_in._should_migrate` 内检查的阈值。 |

---

*— 完 —*
