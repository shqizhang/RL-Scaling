# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 96 |
| completed_requests | 96 |
| http_200 | 96 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 59.958125 |
| request_throughput_rps | 1.601117 |
| latency_avg_s | 4.700174 |
| latency_p50_s | 4.846465 |
| latency_p95_s | 4.977103 |
| latency_p99_s | 4.981925 |
| ttft_avg_s | 4.699997 |
| ttft_p50_s | 4.846241 |
| ttft_p95_s | 4.976887 |
| ttft_p99_s | 4.981726 |
| cluster_prompt_tps | 1288.732764 |
| cluster_generation_tps | 1607.054927 |
| prompt_tokens_delta | 77270 |
| generation_tokens_delta | 96356 |
| user_prompt_tokens | 40311 |
| user_completion_tokens | 96268 |
| user_completion_tps | 1605.587236 |
| engine_replay_or_overhead_tokens | 88 |
| gpu_sample_count | 66 |
| gpu_util_avg_pct | 49.712121 |
| gpu_util_max_pct | 100.000000 |
| gpu_mem_used_avg_mib | 22244.000000 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 71.212121 |
| gpu_active_seconds | 131.620991 |
| gpu_effective_seconds | 91.311208 |
| gpu_effective_hours | 0.025364 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 20155 | 48629 | 326.512 | 787.792 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 20156 | 47639 | 326.528 | 771.754 | 4 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 36959 | 88 | 598.737 | 1.426 | 6 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782962079.0742521 | strategy_driver | none |  |  |  |

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
