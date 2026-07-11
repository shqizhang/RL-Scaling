# 2026-07-10 active-gated 测试复盘

本轮目标是按 `docs/test-strategy.md` 的修正原则重新收集四场景数据：遇到 timeout 立即停止，避免让 timeout 主导 wall time；同时为 S3 增加 decode worker `/v1/active_requests` 快照，避免只凭 controller attempt 解释 Request Consolidation。

## 已完成的脚本修正

1. S3 tail 触发从固定 `sleep(1s)` 改为 active-window polling：
   - 测试期间轮询每个 Ready decode pod 的 sidecar `/v1/active_requests`。
   - 快照保存为 `active_requests_snapshots.jsonl`。
   - 只有看到 active request 后才发送 `progress=0.92` 的 tail consolidation signal。
2. 增加 timeout hard gate：
   - 任一 phase 出现 timeout，当前 run 保存 requests/events/pod samples/logs/summary 后停止。
   - suite 不继续跑后续场景，避免污染对比数据。
3. S2 P->D 后增加 decode readiness probe：
   - `decode_pressure_signal` 后等待并执行 frontend chat readiness probe，再进入 measured decode window。
4. S3 `MIN_BATCH_COMPLETION` 从 `0.60` 提高到 `0.92`：
   - 避免 warmup signal `progress=0.85` 在 measured tail 前提前触发 consolidation/scale-down。
5. Tail workload 中 `tail_long` 的 `max_tokens` 从 64 降到 48：
   - 先前两轮均显示 `manifest_id=130,max_tokens=64` 是 dynamic tail timeout 污染源。

## 可用数据

### Baseline minimal

目录：`../strategy-four-scenario-20260710-active-gated-v2/baseline_minimal/run-01`

- 130/130 request valid decode。
- `timeout_count=0`，`http_5xx_count=0`。
- overall wall time: `83.46s`。
- prefill wall time: `49.77s`。
- balanced decode wall time: `14.88s`。
- decode tail wall time: `18.13s`。

该 baseline 可作为 1P1D minimal baseline。

### S2 only 的部分有效数据

目录：`../strategy-four-scenario-20260710-active-gated-v2/s2_only/run-01`

- S2 动作发生且受控：
  - `decode->prefill`: `432.52ms`
  - `prefill->decode`: `612.63ms`
  - total executed count: `2`
- prefill phase:
  - 80/80 valid decode
  - `timeout_count=0`
  - prefill wall: `48.81s`
  - 相比 baseline `49.77s` 有约 `1.91%` 改善
- balanced decode:
  - 32/32 valid decode
  - `timeout_count=0`
  - wall: `13.67s`

但 S2 run 不能作为完整端到端性能结论，因为 decode tail 出现 3 个 timeout：

- timeout request: `manifest_id=128,129,130`
- shape: `tail_long`
- max_tokens: `48`
- 每个 timeout 约 `120s`

结论：S2 机制和 prefill/前段 decode 数据可用；S2 full-batch wall time 不可用。

## S3 诊断结果

目录：`strategy-four-scenario-20260710-s3-threshold-fix/s3_only/run-01`

修正 `MIN_BATCH_COMPLETION=0.92` 后：

- prefill phase: 80/80 valid decode，`timeout_count=0`。
- balanced decode: 32/32 valid decode，`timeout_count=0`，`http_5xx_count=0`。
- S3 未触发：
  - `s3_history_count=0`
  - `s3_migration_attempts=0`
  - `s3_migrated_requests=0`
  - `s3_drained_sources=[]`
- tail active snapshots 始终没有看到 active request：
  - `active_worker_count=0`
  - `total_active=0`

同时 decode tail 仍有 1 个 timeout：

- timeout request: `manifest_id=130`
- shape: `tail_long`
- max_tokens: `48`

这说明当前 OpenAI chat request path 下，decode worker sidecar `/v1/active_requests` 不能稳定暴露 tail active request。对应代码边界是 `DecodeWorkerHandler._generate_text_mode()` 直接调用 `engine_client.generate()`，没有走 `generate_tokens()` 中的 request registry register/record/deregister 逻辑。因此 controller 无法基于真实 active request 做 S3 tail consolidation。

结论：本轮不能得到 S3 performance evidence。S3 当前仍停留在机制/sidecar 能力已存在，但正式 OpenAI chat workload 下 controller-triggered consolidation 缺少 active request registry 支撑。

## 为什么没有继续跑 mixed_strategy

`mixed_strategy` 同时依赖 S2 和 S3：

- S2 tail 已稳定出现 timeout。
- S3 在 chat path 下没有 active request snapshot，无法触发 migration/drain。

继续跑 mixed 只会产生不可归因的 timeout/wall time 数据，不符合本轮测试策略的 hard gate。

## 下一步修复建议

1. 修复 Dynamo text mode request registry：
   - 在 `_generate_text_mode()` 中注册 request。
   - 将 TextPrompt tokenized prompt 或 input token ids 写入 registry。
   - 在 streaming loop 中记录 generated token ids。
   - finally 中 deregister。
2. 扩展 `/v1/active_requests`：
   - 不只返回 id，还返回 `generated_tokens_count`、`max_tokens`、`remaining_tokens`、`sampling_params`、request age。
3. S3 trigger 只允许在 tail active-window 触发：
   - 保持 `MIN_BATCH_COMPLETION >= 0.92`。
   - 禁止 warmup signal 触发 migration/scale-down。
4. 单独补一个 same-topology disabled baseline：
   - 2P2D disabled baseline，用于 S3 tail GPU-second counterfactual。
5. 修复后再跑：
   - baseline_minimal
   - baseline_2p2d_disabled
   - s2_only
   - s3_only
   - mixed_strategy

本轮已有数据可以用于说明：S2 switch 开销在约 400-600ms，S2 prefill phase 有轻微改善；但 S2/S3 完整端到端性能提升尚未通过质量门，不能作为最终效能结论。
