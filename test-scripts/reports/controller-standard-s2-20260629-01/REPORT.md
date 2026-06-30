# Policy-driven S2/S3 E2E Test Report

## 1. Executive Summary

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B` | mode: `strategy` | strategy driver: `auto`

| comparison target | result | interpretation |
|---|---:|---|
| end-to-end wall time change | 36.244% | positive means strategy completed faster |
| generation throughput change | 56.915% | positive means more generation tokens/s |
| user-visible completion throughput change | 56.847% | positive means more response completion tokens/s, excluding engine replay |
| p95 latency change | 41.047% | positive means lower p95 latency |
| GPU effective seconds change | -72.725% | positive means fewer utilization-weighted GPU seconds for the same workload |

## 2. Test Configuration

| key | value |
|---|---|
| `timestamp` | `20260628-232343` |
| `namespace` | `dynamo-system` |
| `controller_namespace` | `dynamo` |
| `dgd` | `vllm-v1-disagg-router` |
| `model` | `Qwen/Qwen3-0.6B` |
| `mode` | `strategy` |
| `strategy_driver` | `auto` |
| `n_req` | `36` |
| `concurrency` | `6` |
| `max_tokens` | `192` |
| `prompt_words` | `512` |
| `sample_interval` | `1` |
| `gpu_sample_interval` | `2` |
| `role_switch_delay` | `8` |
| `consolidation_delay` | `20` |
| `auto_progress_delay` | `1` |
| `auto_progress_value` | `0.5` |
| `mig_loops` | `4` |
| `migration_spacing` | `1` |
| `strategy_action_timeout` | `120` |
| `consolidation_min_active` | `1` |
| `consolidation_active_max` | `6` |
| `mig_stop_on_success` | `1` |
| `role_switch_source_active_max` | `0` |
| `role_switch_target_role` | `prefill` |
| `controller_label` | `app=rl-scaling-controller` |

## 3. Controller Strategy Logic

| strategy | formal trigger condition | deployed value in this run | validation evidence |
|---|---|---|---|
| Baseline | `ROLE_SWITCH_ENABLED=false` and `CONSOLIDATION_ENABLED=false`; controller observes traffic but does not call S2/S3 sidecars | `ROLE_SWITCH_ENABLED=true`, `CONSOLIDATION_ENABLED=false` | baseline has no S2/S3 controller execution log lines |
| S2 PD Role Switch | prefill-heavy trigger: `prefill_queue_depth >= PREFILL_QUEUE_THRESHOLD` and `decode_utilization <= DECODE_IDLE_THRESHOLD`; decode-heavy trigger: `decode_queue_depth >= DECODE_QUEUE_THRESHOLD` and `prefill_utilization <= PREFILL_IDLE_THRESHOLD`; actions are rate-limited by `MIN_SWITCH_INTERVAL` | `PREFILL_QUEUE_THRESHOLD=0`, `DECODE_QUEUE_THRESHOLD=999`, `DECODE_IDLE_THRESHOLD=1.0`, `PREFILL_IDLE_THRESHOLD=0.0`, `MIN_SWITCH_INTERVAL=1` | controller status/logs expose `s2_history`, `S2 role switch decision`, and `S2 role switch result` |
| S3 Request Consolidation | batch progress must be `>= MIN_BATCH_COMPLETION`; source decode worker must have `1..CONSOLIDATION_THRESHOLD` in-flight requests; target worker must have available capacity at least equal to source active request count; migration must be cost-beneficial; the same plan must remain stable for `CONSOLIDATION_STABLE_SAMPLES` controller ticks and respect `CONSOLIDATION_MIN_INTERVAL` cooldown | `MIN_BATCH_COMPLETION=0.6`, `CONSOLIDATION_THRESHOLD=4`, `CONSOLIDATION_STABLE_SAMPLES=2`, `CONSOLIDATION_MIN_INTERVAL=10`, `CONSOLIDATION_SCALE_DOWN_ENABLED=false` | controller logs expose waiting/decision/executed records; worker logs expose migration complete/rollback records |

## 4. Topology

| role | pod | pod IP | metric port | sidecar port |
|---|---|---|---:|---:|
| decode | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `10.244.0.187` | 19200 | 19300 |
| decode | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | `10.244.0.186` | 19201 | 19301 |
| prefill | `vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89` | `10.244.0.169` | 19202 |  |

## 5. End-to-End Timing And Throughput

### Metric Meanings

| metric | meaning | measurement boundary | why it matters |
|---|---|---|---|
| completed | requests for which the client process returned a row in `requests.csv` | one row per submitted HTTP request | confirms workload size and whether requests finished inside timeout |
| success % | `http_200 / completed * 100` | HTTP status returned by Dynamo frontend `/v1/chat/completions` | validates service correctness while strategy actions occur |
| wall time | `max(end_ts) - min(start_ts)` across measured requests | starts when the first measured curl is launched; ends when the last measured curl returns | represents end-to-end batch completion time |
| req/s | successful frontend HTTP requests per second, `http_200 / wall time` | same wall-time window as above | user-visible request throughput |
| p50 latency | median per-request curl total time | each request start to complete response body | typical user request latency |
| p95/p99 latency | 95th/99th percentile per-request curl total time | each request start to complete response body | tail latency, sensitive to queueing and stragglers |
| p50 TTFT | median curl `time_starttransfer` | request start to first response byte | approximates time-to-first-token / first-byte responsiveness |
| engine gen tok/s | cluster generation token delta divided by wall time | vLLM `generation_tokens_total` sampled before/after scenario | model-side decode throughput; can include migration replay tokens |
| user completion tok/s | sum of HTTP response `usage.completion_tokens` divided by wall time | successful non-streaming frontend responses in `responses/` | user-visible output throughput, excluding internal replay |
| replay/overhead tokens | `engine_generation_tokens_delta - user_completion_tokens`, clamped at 0 | vLLM counters minus frontend response usage | indicates extra engine work such as migration replay/recompute |
| GPU active sample % | share of GPU samples where `nvidia-smi utilization.gpu > 0` | sampled per worker pod every configured GPU interval | coarse proxy for GPU active time / effective-hour utilization |
| GPU effective seconds | sum of `gpu_util_pct / 100 * sample_duration` across worker pods | `nvidia-smi` utilization samples integrated over time | utilization-weighted GPU time; lower is better for equal completed work |
| GPU memory MiB | device memory used by worker pod at sample time | `nvidia-smi memory.used` | shows whether consolidation/switching changes memory footprint or leaves workers occupied |

### Results

| scenario | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) | engine gen tok/s | user completion tok/s | replay/overhead tok | GPU active % | GPU effective s | avg GPU util % | max GPU mem MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | 36 | 100.000 | 16.398 | 2.195 | 2.519 | 2.861 | 2.864 | 2.519 | 423.335 | 421.506 | 30 | 66.667 | 5.468 | 9.143 | 22590.000 |
| strategy | 36 | 100.000 | 10.455 | 3.443 | 1.644 | 1.686 | 1.687 | 1.644 | 664.275 | 661.119 | 33 | 60.000 | 9.444 | 22.133 | 22590.000 |

## 6. Strategy Trigger Evidence

`STRATEGY_DRIVER=auto` means this script did not call worker sidecar action endpoints. S2/S3 evidence must come from controller `/api/v1/status`, controller logs, and worker logs captured under `strategy/logs/`.

Event counts: `{"controller_sampling_progress": 1, "controller_status": 2, "strategy_driver": 1}`

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782689027.4169846 | strategy_driver | `auto` | `` |  |  |
| 1782689028.808053 | controller_sampling_progress | `` | `` | ok |  |
| 1782689028.8927002 | controller_status | `` | `` |  |  |
| 1782689033.9855125 | controller_status | `` | `` |  |  |

Raw event payloads are in `strategy/strategy_events.jsonl`; flattened event rows are in `strategy/event_timeline.csv`.
For auto runs, inspect `strategy/strategy-log-excerpts.txt` for `S2 role switch decision`, `S2 role switch result`, `S3 consolidation decision`, and `S3 consolidation executed` log lines.

## 7. Per-Scenario Reports

| scenario | report | requests | pod throughput | raw metrics | logs |
|---|---|---|---|---|---|
| baseline | `baseline/REPORT.md` | `baseline/requests.csv` | `baseline/pod_throughput.csv` | `baseline/pod_metrics.csv`, `baseline/gpu_metrics.csv` | `baseline/logs/` |
| strategy | `strategy/REPORT.md` | `strategy/requests.csv` | `strategy/pod_throughput.csv` | `strategy/pod_metrics.csv`, `strategy/gpu_metrics.csv` | `strategy/logs/` |

## 8. Cache Control Note

Each scenario uses a unique prompt salt and a separate warmup request. This reduces prefix/KV cache reuse between baseline and strategy. For stricter isolation, run each scenario on freshly restarted workers or clear worker KV state through the deployment-specific clear route before invoking this script.

## 9. Artifact Index

| artifact | exists | purpose |
|---|---|---|
| `experiment_config.csv` | yes | Run configuration captured at script start |
| `topology.csv` | yes | Discovered frontend/prefill/decode topology |
| `comparison.csv` | yes | Machine-readable scenario comparison |
| `controller_config.csv` | yes | Controller ConfigMap and deployment env captured at test start |
| `baseline/REPORT.md` | yes | Baseline scenario report |
| `strategy/REPORT.md` | yes | Strategy scenario report |
| `strategy/event_timeline.csv` | yes | Flattened strategy trigger timeline |
| `strategy/gpu_metrics.csv` | yes | Raw strategy GPU utilization and memory samples |
