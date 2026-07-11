# baseline_minimal run-01 Report

generated_at: 2026-07-10T18:37:01

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783679636.7655368
- T_burst_arrival: 1783679636.7657225
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.0001857280731201172

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 49.35 | 1.62 | 13.36 | 17990.49 | 77.81 |
| balanced_decode | 32 | 100.00 | 0 | 15.46 | 2.07 | 3.99 | 2952.54 | 794.91 |
| decode_tail | 18 | 100.00 | 0 | 19.29 | 0.93 | 2.34 | 321.80 | 26.55 |
| total | 130 | 100.00 | 0 | 92.14 | 1.41 | 12.12 | 10198.02 | 180.58 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 177.24
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 14.38

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
