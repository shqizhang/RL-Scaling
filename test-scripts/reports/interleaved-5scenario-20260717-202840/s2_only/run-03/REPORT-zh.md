# s2_only run-03 Report

generated_at: 2026-07-17T22:12:04

## Timing

- T_signal_recv: 1784297034.8289587
- T_warmup_start: 1784297034.8289587
- T_ready: 1784297224.355565
- T_burst_arrival: 1784297226.0897517
- Signal-to-Ready(s): 189.52660632133484
- Burst Safety Margin(s): 1.7341866493225098

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 21.71 | 2.95 | 7.78 | 4337.62 | 11.79 |
| balanced_decode | 24 | 100.00 | 0 | 7.67 | 3.13 | 2.86 | 2459.40 | 300.38 |
| decode_tail | 17 | 100.00 | 0 | 41.21 | 0.41 | 31.51 | 140.74 | 590.14 |
| total | 105 | 100.00 | 0 | 169.62 | 0.62 | 7.86 | 700.53 | 158.47 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 652.12
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [446.2512116879225, 430.5132981389761]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 10.12

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
