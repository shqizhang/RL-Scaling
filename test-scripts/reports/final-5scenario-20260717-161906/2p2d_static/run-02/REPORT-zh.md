# 2p2d_static run-02 Report

generated_at: 2026-07-17T16:46:40

## Timing

- T_signal_recv: 1784277619.8358603
- T_warmup_start: 1784277619.8358603
- T_ready: 1784277818.825564
- T_burst_arrival: 1784277820.4934947
- Signal-to-Ready(s): 198.98970365524292
- Burst Safety Margin(s): 1.6679308414459229

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 21.30 | 3.00 | 7.99 | 4426.46 | 12.02 |
| balanced_decode | 24 | 100.00 | 0 | 7.08 | 3.39 | 2.65 | 2672.88 | 325.63 |
| decode_tail | 17 | 100.00 | 0 | 40.71 | 0.42 | 30.57 | 143.30 | 597.35 |
| total | 105 | 100.00 | 0 | 75.88 | 1.38 | 8.87 | 1568.69 | 354.24 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 275.70
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 17.22

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
