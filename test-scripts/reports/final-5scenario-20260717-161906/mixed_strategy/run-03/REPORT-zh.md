# mixed_strategy run-03 Report

generated_at: 2026-07-17T18:58:43

## Timing

- T_signal_recv: 1784285402.0113285
- T_warmup_start: 1784285402.0113285
- T_ready: 1784285591.8829832
- T_burst_arrival: 1784285593.4508336
- Signal-to-Ready(s): 189.87165474891663
- Burst Safety Margin(s): 1.5678503513336182

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 17.48 | 3.66 | 4.38 | 5384.09 | 14.65 |
| balanced_decode | 24 | 100.00 | 0 | 7.49 | 3.20 | 2.76 | 2513.84 | 307.43 |
| decode_tail | 17 | 100.00 | 0 | 50.37 | 0.34 | 37.91 | 114.81 | 430.01 |
| total | 105 | 100.00 | 0 | 186.25 | 0.56 | 5.42 | 637.42 | 130.04 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 699.99
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [452.37798150628805, 385.2089876309037]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-rgqnv']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 33.01

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
