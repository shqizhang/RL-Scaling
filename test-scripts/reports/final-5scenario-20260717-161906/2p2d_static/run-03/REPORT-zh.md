# 2p2d_static run-03 Report

generated_at: 2026-07-17T16:53:40

## Timing

- T_signal_recv: 1784278043.0373857
- T_warmup_start: 1784278043.0373857
- T_ready: 1784278233.1616113
- T_burst_arrival: 1784278234.5803156
- Signal-to-Ready(s): 190.12422561645508
- Burst Safety Margin(s): 1.4187042713165283

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 21.63 | 2.96 | 9.45 | 4359.03 | 11.84 |
| balanced_decode | 24 | 100.00 | 0 | 7.31 | 3.28 | 2.98 | 2586.41 | 315.10 |
| decode_tail | 17 | 100.00 | 0 | 41.24 | 0.41 | 31.76 | 141.47 | 589.72 |
| total | 105 | 100.00 | 0 | 77.21 | 1.36 | 9.90 | 1541.77 | 348.16 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 283.16
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 9.37

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
