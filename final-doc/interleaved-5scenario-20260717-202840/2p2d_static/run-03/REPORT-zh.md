# 2p2d_static run-03 Report

generated_at: 2026-07-17T22:03:12

## Timing

- T_signal_recv: 1784296617.3326848
- T_warmup_start: 1784296617.3326848
- T_ready: 1784296806.3222084
- T_burst_arrival: 1784296807.7976983
- Signal-to-Ready(s): 188.9895236492157
- Burst Safety Margin(s): 1.475489854812622

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 18.53 | 3.45 | 5.01 | 5089.21 | 13.82 |
| balanced_decode | 24 | 100.00 | 0 | 7.08 | 3.39 | 2.62 | 2670.75 | 325.37 |
| decode_tail | 17 | 100.00 | 0 | 41.29 | 0.41 | 31.84 | 141.30 | 589.05 |
| total | 105 | 100.00 | 0 | 73.42 | 1.43 | 5.75 | 1621.25 | 366.11 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 269.52
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 21.79

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
