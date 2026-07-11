# baseline_minimal run-01 Report

generated_at: 2026-07-06T18:44:05

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783334465.3597653
- T_burst_arrival: 1783334465.3598156
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 5.030632019042969e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 49.57 | 1.61 | 13.28 | 17911.18 | 77.47 |
| balanced_decode | 32 | 100.00 | 0 | 14.97 | 2.14 | 3.79 | 3048.09 | 820.77 |
| decode_tail | 18 | 100.00 | 0 | 16.62 | 1.08 | 1.95 | 373.50 | 34.67 |
| total | 130 | 100.00 | 0 | 88.51 | 1.47 | 12.01 | 10615.78 | 188.72 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 167.91
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 43.85

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
