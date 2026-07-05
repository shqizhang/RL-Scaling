# 最终论文 E2E 测试说明

入口脚本：

```bash
python test-scripts/final-thesis-autoscaling-suite-e2e.py
```

## 场景

脚本使用同一份 `workload-manifest.jsonl` 依次运行：

- `baseline_minimal`：1P1D，禁用 S1/S2/S3。
- `baseline_static`：2P2D，禁用 S1/S2/S3，作为静态扩容对照。
- `s2_only`：1P3D，只启用 S2 PD Role Switch。
- `s3_only`：2P2D，只启用 S3 Request Consolidation 和 drain-gated scale down。
- `mixed_strategy`：1P1D 起步，发送 trainer signal warmup 到 2P2D，再启用 S1/S2/S3 自动策略。

## 公平性原则

- 所有场景使用相同请求数量、phase 顺序、prompt 长度、`max_tokens` 和并发度。
- `Preparation Time` 与 `Serving Wall Time` 分开记录。
- 只有 controller history 中真实执行的 S2/S3 动作才可作为对应策略收益来源。
- 每个场景保留 `requests.csv`、`responses/`、`pod_samples.csv`、`controller_status.jsonl`、`events.csv` 和 `logs/`。

## 单场景补跑

```bash
python test-scripts/final-thesis-autoscaling-suite-e2e.py \
  --suite-dir test-scripts/reports/final-thesis-autoscaling-YYYYMMDD-HHMMSS \
  --scenarios s3_only
```

补跑时会复用同一目录下已有的 `workload-manifest.jsonl`，保证对比维度一致。
