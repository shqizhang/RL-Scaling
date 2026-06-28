# Policy-driven S2/S3 E2E Test Report

## 1. Executive Summary

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B` | mode: `both` | strategy driver: `sidecar`

| comparison target | result | interpretation |
|---|---:|---|
| end-to-end wall time change | -3.322% | positive means strategy completed faster |
| generation throughput change | -8.219% | positive means more generation tokens/s |
| p95 latency change | -12.421% | positive means lower p95 latency |

## 2. Test Configuration

| key | value |
|---|---|
| `timestamp` | `20260625-140918` |
| `namespace` | `dynamo-system` |
| `dgd` | `vllm-v1-disagg-router` |
| `model` | `Qwen/Qwen3-0.6B` |
| `mode` | `both` |
| `strategy_driver` | `sidecar` |
| `n_req` | `48` |
| `concurrency` | `8` |
| `max_tokens` | `768` |
| `prompt_words` | `120` |
| `sample_interval` | `1` |
| `role_switch_delay` | `8` |
| `consolidation_delay` | `20` |
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
| baseline | 48 | 100.000 | 19.426 | 2.471 | 2.967 | 3.222 | 3.230 | 2.967 | 1899.695 |
| strategy | 48 | 100.000 | 20.072 | 2.391 | 3.159 | 3.622 | 3.628 | 3.159 | 1743.558 |

## 5. Strategy Trigger Evidence

Event counts: `{"request_consolidation": 4, "role_switch": 1}`

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782396608.822523 | role_switch | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `decode_to_prefill` | ok | 527.329 |
| 1782396620.3122158 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 20.31 |
| 1782396621.4208732 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 25.256 |
| 1782396622.5229328 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 22.018 |
| 1782396623.632701 | request_consolidation | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk` | `vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg` | error | 21.837 |

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
