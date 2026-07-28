# s3_only run-01 Report

generated_at: 2026-07-17T17:59:52

## Timing

- T_signal_recv: 1784282013.7869484
- T_warmup_start: 1784282013.7869484
- T_ready: 1784282202.0170252
- T_burst_arrival: 1784282203.6261363
- Signal-to-Ready(s): 188.23007678985596
- Burst Safety Margin(s): 1.6091110706329346

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 15.36 | 4.17 | 4.25 | 6128.92 | 16.66 |
| balanced_decode | 24 | 100.00 | 0 | 6.80 | 3.53 | 2.58 | 2773.68 | 338.77 |
| decode_tail | 17 | 100.00 | 0 | 40.39 | 0.42 | 29.97 | 143.60 | 495.91 |
| total | 105 | 100.00 | 0 | 67.94 | 1.55 | 4.33 | 1748.92 | 332.49 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 249.40
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-w6csk']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 12.57

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
