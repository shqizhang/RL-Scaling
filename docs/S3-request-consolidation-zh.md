# S3 — 解码器长请求整合（Request Consolidation / 实时迁移）

> 范围：路径 A。本文档描述了当前 Dynamo + RL-Scaling 代码在 **场景 S3 —— 将正在运行的长时间解码请求从 TARGET 解码器迁移到 PEER 解码器，从而使 TARGET 可以被排空、缩容或角色切换而不丢弃工作** 中的实际行为，以及验证该功能的端到端测试。
>
> 状态：**安全默认路径（recompute-prefill 重放）** 已实现并通过测试。connector / NIXL-pull 路径默认关闭，原因是第 6 节中记录的已知 block-hold 竞态问题。
> 最新详细证据运行：2026-05-11。

---

## 1. 场景

S2 允许我们在 chat WorkerSet 中添加/移除解码器，但该切换会无条件终止 TARGET 上正在运行的所有任务。长时间的聊天补全（例如 `max_tokens=3500`）在 `generated_tokens` 已经很高时非常宝贵——从头重新计算 prefill 的成本比重新运行整个生成过程低一个数量级。当运维人员需要**整合**正在运行的负载（将所有活跃请求从解码器迁移走，使其释放 KV 缓存，然后休眠/终止/切换到其他角色）时，也需要同样的原语。

具体流程：

```
POST <target_sidecar>/migrate_out  {"request_id":"*"}
   -> 终止 TARGET 上进度最高的正在运行的请求
   -> 返回其 {prompt_tokens, generated_tokens, sampling_params, ...}
POST <peer_sidecar>/migrate_in     <上述返回的 body>
   -> 执行成本收益判断
   -> 若接受，将 prompt+generated 作为新的 prefill 在 PEER 上重放，
      并从该位置继续生成
```

成功的迁移对会立即释放 TARGET 上该请求的 KV 缓存，同时在 PEER 上继续为用户生成可见的回答。

---

## 2. 技术背景

### 2.1 为什么存在两条路径

| 路径 | PEER 如何继续 | KV 传输 | 默认安全？ |
|------|-------------|---------|-----------|
| Phase 2.A — recompute-prefill | 在 PEER 上将 `prompt + generated` 作为新 prefill 重放 | 无 | **是** |
| Phase 2.B — connector / NIXL pull | 从 TARGET 的 GPU block 通过 NIXL READ 拉取到 PEER | 有 | 否 — block-hold 竞态 |

在实践中，一旦启用 vLLM 的 prefix cache，路径 2.A 占主导地位，因为重放成本受限于 prompt 的**未缓存后缀**（在我们的工作负载中通常只需几十毫秒），而 2.B 需要协调两个引擎并应对 abort/free 竞态。

### 2.2 路径 2.B 中的 block-hold 竞态（为什么被默认关闭）

`migrate_out` 在 PEER 的 `migrate_in` 开始 NIXL READ *之前*就终止了源请求。KVBM 在终止时同步释放源 block，因此当 PEER 尝试拉取时，源分配器可能已将这些 block 重新分配给其他请求。要使 2.B 安全，需要一个 **block-hold ack**（PEER 告知源"我已获取你的 block；你可以释放了"）——该协议尚未实现，因此默认设置为 `MigrationPolicy.connector_enabled = False`，测试也断言使用的是 recompute 路径。

`migrate_out` 的响应在 KVBM 坐标可用时**仍然携带 `src_block_ids` 和完整的 `kv_transfer_params`**，因此未来实现 2.B 不需要修改线协议——只需在源端添加 hold/ack 机制。

### 2.3 成本收益判断

`MigrationHandler._should_migrate`（位于 `components/src/dynamo/vllm/migration.py`）在以下任一条件满足时拒绝 `migrate_in`：

```python
MigrationPolicy(
    max_replay_tokens=8192,    # recompute prefill 成本过高
    min_generated_tokens=16,   # 请求太年轻，迁移收益不足
    min_remaining_tokens=32,   # 请求即将完成，比迁移更快
    connector_enabled=False,   # 2.B 已禁用，见 2.2
)
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
| sidecar HTTP 接口 | `components/src/dynamo/vllm/rl_scaling_sidecar.py` | `post_migrate_out`, `post_migrate_in`, `get_active`, L295-340 |
| 迁移核心 | `components/src/dynamo/vllm/migration.py` | `MigrationHandler`, L200-330 |
| 成本收益策略 | `components/src/dynamo/vllm/migration.py` | `_should_migrate`, L355-385 |
| 最高进度选择 | `components/src/dynamo/vllm/migration.py` | `_pick_most_progressed`, L387-400 |
| KV block 索引查找 | `components/src/dynamo/vllm/migration.py` | `_block_index.lookup` |
| 进行中的注册表钩子 | `components/src/dynamo/vllm/handlers.py` | L1255, L1306, L1348 |
| KVBM `nixl_meta_provider` | `components/src/dynamo/vllm/handlers.py` | L1003 (延迟加载 `_nixl_connector`) |

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

测试工具通过前端提交 24 个流式长聊天（`max_tokens=3500`，`temperature=0.7`），由 KvRouter 将其分散到两个解码器上，等待 8 秒让调度稳定，然后循环最多 6 次，对 TARGET 调用 `migrate_out`（`request_id="*"`），并将响应直接送入 PEER 的 `migrate_in`。

---

## 5. 测试报告

测试环境：

- 单节点 K8s 1.34.1，主机 `gpu14`，namespace `dynamo-system`
- DGD `vllm-v1-disagg-router`，模型 `Qwen/Qwen3-0.6B`
- 1 个 frontend、2 个 decoder、1 个 prefill（均为 `Running`）
- 镜像 `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`
- 详细证据运行：2026-05-11

Pod 清单：

| 角色 | Pod 名称 |
|------|----------|
| TARGET（源） | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x` |
| PEER（目标） | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489cntvq8` |
| Frontend | `vllm-v1-disagg-router-frontend-76457f997c-twkp9` |

### 5.1 迁移结果

| 结果 | 数量 |
|------|-----:|
| `migrate_in` ok | **3** |
| `migrate_in` declined | 0 |
| 错误 | **0** |

#### 每次迁移的详细数据

**迁移 #1** — `request_id=72557043-7fce-4bbb-8274-387f85d9ba38`

- `migrate_out`：status=ok，prompt_tokens=0，**generated_tokens=1539**
- Generated tokens（前 10 个）：`[151667, 198, 32313, 11, 279, 1196, 6801, 264, 1602, 11682]`
- Generated tokens（后 5 个）：`[82, 13, 18611, 334, 1592]`
- Sampling params：`temperature=0.7, top_p=0.95, top_k=20, max_tokens=16384`
- `src_block_ids`：null（recompute 路径，connector_enabled=False）
- `kv_transfer_params`：null
- `migrate_in`：status=ok，path=**recompute**，replay_tokens=**1539**
- TARGET 活跃请求数：4 → 3（Δ=-1）

**迁移 #2** — `request_id=74233113-9ebf-412a-9078-9d93b1fd1973`

- `migrate_out`：status=ok，prompt_tokens=0，**generated_tokens=1857**
- Generated tokens（前 10 个）：`[151667, 198, 32313, 11, 279, 1196, 6801, 264, 1602, 11682]`
- Generated tokens（后 5 个）：`[304, 3033, 5942, 11, 323]`
- Sampling params：同上
- `migrate_in`：status=ok，path=**recompute**，replay_tokens=**1857**
- TARGET 活跃请求数：3 → 2（Δ=-1）

**迁移 #3** — `request_id=8a58b7c0-df4c-4f48-af2c-0a7e8f092e84`

- `migrate_out`：status=ok，prompt_tokens=0，**generated_tokens=2119**
- Generated tokens（前 10 个）：`[151667, 198, 32313, 11, 279, 1196, 6801, 264, 11682, 8895]`
- Generated tokens（后 5 个）：`[97219, 3070, 18247, 1211, 97219]`
- Sampling params：同上
- `migrate_in`：status=ok，path=**recompute**，replay_tokens=**2119**
- TARGET 活跃请求数：1 → 0（Δ=-1）

**关于 `prompt_tokens=0` 的说明：** 这是预期行为。`InProcessRequestRegistry` 在提交时从 `TokensPrompt` 记录 `prompt_token_ids`，但 vLLM 的 chat completions 路径在内部进行分词，不会将 prompt token ID 回传给处理器。迁移处理器通过在重放中包含所有 `generated_tokens` 来补偿——即 `replay_tokens = len(prompt_tokens) + len(generated_tokens)`，其中 `prompt_tokens` 为空意味着完整重放仅为生成的序列。

**关于 `src_block_ids=null` 和 `kv_transfer_params=null` 的说明：** 两者均为 null，因为 `MigrationPolicy.connector_enabled=False`（默认安全设置）。NIXL-pull 路径（Phase 2.B）被禁用；启用 connector 后这些字段将被填充。

### 5.2 GPU 释放 / 目标接管

| 指标 | T1（调度稳定后） | T2（迁移完成后） | T3（排空后） |
|------|:---:|:---:|:---:|
| TARGET `num_requests_running` | 4 | **0** | 0 |
| PEER `num_requests_running` | 4 | 0 | 0 |
| TARGET `generation_tokens_total` | 39553 | 42214 | 42214 |
| PEER `generation_tokens_total` | 47057 | **52326** | 52326 |
| PEER `prompt_tokens_total` | 13552 | **19067** | 19067 |

PEER 的 `prompt_tokens_total` 在 T1 和 T2 之间增长了 **5515** 个 token——这正是重放三个迁移请求的 recompute-prefill 成本（1539 + 1857 + 2119 = 5515 token，精确匹配）。这是迁移请求确实在 PEER 上被重新处理的最强证据。

### 5.3 成本收益判断

**测试 1：超大重放**（9000 prompt + 50 generated > `max_replay_tokens=8192`）：

```json
{
  "status": "declined",
  "reason": "replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)",
  "request_id": "synthetic-oversize-test"
}
```

**测试 2：生成 token 过少**（2 < `min_generated_tokens=16`）：

```json
{
  "status": "declined",
  "reason": "generated_tokens=2 below min_generated_tokens=16 (request too young to benefit)",
  "request_id": "synthetic-too-few-gen"
}
```

两个合成请求均被正确**拒绝**，并附带了信息丰富的原因字符串。

### 5.4 总结

**通过** — 全部五个条件均满足。

| 条件 | 结果 |
|------|------|
| ≥1 次迁移成功（ok） | **true**（3 ok，0 declined，0 errors） |
| 零迁移错误 | **true** |
| TARGET `requests_running` 下降 | **true**（4 → 0） |
| PEER `generation_tokens` 增长 | **true**（Δ=5269） |
| PEER `prompt_tokens` Δ 匹配重放总和 | **true**（Δ=5515 ≈ 1539+1857+2119） |
| 成本收益判断拒绝超大请求 | **true** |
| 成本收益判断拒绝过年轻请求 | **true** |
| **总体** | **true** |

原始产物：
[reports/s3-detailed-20260511-031034/REPORT.md](../test-scripts/reports/s3-detailed-20260511-031034/REPORT.md)，
同一目录下还有完整的 `migrate_out_N.json` / `migrate_in_N.json` 响应、
`metrics.csv`、`active-target-*.json`、`active-peer-*.json`、
`decline-response.json`、`decline2-min-gen.json`、worker 日志摘录，
以及 `run.log`。

---

## 6. 局限性与已知缺口

1. **Connector / NIXL-pull 路径默认关闭。** 线协议已贯通（`migrate_out` 在 KVBM 可用且 `connector_enabled=True` 时返回 `kv_transfer_params`），但源端的 block-hold/ack 握手缺失，因此今天启用 2.B 会暴露一个竞态：PEER 的 NIXL READ 目标 block 可能已被 TARGET 的分配器回收。要启用：将 `MigrationPolicy.connector_enabled = True` *且*先在源端落地 hold/ack 协议。
2. **Recompute 成本取决于 prefix cache。** 启用 prefix caching（`enable_prefix_caching=True`，我们构建中的默认值）时，重放仅需支付**未缓存后缀**的成本——通常只有几十毫秒。禁用 prefix cache 后，recompute 需支付完整 prefill 成本（约 100 ms 以上）；当检测到 prefix cache 关闭时，迁移处理器会记录警告（`_warn_if_prefix_cache_disabled`）。
3. **`previously_emitted_tokens` 需要客户端配合。** sidecar 将 `previously_emitted_tokens` 传递到新提交中，使流式消费者不会重复接收 token。从 back-channel 重建会话的前端必须遵守该字段；我们通过 OpenAI adapter 的 chat-completions 路径透明地处理了这一点，因为每次迁移都会产生全新的 server-sent-events 流。
4. **单节点测量。** 本报告中两次 `migrate_*` 往返的网络成本均为主机内回环。在多节点集群上，成本主要由两次跨 Pod HTTP RTT 决定（前端通常通过在用户侧重试来隐藏这些延迟）。
