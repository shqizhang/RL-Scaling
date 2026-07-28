# baseline_minimal run-02 Report

generated_at: 2026-07-17T21:15:32

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784293934.4896538
- T_burst_arrival: 1784293934.4904006
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.0007467269897460938

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 33.31 | 1.92 | 6.57 | 2826.44 | 7.68 |
| balanced_decode | 24 | 100.00 | 0 | 9.98 | 2.40 | 3.44 | 1890.26 | 230.87 |
| decode_tail | 17 | 100.00 | 0 | 46.96 | 0.36 | 37.96 | 123.50 | 517.86 |
| total | 105 | 100.00 | 0 | 97.61 | 1.08 | 6.64 | 1217.36 | 275.39 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 178.31
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 15.06

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
