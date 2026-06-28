# Run Report: s2-after-drain / baseline

## Overall

| metric | value |
|---|---:|
| completed_requests | 56 |
| http_200 | 56 |
| http_non_200 | 0 |
| success_rate_pct | 100.000000 |
| end_to_end_wall_s | 33.111768 |
| request_throughput_rps | 1.691242 |
| cluster_prompt_tps | 2415.032660 |
| cluster_generation_tps | 618.722633 |
| prompt_tokens_delta | 79966 |
| generation_tokens_delta | 20487 |

## Phase Metrics

| phase | completed | success % | wall time (s) | req/s | p50 latency (s) | p95 latency (s) | p99 latency (s) | p50 TTFT (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pre | 24 | 100.000 | 16.474 | 1.457 | 1.739 | 4.326 | 4.639 | 1.739 |
| post | 32 | 100.000 | 16.543 | 1.934 | 3.731 | 4.267 | 4.270 | 3.731 |

## Pod Throughput

| role | pod | current role start -> end | prompt delta | gen delta | prompt tok/s | gen tok/s | max running | max active |
|---|---|---|---:|---:|---:|---:|---:|---:|
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk | decode -> decode | 20382 | 10333 | 602.590 | 305.493 | 4 | 4 |
| decode | vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7k7gtg | decode -> decode | 20384 | 10104 | 602.649 | 298.723 | 4 | 4 |
| prefill | vllm-v1-disagg-router-vllmprefillworker-574b777c-ffddb778dj8r89 | prefill -> prefill | 39200 | 50 | 1158.940 | 1.478 | 0 | 0 |

## Strategy Timeline

| ts | type | subject | target/direction | status | client wall ms |
|---:|---|---|---|---|---:|
| 1782399000.9759002 | phase_boundary | s2_prep |  |  |  |
