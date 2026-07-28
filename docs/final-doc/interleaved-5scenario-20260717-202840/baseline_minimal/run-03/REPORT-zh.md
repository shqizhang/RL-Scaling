# baseline_minimal run-03 Report

generated_at: 2026-07-17T21:56:14

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784296379.4534488
- T_burst_arrival: 1784296379.4559057
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.0024569034576416016

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 30.61 | 2.09 | 6.74 | 3075.85 | 8.36 |
| balanced_decode | 24 | 100.00 | 0 | 10.84 | 2.21 | 3.73 | 1740.19 | 212.54 |
| decode_tail | 17 | 100.00 | 0 | 47.10 | 0.36 | 38.39 | 123.14 | 516.33 |
| total | 105 | 100.00 | 0 | 94.63 | 1.11 | 6.74 | 1255.72 | 284.06 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 186.18
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 4.60

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
