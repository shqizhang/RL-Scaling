# s2_only run-01 Report

generated_at: 2026-07-14T15:44:05

## Timing

- T_signal_recv: 1784014553.3613796
- T_warmup_start: 1784014553.3613796
- T_ready: 1784014742.1600509
- T_burst_arrival: 1784014743.907871
- Signal-to-Ready(s): 188.79867124557495
- Burst Safety Margin(s): 1.7478201389312744

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 98.44 | 0 | 22.08 | 2.85 | 8.82 | 4200.06 | 11.41 |
| balanced_decode | 24 | 100.00 | 0 | 8.11 | 2.96 | 2.82 | 2329.18 | 284.12 |
| decode_tail | 17 | 100.00 | 0 | 37.39 | 0.45 | 32.34 | 155.56 | 650.39 |
| total | 105 | 99.05 | 0 | 170.84 | 0.61 | 9.05 | 687.54 | 157.32 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.04761904761905, 'timeout_count': 0, 'http_5xx_count': 1}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 681.19
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [617.9594341665506, 402.6628937572241]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -87.81

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
