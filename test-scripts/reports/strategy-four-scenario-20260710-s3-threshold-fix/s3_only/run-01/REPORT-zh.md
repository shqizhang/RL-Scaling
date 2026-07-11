# s3_only run-01 Report

generated_at: 2026-07-10T12:18:43

## Timing

- T_signal_recv: 1783656694.4260721
- T_warmup_start: 1783656694.4260721
- T_ready: 1783656886.8074915
- T_burst_arrival: 1783656888.480913
- Signal-to-Ready(s): 192.3814194202423
- Burst Safety Margin(s): 1.6734213829040527

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 29.69 | 2.69 | 6.24 | 29898.88 | 129.33 |
| balanced_decode | 32 | 100.00 | 0 | 12.79 | 2.50 | 3.33 | 3566.15 | 960.94 |
| decode_tail | 18 | 94.44 | 1 | 134.94 | 0.13 | 2.05 | 43.68 | 3.44 |
| total | 130 | 99.23 | 1 | 185.25 | 0.70 | 6.24 | 5070.08 | 89.57 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.23076923076923, 'timeout_count': 1, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['S3 migration/drain evidence missing', 'decode_tail timeout_count=1']}
- request-window GPU seconds: 723.75
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 2.67

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
