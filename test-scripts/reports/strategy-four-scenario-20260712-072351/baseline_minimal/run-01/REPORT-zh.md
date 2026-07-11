# baseline_minimal run-01 Report

generated_at: 2026-07-12T07:29:45

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783812405.3644497
- T_burst_arrival: 1783812405.3645096
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 5.984306335449219e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 56.89 | 1.12 | 12.55 | 1657.25 | 4.50 |
| balanced_decode | 24 | 100.00 | 0 | 14.43 | 1.66 | 5.75 | 1310.49 | 159.65 |
| decode_tail | 18 | 100.00 | 0 | 13.77 | 1.31 | 1.84 | 445.24 | 37.19 |
| total | 106 | 100.00 | 0 | 90.44 | 1.17 | 12.54 | 1319.48 | 33.97 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 171.83
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 41.01

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
