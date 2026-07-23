# s2_only run-01 Report

generated_at: 2026-07-17T20:50:28

## Timing

- T_signal_recv: 1784292141.229591
- T_warmup_start: 1784292141.229591
- T_ready: 1784292330.3662395
- T_burst_arrival: 1784292331.6013992
- Signal-to-Ready(s): 189.13664865493774
- Burst Safety Margin(s): 1.2351596355438232

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 20.88 | 3.07 | 7.18 | 4510.32 | 12.26 |
| balanced_decode | 24 | 100.00 | 0 | 7.09 | 3.39 | 2.63 | 2660.79 | 324.98 |
| decode_tail | 17 | 100.00 | 0 | 41.52 | 0.41 | 31.12 | 139.68 | 585.68 |
| total | 105 | 100.00 | 0 | 168.44 | 0.62 | 7.19 | 705.44 | 159.58 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 657.77
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [421.80973291397095, 395.25246527045965]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 9.54

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
