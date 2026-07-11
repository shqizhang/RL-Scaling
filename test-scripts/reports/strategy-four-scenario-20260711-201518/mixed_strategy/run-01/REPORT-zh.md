# mixed_strategy run-01 Report

generated_at: 2026-07-11T21:09:01

## Timing

- T_signal_recv: 1783774473.4402623
- T_warmup_start: 1783774473.4402623
- T_ready: 1783774659.7580016
- T_burst_arrival: 1783774661.42691
- Signal-to-Ready(s): 186.31773924827576
- Burst Safety Margin(s): 1.6689083576202393

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 178.90 | 0.45 | 59.73 | 4961.99 | 21.46 |
| balanced_decode | 32 | 100.00 | 0 | 17.72 | 1.81 | 5.28 | 2572.95 | 693.31 |
| decode_tail | 18 | 77.78 | 4 | 251.53 | 0.06 | 120.01 | 19.93 | 1.27 |
| total | 130 | 96.92 | 4 | 496.20 | 0.25 | 62.82 | 1891.04 | 33.15 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 96.92307692307692, 'timeout_count': 4, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['S3 migration/drain evidence missing']}
- request-window GPU seconds: 1956.11
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [422.94759675860405, 441.81597139686346]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 2.14

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
