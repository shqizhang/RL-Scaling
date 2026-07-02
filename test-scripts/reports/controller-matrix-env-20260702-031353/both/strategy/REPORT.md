# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 96 |
| completed_requests | 96 |
| http_200 | 96 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 60.160125 |
| request_throughput_rps | 1.595741 |
| latency_avg_s | 4.777795 |
| latency_p50_s | 4.882738 |
| latency_p95_s | 4.964712 |
| latency_p99_s | 4.970162 |
| ttft_avg_s | 4.777628 |
| ttft_p50_s | 4.882558 |
| ttft_p95_s | 4.964510 |
| ttft_p99_s | 4.969974 |
| cluster_prompt_tps | 1312.264571 |
| cluster_generation_tps | 1600.063177 |
| prompt_tokens_delta | 78946 |
| generation_tokens_delta | 96260 |
| user_prompt_tokens | 40311 |
| user_completion_tokens | 96168 |
| user_completion_tps | 1598.533925 |
| engine_replay_or_overhead_tokens | 92 |
| gpu_sample_count | 66 |
| gpu_util_avg_pct | 29.181818 |
| gpu_util_max_pct | 100.000000 |
| gpu_mem_used_avg_mib | 22261.333333 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 45.454545 |
| gpu_active_seconds | 84.075313 |
| gpu_effective_seconds | 53.787161 |
| gpu_effective_hours | 0.014941 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | prefill -> prefill | 20156 | 48 | 327.183 | 0.779 | 0 | 0 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 40311 | 96168 | 654.349 | 1561.049 | 8 | 8 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 18479 | 44 | 299.961 | 0.714 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782962499.8431919 | strategy_driver | auto |  |  |  |
| 1782962503.2451298 | controller_sampling_progress |  |  |  |  |
| 1782962503.3312888 | controller_status |  |  |  |  |
| 1782962508.424202 | controller_status |  |  |  |  |

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
