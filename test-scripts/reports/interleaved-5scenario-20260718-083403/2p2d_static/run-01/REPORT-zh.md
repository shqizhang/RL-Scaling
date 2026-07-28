# 2p2d_static run-01 Report

generated_at: 2026-07-18T08:47:22

## Timing

- T_signal_recv: 1784335256.4014223
- T_warmup_start: 1784335256.4014223
- T_ready: 1784335455.755382
- T_burst_arrival: 1784335457.4165845
- Signal-to-Ready(s): 199.35395979881287
- Burst Safety Margin(s): 1.6612024307250977

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 23.66 | 2.70 | 6.80 | 3984.73 | 10.82 |
| balanced_decode | 24 | 100.00 | 0 | 8.04 | 2.98 | 2.81 | 2350.88 | 286.40 |
| decode_tail | 17 | 100.00 | 0 | 42.62 | 0.40 | 37.33 | 136.87 | 640.94 |
| total | 105 | 100.00 | 0 | 80.08 | 1.31 | 6.96 | 1486.50 | 373.14 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 320.31
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 0.00

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
