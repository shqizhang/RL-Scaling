# Scenario Report: baseline

## 1. Run Result

| metric | value |
|---|---:|
| expected_requests | 64 |
| completed_requests | 64 |
| http_200 | 64 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 33.025427 |
| request_throughput_rps | 1.937901 |
| latency_avg_s | 3.873080 |
| latency_p50_s | 3.970561 |
| latency_p95_s | 4.067446 |
| latency_p99_s | 4.069781 |
| ttft_avg_s | 3.872876 |
| ttft_p50_s | 3.970409 |
| ttft_p95_s | 4.067244 |
| ttft_p99_s | 4.069618 |
| cluster_prompt_tps | 813.615530 |
| cluster_generation_tps | 1951.829441 |
| prompt_tokens_delta | 26870 |
| generation_tokens_delta | 64460 |

## 2. Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 7164 | 32332 | 211.969 | 956.640 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 7163 | 32072 | 211.939 | 948.947 | 4 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 12543 | 56 | 371.122 | 1.657 | 0 | 0 |

## 3. Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782397255.595782 | strategy_driver | none |  |  |  |

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
