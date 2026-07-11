# 四场景一致性策略 E2E 测试

入口脚本：

```bash
python test-scripts/run_four_scenario_strategy_e2e.py
```

## 前置条件

- controller 和 Dynamo worker 镜像必须已经通过 CI/CD 构建并由自动化部署到目标 Kubernetes 集群。
- 正式测试脚本只负责场景配置、拓扑 reset、request 发送和数据采集；不使用本地 source overlay，不手工 patch 镜像内容。
- Dynamic 场景必须先从 1P1D warmup 到 2P2D，并确认 Ready 后，才开始 measured batch request。
- Scale-up / Signal-to-Ready / Burst Safety Margin 单独记录，不计入 Serving Wall Time。

## 场景

| 场景 | 策略 | 目标 |
|---|---|---|
| `baseline_minimal` | 固定 1P1D，禁用 S1/S2/S3 | 大 workload 下的资源受限慢基线 |
| `s2_only` | warmup 到 2P2D，只启用 S2 | 验证受控 PD switch 和 prefill phase 效果 |
| `s3_only` | warmup 到 2P2D，只启用 S3 | 验证 tail consolidation、drain、GPU-second savings |
| `mixed_strategy` | warmup 到 2P2D，启用 S2+S3 | 验证 prefill peak + decode tail 的组合收益 |

## Workload

脚本生成并复用同一份 `workload-manifest.jsonl`：

- `prefill_burst`：80 个长 prompt、短输出 request，用于观察 S2 D->P 后的 prefill wall 改善。
- `balanced_decode`：32 个中等 prompt、中等输出 request，用于过渡到 decode pressure，限制 S2 不发生频繁切换。
- `decode_tail`：18 个长尾 request，用于观察 S3 migration/drain 和 tail GPU-second savings。

## 质量门

正式性能结论必须满足：

- `valid_decode_pct >= 99%`
- `timeout_count == 0`
- `http_5xx_count == 0`
- S2 场景中 `s2_executed_count <= 2`
- S2 only 中 S3 必须为 0
- S3 only 中 S2 必须为 0

如果质量门失败，脚本仍保留原始数据，但该 run 的 `performance_valid=false`，不能用于正向性能结论。

## S2 判定

S2 不是高频调度测试。每个 run 只允许 1-2 次阶段性 PD switch。

判定顺序：

1. `s2_executed_count > 0`
2. `s2_executed_count <= 2`
3. 质量门通过
4. `s2_only.prefill_wall_s < baseline_minimal.prefill_wall_s`
5. 报告 overall wall time 与 tokens/GPU-second 变化

## S3 判定

S3 的主指标是 tail GPU allocated time：

```text
tail_decode_gpu_s_counterfactual = decode_tail.wall_s * 2
tail_decode_gpu_s_saved = counterfactual - observed_tail_decode_gpu_s
tail_decode_gpu_s_savings_pct = saved / counterfactual
```

判定顺序：

1. migration/drain 证据可见
2. drain 后 scale-down 或 release 证据可见
3. 质量门通过
4. tail decode GPU-second savings 为正
5. 报告 wall time 是否有改善或小幅代价

## 输出目录

```text
test-scripts/reports/strategy-four-scenario-YYYYMMDD-HHMMSS/
  workload-manifest.jsonl
  readiness_gate/
  baseline_minimal/run-01/
  s2_only/run-01/
  s3_only/run-01/
  mixed_strategy/run-01/
  progress.json
  suite-aggregate.json
  suite-goal-analysis.json
  REPORT-zh.md
```

每个 `run-01` 包含：

- `requests.csv`
- `responses/`
- `pod_samples.csv`
- `controller_status.jsonl`
- `events.csv`
- `summary.json`
- `REPORT-zh.md`
- `logs/`

## 常用命令

完整四场景：

```bash
python test-scripts/run_four_scenario_strategy_e2e.py --repeats 1
```

只补跑某个场景并复用既有 manifest：

```bash
python test-scripts/run_four_scenario_strategy_e2e.py \
  --suite-dir test-scripts/reports/strategy-four-scenario-YYYYMMDD-HHMMSS \
  --scenarios mixed_strategy \
  --repeats 1 \
  --skip-readiness-gate
```

查看长任务进度：

```bash
type test-scripts\reports\strategy-four-scenario-YYYYMMDD-HHMMSS\progress.json
```
