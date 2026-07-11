# baseline_minimal run-01 Report

generated_at: 2026-07-11T23:33:23

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783783496.8537903
- T_burst_arrival: 1783783496.8538537
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 6.341934204101562e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 323.68 | 0.25 | 89.44 | 2742.83 | 11.86 |
| balanced_decode | 32 | 100.00 | 0 | 29.45 | 1.09 | 8.24 | 1549.71 | 417.30 |
| decode_tail | 18 | 100.00 | 0 | 14.44 | 1.25 | 1.81 | 429.69 | 35.45 |
| total | 130 | 100.00 | 0 | 406.86 | 0.32 | 84.92 | 2309.47 | 40.90 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 806.63
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 17.05

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
