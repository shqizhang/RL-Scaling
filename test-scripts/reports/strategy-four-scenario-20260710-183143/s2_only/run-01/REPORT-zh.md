# s2_only run-01 Report

generated_at: 2026-07-10T18:48:38

## Timing

- T_signal_recv: 1783679874.3451052
- T_warmup_start: 1783679874.3451052
- T_ready: 1783680070.15268
- T_burst_arrival: 1783680071.8950396
- Signal-to-Ready(s): 195.80757474899292
- Burst Safety Margin(s): 1.7423596382141113

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 38.52 | 2.08 | 13.80 | 23043.69 | 99.68 |
| balanced_decode | 32 | 100.00 | 0 | 13.47 | 2.38 | 3.69 | 3386.36 | 912.50 |
| decode_tail | 18 | 77.78 | 4 | 253.84 | 0.06 | 120.01 | 19.74 | 1.26 |
| total | 130 | 96.92 | 4 | 357.76 | 0.35 | 14.79 | 2622.78 | 45.97 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 96.92307692307692, 'timeout_count': 4, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['decode_tail timeout_count=4']}
- request-window GPU seconds: 1420.10
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [430.50110898911953, 606.7923195660114]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -95.76

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
