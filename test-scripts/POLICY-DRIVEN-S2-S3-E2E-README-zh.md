# RL-Scaling S2/S3 端到端 Timing 与吞吐测试说明

本文档对应脚本 `test-policy-driven-s2-s3-e2e.sh`，用于完成 baseline 与 strategy 两组端到端实验，并产出请求处理时长、Pod 级吞吐、策略触发事件和日志证据。

## 1. 需求重新梳理

这次端到端测试要回答两个问题。

第一，在不触发 S1/S2/S3 策略的 baseline 情况下，当前 Decoder/Prefill 拓扑处理一批真实 frontend 请求需要多久，每个 Pod 的 prompt/generation token throughput 是多少。

第二，在开启策略后，使用同样形态的 workload 重新测试，记录整体处理时长和吞吐变化，并明确记录什么时候触发了 S2 Role Switch、什么时候触发了 S3 Request Consolidation，以及对应 sidecar/controller/worker 日志。

测试必须记录以下结果：

| 类型 | 记录内容 | 输出文件 |
|------|----------|----------|
| 全链路处理时长 | 从 frontend 提交请求批次到全部请求完成的 wall time | `<scenario>/summary.json`, `REPORT.md` |
| 单请求耗时 | 每个请求的 start/end timestamp、HTTP code、curl total time、TTFT | `<scenario>/requests.csv` |
| Pod 级吞吐 | 每个 Pod 的 prompt token delta、generation token delta、tokens/s、running request 峰值 | `<scenario>/pod_metrics.csv`, `<scenario>/pod_throughput.csv` |
| 策略触发 | Role Switch 与 Request Consolidation 的触发时间、目标 Pod、返回值、client wall time | `<scenario>/strategy_events.jsonl` |
| 日志证据 | controller、worker 日志和策略关键字摘录 | `<scenario>/logs/`, `<scenario>/strategy-log-excerpts.txt` |
| 场景报告 | 每个 scenario 的 timing、吞吐、事件和产物索引 | `<scenario>/REPORT.md` |
| 对比结果 | baseline vs strategy 的 wall time、req/s、token/s、p95 latency 对比 | `comparison.csv`, `REPORT.md` |

## 2. 当前实现边界

当前代码库已经具备 worker-side S2/S3 能力：

- S2 通过 decode worker sidecar 的 `/switch_role` 执行 `decode -> prefill`。
- S3 通过 source decode worker sidecar 的 `/migrate` 执行 request consolidation。
- vLLM `/metrics` 暴露 prompt/generation token counter 和 running request 指标。

但 controller 主循环当前仍主要体现 S1 rollout-driven scaling，S2/S3 策略自动闭环是否已经接入部署，需要以实际 controller 镜像和日志为准。因此脚本提供两种 strategy driver：

| Driver | 用途 |
|--------|------|
| `STRATEGY_DRIVER=sidecar` | 默认模式。脚本在 workload 运行中主动调用 sidecar，验证当前 worker-side 机制对 E2E timing/throughput 的影响。 |
| `STRATEGY_DRIVER=auto` | 观测模式。脚本不主动调用 sidecar，只采集指标和日志，用于验证已部署 controller 是否自动触发 S2/S3。 |
| `STRATEGY_DRIVER=none` | 不触发动作，用于被动观测。 |

## 3. 运行方式

默认运行 baseline 与 strategy，并生成对比报告：

```bash
bash RL-Scaling/test-scripts/test-policy-driven-s2-s3-e2e.sh
```

只运行 baseline：

```bash
MODE=baseline bash RL-Scaling/test-scripts/test-policy-driven-s2-s3-e2e.sh
```

使用 sidecar 驱动策略动作：

```bash
MODE=strategy STRATEGY_DRIVER=sidecar \
  bash RL-Scaling/test-scripts/test-policy-driven-s2-s3-e2e.sh
```

只观察 controller 自动触发：

```bash
MODE=strategy STRATEGY_DRIVER=auto \
  bash RL-Scaling/test-scripts/test-policy-driven-s2-s3-e2e.sh
```

如果要做严格 baseline，请先确保部署侧没有自动触发策略，例如关闭 controller 中的 `ROLE_SWITCH_ENABLED` 和 `CONSOLIDATION_ENABLED`，或者在未运行 S2/S3 policy loop 的环境中执行 baseline。

## 4. 常用参数

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `NS` | `dynamo-system` | Kubernetes namespace |
| `DGD` | `vllm-v1-disagg-router` | DynamoGraphDeployment 名称 |
| `MODEL` | `Qwen/Qwen3-0.6B` | OpenAI chat completion model name |
| `MODE` | `both` | `baseline`、`strategy` 或 `both` |
| `STRATEGY_DRIVER` | `sidecar` | `sidecar`、`auto` 或 `none` |
| `N_REQ` | `48` | 每组 scenario 的请求数 |
| `CONCURRENCY` | `8` | 并发请求数 |
| `MAX_TOKENS` | `768` | 每个请求最大生成 token 数 |
| `PROMPT_WORDS` | `120` | prompt 长度，用于制造 prefill 压力 |
| `SAMPLE_INTERVAL` | `1` | Pod metrics 采样间隔，单位秒 |
| `ROLE_SWITCH_DELAY` | `8` | strategy workload 开始后多久触发 Role Switch |
| `CONSOLIDATION_DELAY` | `20` | strategy workload 开始后多久触发 Consolidation |
| `MIG_LOOPS` | `4` | Request Consolidation 尝试次数 |
| `CONTROLLER_LABEL` | `app=rl-scaling-controller` | 抓取 controller 日志的 label |

## 5. 输出目录

脚本输出到：

```text
RL-Scaling/test-scripts/reports/policy-e2e-<timestamp>/
```

核心文件：

```text
REPORT.md
comparison.csv
topology.csv
experiment_config.csv
baseline/
  REPORT.md
  requests.csv
  pod_metrics.csv
  pod_throughput.csv
  summary.json
  event_timeline.csv
  logs/
strategy/
  REPORT.md
  requests.csv
  pod_metrics.csv
  pod_throughput.csv
  summary.json
  event_timeline.csv
  strategy_events.jsonl
  strategy-log-excerpts.txt
  logs/
```

### 5.1 顶层报告组织方式

顶层 `REPORT.md` 作为测试首页，按以下顺序组织：

1. `Executive Summary`：baseline 与 strategy 的总耗时、generation throughput、p95 latency 改善比例。
2. `Test Configuration`：运行参数，包括 namespace、DGD、model、请求数、并发数、策略 driver 等。
3. `Topology`：frontend、decode、prefill Pod，以及本地 metric/sidecar port-forward 端口。
4. `End-to-End Timing And Throughput`：baseline 与 strategy 的请求完成数、成功率、wall time、req/s、latency、TTFT、generation tok/s。
5. `Strategy Trigger Evidence`：策略事件计数与事件时间线。
6. `Per-Scenario Reports`：跳转到 baseline/strategy 各自的详细报告。
7. `Cache Control Note`：说明本轮测试如何降低 KV cache 干扰。
8. `Artifact Index`：列出关键产物是否存在及用途。

### 5.2 Scenario 报告组织方式

每个 `<scenario>/REPORT.md` 聚焦单次实验，按以下顺序组织：

1. `Run Result`：请求数、HTTP 成功率、总 wall time、latency、TTFT、cluster token throughput。
2. `Pod Throughput`：每个 Pod 的 role、current role 变化、prompt/generation token delta、tokens/s、running/active request 峰值。
3. `Strategy Timeline`：Role Switch、Request Consolidation 或 auto/none driver 记录。
4. `Artifact Index`：当前 scenario 下每个 CSV、JSON、日志文件的用途。

## 6. KV Cache 影响控制

脚本采用 best-effort 的方式降低 KV cache 对 baseline/strategy 对比的影响：

1. 每个 scenario 使用唯一 salt，写入每个 prompt。
2. baseline 与 strategy 的 prompt salt 不同，避免跨场景 prefix cache 复用。
3. 每个 scenario 先发送独立 warmup 请求，避免只测到首次模型触达开销。
4. `MODE=both` 时两组实验之间默认暂停 `SCENARIO_PAUSE_SECONDS=10` 秒。

如果需要更严格的客观对比，建议在两组实验前分别重启 worker，或者在部署侧提供明确的 KV/prefix cache clear endpoint。当前脚本不会默认重启 Pod，因为这会改变测试拓扑并引入额外 cold-start 变量。

## 7. 结果判读

关注 `REPORT.md` 中的三类指标：

- `end_to_end_wall_s`：从第一批请求开始到全部请求结束的总处理时长。
- `cluster_generation_tps` / `cluster_prompt_tps`：通过 Pod metric counter delta 计算的集群级 token throughput。
- `strategy_events`：Role Switch 与 Request Consolidation 的触发证据。

如果要深入分析某一次 run，不建议只看顶层 `REPORT.md`。更完整的阅读顺序是：

1. 先看顶层 `REPORT.md` 的 `Executive Summary` 和 `End-to-End Timing And Throughput`。
2. 再看 `strategy/event_timeline.csv` 或顶层 `Strategy Trigger Evidence`，确认策略是否真的触发。
3. 进入 `baseline/REPORT.md` 与 `strategy/REPORT.md` 比较 Pod 级 throughput 分布。
4. 最后用 `<scenario>/logs/` 和 `<scenario>/strategy-log-excerpts.txt` 追溯 controller/worker 日志证据。

如果使用 `STRATEGY_DRIVER=auto` 但 `strategy_events.jsonl` 只有 `strategy_driver` 记录，需要结合 `strategy-log-excerpts.txt` 和 `controller.log` 判断 controller 是否真的触发了 S2/S3。若日志也没有相关记录，则说明当前部署没有形成 S2/S3 自动策略闭环，测试只能证明 baseline 指标和被动观测结果。