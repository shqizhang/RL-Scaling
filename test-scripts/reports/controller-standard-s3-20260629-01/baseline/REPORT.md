# Scenario Report: baseline

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 48 |
| completed_requests | 48 |
| http_200 | 48 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 19.918137 |
| request_throughput_rps | 2.409864 |
| latency_avg_s | 3.180700 |
| latency_p50_s | 3.188396 |
| latency_p95_s | 3.259720 |
| latency_p99_s | 3.261807 |
| ttft_avg_s | 3.180550 |
| ttft_p50_s | 3.188251 |
| ttft_p95_s | 3.259621 |
| ttft_p99_s | 3.261663 |
| cluster_prompt_tps | 989.148754 |
| cluster_generation_tps | 1852.783759 |
| prompt_tokens_delta | 19702 |
| generation_tokens_delta | 36904 |
| user_prompt_tokens | 10743 |
| user_completion_tokens | 36864 |
| user_completion_tps | 1850.775539 |
| engine_replay_or_overhead_tokens | 40 |
| gpu_sample_count | 24 |
| gpu_util_avg_pct | 46.541667 |
| gpu_util_max_pct | 100.000000 |
| gpu_mem_used_avg_mib | 22243.333333 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 62.500000 |
| gpu_active_seconds | 41.983648 |
| gpu_effective_seconds | 31.163216 |
| gpu_effective_hours | 0.008656 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 5371 | 18432 | 246.731 | 846.724 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 5372 | 18432 | 246.777 | 846.724 | 4 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 8959 | 40 | 411.556 | 1.838 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782688690.0019777 | strategy_driver | none |  |  |  |

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
