# s2_only run-01 Report

generated_at: 2026-07-10T12:01:09

## Timing

- T_signal_recv: 1783655477.9545043
- T_warmup_start: 1783655477.9545043
- T_ready: 1783655671.16365
- T_burst_arrival: 1783655673.1567192
- Signal-to-Ready(s): 193.20914578437805
- Burst Safety Margin(s): 1.9930691719055176

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 48.81 | 1.64 | 12.79 | 18185.81 | 78.67 |
| balanced_decode | 32 | 100.00 | 0 | 13.67 | 2.34 | 4.00 | 3336.70 | 899.11 |
| decode_tail | 18 | 83.33 | 3 | 254.48 | 0.06 | 120.01 | 20.85 | 1.45 |
| total | 130 | 97.69 | 3 | 340.39 | 0.37 | 13.47 | 2757.46 | 48.46 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 97.6923076923077, 'timeout_count': 3, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['decode_tail timeout_count=3']}
- request-window GPU seconds: 1354.67
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [432.52452462911606, 612.6265432685614]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -98.79

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
