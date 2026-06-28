# Scenario Report: baseline

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 48 |
| completed_requests | 48 |
| http_200 | 48 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 19.426280 |
| request_throughput_rps | 2.470880 |
| latency_avg_s | 3.030255 |
| latency_p50_s | 2.966767 |
| latency_p95_s | 3.222223 |
| latency_p99_s | 3.230111 |
| ttft_avg_s | 3.029846 |
| ttft_p50_s | 2.966503 |
| ttft_p95_s | 3.222091 |
| ttft_p99_s | 3.229957 |
| cluster_prompt_tps | 1014.193119 |
| cluster_generation_tps | 1899.694592 |
| prompt_tokens_delta | 19702 |
| generation_tokens_delta | 36904 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 5371 | 18432 | 249.651 | 856.744 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 5372 | 18432 | 249.698 | 856.744 | 4 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 8959 | 40 | 416.426 | 1.859 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782396564.2807255 | strategy_driver | none |  |  |  |

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
