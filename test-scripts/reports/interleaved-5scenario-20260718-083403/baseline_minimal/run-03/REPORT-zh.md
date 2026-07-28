# baseline_minimal run-03 Report

generated_at: 2026-07-18T10:04:53

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784340088.8742132
- T_burst_arrival: 1784340088.8747199
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.0005066394805908203

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 34.15 | 1.87 | 6.99 | 2757.42 | 7.50 |
| balanced_decode | 24 | 100.00 | 0 | 10.23 | 2.35 | 3.70 | 1843.96 | 225.22 |
| decode_tail | 17 | 100.00 | 0 | 53.69 | 0.32 | 44.23 | 108.02 | 508.83 |
| total | 105 | 100.00 | 0 | 104.74 | 1.00 | 6.99 | 1134.50 | 285.29 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 209.47
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
