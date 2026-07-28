# s3_only run-02 Report

generated_at: 2026-07-17T21:38:35

## Timing

- T_signal_recv: 1784295129.3143563
- T_warmup_start: 1784295129.3143563
- T_ready: 1784295320.1763504
- T_burst_arrival: 1784295321.7059453
- Signal-to-Ready(s): 190.86199402809143
- Burst Safety Margin(s): 1.529594898223877

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 22.06 | 2.90 | 6.74 | 4267.91 | 11.60 |
| balanced_decode | 24 | 100.00 | 0 | 7.68 | 3.13 | 2.84 | 2456.73 | 300.06 |
| decode_tail | 17 | 100.00 | 0 | 41.45 | 0.41 | 31.14 | 139.92 | 537.61 |
| total | 105 | 100.00 | 0 | 77.64 | 1.35 | 7.64 | 1530.44 | 320.00 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 288.20
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-xbmk4']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 9.95

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
