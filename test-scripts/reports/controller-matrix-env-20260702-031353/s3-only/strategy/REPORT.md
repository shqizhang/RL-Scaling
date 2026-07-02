# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 96 |
| completed_requests | 96 |
| http_200 | 96 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 61.576910 |
| request_throughput_rps | 1.559026 |
| latency_avg_s | 4.546652 |
| latency_p50_s | 4.841352 |
| latency_p95_s | 5.167521 |
| latency_p99_s | 5.648437 |
| ttft_avg_s | 4.546478 |
| ttft_p50_s | 4.841137 |
| ttft_p95_s | 5.167213 |
| ttft_p99_s | 5.648262 |
| cluster_prompt_tps | 1413.727975 |
| cluster_generation_tps | 1728.667456 |
| prompt_tokens_delta | 87053 |
| generation_tokens_delta | 106446 |
| user_prompt_tokens | 40311 |
| user_completion_tokens | 89974 |
| user_completion_tps | 1461.164588 |
| engine_replay_or_overhead_tokens | 16472 |
| gpu_sample_count | 69 |
| gpu_util_avg_pct | 49.304348 |
| gpu_util_max_pct | 100.000000 |
| gpu_mem_used_avg_mib | 22244.000000 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 68.115942 |
| gpu_active_seconds | 133.509923 |
| gpu_effective_seconds | 96.675366 |
| gpu_effective_hours | 0.026854 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 20155 | 42364 | 318.653 | 669.779 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 29939 | 63994 | 473.339 | 1011.751 | 8 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 36959 | 88 | 584.325 | 1.391 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782962361.988091 | strategy_driver | auto |  |  |  |
| 1782962365.38803 | controller_sampling_progress |  |  |  |  |
| 1782962365.4563487 | controller_status |  |  |  |  |
| 1782962370.549196 | controller_status |  |  |  |  |

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
