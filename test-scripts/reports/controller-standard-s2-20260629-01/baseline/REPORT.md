# Scenario Report: baseline

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 36 |
| completed_requests | 36 |
| http_200 | 36 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 16.398343 |
| request_throughput_rps | 2.195344 |
| latency_avg_s | 2.535626 |
| latency_p50_s | 2.518719 |
| latency_p95_s | 2.860671 |
| latency_p99_s | 2.864304 |
| ttft_avg_s | 2.535492 |
| ttft_p50_s | 2.518597 |
| ttft_p95_s | 2.860545 |
| ttft_p99_s | 2.864124 |
| cluster_prompt_tps | 3154.708922 |
| cluster_generation_tps | 423.335447 |
| prompt_tokens_delta | 51732 |
| generation_tokens_delta | 6942 |
| user_prompt_tokens | 28215 |
| user_completion_tokens | 6912 |
| user_completion_tps | 421.505994 |
| engine_replay_or_overhead_tokens | 30 |
| gpu_sample_count | 21 |
| gpu_util_avg_pct | 9.142857 |
| gpu_util_max_pct | 99.000000 |
| gpu_mem_used_avg_mib | 22243.333333 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 66.666667 |
| gpu_active_seconds | 39.463271 |
| gpu_effective_seconds | 5.467886 |
| gpu_effective_hours | 0.001519 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 14107 | 3456 | 763.008 | 186.925 | 3 | 3 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 14108 | 3456 | 763.062 | 186.925 | 3 | 3 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 23517 | 30 | 1271.968 | 1.623 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782688943.6562111 | strategy_driver | none |  |  |  |

## 4. Artifact Index

| artifact | purpose |
|---|---|
| `summary.json` | Machine-readable scenario summary |
| `requests.csv` | Per-request timing and HTTP status |
| `pod_metrics.csv` | Raw per-pod metric samples |
| `gpu_metrics.csv` | Raw per-pod GPU utilization and memory samples |
| `pod_throughput.csv` | Per-pod throughput summary |
| `event_timeline.csv` | Flattened strategy event timeline |
| `strategy_events.jsonl` | Raw strategy event payloads |
| `strategy-log-excerpts.txt` | Filtered controller/worker log excerpts |
| `logs/` | Controller and worker logs |
