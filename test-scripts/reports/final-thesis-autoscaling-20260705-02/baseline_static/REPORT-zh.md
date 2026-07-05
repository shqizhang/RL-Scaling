# baseline_static ????

- ?????{'prefill': 2, 'decode': 2}
- Valid Decode?100.00%
- Serving Wall Time?46.27s
- req/s?2.25
- p50/p95/p99 latency?3.45 / 4.39 / 4.40s
- Prompt tok/s?7477.36
- Completion tok/s?637.22
- Request-window GPU seconds?172.70
- Avg ready workers?4.00
- S2 executed?0
- S3 migrated/drained/scaled?0 / [] / []

## ?????
| phase | requests | success | valid decode | wall(s) | req/s | p50(s) | p95(s) | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 48 | 100.00% | 100.00% | 12.48 | 3.85 | 4.04 | 4.39 | 369.16 |
| decode_bulk | 32 | 100.00% | 100.00% | 12.32 | 2.60 | 2.94 | 3.15 | 1005.20 |
| decode_tail | 24 | 100.00% | 100.00% | 14.52 | 1.65 | 3.14 | 4.38 | 860.00 |

