# s2_only run-01 Report

generated_at: 2026-07-06T18:54:19

## Timing

- T_signal_recv: 1783334694.035197
- T_warmup_start: 1783334694.035197
- T_ready: 1783334887.0665064
- T_burst_arrival: 1783334888.9271827
- Signal-to-Ready(s): 193.0313093662262
- Burst Safety Margin(s): 1.8606762886047363

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 52.83 | 1.51 | 14.13 | 16802.65 | 72.68 |
| balanced_decode | 32 | 100.00 | 0 | 13.28 | 2.41 | 3.79 | 3433.20 | 925.12 |
| decode_tail | 18 | 94.44 | 1 | 134.26 | 0.13 | 1.93 | 43.90 | 3.81 |
| total | 130 | 99.23 | 1 | 212.54 | 0.61 | 13.46 | 4419.06 | 78.29 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.23076923076923, 'timeout_count': 1, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 827.46
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [429.2339663952589, 475.46351235359907]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -97.22

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
