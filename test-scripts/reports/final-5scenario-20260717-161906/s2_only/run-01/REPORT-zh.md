# s2_only run-01 Report

generated_at: 2026-07-17T17:32:59

## Timing

- T_signal_recv: 1784280280.230987
- T_warmup_start: 1784280280.230987
- T_ready: 1784280479.077447
- T_burst_arrival: 1784280480.2191062
- Signal-to-Ready(s): 198.84645986557007
- Burst Safety Margin(s): 1.1416592597961426

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 27.09 | 2.36 | 13.63 | 3475.70 | 9.45 |
| balanced_decode | 24 | 100.00 | 0 | 7.50 | 3.20 | 2.97 | 2513.93 | 307.05 |
| decode_tail | 17 | 100.00 | 0 | 40.98 | 0.41 | 31.42 | 141.52 | 593.40 |
| total | 105 | 100.00 | 0 | 172.08 | 0.61 | 15.24 | 690.51 | 156.21 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 666.07
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [774.9019861221313, 477.55702771246433]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 11.63

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
