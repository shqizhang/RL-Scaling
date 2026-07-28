# 2p2d_static run-01 Report

generated_at: 2026-07-17T16:39:36

## Timing

- T_signal_recv: 1784277191.4465299
- T_warmup_start: 1784277191.4465299
- T_ready: 1784277391.179939
- T_burst_arrival: 1784277392.8274949
- Signal-to-Ready(s): 199.73340916633606
- Burst Safety Margin(s): 1.6475558280944824

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 22.95 | 2.79 | 9.83 | 4109.17 | 11.16 |
| balanced_decode | 24 | 100.00 | 0 | 7.92 | 3.03 | 3.25 | 2387.32 | 290.84 |
| decode_tail | 17 | 100.00 | 0 | 41.41 | 0.41 | 31.45 | 140.90 | 587.36 |
| total | 105 | 100.00 | 0 | 79.54 | 1.32 | 10.14 | 1496.56 | 337.95 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 282.86
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 9.99

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
