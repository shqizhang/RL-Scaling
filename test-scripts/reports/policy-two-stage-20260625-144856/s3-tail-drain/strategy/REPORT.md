# Run Report: s3-tail-drain / strategy

## Overall

| metric | value |
|---|---:|
| completed_requests | 48 |
| http_200 | 48 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 23.571710 |
| request_throughput_rps | 2.036339 |
| cluster_prompt_tps | 1023.430200 |
| cluster_generation_tps | 1269.190901 |
| prompt_tokens_delta | 24124 |
| generation_tokens_delta | 29917 |

## Phase Metrics

| phase | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pre | 24 | 100.000 | 19.231 | 1.248 | 1.945 | 4.852 | 5.247 | 1.945 |
| post | 24 | 100.000 | 17.318 | 1.386 | 1.827 | 4.588 | 4.847 | 1.827 |

## Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 6589 | 13853 | 267.574 | 562.560 | 6 | 6 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 6459 | 16022 | 262.295 | 650.641 | 7 | 6 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 11076 | 42 | 449.788 | 1.706 | 0 | 0 |

## Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782398974.1048632 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | ok | 28.222 |
