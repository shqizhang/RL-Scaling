# Run Report: s2-after-drain / strategy

## Overall

| metric | value |
|---|---:|
| completed_requests | 56 |
| http_200 | 56 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 30.238722 |
| request_throughput_rps | 1.851930 |
| cluster_prompt_tps | 2650.310391 |
| cluster_generation_tps | 727.676248 |
| prompt_tokens_delta | 80142 |
| generation_tokens_delta | 22004 |

## Phase Metrics

| phase | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pre | 24 | 100.000 | 19.376 | 1.239 | 1.726 | 4.802 | 5.092 | 1.726 |
| post | 32 | 100.000 | 10.179 | 3.144 | 2.395 | 2.559 | 2.560 | 2.395 |

## Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> prefill | 20383 | 5511 | 661.720 | 178.911 | 3 | 3 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 37803 | 16459 | 1227.249 | 534.330 | 8 | 8 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 21956 | 34 | 712.787 | 1.104 | 0 | 0 |

## Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782399037.4779565 | request_consolidation | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | ok | 28.723 |
| 1782399051.2649786 | role_switch | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode_to_prefill | ok | 480.395 |
