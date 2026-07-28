# s2_only run-01 Report

generated_at: 2026-07-18T08:56:19

## Timing

- T_signal_recv: 1784335685.7720256
- T_warmup_start: 1784335685.7720256
- T_ready: 1784335874.4171798
- T_burst_arrival: 1784335876.212413
- Signal-to-Ready(s): 188.6451542377472
- Burst Safety Margin(s): 1.7952332496643066

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 20.46 | 3.13 | 6.46 | 4601.49 | 12.51 |
| balanced_decode | 24 | 100.00 | 0 | 6.77 | 3.54 | 2.52 | 2784.94 | 340.15 |
| decode_tail | 17 | 100.00 | 0 | 42.02 | 0.40 | 36.47 | 138.02 | 650.12 |
| total | 105 | 100.00 | 0 | 171.71 | 0.61 | 8.80 | 692.00 | 174.01 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 686.84
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [967.4424976110458, 917.1536825597286]
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
