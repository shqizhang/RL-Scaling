# s3_only run-03 Report

generated_at: 2026-07-18T10:28:21

## Timing

- T_signal_recv: 1784341318.8201413
- T_warmup_start: 1784341318.8201413
- T_ready: 1784341508.624126
- T_burst_arrival: 1784341509.797964
- Signal-to-Ready(s): 189.8039846420288
- Burst Safety Margin(s): 1.1738381385803223

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 19.00 | 3.37 | 5.33 | 4955.75 | 13.47 |
| balanced_decode | 24 | 100.00 | 0 | 7.25 | 3.31 | 2.84 | 2602.83 | 317.90 |
| decode_tail | 17 | 100.00 | 0 | 46.32 | 0.37 | 35.43 | 125.23 | 498.69 |
| total | 105 | 100.00 | 0 | 78.77 | 1.33 | 5.47 | 1508.51 | 325.72 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 303.86
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-6d4cfd48d7dg86h']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 12.10

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
