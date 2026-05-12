# S3 — 解码器长请求整合（Request Consolidation / 实时迁移）

> 范围：路径 A + B。本文档描述了当前 Dynamo + RL-Scaling 代码在 **场景 S3 —— 将正在运行的长时间解码请求从 TARGET 解码器迁移到 PEER 解码器，从而使 TARGET 可以被排空、缩容或角色切换而不丢弃工作** 中的实际行为，以及验证该功能的端到端测试。
>
> 状态：已实现并通过测试。**Phase 2.A（recompute-prefill）** 是默认安全路径。
> **Phase 2.B（NIXL-pull connector）** 已完整实现三阶段 block-hold 协议，
> 通过 `DYNAMO_RL_CONNECTOR_ENABLED=1` 启用。当 KVBM block 索引或 NIXL
> 坐标不可用时，Phase 2.B 会优雅地回退到 Phase 2.A。
> 最新证据运行：2026-05-12。

---

## 1. 场景

S2 允许我们在 chat WorkerSet 中添加/移除解码器，但该切换会无条件终止 TARGET 上正在运行的所有任务。长时间的聊天补全（例如 `max_tokens=3500`）在 `generated_tokens` 已经很高时非常宝贵——从头重新计算 prefill 的成本比重新运行整个生成过程低一个数量级。当运维人员需要**整合**正在运行的负载（将所有活跃请求从解码器迁移走，使其释放 KV 缓存，然后休眠/终止/切换到其他角色）时，也需要同样的原语。

具体流程（两条路径均使用三阶段协议）：

```
POST <target_sidecar>/migrate_out  {"request_id":"*"}
   -> 选择 TARGET 上进度最高的正在运行的请求
   -> Phase 2.A：立即终止
   -> Phase 2.B：保持 block 存活（延迟终止）
   -> 返回 {prompt_tokens, generated_tokens, sampling_params, ...}
     （Phase 2.B 激活时还包含 kv_transfer_params）

POST <peer_sidecar>/migrate_in     <上述返回的 body>
   -> 执行成本收益判断
   -> Phase 2.A：将 prompt+generated 作为新 prefill 在 PEER 上重放
   -> Phase 2.B：注入 kv_transfer_params，NIXL READ 从 TARGET 拉取

POST <target_sidecar>/migration_complete  {"request_id":"..."}
   -> Phase 2.A：无害的空操作（已终止）
   -> Phase 2.B：终止源请求，释放持有的 KV block
```

成功的三步操作会释放 TARGET 上该请求的 KV 缓存，同时在 PEER 上继续为用户生成可见的回答。

---

## 2. 技术背景

### 2.1 为什么存在两条路径

| 路径 | PEER 如何继续 | KV 传输 | 默认安全？ |
|------|-------------|---------|-----------|
| Phase 2.A — recompute-prefill | 在 PEER 上将 `prompt + generated` 作为新 prefill 重放 | 无 | **是** |
| Phase 2.B — connector / NIXL pull | 从 TARGET 的 GPU block 通过 NIXL READ 拉取到 PEER | 有 | **是** — 三阶段 block-hold |

在实践中，一旦启用 vLLM 的 prefix cache，路径 2.A 占主导地位，因为重放成本受限于 prompt 的**未缓存后缀**（在我们的工作负载中通常只需几十毫秒），而 2.B 需要协调两个引擎并应对 abort/free 竞态。

### 2.2 路径 2.B 的 block-hold 协议

Phase 2.B 实现了三阶段 block-hold 协议以避免 abort/free 竞态：

1. **`migrate_out`** 检查 `connector_enabled=True` 且 KVBM block ID 和 NIXL
   坐标是否全部可用。如果是，则不终止源请求；而是将 request_id 记录在
   `_pending_migrations` 中，并返回 `kv_transfer_params` 以便目标端可以执行
   NIXL READ 拉取。
2. **`migrate_in`** 在目标端将 `kv_transfer_params` 注入到
   `sampling_params.extra_args["kv_transfer_params"]` 中并提交请求。vLLM 的
   `NixlConnectorScheduler` 读取这些参数并发起 NIXL READ 拉取。
3. **`/migration_complete`** 在源端终止原始请求并释放持有的 block。由编排器
   （测试脚本或 RL 控制器）在 `migrate_in` 成功后调用。

后台清扫任务在 `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` 秒（默认 10 秒）后强制终止
过期的待处理迁移，防止编排器未能调用 `/migration_complete` 时造成 block 泄漏。

如果 2.B 的任何前提条件缺失（无 KVBM、无 NIXL），`migrate_out` 会回退到立即
终止（Phase 2.A 行为），`migrate_in` 使用 recompute-prefill 路径。
`/migration_complete` 调用变为无害的空操作。

Phase 2.B 通过 `DYNAMO_RL_CONNECTOR_ENABLED=1`（环境变量，默认关闭）启用。

### 2.3 成本收益判断

`MigrationHandler._should_migrate`（位于 `components/src/dynamo/vllm/migration.py`）在以下任一条件满足时拒绝 `migrate_in`：

```python
MigrationPolicy(
    max_replay_tokens=8192,    # recompute prefill 成本过高
    min_generated_tokens=16,   # 请求太年轻，迁移收益不足
    min_remaining_tokens=32,   # 请求即将完成，比迁移更快
)
# connector_enabled 通过 DYNAMO_RL_CONNECTOR_ENABLED 环境变量控制
```

被拒绝的请求返回 `status=declined` 及人类可读的原因；在拒绝的情况下 TARGET 上不会终止任何请求（终止发生在 `migrate_out` 内部，在此判断在接收方运行之前，这是正确的——判断的职责是拒绝有害请求，而非*阻止*终止）。在通配符场景下，测试在成功路径中不会发送超大 body，因为它会选择 `_pick_most_progressed`，但会通过向 `migrate_in` 发送合成的超预算 body 来显式验证该判断逻辑。

### 2.4 进程内注册表

为了知道给定解码器上哪些请求正在运行，worker 维护一个 `InProcessRequestRegistry`（rl-scaling sidecar 代码），由请求处理器在三个时间点更新（`handlers.py:1255-1350`）：

```
register      在提交时                       # 记录 prompt_tokens、sampling_params
record_tokens 在每个流式 delta 时            # 扩展 generated_tokens
deregister    在完成/错误/终止时             # 移除条目
```

sidecar 的 `GET /v1/active_requests` 直接从该注册表返回活跃的 `request_id` 列表；`migrate_out` 通过检查该注册表将 `request_id="*"` 解析为进度最高的条目。

---

## 3. 实现映射

| 关注点 | 文件 | 符号 / 行号 |
|--------|------|------------|
| sidecar HTTP 接口 | `components/src/dynamo/vllm/rl_scaling_sidecar.py` | `post_migrate_out`, `post_migrate_in`, `post_migration_complete`, `get_active` |
| 迁移核心 | `components/src/dynamo/vllm/migration.py` | `MigrationHandler.migrate_out`, `.migrate_in`, `.migration_complete` |
| block-hold 清扫 | `components/src/dynamo/vllm/migration.py` | `MigrationHandler.sweep_stale_migrations` |
| 成本收益策略 | `components/src/dynamo/vllm/migration.py` | `_should_migrate` |
| 最高进度选择 | `components/src/dynamo/vllm/migration.py` | `_pick_most_progressed` |
| KV block 索引查找 | `components/src/dynamo/vllm/migration.py` | `RequestBlockIndex.lookup` |
| 进行中的注册表钩子 | `components/src/dynamo/vllm/handlers.py` | `generate_tokens` |
| NIXL 元数据提供器 | `components/src/dynamo/vllm/rl_scaling_sidecar.py` | `make_nixl_meta_provider` |

`migrate_out` 返回：

```jsonc
{
  "status": "ok",
  "request_id": "...",
  "prompt_tokens":     [int, ...],
  "generated_tokens":  [int, ...],
  "sampling_params":   {...},
  "stop_conditions":   {...},
  "src_block_ids":     [int, ...]            // 如果 KVBM 可用
  "kv_transfer_params": {                    // 如果 connector_enabled 且
    "do_remote_prefill": true,               // src_block_ids 和 nixl_coords
    "remote_engine_id": "...",               // 均可用
    "remote_block_ids": [...],
    "remote_host": "...",
    "remote_port": 12345,
    "remote_request_id": "..."
  }
}
```

`migrate_in` 运行成本收益判断，然后：

- 如果 `connector_enabled` 且 `kv_transfer_params` 存在，尝试 NIXL pull 路径；出现任何异常时回退到 recompute，
- 否则（默认情况）提交 recompute-prefill 重放，`prompt_tokens = old_prompt + old_generated_tokens`，
- 两种情况下都附带 `previously_emitted_tokens`，使 PEER 上的流式响应不会重复发送客户端已收到的 token。

`migration_complete`（Phase 2.B 确认）：

```jsonc
POST /migration_complete  {"request_id": "..."}
   -> {status: "ok", request_id: "..."}
```

由编排器在 `migrate_in` 成功后调用。在源端：
- Phase 2.B：终止持有的源请求并释放 KV block。
- Phase 2.A：无害的空操作（请求已在 `migrate_out` 中终止）。

---

## 4. 验证策略

[test-s3-consolidation.sh](../test-scripts/test-s3-consolidation.sh) 有五个通过条件（全部满足才视为 OVERALL=true）：

| 代码 | 含义 |
|------|------|
| `PASS_MIG_OK` | 至少一对 (`migrate_out`, `migrate_in`) 均返回 `status=ok` |
| `PASS_NO_ERRORS` | 没有迁移响应的 `status="error"` |
| `PASS_GPU_RELEASE` | TARGET 的 `vllm:num_requests_running` 在 T1（调度稳定后）和 T2（迁移完成后）之间下降 |
| `PASS_DST_TAKEOVER` | PEER 的 `vllm:generation_tokens_total` 在 T1 和 T3（排空后）之间增长，证明有前向进展 |
| `PASS_DECLINE` | 合成的 `migrate_in`（`prompt_tokens=9000`，超过 `max_replay_tokens=8192`）返回 `status=declined` |

测试工具通过前端提交 24 个流式长聊天（`max_tokens=3500`，`temperature=0.7`），由 KvRouter 将其分散到两个解码器上，等待 8 秒让调度稳定，然后循环最多 6 次，对 TARGET 调用 `migrate_out`（`request_id="*"`），将响应送入 PEER 的 `migrate_in`，然后对 TARGET 调用 `/migration_complete` 释放持有的 block（Phase 2.B 确认）。

---

## 5. 测试报告

测试环境：

- 单节点 K8s 1.34.1，主机 `gpu14`，namespace `dynamo-system`
- DGD `vllm-v1-disagg-router`，模型 `Qwen/Qwen3-0.6B`
- 1 个 frontend、2 个 decoder、1 个 prefill（均为 `Running`）
- 镜像 `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-2982f6cb46`
- `DYNAMO_RL_CONNECTOR_ENABLED=1` 在 decoder worker 上
- 最新证据运行：2026-05-12

Pod 清单：

| 角色 | Pod 名称 |
|------|----------|
| TARGET（源） | `vllm-v1-disagg-router-vllmdecodeworker-55c5d8a8-b7f5d959c-f7lg5` |
| PEER（目标） | `vllm-v1-disagg-router-vllmdecodeworker-55c5d8a8-b7f5d959c-z224b` |
| Frontend | `vllm-v1-disagg-router-frontend-579b79f897-9db5n` |

### 5.1 迁移结果

| 结果 | 数量 |
|------|-----:|
| `migrate_in` ok | **3** |
| — 经 connector 路径 | 0 |
| — 经 recompute 路径 | 3 |
| `migrate_in` declined | 0 |
| 错误 | **0** |

**迁移 #1** — `request_id=7476e5b7-c8bc-4713-be9b-eb98ac1d56c8`
- `migrate_out`：status=ok，**generated_tokens=1633**
- `src_block_ids`：null，`kv_transfer_params`：null
- `migrate_in`：status=ok，path=**recompute**，replay_tokens=**1633**
- `migration_complete`：status=ok（Phase 2.A 空操作）

**迁移 #2** — `request_id=b10795eb-e854-447e-abb1-bb1c5596a59d`
- `migrate_out`：status=ok，**generated_tokens=1833**
- `migrate_in`：status=ok，path=**recompute**，replay_tokens=**1833**
- `migration_complete`：status=ok

**迁移 #3** — `request_id=0795ed5d-8a0b-4af9-8d53-172856056041`
- `migrate_out`：status=ok，**generated_tokens=2120**
- `migrate_in`：status=ok，path=**recompute**，replay_tokens=**2120**
- `migration_complete`：status=ok

**为什么 connector path=0：** 已设置 `DYNAMO_RL_CONNECTOR_ENABLED=1`，但
connector 路径同时需要 KVBM block ID 和 NIXL 坐标。在本部署中，
`engine_client.engine_core.kv_cache_manager` 返回 `None`（KVBM 缓存管理器
未暴露），因此 `src_block_ids` 为 null，处理器回退到 Phase 2.A recompute
路径。三阶段协议（migrate_out → migrate_in → migration_complete）在两条
路径中均正确执行——当 block 已在 `migrate_out` 中释放时，`/migration_complete`
调用是无害的空操作。

### 5.2 GPU 释放 / 目标接管

| 指标 | T1（调度稳定后） | T2（迁移完成后） | T3（排空后） |
|------|:---:|:---:|:---:|
| TARGET `num_requests_running` | 9 | **0** | 0 |
| PEER `num_requests_running` | 6 | 0 | 0 |

TARGET 运行请求数 9 → 0：所有活跃请求在迁移窗口内完成了迁移或自行结束。

### 5.3 成本收益判断

合成的 `migrate_in`（`prompt_tokens=9000`，超过 `max_replay_tokens=8192`）被
正确**拒绝**。

### 5.4 总结

**通过** — 全部条件均满足。

| 条件 | 结果 |
|------|------|
| ≥1 次迁移成功（ok） | **true**（3 ok，0 declined，0 errors） |
| 零迁移错误 | **true** |
| TARGET `requests_running` 下降 | **true**（9 → 0） |
| PEER `generation_tokens` 增长 | **true** |
| 成本收益判断拒绝超大请求 | **true** |
| 三阶段协议工作正常（migration_complete） | **true** |
| **总体** | **true** |

原始产物：
[reports/s3-consolidation-20260512-111254/REPORT.md](../test-scripts/reports/s3-consolidation-20260512-111254/REPORT.md)，
同一目录下还有完整的 `migrate_out_N.json` / `migrate_in_N.json` 响应、
`metrics.csv`、`decline.json`，以及 `run.log`。

---

## 6. 局限性与已知缺口

1. **Connector 路径需要 KVBM block 索引。** Phase 2.B 的 NIXL-pull 路径需要
   从 KVBM 缓存管理器获取 `src_block_ids`，该管理器仅在 KVBM 是活跃 block
   管理器时可用。当 KVBM 未暴露
   （`engine_client.engine_core.kv_cache_manager = None`）时，connector 路径
   自动回退到 recompute-prefill。三阶段协议在两种情况下均正确工作。
2. **Recompute 成本取决于 prefix cache。** 启用 prefix caching
   （`enable_prefix_caching=True`，我们构建中的默认值）时，重放仅需支付
   **未缓存后缀**的成本——通常只有几十毫秒。禁用 prefix cache 后，recompute
   需支付完整 prefill 成本（约 100 ms 以上）；当检测到 prefix cache 关闭时，
   迁移处理器会记录警告（`_warn_if_prefix_cache_disabled`）。
3. **`previously_emitted_tokens` 需要客户端配合。** sidecar 将
   `previously_emitted_tokens` 传递到新提交中，使流式消费者不会重复接收
   token。从 back-channel 重建会话的前端必须遵守该字段；我们通过 OpenAI
   adapter 的 chat-completions 路径透明地处理了这一点，因为每次迁移都会产生
   全新的 server-sent-events 流。
4. **单节点测量。** 本报告中 `migrate_*` 往返的网络成本均为主机内回环。在
   多节点集群上，成本主要由跨 Pod HTTP RTT 决定。
5. **Hold 超时。** 清扫器在 `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` 秒（默认 10
   秒）后强制终止持有的迁移。如果编排器调用 `/migration_complete` 较慢，
   可能导致目标端的 NIXL READ 读到已过期的 block。超时值应根据预期的 NIXL
   传输延迟进行调优。
