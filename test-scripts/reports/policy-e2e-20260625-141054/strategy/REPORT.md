# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 64 |
| completed_requests | 64 |
| http_200 | 64 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 36.464676 |
| request_throughput_rps | 1.755123 |
| latency_avg_s | 4.323309 |
| latency_p50_s | 4.417330 |
| latency_p95_s | 4.490588 |
| latency_p99_s | 4.512809 |
| ttft_avg_s | 4.323143 |
| ttft_p50_s | 4.417176 |
| ttft_p95_s | 4.490411 |
| ttft_p99_s | 4.512710 |
| cluster_prompt_tps | 761.339547 |
| cluster_generation_tps | 1758.880286 |
| prompt_tokens_delta | 27762 |
| generation_tokens_delta | 64137 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | prefill -> prefill | 7163 | 32 | 186.262 | 0.832 | 0 | 0 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 14327 | 64077 | 372.550 | 1666.216 | 8 | 8 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 6272 | 28 | 163.093 | 0.728 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782396666.0836658 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 25.322 |
| 1782396667.1867635 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 17.995 |
| 1782396668.2961915 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 25.026 |
| 1782396669.4088519 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | error | 27.216 |
| 1782396678.0889328 | role_switch | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode_to_prefill | ok | 40.982 |

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
