# s2_only run-01 Report

generated_at: 2026-07-11T20:39:31

## Timing

- T_signal_recv: 1783772779.8450367
- T_warmup_start: 1783772779.8450367
- T_ready: 1783772972.9453115
- T_burst_arrival: 1783772974.5683303
- Signal-to-Ready(s): 193.10027480125427
- Burst Safety Margin(s): 1.623018741607666

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 146.77 | 0.55 | 49.07 | 6048.38 | 26.16 |
| balanced_decode | 32 | 100.00 | 0 | 18.74 | 1.71 | 5.05 | 2433.25 | 655.19 |
| decode_tail | 18 | 77.78 | 4 | 251.48 | 0.06 | 120.01 | 19.93 | 1.27 |
| total | 130 | 96.92 | 4 | 467.67 | 0.27 | 50.55 | 2006.39 | 35.15 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 96.92307692307692, 'timeout_count': 4, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 1856.68
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [505.7417247444391, 483.5230251774192]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -99.03

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
