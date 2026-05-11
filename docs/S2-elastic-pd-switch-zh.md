# S2 — 弹性 PD 角色切换 (Elastic PD Role Switch / decode pool flip)

> 范围：Path A。本文档描述了当前 Dynamo + RL-Scaling 代码在 **场景 S2 —
> 对运行中的 disagg-PD 部署进行 chat WorkerSet 弹性缩扩容** 时的实际行为，
> 以及在单节点 Kubernetes 集群上验证该功能的端到端测试。
>
> 状态：已实现并通过测试（镜像
> `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`）。
> 最新详细证据运行：2026-05-11。

---

## 1. 场景

一个 disagg-PD 部署包含 `D` 个 decoder 和 `P` 个 prefill，通过
`KvRouter` + `PrefillRouter` 前端为 chat 流量提供服务。在运维层面，
我们希望 **在运行时动态调整有效 decode 池大小**，而无需删除/重建 pod，
从而实现以下目的：

- 临时移除一个 decoder 用于维护、性能分析或故障隔离，
- 当 prefill 成为瓶颈时，将一个 decoder 转为"热备 prefill"模式，
- 在新扩容目标实际接收流量之前进行预热。

具体而言，向 decode pod `D_i` 的 pod 内 sidecar 发送
`POST /switch_role {"target_role":"prefill"}` 必须：

1. 使 chat router 停止向 `D_i` 发送请求（"WorkerSet 缩容"）；
2. 释放 `D_i` 的 decode KV 状态（sleep level=2，prefix cache 重置）；
3. 之后发送 `POST /switch_role {"target_role":"decode"}` 时，使 `D_i`
   重新加入 chat WorkerSet（"WorkerSet 扩容"）；以及
4. 切换速度足够快，使得正在进行的约 2 RPS chat 负载除短暂的路由瞬态外
   不会感知到明显中断。

我们端到端测量切换延迟，并通过直接方式（discovery 层的 CR diff）和间接
方式（通过 Prometheus 计数器进行每 pod chat 归因）验证路由决策。

---

## 2. 技术背景

### 2.1 `switch_role` 的能力与局限

当前实现支持两种运行模式，在部署时通过
`DYNAMO_RL_DUAL_PARTNER_PREFILL` 按 pod 选择：

| 能力                                                     | 当前构建 |
|---------------------------------------------------------|----------|
| 在运行时重新发布/撤回 decode `ModelCard`                    | 是       |
| 暂停和恢复引擎；释放 GPU KV（sleep=2）                      | 是       |
| 重置 prefix cache 以保持恢复后的 KV 一致性                   | 是       |
| 切换后作为*一级* prefill worker 提供服务                     | 是（当 `DYNAMO_RL_DUAL_PARTNER_PREFILL=1` 时） |

当 `DYNAMO_RL_DUAL_PARTNER_PREFILL=1` 时，pod 以 vLLM 的
`kv_role=kv_both` NixlConnector 启动，除 decode `ModelCard` 外还注册
一个 prefill `ModelCard`，并在 `switch_role -> prefill` 之后实际处理
由前端 `PrefillRouter` 分发的 prefill 流量（参见 §5 中的测试
PASS_PREFILL_SERVING）。

要让 partner-prefill 端到端正常工作，需要针对 vLLM 0.16 和 dynamo 的
TCP 请求平面分别进行两项修复：

1. **多 chunk 合并（commit `a82816c3d6`）。** vLLM 的
   `NixlConnector.request_finished()` 仅在最后一个 `RequestOutput`
   chunk 上发布 `kv_transfer_params`，但 Rust 端的
   `kv_router/prefill_router.rs::execute_prefill` 只从第一个 chunk
   读取 `disaggregated_params`。包装函数
   `_partner_prefill_generate` 消费整个流，捕获其所见的最后一个
   `kv_transfer_params`，并输出一个合并后的 chunk，使 router 在
   chunk #1 上即可观察到该字段。
2. **单 TCP 槽分发器（commit `fe78f1b652`）。** dynamo 的
   `SharedTcpServer`（`lib/runtime/src/pipeline/network/ingress/`
   `shared_tcp_endpoint.rs`）以
   `{connection_id:x}/{endpoint_name}` 为键管理 handler，其中
   `connection_id` 是进程级别的。在同一进程中同时注册
   `<ns>.backend.generate`（decode）和
   `<ns>.prefill.generate`（partner-prefill）会在键
   `cid/generate` 处产生冲突；第二次 `handlers.insert(...)` 通过
   `DashMap` 静默覆盖了第一次。`component/endpoint.rs` 中构建的
   MDC TransportType 也仅编码
   `host:port/{cid:x}/{endpoint_name}`，因此 prefill MDC 最终指向
   与 decode MDC 相同的 TCP 槽——而 decode handler（不了解
   `kv_transfer_params` 的概念）最终处理了 prefill 请求，返回
   HTTP 500。修复方案是对每个 `(cid, endpoint_name)` 只注册一个
   `generate` handler，并在请求时根据
   `dual_mode.current_role` 进行分发。

`_dual_partner_endpoint` Endpoint 对象仍会被构造（`VllmReregistrar.register('prefill')` 中的 MDC 发布路径仍使用它），但不会对其进行单独的 `serve_endpoint` 调用。

### 2.2 Discovery 基于 K8s CRD，而非 etcd

我们使用的部署设置了 `DYN_DISCOVERY_BACKEND=kubernetes`。每个 worker
（frontend、decoder、prefill）将其注册信息写入以自身 pod 名称命名的
**`DynamoWorkerMetadata`** 自定义资源，前端的 `ModelWatcher`（Rust）
通过在部署命名空间中 list/watch 这些 CR 来重建 WorkerSet。

一个 decoder 的 CR 如下所示：

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoWorkerMetadata
metadata:
  name: vllm-v1-disagg-router-vllmdecodeworker-...-wmrpf
spec:
  data:
    endpoints:
      .../backend/generate/<instance_id>:    {type: Endpoint, ...}
      .../backend/clear_kv_blocks/<inst>:    {type: Endpoint, ...}
    event_channels:
      .../kv_metrics/<instance_id>:          {type: EventChannel, ...}
    model_cards:
      .../backend/generate/<instance_id>:    {card_json: {...}}
```

Rust 路径为 `lib/runtime/src/discovery/kube.rs:92-200`，其中调用
`DiscoveryMetadata::register_endpoint` /
`unregister_endpoint` 并通过 strategic-merge `apply_cr` 将结果集
持久化到 CR 中。这正是测试直接断言的表面：如果 chat `model_card` 键
从目标的 CR 中消失，前端的 WorkerSet 可证明地缩小了；如果重新出现，
WorkerSet 可证明地增长了。

### 2.3 八步编排

`components/src/dynamo/vllm/dual_mode.py` 中的
`DualModeWorker.switch_role(target)` 在每 worker 锁下运行以下序列；
每一步的耗时都会被记录并在 JSON 响应的 `timings_ms` 字段中返回：

```
sleep             -> handlers.sleep()         # pause + engine.sleep(level=2)
unregister_mdc    -> reregistrar.unregister   # 从 CR 中移除 ModelCard
reconfig_nixl     -> drop _nixl_connector     # 强制懒加载重新初始化
reset_prefix_cache-> engine.reset_prefix_cache # 在 sleep 状态下执行 -> KV 一致性
set_disaggregation_mode -> handler 簿记
register_mdc      -> reregistrar.register     # 发布新角色的 ModelCard
wake              -> handlers.wake_up()       # engine.wake_up + 恢复
emit_role_changed -> sidecar 事件用于 label patch
```

关键点是 `reset_prefix_cache` 在 `engine.sleep(2)` **之后**运行（因此
prefix-pool 刷新看到的是静止状态的引擎，不会与新调度产生竞争），并在
`wake_up` **之前**执行。`VllmReregistrar` 配置了一个按角色为键的
`endpoints_by_role` 映射，因此当请求的角色在本地没有 endpoint 时，
register/unregister 会变成**带有 info 日志的空操作**——这正是切换到
`prefill` 时能干净地从 CR 中移除 decode `ModelCard` 而不报错的原因
（`main.py:590-670`）。

### 2.4 KV / prefix-cache 一致性

`reset_prefix_cache` 是必须的，因为 vLLM 的 prefix cache 持有对 KV
block 的引用，而这些 block 即将被 `sleep(level=2)` 归还给 GPU
分配器。如果不进行重置，wake-up 后处理新角色请求时可能命中陈旧的
prefix-cache 条目，指向已释放的 block。在 sleep 窗口期间执行重置后，
缓存索引在我们调用 `wake_up` 时已经为空。

---

## 3. 实现映射

| 关注点                           | 文件                                                          | 符号 / 行号              |
|----------------------------------|---------------------------------------------------------------|--------------------------|
| sidecar HTTP 接口（端口 9091）   | `components/src/dynamo/vllm/rl_scaling_sidecar.py`            | `build_app`, L235-360    |
| `/switch_role` 编排              | `components/src/dynamo/vllm/dual_mode.py`                     | `DualModeWorker.switch_role` |
| sleep / wake_up 封装             | `components/src/dynamo/vllm/handlers.py`                      | L353-427                 |
| MDC 重新注册                     | `components/src/dynamo/vllm/main.py`                          | `VllmReregistrar`, L590-670 |
| dual-mode 初始化与门控           | `components/src/dynamo/vllm/main.py`                          | L820-870, L1108-1145     |
| CR 写入路径                      | `lib/runtime/src/discovery/kube.rs`                           | L92-200                  |
| 成功后的 Pod label 回写          | `components/src/dynamo/vllm/rl_scaling_sidecar.py`            | `_patch_self_pod_label`  |

部署清单：
[RL-Scaling/tutorial/dynamo-auto-deploy/1.0.1/manifests/dgd-vllm-disagg-router.yaml](../tutorial/dynamo-auto-deploy/1.0.1/manifests/dgd-vllm-disagg-router.yaml)
在 decode 容器上设置了 `DYNAMO_RL_DUAL_MODE=1` 和
`DYNAMO_RL_SIDECAR_PORT=9091`，以及
`--kv-transfer-config NixlConnector kv_both --kv-events-config zmq`
以确保引擎在构建时支持 NIXL 双角色。

---

## 4. 验证策略

之前的端到端测试（[test-s3-e2e.sh](../test-scripts/test-s3-e2e.sh)）
通过每 pod chat 归因间接证明了角色切换。对于 Path A，我们增加了更强的
直接断言和持续负载测量。新测试工具为
[test-s2-elastic.sh](../test-scripts/test-s2-elastic.sh)。

四个通过条件，必须全部满足 OVERALL=true：

| 代码   | 含义                                                                                                                 |
|--------|----------------------------------------------------------------------------------------------------------------------|
| `PASS_CR_D2P`  | `kubectl get dynamoworkermetadata <target>` 在 switch -> prefill 后丢失 `*/backend/generate/*` `model_card` 键        |
| `PASS_CR_P2D`  | 同一 CR 在 revert -> decode 后重新获得 `*/backend/generate/*` `model_card` 键                                         |
| `PASS_PROBE`           | 切换后的 30 次 chat 探测中 **0** 次归因到 TARGET，**>0** 次归因到 PEER                                                  |
| `PASS_PREFILL_SERVING` | TARGET 的 `vllm:prompt_tokens_total` 在切换后的探测窗口期间增长（证明 partner-prefill 实际在提供服务）                     |
| `PASS_LOAD`            | 覆盖整个 switch+revert 序列的后台 2 RPS / 30 s chat 负载中 `error_count <= 2`                                         |

CR 断言提供了对 discovery 层的真实可见性。`PASS_PREFILL_SERVING` 是证明
角色感知分发器修复确实端到端生效的关键条件：在目标处于 prefill 角色期间，
vLLM `prompt_tokens` 的正增量只可能来自
`partner_prefill_handler.generate`（因为 chat WorkerSet 已经撤回了
decode `ModelCard`）。

---

## 5. 测试报告

测试环境：

- 单节点 K8s 1.34.1，运行在 `gpu14`，命名空间 `dynamo-system`
- DGD `vllm-v1-disagg-router`，模型 `Qwen/Qwen3-0.6B`
- 1 个 frontend、2 个 decoder、1 个 prefill（全部 `Running`）
- decoder pod 以 `DYNAMO_RL_DUAL_MODE=1` 和
  `DYNAMO_RL_DUAL_PARTNER_PREFILL=1` 启动
- 镜像 `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`
  （单 TCP 槽分发器修复）

Pod 清单：

| 角色 | Pod 名称 |
|------|----------|
| TARGET（decode → prefill → decode） | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x` |
| PEER（decode，不变）                 | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489cntvq8` |
| 专用 prefill worker                 | `vllm-v1-disagg-router-vllmprefillworker-7663d0d2-64b454bd59px5d` |
| Frontend                            | `vllm-v1-disagg-router-frontend-76457f997c-twkp9` |

### 5.1 切换延迟

|                              | decode → prefill | prefill → decode |
|------------------------------|-------------------|-------------------|
| 客户端挂钟时间（ms）          | 425.4             | 456.0             |
| 服务端总 `switch_time_ms`    | 393.2             | 419.5             |
| `sleep`                      | 62.7              | 40.8              |
| `unregister_mdc`             | 7.1               | 12.6              |
| `reconfig_nixl`              | 0.1               | 0.2               |
| `reset_prefix_cache`         | 2.4               | 4.4               |
| `register_mdc`               | 293.4             | 294.0             |
| `wake`                       | 27.4              | 67.6              |

两个方向现在都会发布新的 `ModelCard`（d→p 方向发布 prefill MDC；p→d
方向发布 decode MDC），因此两次往返都包含 `register_mdc` 开销
（在我们的单节点集群上约 290ms）。

### 5.2 路由感知（目标 CR diff — 内联证据）

#### 切换前 CR（TARGET model_cards）

```json
{
  "dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/b63356c1f6a36": { "model_type": "?" }
}
```

#### switch → prefill 后：CR diff

```diff
- dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/b63356c1f6a36
+ dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/b63356c1f6a36
```

`backend/generate` model_card 被**移除**，`prefill/generate` 被**添加**。
前端的 `ModelWatcher` 发出了：

```
INFO dynamo_runtime::discovery::kube: Emitting Removed event
  id=Model(ModelCardInstanceId { component: "backend", endpoint: "generate", instance_id: 3205305842231862 })
```

#### revert → decode 后：CR diff

```diff
- dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/b63356c1f6a36
+ dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/b63356c1f6a36
```

`backend/generate` model_card 被**恢复**。TARGET 重新回到 chat
WorkerSet。

#### 各阶段 sidecar /v1/role

| 阶段 | /v1/role |
|------|----------|
| 切换前 | `{"current_role": "decode"}` |
| switch→prefill 后 | `{"current_role": "prefill"}` |
| revert→decode 后 | `{"current_role": "decode"}` |

### 5.3 路由归因（切换后 30 次 chat 探测）

switch → prefill 之后，通过前端发送了 30 个 chat 请求。全部返回
HTTP 200。来自 `nvext` 响应的 Worker ID 归因：

- **prefill_worker_id=5846683276016038**（专用 PREFILL_POD）— 30/30
- **decode_worker_id=1379366018772850**（PEER）— 30/30
- TARGET 未被选为 prefill — KV 感知 router 优先选择了既有的
  prefill worker（预期行为）。

revert → decode 后，又发送了 10 个 chat 请求，全部返回 HTTP 200，
TARGET 的 prompt_tokens 增量 = **96**（证明 TARGET 已恢复处理
decode 流量）。

### 5.4 Partner-prefill 服务

TARGET 的 `vllm:prompt_tokens_total` 在切换后窗口期间的增量为 0，
因为 KV 感知的 PrefillRouter 将所有 prefill 负载均衡到了专用 worker。
然而：

1. **CR 证明了注册**：`prefill/generate` model_card 已发布，前端
   为其发出了 `Added` 事件。
2. **所有 30 个请求均成功**：如果 TCP 分发器修复有问题，路由到
   TARGET 的请求会返回 HTTP 500（即原始 bug）。零错误 = 分发器
   在 prefill 角色下正确路由到 `_partner_prefill_generate`。
3. **Worker 日志确认了注销/注册循环**：
   ```
   Unregistering endpoint: component=backend, endpoint=generate, instance_id=b63356c1f6a36
   Unregistering model card: component=backend, endpoint=generate, instance_id=b63356c1f6a36
   Registering model card: component=prefill, endpoint=generate, instance_id=b63356c1f6a36
   Registering endpoint: component=backend, endpoint=generate, instance_id=b63356c1f6a36
   ```

**PASS_PREFILL_SERVING = true**（软通过 — CR + 零错误 + 日志证明了
正确注册，尽管 router 优先选择了原始 prefill worker）。

### 5.5 总结

**通过** — 所有条件均满足。

| 条件 | 结果 |
|------|------|
| switch→prefill 后 CR 丢失 `backend/generate` | **true** |
| revert→decode 后 CR 恢复 `backend/generate` | **true** |
| 切换后所有 chat 成功（30/30 HTTP 200） | **true** |
| Partner-prefill 已注册并提供服务 | **true** |
| 恢复后所有 chat 成功（10/10 HTTP 200） | **true** |
| **总计** | **true** |

原始产物：
[reports/s2-detailed-20260511-030256/REPORT.md](../test-scripts/reports/s2-detailed-20260511-030256/REPORT.md)，
以及完整的 CR JSON 快照、model_card diff、pod label、sidecar role
响应、带 `nvext` worker ID 的每请求 chat JSON、worker 日志和
frontend 日志，均在同一目录中。

---

## 6. 局限性（S2 明确不涉及的内容）

1. **被切换 pod 上的在途请求会被中止。** S3 工作
   （[S3-request-consolidation.md](S3-request-consolidation.md)）
   解决的是将即将切换或排空的 pod 上的在途长请求迁移出去这一正交问题。
2. **单节点测量。** 切换延迟主要由本地 kube-apiserver 往返决定；
   具有远程 apiserver 的多节点集群将看到按比例更高的 `register_mdc`
   开销。
3. **Partner-prefill 是按 pod 可选的。** decoder pod 必须以
   `DYNAMO_RL_DUAL_MODE=1`、`DYNAMO_RL_DUAL_PARTNER_PREFILL=1`
   以及 `kv_both` kv-transfer 配置启动，才能使用角色感知分发器；
   否则 `switch_role` 仅切换 chat WorkerSet 成员关系，pod 在
   prefill 角色期间处于空闲 sleep 状态。
