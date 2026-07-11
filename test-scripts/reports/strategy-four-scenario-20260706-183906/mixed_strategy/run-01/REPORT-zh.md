# mixed_strategy run-01 Report

generated_at: 2026-07-06T19:16:33

## Timing

- T_signal_recv: 1783335959.9505448
- T_warmup_start: 1783335959.9505448
- T_ready: 1783336155.3787942
- T_burst_arrival: 1783336157.1154509
- Signal-to-Ready(s): 195.42824935913086
- Burst Safety Margin(s): 1.736656665802002

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 49.07 | 1.63 | 13.14 | 18091.26 | 78.26 |
| balanced_decode | 32 | 100.00 | 0 | 13.09 | 2.44 | 3.82 | 3483.63 | 938.71 |
| decode_tail | 18 | 94.44 | 1 | 134.20 | 0.13 | 1.94 | 43.92 | 3.82 |
| total | 130 | 99.23 | 1 | 208.14 | 0.62 | 12.23 | 4512.39 | 79.95 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.23076923076923, 'timeout_count': 1, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['S3 migration/drain evidence missing']}
- request-window GPU seconds: 828.94
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [580.3799778223038, 483.25217235833406]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 2.03

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
