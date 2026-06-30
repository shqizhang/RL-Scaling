# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 48 |
| completed_requests | 48 |
| http_200 | 48 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 19.912791 |
| request_throughput_rps | 2.410511 |
| latency_avg_s | 3.107331 |
| latency_p50_s | 3.201874 |
| latency_p95_s | 3.257747 |
| latency_p99_s | 3.260092 |
| ttft_avg_s | 3.107164 |
| ttft_p50_s | 3.201773 |
| ttft_p95_s | 3.257546 |
| ttft_p99_s | 3.259943 |
| cluster_prompt_tps | 1098.138350 |
| cluster_generation_tps | 1915.251311 |
| prompt_tokens_delta | 21867 |
| generation_tokens_delta | 38138 |
| user_prompt_tokens | 10743 |
| user_completion_tokens | 35961 |
| user_completion_tps | 1805.924600 |
| engine_replay_or_overhead_tokens | 2177 |
| gpu_sample_count | 24 |
| gpu_util_avg_pct | 46.208333 |
| gpu_util_max_pct | 100.000000 |
| gpu_mem_used_avg_mib | 22243.333333 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 58.333333 |
| gpu_active_seconds | 39.206023 |
| gpu_effective_seconds | 30.918905 |
| gpu_effective_hours | 0.008589 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 5372 | 17529 | 248.130 | 809.656 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 7536 | 20569 | 348.084 | 950.072 | 4 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 8959 | 40 | 413.812 | 1.848 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782688776.5210788 | strategy_driver | auto |  |  |  |
| 1782688790.9236503 | controller_sampling_progress |  |  |  |  |
| 1782688791.0094223 | controller_status |  |  |  |  |
| 1782688796.1081789 | controller_status |  |  |  |  |

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
