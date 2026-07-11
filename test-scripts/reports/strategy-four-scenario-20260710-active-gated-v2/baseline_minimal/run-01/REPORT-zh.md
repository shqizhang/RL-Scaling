# baseline_minimal run-01 Report

generated_at: 2026-07-10T11:50:26

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783655243.6737947
- T_burst_arrival: 1783655243.673895
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.00010013580322265625

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 49.77 | 1.61 | 13.60 | 17839.53 | 77.16 |
| balanced_decode | 32 | 100.00 | 0 | 14.88 | 2.15 | 3.85 | 3065.97 | 825.58 |
| decode_tail | 18 | 100.00 | 0 | 18.13 | 0.99 | 2.25 | 342.29 | 28.24 |
| total | 130 | 100.00 | 0 | 90.73 | 1.43 | 12.28 | 10356.49 | 183.40 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 177.97
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 15.28

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
