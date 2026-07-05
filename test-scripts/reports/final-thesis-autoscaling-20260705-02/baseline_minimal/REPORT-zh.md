# baseline_minimal ????

- ?????{'prefill': 1, 'decode': 1}
- Valid Decode?100.00%
- Serving Wall Time?53.55s
- req/s?1.94
- p50/p95/p99 latency?3.71 / 7.04 / 7.06s
- Prompt tok/s?6460.03
- Completion tok/s?507.09
- Request-window GPU seconds?103.29
- Avg ready workers?2.00
- S2 executed?0
- S3 migrated/drained/scaled?0 / [] / []

## ?????
| phase | requests | success | valid decode | wall(s) | req/s | p50(s) | p95(s) | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 48 | 100.00% | 100.00% | 19.89 | 2.41 | 6.47 | 7.05 | 231.73 |
| decode_bulk | 32 | 100.00% | 100.00% | 12.78 | 2.50 | 3.12 | 3.47 | 897.34 |
| decode_tail | 24 | 100.00% | 100.00% | 13.37 | 1.80 | 3.13 | 3.75 | 829.29 |

