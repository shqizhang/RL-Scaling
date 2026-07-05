# mixed_strategy ????

- ?????{'prefill': 1, 'decode': 1}
- Valid Decode?100.00%
- Serving Wall Time?59.35s
- req/s?1.75
- p50/p95/p99 latency?3.57 / 7.36 / 7.38s
- Prompt tok/s?5828.94
- Completion tok/s?472.03
- Request-window GPU seconds?198.62
- Avg ready workers?3.50
- S2 executed?1
- S3 migrated/drained/scaled?8 / ['vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b72z8dk'] / [1]

## ?????
| phase | requests | success | valid decode | wall(s) | req/s | p50(s) | p95(s) | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 48 | 100.00% | 100.00% | 15.46 | 3.10 | 4.06 | 7.37 | 274.33 |
| decode_bulk | 32 | 100.00% | 100.00% | 13.52 | 2.37 | 3.26 | 3.57 | 908.45 |
| decode_tail | 24 | 100.00% | 100.00% | 13.85 | 1.73 | 3.16 | 3.79 | 829.45 |

