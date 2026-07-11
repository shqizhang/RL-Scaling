# s2_only run-01 Report

generated_at: 2026-07-11T17:56:46

## Timing

- T_signal_recv: 1783762997.5276809
- T_warmup_start: 1783762997.5276809
- T_ready: 1783763181.9044788
- T_burst_arrival: 1783763183.1951745
- Signal-to-Ready(s): 184.376797914505
- Burst Safety Margin(s): 1.2906956672668457

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 166.69 | 0.48 | 50.77 | 5325.63 | 23.04 |
| balanced_decode | 32 | 100.00 | 0 | 16.65 | 1.92 | 5.03 | 2739.25 | 738.12 |
| decode_tail | 18 | 77.78 | 4 | 252.00 | 0.06 | 120.01 | 19.89 | 1.27 |
| total | 130 | 96.92 | 4 | 483.15 | 0.26 | 51.40 | 1942.10 | 34.04 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 96.92307692307692, 'timeout_count': 4, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 1904.45
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [435.4087570682168, 506.6629620268941]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -94.24

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
