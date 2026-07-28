# mixed_strategy run-01 Report

generated_at: 2026-07-18T09:18:33

## Timing

- T_signal_recv: 1784337004.9767377
- T_warmup_start: 1784337004.9767377
- T_ready: 1784337193.3723693
- T_burst_arrival: 1784337194.9292922
- Signal-to-Ready(s): 188.39563155174255
- Burst Safety Margin(s): 1.5569229125976562

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 17.81 | 3.59 | 5.01 | 5282.99 | 14.37 |
| balanced_decode | 24 | 100.00 | 0 | 6.95 | 3.45 | 2.64 | 2711.08 | 331.55 |
| decode_tail | 17 | 100.00 | 0 | 45.73 | 0.37 | 35.34 | 126.46 | 458.00 |
| total | 105 | 100.00 | 0 | 177.85 | 0.59 | 5.01 | 667.52 | 132.16 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 696.79
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [903.5306368023157, 1076.250720769167]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-6d4cfd48d7f7g5s']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 15.98

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
