# s3_only run-02 Report

generated_at: 2026-07-18T09:47:05

## Timing

- T_signal_recv: 1784338853.3000505
- T_warmup_start: 1784338853.3000505
- T_ready: 1784339042.0655768
- T_burst_arrival: 1784339043.61114
- Signal-to-Ready(s): 188.76552629470825
- Burst Safety Margin(s): 1.5455632209777832

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 6.94 | 9.23 | 1.47 | 13576.34 | 36.91 |
| balanced_decode | 24 | 100.00 | 0 | 5.17 | 4.64 | 1.91 | 3645.56 | 445.26 |
| decode_tail | 17 | 100.00 | 0 | 47.72 | 0.36 | 38.34 | 121.55 | 503.67 |
| total | 105 | 100.00 | 0 | 67.03 | 1.57 | 1.91 | 1772.70 | 396.75 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 257.08
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-6d4cfd48d7l5vx2']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 11.56

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
