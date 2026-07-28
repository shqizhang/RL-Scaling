# baseline_minimal run-03 Report

generated_at: 2026-07-17T16:32:30

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784276965.754297
- T_burst_arrival: 1784276965.7543628
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 6.580352783203125e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 29.69 | 2.16 | 7.64 | 3171.04 | 8.62 |
| balanced_decode | 24 | 100.00 | 0 | 9.83 | 2.44 | 3.66 | 1918.38 | 234.31 |
| decode_tail | 17 | 100.00 | 0 | 47.00 | 0.36 | 37.97 | 123.42 | 517.50 |
| total | 105 | 100.00 | 0 | 93.49 | 1.12 | 7.66 | 1270.97 | 287.51 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 179.83
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 8.21

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
