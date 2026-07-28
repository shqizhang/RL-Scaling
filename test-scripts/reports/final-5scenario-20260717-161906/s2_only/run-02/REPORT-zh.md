# s2_only run-02 Report

generated_at: 2026-07-17T17:42:16

## Timing

- T_signal_recv: 1784280875.4734707
- T_warmup_start: 1784280875.4734707
- T_ready: 1784281063.5951457
- T_burst_arrival: 1784281064.9770167
- Signal-to-Ready(s): 188.12167501449585
- Burst Safety Margin(s): 1.381870985031128

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 17.12 | 3.74 | 4.55 | 5501.17 | 14.96 |
| balanced_decode | 24 | 100.00 | 0 | 6.35 | 3.78 | 2.25 | 2971.67 | 362.95 |
| decode_tail | 17 | 100.00 | 0 | 41.67 | 0.41 | 31.01 | 139.19 | 583.63 |
| total | 105 | 100.00 | 0 | 151.15 | 0.69 | 4.56 | 786.11 | 177.83 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 591.07
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [442.1078274026513, 398.6995369195938]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 12.30

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
