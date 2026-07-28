# s3_only run-03 Report

generated_at: 2026-07-17T18:20:38

## Timing

- T_signal_recv: 1784283251.9060698
- T_warmup_start: 1784283251.9060698
- T_ready: 1784283443.1553137
- T_burst_arrival: 1784283444.4279487
- Signal-to-Ready(s): 191.24924397468567
- Burst Safety Margin(s): 1.2726349830627441

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 14.69 | 4.36 | 3.92 | 6410.79 | 17.43 |
| balanced_decode | 24 | 100.00 | 0 | 7.18 | 3.34 | 2.61 | 2626.16 | 320.75 |
| decode_tail | 17 | 100.00 | 0 | 41.57 | 0.41 | 31.73 | 139.54 | 546.62 |
| total | 105 | 100.00 | 0 | 70.06 | 1.50 | 4.03 | 1696.00 | 360.84 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 276.52
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-jd7bk']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 5.08

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
