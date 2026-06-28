# Run Report: s3-tail-drain / baseline

## Overall

| metric | value |
|---|---:|
| completed_requests | 48 |
| http_200 | 48 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 25.096363 |
| request_throughput_rps | 1.912628 |
| cluster_prompt_tps | 945.555353 |
| cluster_generation_tps | 1190.969404 |
| prompt_tokens_delta | 23730 |
| generation_tokens_delta | 29889 |

## Phase Metrics

| phase | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pre | 24 | 100.000 | 19.190 | 1.251 | 1.761 | 4.906 | 5.097 | 1.761 |
| post | 24 | 100.000 | 19.058 | 1.259 | 1.725 | 4.553 | 5.272 | 1.725 |

## Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 6590 | 13350 | 252.239 | 510.984 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 6064 | 16497 | 232.105 | 631.438 | 4 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 11076 | 42 | 423.944 | 1.608 | 0 | 0 |

## Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782398945.2963865 | phase_boundary | s3_tail |  |  |  |
