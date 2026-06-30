# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 36 |
| completed_requests | 36 |
| http_200 | 36 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 10.455009 |
| request_throughput_rps | 3.443326 |
| latency_avg_s | 1.631796 |
| latency_p50_s | 1.643794 |
| latency_p95_s | 1.686441 |
| latency_p99_s | 1.687357 |
| ttft_avg_s | 1.631657 |
| ttft_p50_s | 1.643670 |
| ttft_p95_s | 1.686346 |
| ttft_p99_s | 1.687249 |
| cluster_prompt_tps | 5172.736107 |
| cluster_generation_tps | 664.274926 |
| prompt_tokens_delta | 54081 |
| generation_tokens_delta | 6945 |
| user_prompt_tokens | 28215 |
| user_completion_tokens | 6912 |
| user_completion_tps | 661.118544 |
| engine_replay_or_overhead_tokens | 33 |
| gpu_sample_count | 15 |
| gpu_util_avg_pct | 22.133333 |
| gpu_util_max_pct | 100.000000 |
| gpu_mem_used_avg_mib | 22264.000000 |
| gpu_mem_used_max_mib | 22590.000000 |
| gpu_active_sample_pct | 60.000000 |
| gpu_active_seconds | 25.534711 |
| gpu_effective_seconds | 9.444383 |
| gpu_effective_hours | 0.002623 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | prefill -> prefill | 14108 | 18 | 1133.026 | 1.446 | 0 | 0 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 28215 | 6912 | 2265.972 | 555.109 | 6 | 6 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 11758 | 15 | 944.295 | 1.205 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782689027.4169846 | strategy_driver | auto |  |  |  |
| 1782689028.808053 | controller_sampling_progress |  |  | ok |  |
| 1782689028.8927002 | controller_status |  |  |  |  |
| 1782689033.9855125 | controller_status |  |  |  |  |

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
