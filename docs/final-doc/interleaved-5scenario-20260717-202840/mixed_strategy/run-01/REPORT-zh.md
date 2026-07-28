# mixed_strategy run-01 Report

generated_at: 2026-07-17T21:09:17

## Timing

- T_signal_recv: 1784293243.0723486
- T_warmup_start: 1784293243.0723486
- T_ready: 1784293433.4914024
- T_burst_arrival: 1784293435.1675973
- Signal-to-Ready(s): 190.4190537929535
- Burst Safety Margin(s): 1.6761949062347412

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 17.77 | 3.60 | 5.42 | 5294.97 | 14.41 |
| balanced_decode | 24 | 100.00 | 0 | 7.57 | 3.17 | 2.65 | 2487.94 | 304.26 |
| decode_tail | 17 | 100.00 | 0 | 40.86 | 0.42 | 30.46 | 141.54 | 500.06 |
| total | 105 | 100.00 | 0 | 170.18 | 0.62 | 5.42 | 697.60 | 135.10 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 642.07
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [452.2230941802263, 407.2542265057564]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-txvvw']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 17.81

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
