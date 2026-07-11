# s3_only run-01 Report

generated_at: 2026-07-06T19:05:11

## Timing

- T_signal_recv: 1783335307.4764774
- T_warmup_start: 1783335307.4764774
- T_ready: 1783335504.4337704
- T_burst_arrival: 1783335506.2928667
- Signal-to-Ready(s): 196.95729303359985
- Burst Safety Margin(s): 1.8590962886810303

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 30.55 | 2.62 | 6.36 | 29059.31 | 125.70 |
| balanced_decode | 32 | 100.00 | 0 | 12.65 | 2.53 | 3.24 | 3604.38 | 971.24 |
| decode_tail | 18 | 94.44 | 1 | 134.77 | 0.13 | 1.87 | 43.73 | 3.80 |
| total | 130 | 99.23 | 1 | 185.13 | 0.70 | 6.36 | 5073.33 | 89.88 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.23076923076923, 'timeout_count': 1, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['S3 migration/drain evidence missing']}
- request-window GPU seconds: 725.41
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 3.96

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
