# s3_only run-01 Report

generated_at: 2026-07-14T15:51:10

## Timing

- T_signal_recv: 1784015089.0592186
- T_warmup_start: 1784015089.0592186
- T_ready: 1784015279.2599046
- T_burst_arrival: 1784015280.8000026
- Signal-to-Ready(s): 190.2006859779358
- Burst Safety Margin(s): 1.540097951889038

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 20.45 | 3.13 | 5.71 | 4606.71 | 12.52 |
| balanced_decode | 24 | 100.00 | 0 | 6.87 | 3.50 | 2.80 | 2751.32 | 335.61 |
| decode_tail | 17 | 100.00 | 0 | 37.12 | 0.46 | 32.03 | 156.69 | 534.15 |
| total | 105 | 100.00 | 0 | 70.43 | 1.49 | 5.79 | 1688.69 | 317.92 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 263.89
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-99f456c9-t7662']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 15.19

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
