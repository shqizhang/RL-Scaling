# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 48 |
| completed_requests | 48 |
| http_200 | 48 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 20.071601 |
| request_throughput_rps | 2.391438 |
| latency_avg_s | 3.072920 |
| latency_p50_s | 3.159206 |
| latency_p95_s | 3.622454 |
| latency_p99_s | 3.628454 |
| ttft_avg_s | 3.072746 |
| ttft_p50_s | 3.159032 |
| ttft_p95_s | 3.622268 |
| ttft_p99_s | 3.628296 |
| cluster_prompt_tps | 981.585854 |
| cluster_generation_tps | 1743.557941 |
| prompt_tokens_delta | 19702 |
| generation_tokens_delta | 34996 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> prefill | 5371 | 7320 | 203.879 | 277.861 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 8060 | 27648 | 305.951 | 1049.496 | 8 | 8 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 6271 | 28 | 238.042 | 1.063 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782396608.822523 | role_switch | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode_to_prefill | ok | 527.329 |
| 1782396620.3122158 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 20.31 |
| 1782396621.4208732 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 25.256 |
| 1782396622.5229328 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 22.018 |
| 1782396623.632701 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 21.837 |

## 4. Artifact Index

| artifact | purpose |
|---|---|
| `summary.json` | Machine-readable scenario summary |
| `requests.csv` | Per-request timing and HTTP status |
| `pod_metrics.csv` | Raw per-pod metric samples |
| `pod_throughput.csv` | Per-pod throughput summary |
| `event_timeline.csv` | Flattened strategy event timeline |
| `strategy_events.jsonl` | Raw strategy event payloads |
| `strategy-log-excerpts.txt` | Filtered controller/worker log excerpts |
| `logs/` | Controller and worker logs |
