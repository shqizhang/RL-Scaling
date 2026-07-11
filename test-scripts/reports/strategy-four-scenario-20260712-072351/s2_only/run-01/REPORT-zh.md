# s2_only run-01 Report

generated_at: 2026-07-12T07:38:05

## Timing

- T_signal_recv: 1783812635.2198656
- T_warmup_start: 1783812635.2198656
- T_ready: 1783812817.8925264
- T_burst_arrival: 1783812819.3218074
- Signal-to-Ready(s): 182.67266082763672
- Burst Safety Margin(s): 1.4292809963226318

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 32.37 | 1.98 | 7.48 | 2910.51 | 7.91 |
| balanced_decode | 24 | 100.00 | 0 | 9.47 | 2.53 | 4.41 | 1993.63 | 243.19 |
| decode_tail | 18 | 100.00 | 0 | 14.32 | 1.26 | 1.86 | 426.73 | 35.75 |
| total | 106 | 100.00 | 0 | 132.62 | 0.80 | 7.48 | 898.98 | 23.16 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 513.93
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [418.70804596692324, 491.64630100131035]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: -64.50

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
