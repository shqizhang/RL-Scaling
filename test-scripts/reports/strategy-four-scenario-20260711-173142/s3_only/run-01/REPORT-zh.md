# s3_only run-01 Report

generated_at: 2026-07-11T18:08:13

## Timing

- T_signal_recv: 1783763848.4351072
- T_warmup_start: 1783763848.4351072
- T_ready: 1783764042.357939
- T_burst_arrival: 1783764044.0689738
- Signal-to-Ready(s): 193.92283177375793
- Burst Safety Margin(s): 1.7110347747802734

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 185.66 | 0.43 | 72.13 | 4781.35 | 20.68 |
| balanced_decode | 32 | 100.00 | 0 | 18.32 | 1.75 | 5.26 | 2489.23 | 670.75 |
| decode_tail | 18 | 94.44 | 1 | 134.01 | 0.13 | 1.93 | 43.98 | 3.46 |
| total | 130 | 99.23 | 1 | 343.82 | 0.38 | 68.87 | 2731.72 | 48.26 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.23076923076923, 'timeout_count': 1, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['S3 migration/drain evidence missing']}
- request-window GPU seconds: 1362.27
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 2.60

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
