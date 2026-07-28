# mixed_strategy run-02 Report

generated_at: 2026-07-17T21:50:04

## Timing

- T_signal_recv: 1784295693.7152762
- T_warmup_start: 1784295693.7152762
- T_ready: 1784295883.7110815
- T_burst_arrival: 1784295885.145133
- Signal-to-Ready(s): 189.9958052635193
- Burst Safety Margin(s): 1.434051513671875

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 18.54 | 3.45 | 5.00 | 5073.99 | 13.80 |
| balanced_decode | 24 | 100.00 | 0 | 7.41 | 3.24 | 2.81 | 2541.35 | 310.79 |
| decode_tail | 17 | 100.00 | 0 | 41.34 | 0.41 | 31.47 | 139.89 | 511.87 |
| total | 105 | 100.00 | 0 | 171.54 | 0.61 | 5.04 | 692.09 | 138.28 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 660.41
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [501.8954696133733, 505.7490570470691]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-tq8q7']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 23.13

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
