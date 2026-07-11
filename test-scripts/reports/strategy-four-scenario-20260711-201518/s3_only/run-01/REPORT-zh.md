# s3_only run-01 Report

generated_at: 2026-07-11T20:51:32

## Timing

- T_signal_recv: 1783773613.2160351
- T_warmup_start: 1783773613.2160351
- T_ready: 1783773809.3880742
- T_burst_arrival: 1783773810.9438434
- Signal-to-Ready(s): 196.17203903198242
- Burst Safety Margin(s): 1.5557692050933838

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 155.78 | 0.51 | 49.88 | 5698.63 | 24.65 |
| balanced_decode | 32 | 100.00 | 0 | 16.35 | 1.96 | 4.84 | 2788.69 | 751.45 |
| decode_tail | 18 | 94.44 | 1 | 133.91 | 0.13 | 1.94 | 44.01 | 3.46 |
| total | 130 | 99.23 | 1 | 346.29 | 0.37 | 49.80 | 2712.17 | 47.91 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.23076923076923, 'timeout_count': 1, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['S3 migration/drain evidence missing']}
- request-window GPU seconds: 1357.19
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 5.25

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
