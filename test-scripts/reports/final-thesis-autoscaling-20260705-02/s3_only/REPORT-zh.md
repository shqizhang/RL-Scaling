# s3_only ????

- ?????{'prefill': 2, 'decode': 4}
- Valid Decode?98.08%
- Serving Wall Time?44.59s
- req/s?2.29
- p50/p95/p99 latency?2.81 / 3.13 / 3.44s
- Prompt tok/s?7739.95
- Completion tok/s?615.40
- Request-window GPU seconds?228.16
- Avg ready workers?6.00
- S2 executed?0
- S3 migrated/drained/scaled?1 / ['vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7swhxx'] / [3]

## ?????
| phase | requests | success | valid decode | wall(s) | req/s | p50(s) | p95(s) | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 48 | 100.00% | 100.00% | 8.19 | 5.86 | 2.81 | 2.85 | 562.77 |
| decode_bulk | 32 | 100.00% | 100.00% | 11.56 | 2.77 | 2.82 | 3.08 | 1073.46 |
| decode_tail | 24 | 91.67% | 91.67% | 12.83 | 1.71 | 2.82 | 3.44 | 812.44 |

