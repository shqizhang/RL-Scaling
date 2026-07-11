# baseline_minimal run-01 Report

generated_at: 2026-07-10T11:35:12

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1783654329.2246683
- T_burst_arrival: 1783654329.2247558
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 8.749961853027344e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 49.08 | 1.63 | 13.09 | 18090.49 | 78.25 |
| balanced_decode | 32 | 100.00 | 0 | 14.70 | 2.18 | 3.84 | 3105.19 | 836.14 |
| decode_tail | 18 | 100.00 | 0 | 18.11 | 0.99 | 2.15 | 342.63 | 31.80 |
| total | 130 | 100.00 | 0 | 89.37 | 1.45 | 11.76 | 10513.81 | 186.91 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 162.74
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 43.41

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
