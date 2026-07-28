# 2p2d_static run-03 Report

generated_at: 2026-07-18T10:12:14

## Timing

- T_signal_recv: 1784340337.5034807
- T_warmup_start: 1784340337.5034807
- T_ready: 1784340527.5181458
- T_burst_arrival: 1784340529.2760797
- Signal-to-Ready(s): 190.01466512680054
- Burst Safety Margin(s): 1.7579338550567627

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 22.75 | 2.81 | 6.11 | 4145.00 | 11.25 |
| balanced_decode | 24 | 100.00 | 0 | 8.10 | 2.96 | 3.11 | 2335.66 | 284.55 |
| decode_tail | 17 | 100.00 | 0 | 46.17 | 0.37 | 36.43 | 126.35 | 591.70 |
| total | 105 | 100.00 | 0 | 83.35 | 1.26 | 6.14 | 1428.21 | 358.51 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 333.38
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 0.00

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
