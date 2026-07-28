# baseline_minimal run-02 Report

generated_at: 2026-07-18T09:24:53

## Timing

- T_signal_recv: None
- T_warmup_start: None
- T_ready: 1784337689.9156165
- T_burst_arrival: 1784337689.917565
- Signal-to-Ready(s): None
- Burst Safety Margin(s): 0.0019485950469970703

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 33.39 | 1.92 | 7.21 | 2820.27 | 7.67 |
| balanced_decode | 24 | 100.00 | 0 | 9.52 | 2.52 | 3.41 | 1981.11 | 241.97 |
| decode_tail | 17 | 100.00 | 0 | 53.55 | 0.32 | 44.13 | 108.30 | 510.13 |
| total | 105 | 100.00 | 0 | 103.33 | 1.02 | 7.21 | 1149.93 | 289.17 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 206.66
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
