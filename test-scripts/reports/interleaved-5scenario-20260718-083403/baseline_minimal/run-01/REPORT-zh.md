# baseline_minimal run-01 Report

generated_at: 2026-07-18T08:40:14

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784335004.529743
- T_burst_arrival: 1784335004.5317645
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.0020215511322021484

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 37.94 | 1.69 | 10.25 | 2481.51 | 6.75 |
| balanced_decode | 24 | 100.00 | 0 | 11.61 | 2.07 | 4.16 | 1624.86 | 198.46 |
| decode_tail | 17 | 100.00 | 0 | 53.53 | 0.32 | 44.08 | 108.35 | 510.35 |
| total | 105 | 100.00 | 0 | 109.75 | 0.96 | 10.55 | 1082.70 | 272.26 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 219.50
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
