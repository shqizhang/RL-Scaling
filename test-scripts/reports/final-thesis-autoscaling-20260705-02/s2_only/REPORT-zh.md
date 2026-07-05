# s2_only ????

- ?????{'prefill': 1, 'decode': 3}
- Valid Decode?100.00%
- Serving Wall Time?45.04s
- req/s?2.31
- p50/p95/p99 latency?3.44 / 4.15 / 4.42s
- Prompt tok/s?7680.81
- Completion tok/s?622.54
- Request-window GPU seconds?169.04
- Avg ready workers?4.00
- S2 executed?2
- S3 migrated/drained/scaled?0 / [] / []

## ?????
| phase | requests | success | valid decode | wall(s) | req/s | p50(s) | p95(s) | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 48 | 100.00% | 100.00% | 12.06 | 3.98 | 3.84 | 4.41 | 382.07 |
| decode_bulk | 32 | 100.00% | 100.00% | 12.65 | 2.53 | 3.14 | 3.45 | 956.65 |
| decode_tail | 24 | 100.00% | 100.00% | 13.13 | 1.83 | 3.13 | 3.44 | 862.67 |

