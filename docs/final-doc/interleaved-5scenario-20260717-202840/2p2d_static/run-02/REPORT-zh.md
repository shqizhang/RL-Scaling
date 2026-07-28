# 2p2d_static run-02 Report

generated_at: 2026-07-17T21:22:25

## Timing

- T_signal_recv: 1784294173.174624
- T_warmup_start: 1784294173.174624
- T_ready: 1784294364.3729753
- T_burst_arrival: 1784294366.1930678
- Signal-to-Ready(s): 191.19835138320923
- Burst Safety Margin(s): 1.8200924396514893

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 21.20 | 3.02 | 5.63 | 4448.15 | 12.08 |
| balanced_decode | 24 | 100.00 | 0 | 6.94 | 3.46 | 2.70 | 2726.23 | 332.13 |
| decode_tail | 17 | 100.00 | 0 | 41.06 | 0.41 | 30.51 | 142.10 | 592.35 |
| total | 105 | 100.00 | 0 | 75.36 | 1.39 | 5.73 | 1579.53 | 356.69 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 265.89
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 21.32

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
