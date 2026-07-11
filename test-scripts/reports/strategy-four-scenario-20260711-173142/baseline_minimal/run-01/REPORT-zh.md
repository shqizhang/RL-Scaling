# baseline_minimal run-01 Report

generated_at: 2026-07-11T17:42:35

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783762459.6267805
- T_burst_arrival: 1783762459.6268969
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.0001163482666015625

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 321.28 | 0.25 | 85.32 | 2763.26 | 11.95 |
| balanced_decode | 32 | 100.00 | 0 | 27.27 | 1.17 | 7.28 | 1673.65 | 450.60 |
| decode_tail | 18 | 100.00 | 0 | 16.33 | 1.10 | 1.91 | 380.09 | 31.36 |
| total | 130 | 100.00 | 0 | 403.42 | 0.32 | 85.31 | 2329.15 | 41.24 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 804.86
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 17.80

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
