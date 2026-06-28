# Policy-driven S2/S3 E2E Test Report

## 1. Executive Summary

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B` | mode: `both` | strategy driver: `sidecar`

| comparison target | result | interpretation |
|---|---:|---|
| end-to-end wall time change | -1.279% | positive means strategy completed faster |
| generation throughput change | -0.183% | positive means more generation tokens/s |
| p95 latency change | -1.373% | positive means lower p95 latency |

## 2. Test Configuration

| key | value |
|---|---|
| `timestamp` | `20260625-142050` |
| `namespace` | `dynamo-system` |
| `dgd` | `vllm-v1-disagg-router` |
| `model` | `Qwen/Qwen3-0.6B` |
| `mode` | `both` |
| `strategy_driver` | `sidecar` |
| `n_req` | `64` |
| `concurrency` | `8` |
| `max_tokens` | `1024` |
| `prompt_words` | `120` |
| `sample_interval` | `1` |
| `role_switch_delay` | `4` |
| `consolidation_delay` | `6` |
| `mig_loops` | `6` |
| `migration_spacing` | `1` |
| `strategy_action_timeout` | `120` |
| `consolidation_min_active` | `1` |
| `consolidation_active_max` | `8` |
| `mig_stop_on_success` | `1` |
| `role_switch_source_active_max` | `0` |
| `role_switch_target_role` | `prefill` |
| `controller_label` | `app=rl-scaling-controller` |

## 3. Topology

| role | pod | pod IP | metric port | sidecar port |
|---|---|---|---:|---:|
| decode | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `10.244.0.187` | 19200 | 19300 |
| decode | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | `10.244.0.186` | 19201 | 19301 |
| prefill | `vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89` | `10.244.0.169` | 19202 |  |

## 4. End-to-End Timing And Throughput

| scenario | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) | gen tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | 64 | 100.000 | 33.025 | 1.938 | 3.971 | 4.067 | 4.070 | 3.970 | 1951.829 |
| strategy | 64 | 100.000 | 33.448 | 1.913 | 3.939 | 4.123 | 4.168 | 3.939 | 1948.260 |

## 5. Strategy Trigger Evidence

Event counts: `{"request_consolidation": 1, "role_switch": 1}`

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782397310.7382066 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | ok | 30.589 |
| 1782397339.7903607 | role_switch | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `decode_to_prefill` | ok | 898.41 |

Raw event payloads are in `strategy/strategy_events.jsonl`; flattened event rows are in `strategy/event_timeline.csv`.

## 6. Per-Scenario Reports

| scenario | report | requests | pod throughput | raw metrics | logs |
|---|---|---|---|---|---|
| baseline | `baseline/REPORT.md` | `baseline/requests.csv` | `baseline/pod_throughput.csv` | `baseline/pod_metrics.csv` | `baseline/logs/` |
| strategy | `strategy/REPORT.md` | `strategy/requests.csv` | `strategy/pod_throughput.csv` | `strategy/pod_metrics.csv` | `strategy/logs/` |

## 7. Cache Control Note

Each scenario uses a unique prompt salt and a separate warmup request. This reduces prefix/KV cache reuse between baseline and strategy. For stricter isolation, run each scenario on freshly restarted workers or clear worker KV state through the deployment-specific clear route before invoking this script.

## 8. Artifact Index

| artifact | exists | purpose |
|---|---|---|
| `experiment_config.csv` | yes | Run configuration captured at script start |
| `topology.csv` | yes | Discovered frontend/prefill/decode topology |
| `comparison.csv` | yes | Machine-readable scenario comparison |
| `baseline/REPORT.md` | yes | Baseline scenario report |
| `strategy/REPORT.md` | yes | Strategy scenario report |
| `strategy/event_timeline.csv` | yes | Flattened strategy trigger timeline |
