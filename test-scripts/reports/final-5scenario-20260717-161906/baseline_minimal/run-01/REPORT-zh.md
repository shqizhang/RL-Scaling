# baseline_minimal run-01 Report

generated_at: 2026-07-17T16:24:53

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784276496.819183
- T_burst_arrival: 1784276496.819253
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 6.985664367675781e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 33.25 | 1.92 | 9.09 | 2831.82 | 7.70 |
| balanced_decode | 24 | 100.00 | 0 | 10.41 | 2.30 | 3.68 | 1811.45 | 221.25 |
| decode_tail | 17 | 100.00 | 0 | 46.88 | 0.36 | 37.73 | 123.73 | 518.82 |
| total | 105 | 100.00 | 0 | 96.89 | 1.08 | 9.09 | 1226.42 | 277.44 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 181.15
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 8.51

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
