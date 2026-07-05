# baseline_overprovisioned ????

- ?????{'prefill': 2, 'decode': 4}
- Valid Decode?100.00%
- Serving Wall Time?40.49s
- req/s?2.57
- p50/p95/p99 latency?2.82 / 3.19 / 3.48s
- Prompt tok/s?8543.67
- Completion tok/s?698.26
- Request-window GPU seconds?204.55
- Avg ready workers?6.00
- S2 executed?0
- S3 migrated/drained/scaled?0 / [] / []

## ?????
| phase | requests | success | valid decode | wall(s) | req/s | p50(s) | p95(s) | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 48 | 100.00% | 100.00% | 8.72 | 5.50 | 2.77 | 3.12 | 528.32 |
| decode_bulk | 32 | 100.00% | 100.00% | 11.69 | 2.74 | 2.85 | 3.16 | 1047.17 |
| decode_tail | 24 | 100.00% | 100.00% | 12.93 | 1.86 | 2.90 | 3.48 | 883.53 |

