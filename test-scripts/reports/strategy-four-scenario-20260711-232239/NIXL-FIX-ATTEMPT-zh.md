# NIXL connector 修复尝试与决定性结论（2026-07-11）

本文记录按用户要求「尝试修 disaggregate KV NIXL connector，让切回后正确释放已传输 KV block、不再触发 timeout」所做的实现、部署、测试，以及**决定性结论：tail 超时的真正根因是 receive 侧，不是 send 侧的 block 泄漏**，因此该修复不能消除 timeout。

## 1. 实现的修复

worker 侧（`dynamo/components/src/dynamo/vllm/dual_mode.py`，commit `3fc3e8f`）：

- 在每次 role switch 前，通过 `AsyncLLM.collective_rpc` 在引擎 worker 内运行一个 cloudpickled 回调，把 NIXL connector 的 `_reqs_to_send`（prefill 角色遗留、等待 decode 拉取的待发送 KV）全部 expire 到「现在」，使下一次 `get_finished()` 把它们上报为 finished-sending，从而让 scheduler 释放这些 block。
- 需要 `VLLM_ALLOW_INSECURE_SERIALIZATION=1` 才能让 collective_rpc 序列化该回调（已加入 DGD decode worker env）。第一次运行缺此 env，flush 静默失败（`Object of type function is not serializable`）；加上后 flush 正常执行。

## 2. 决定性测试数据（本轮 s2_only，flush 已生效）

worker 日志：

```text
[DualMode] flush_kv_connector: expired pending sends -> [{'ok': True, 'expired': 0}]   # D->P
[DualMode] reconfig_kv_pool(prefill): reset_prefix_cache result=True
[DualMode] flush_kv_connector: expired pending sends -> [{'ok': True, 'expired': 2}]   # P->D
[DualMode] reconfig_kv_pool(decode): reset_prefix_cache result=False
```

s2_only 结果：`timeout=4`（全部 `max_tokens=48` tail_long），tail=252s，prefill=147.7s（S2 prefill 收益依旧 ~50%）。

## 3. 结论：根因在 receive 侧，不是 send 侧

1. **flush 确实生效**（P->D 时 expired=2），但**只有 2 个待发送请求**，远不是之前 `reset_prefix_cache` 报的「~2773 blocks not freed」。说明那几千个被 pin 的 block **不是** `_reqs_to_send` 持有的——send 侧根本没有那么多泄漏。
2. **reset_prefix_cache 仍 False、tail 仍 4 个 timeout**：flush 掉 send 侧后，超时数量**完全没变**。
3. 结合此前证据——挂起的 tail 请求 `Running: 0, Waiting: 1-3`、`GPU KV cache usage ~0%`（cache 几乎是空的）——可确定：**decode 请求不是缺 block，而是在等它的 prefill KV 从 prefill worker 传过来（disagg receive），而这次 receive 挂住了**。切回后的 decode worker 无法与 prefill worker 建立/恢复 NIXL receive 握手，导致 receive 永远不完成，请求等到 120s client timeout。

因此 send 侧 flush（用户要求的「释放已传输 KV block」）在语义上是对的、也已实现并验证生效，但它**修的是 send 侧的 block 释放，而 timeout 的真正原因是 receive 侧握手/路由挂起**，两者不同。所以该修复**不能消除 tail timeout**。

## 4. 真正需要的修复（更深的 vLLM 改动）

要消除切回后的 tail timeout，需要在 **vLLM NixlConnector / Dynamo disagg 层**修复 role 切换后的 **receive 侧状态**：

- 切回 decode 后，重新初始化/重建该 worker 与当前 prefill workers 之间的 NIXL receive 握手（`_recving_metadata`、`_recving_transfers`、handshake metadata、xfer handles 等），使它能作为新的 decode consumer 正常接收 KV；
- 或在 role 切换时让 connector 完整 re-handshake（等价于「换 KV role 时重建传输拓扑」）。

这是引擎级、跨 send/receive 的深度改动，且 `NixlConnector.reset_cache()` 在本版本是 no-op、没有现成 API 触发 receive 侧重建，风险高、需专门验证。同时注意：s3_only（无切换）本就有 ~1 个同类 tail timeout，说明**动态 2P2D 的 disagg receive 在长尾请求上本身也不稳定**，切回只是把它从 ~1 放大到 4。二者同源，都在 disagg receive 层。

## 5. 保留与现状

- send 侧 flush 作为正确的 switch 清理逻辑保留（commit `3fc3e8f`，DGD 加 `VLLM_ALLOW_INSECURE_SERIALIZATION=1`）。
- S2 prefill capacity 收益依旧成立且可复现（~50%）。
- decode_tail timeout 与 S3 无法触发的根因，均归结为上面的 disagg receive 层问题，需 vLLM 侧修复。
