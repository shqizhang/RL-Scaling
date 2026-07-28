# mixed_strategy run-03 Report

generated_at: 2026-07-17T22:31:00

## Timing

- T_signal_recv: 1784298140.459521
- T_warmup_start: 1784298140.459521
- T_ready: 1784298330.1812747
- T_burst_arrival: 1784298332.0835524
- Signal-to-Ready(s): 189.72175359725952
- Burst Safety Margin(s): 1.9022777080535889

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 98.44 | 0 | 17.05 | 3.69 | 5.11 | 5431.11 | 14.78 |
| balanced_decode | 24 | 100.00 | 0 | 7.14 | 3.36 | 2.54 | 2638.37 | 322.65 |
| decode_tail | 17 | 100.00 | 0 | 40.65 | 0.42 | 29.88 | 142.27 | 499.42 |
| total | 105 | 99.05 | 0 | 167.63 | 0.62 | 5.11 | 699.43 | 136.35 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.04761904761905, 'timeout_count': 0, 'http_5xx_count': 1}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 637.92
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [416.267778724432, 466.8925078585744]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-7xmmg']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 22.97

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
