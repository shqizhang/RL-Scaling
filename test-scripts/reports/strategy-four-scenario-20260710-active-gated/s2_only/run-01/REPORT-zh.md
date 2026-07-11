# s2_only run-01 Report

generated_at: 2026-07-10T11:43:51

## Timing

- T_signal_recv: 1783654563.37159
- T_warmup_start: 1783654563.37159
- T_ready: 1783654762.1775043
- T_burst_arrival: 1783654763.608186
- Signal-to-Ready(s): 198.80591440200806
- Burst Safety Margin(s): 1.4306817054748535

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 48.43 | 1.65 | 13.08 | 18330.32 | 79.29 |
| balanced_decode | 32 | 100.00 | 0 | 13.77 | 2.32 | 3.96 | 3312.11 | 892.49 |
| decode_tail | 18 | 94.44 | 1 | 135.89 | 0.13 | 2.25 | 43.37 | 3.77 |
| total | 130 | 99.23 | 1 | 210.74 | 0.61 | 12.36 | 4456.64 | 78.96 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.23076923076923, 'timeout_count': 1, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['decode_tail timeout_count=1']}
- request-window GPU seconds: 820.95
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [539.9867864325643, 494.2336017265916]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -94.74

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
