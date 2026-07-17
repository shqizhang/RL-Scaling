# baseline_minimal run-01 Report

generated_at: 2026-07-14T15:35:11

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784014312.1781132
- T_burst_arrival: 1784014312.1781883
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 7.510185241699219e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 34.43 | 1.86 | 9.10 | 2738.39 | 7.43 |
| balanced_decode | 24 | 100.00 | 0 | 10.29 | 2.33 | 3.74 | 1838.44 | 223.97 |
| decode_tail | 17 | 100.00 | 0 | 46.37 | 0.37 | 37.65 | 125.80 | 524.43 |
| total | 105 | 100.00 | 0 | 97.36 | 1.08 | 9.10 | 1222.68 | 276.10 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 186.58
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 8.04

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
