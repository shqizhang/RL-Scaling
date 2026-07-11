# s3_only run-01 Report

generated_at: 2026-07-10T12:09:40

## Timing

- T_signal_recv: 1783656154.8601558
- T_warmup_start: 1783656154.8601558
- T_ready: 1783656349.3957005
- T_burst_arrival: 1783656351.420463
- Signal-to-Ready(s): 194.53554463386536
- Burst Safety Margin(s): 2.0247626304626465

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 29.73 | 2.69 | 6.36 | 29862.22 | 129.18 |
| balanced_decode | 32 | 28.12 | 0 | 9.82 | 0.92 | 3.36 | 1308.43 | 315.52 |
| decode_tail | 18 | 0.00 | 1 | 135.68 | 0.00 | 2.15 | 0.00 | 0.00 |
| total | 130 | 68.46 | 1 | 182.90 | 0.49 | 6.36 | 4923.84 | 37.93 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 68.46153846153847, 'timeout_count': 1, 'http_5xx_count': 15}
- scenario_gate: {'passed': False, 'reasons': ['decode_tail timeout_count=1']}
- request-window GPU seconds: 442.69
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-574b777c-54d9c4d8b7447ns']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 100.00

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
