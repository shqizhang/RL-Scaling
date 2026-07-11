# s2_only run-01 Report

generated_at: 2026-07-11T23:47:17

## Timing

- T_signal_recv: 1783784045.167766
- T_warmup_start: 1783784045.167766
- T_ready: 1783784231.6873186
- T_burst_arrival: 1783784233.51923
- Signal-to-Ready(s): 186.51955246925354
- Burst Safety Margin(s): 1.831911325454712

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 97.50 | 0 | 147.69 | 0.53 | 49.32 | 5860.30 | 25.35 |
| balanced_decode | 32 | 100.00 | 0 | 16.47 | 1.94 | 4.75 | 2769.41 | 746.25 |
| decode_tail | 18 | 77.78 | 4 | 251.98 | 0.06 | 120.02 | 19.89 | 1.27 |
| total | 130 | 95.38 | 4 | 475.05 | 0.26 | 51.14 | 1928.53 | 34.42 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 95.38461538461539, 'timeout_count': 4, 'http_5xx_count': 2}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 1885.89
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [533.0230612307787, 559.2358466237783]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -95.79

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
