# s3_only run-02 Report

generated_at: 2026-07-17T18:11:12

## Timing

- T_signal_recv: 1784282568.3056512
- T_warmup_start: 1784282568.3056512
- T_ready: 1784282851.1929815
- T_burst_arrival: 1784282852.869264
- Signal-to-Ready(s): 282.8873302936554
- Burst Safety Margin(s): 1.6762824058532715

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 18.66 | 3.43 | 6.21 | 5047.25 | 13.72 |
| balanced_decode | 24 | 100.00 | 0 | 6.80 | 3.53 | 2.46 | 2774.56 | 338.88 |
| decode_tail | 17 | 100.00 | 0 | 40.76 | 0.42 | 31.21 | 142.30 | 486.15 |
| total | 105 | 100.00 | 0 | 106.37 | 0.99 | 6.98 | 1117.08 | 210.35 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 405.57
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-tc76m']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 22.31

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
