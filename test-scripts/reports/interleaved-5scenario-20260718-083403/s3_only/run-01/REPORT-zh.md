# s3_only run-01 Report

generated_at: 2026-07-18T09:03:35

## Timing

- T_signal_recv: 1784336221.7327492
- T_warmup_start: 1784336221.7327492
- T_ready: 1784336411.268711
- T_burst_arrival: 1784336412.911082
- Signal-to-Ready(s): 189.53596186637878
- Burst Safety Margin(s): 1.6423709392547607

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 19.64 | 3.26 | 6.20 | 4794.30 | 13.03 |
| balanced_decode | 24 | 100.00 | 0 | 7.28 | 3.30 | 3.01 | 2592.17 | 316.60 |
| decode_tail | 17 | 100.00 | 0 | 46.49 | 0.37 | 36.92 | 124.76 | 520.07 |
| total | 105 | 100.00 | 0 | 79.88 | 1.31 | 7.15 | 1487.48 | 334.70 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 311.72
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-6d4cfd48d7jstjc']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 8.40

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
