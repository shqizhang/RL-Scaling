# baseline_minimal run-01 Report

generated_at: 2026-07-17T20:34:50

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784291497.3878794
- T_burst_arrival: 1784291497.3889034
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.001024007797241211

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 28.87 | 2.22 | 6.55 | 3261.54 | 8.87 |
| balanced_decode | 24 | 100.00 | 0 | 9.45 | 2.54 | 3.36 | 1996.32 | 243.83 |
| decode_tail | 17 | 100.00 | 0 | 46.97 | 0.36 | 37.78 | 123.48 | 517.77 |
| total | 105 | 100.00 | 0 | 91.73 | 1.14 | 7.03 | 1295.43 | 293.05 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 171.50
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 4.56

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
