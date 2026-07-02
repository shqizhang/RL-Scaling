# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 96 |
| completed_requests | 96 |
| http_200 | 96 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 60.240819 |
| request_throughput_rps | 1.593604 |
| latency_avg_s | 4.798650 |
| latency_p50_s | 4.886172 |
| latency_p95_s | 4.964644 |
| latency_p99_s | 4.967268 |
| ttft_avg_s | 4.798472 |
| ttft_p50_s | 4.885998 |
| ttft_p95_s | 4.964477 |
| ttft_p99_s | 4.967128 |
| cluster_prompt_tps | 1310.506747 |
| cluster_generation_tps | 1608.460862 |
| prompt_tokens_delta | 78946 |
| generation_tokens_delta | 96895 |
| user_prompt_tokens | 40311 |
| user_completion_tokens | 96803 |
| user_completion_tps | 1606.933658 |
| engine_replay_or_overhead_tokens | 92 |
| gpu_sample_count | 69 |
| gpu_util_avg_pct | 30.014493 |
| gpu_util_max_pct | 100.000000 |
| gpu_mem_used_avg_mib | 22260.405797 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 44.927536 |
| gpu_active_seconds | 87.763571 |
| gpu_effective_seconds | 58.611387 |
| gpu_effective_hours | 0.016281 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | prefill -> prefill | 20156 | 48 | 326.431 | 0.777 | 0 | 0 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 40311 | 96803 | 652.845 | 1567.745 | 8 | 8 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 18479 | 44 | 299.271 | 0.713 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782962215.1746764 | strategy_driver | auto |  |  |  |
| 1782962218.587801 | controller_sampling_progress |  |  |  |  |
| 1782962218.6832793 | controller_status |  |  |  |  |
| 1782962223.7912931 | controller_status |  |  |  |  |

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
