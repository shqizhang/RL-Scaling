# Scenario Report: strategy

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 64 |
| completed_requests | 64 |
| http_200 | 64 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 33.447793 |
| request_throughput_rps | 1.913430 |
| latency_avg_s | 3.900075 |
| latency_p50_s | 3.939270 |
| latency_p95_s | 4.123308 |
| latency_p99_s | 4.167866 |
| ttft_avg_s | 3.899898 |
| ttft_p50_s | 3.939081 |
| ttft_p95_s | 4.123103 |
| ttft_p99_s | 4.167677 |
| cluster_prompt_tps | 817.512844 |
| cluster_generation_tps | 1948.260111 |
| prompt_tokens_delta | 27344 |
| generation_tokens_delta | 65165 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> prefill | 7163 | 31829 | 193.358 | 859.192 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 7638 | 33280 | 206.180 | 898.360 | 5 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 12543 | 56 | 338.586 | 1.512 | 2 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782397310.7382066 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | ok | 30.589 |
| 1782397339.7903607 | role_switch | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode_to_prefill | ok | 898.41 |

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
