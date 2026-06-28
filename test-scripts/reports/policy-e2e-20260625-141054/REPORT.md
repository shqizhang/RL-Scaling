# Policy-driven S2/S3 E2E Test Report

## 1. Executive Summary

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B` | mode: `strategy` | strategy driver: `sidecar`

Single-scenario report generated for `strategy`. Run with `MODE=both` to produce baseline-vs-strategy comparison.

## 2. Test Configuration

| key | value |
|---|---|
| `timestamp` | `20260625-141054` |
| `namespace` | `dynamo-system` |
| `dgd` | `vllm-v1-disagg-router` |
| `model` | `Qwen/Qwen3-0.6B` |
| `mode` | `strategy` |
| `strategy_driver` | `sidecar` |
| `n_req` | `64` |
| `concurrency` | `8` |
| `max_tokens` | `1024` |
| `prompt_words` | `120` |
| `sample_interval` | `1` |
| `role_switch_delay` | `18` |
| `consolidation_delay` | `6` |
| `mig_loops` | `4` |
| `migration_spacing` | `1` |
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
| strategy | 64 | 100.000 | 36.465 | 1.755 | 4.417 | 4.491 | 4.513 | 4.417 | 1758.880 |

## 5. Strategy Trigger Evidence

Event counts: `{"request_consolidation": 4, "role_switch": 1}`

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782396666.0836658 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 25.322 |
| 1782396667.1867635 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 17.995 |
| 1782396668.2961915 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 25.026 |
| 1782396669.4088519 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 27.216 |
| 1782396678.0889328 | role_switch | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `decode_to_prefill` | ok | 40.982 |

Raw event payloads are in `strategy/strategy_events.jsonl`; flattened event rows are in `strategy/event_timeline.csv`.

## 6. Per-Scenario Reports

| scenario | report | requests | pod throughput | raw metrics | logs |
|---|---|---|---|---|---|
| strategy | `strategy/REPORT.md` | `strategy/requests.csv` | `strategy/pod_throughput.csv` | `strategy/pod_metrics.csv` | `strategy/logs/` |

## 7. Cache Control Note

Each scenario uses a unique prompt salt and a separate warmup request. This reduces prefix/KV cache reuse between baseline and strategy. For stricter isolation, run each scenario on freshly restarted workers or clear worker KV state through the deployment-specific clear route before invoking this script.

## 8. Artifact Index

| artifact | exists | purpose |
|---|---|---|
| `experiment_config.csv` | yes | Run configuration captured at script start |
| `topology.csv` | yes | Discovered frontend/prefill/decode topology |
| `comparison.csv` | yes | Machine-readable scenario comparison |
| `baseline/REPORT.md` | no | Baseline scenario report |
| `strategy/REPORT.md` | yes | Strategy scenario report |
| `strategy/event_timeline.csv` | yes | Flattened strategy trigger timeline |
