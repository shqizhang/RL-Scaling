# s3_only run-01 Report

generated_at: 2026-07-17T20:57:43

## Timing

- T_signal_recv: 1784292671.0100942
- T_warmup_start: 1784292671.0100942
- T_ready: 1784292868.0068882
- T_burst_arrival: 1784292869.6941998
- Signal-to-Ready(s): 196.99679398536682
- Burst Safety Margin(s): 1.6873116493225098

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 19.45 | 3.29 | 5.36 | 4840.03 | 13.16 |
| balanced_decode | 24 | 100.00 | 0 | 7.81 | 3.07 | 3.05 | 2414.53 | 294.90 |
| decode_tail | 17 | 100.00 | 0 | 47.60 | 0.36 | 32.37 | 121.85 | 442.39 |
| total | 105 | 100.00 | 0 | 81.17 | 1.29 | 5.65 | 1463.81 | 290.94 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 299.79
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-nq5lp']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 19.13

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
