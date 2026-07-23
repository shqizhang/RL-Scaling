# s3_only run-03 Report

generated_at: 2026-07-17T22:19:21

## Timing

- T_signal_recv: 1784297565.882945
- T_warmup_start: 1784297565.882945
- T_ready: 1784297755.489867
- T_burst_arrival: 1784297757.1820142
- Signal-to-Ready(s): 189.60692191123962
- Burst Safety Margin(s): 1.6921472549438477

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 22.74 | 2.81 | 9.77 | 4140.01 | 11.26 |
| balanced_decode | 24 | 100.00 | 0 | 7.48 | 3.21 | 3.14 | 2520.99 | 307.91 |
| decode_tail | 17 | 100.00 | 0 | 40.47 | 0.42 | 29.81 | 143.32 | 525.78 |
| total | 105 | 100.00 | 0 | 77.32 | 1.36 | 10.74 | 1536.69 | 308.28 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 287.54
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-cb9jj']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 5.14

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
