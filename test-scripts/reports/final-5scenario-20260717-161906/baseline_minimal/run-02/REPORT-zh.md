# baseline_minimal run-02 Report

generated_at: 2026-07-17T16:28:45

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784276733.6986213
- T_burst_arrival: 1784276733.6986852
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 6.389617919921875e-05

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 36.96 | 1.73 | 6.87 | 2547.51 | 6.93 |
| balanced_decode | 24 | 100.00 | 0 | 10.38 | 2.31 | 3.66 | 1817.41 | 221.97 |
| decode_tail | 17 | 100.00 | 0 | 46.71 | 0.36 | 37.85 | 124.18 | 520.68 |
| total | 105 | 100.00 | 0 | 100.78 | 1.04 | 6.91 | 1179.05 | 266.72 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 184.72
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 4.87

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
