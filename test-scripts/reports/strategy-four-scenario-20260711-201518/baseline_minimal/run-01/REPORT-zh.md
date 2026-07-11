# baseline_minimal run-01 Report

generated_at: 2026-07-11T20:25:36

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783772273.7995496
- T_burst_arrival: 1783772273.7996182
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 6.866455078125e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 296.93 | 0.27 | 91.80 | 2989.94 | 12.93 |
| balanced_decode | 32 | 100.00 | 0 | 22.77 | 1.41 | 6.81 | 2004.36 | 539.72 |
| decode_tail | 18 | 100.00 | 0 | 16.33 | 1.10 | 1.88 | 380.05 | 31.35 |
| total | 130 | 100.00 | 0 | 342.71 | 0.38 | 91.79 | 2741.79 | 48.55 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 678.15
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 20.17

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
