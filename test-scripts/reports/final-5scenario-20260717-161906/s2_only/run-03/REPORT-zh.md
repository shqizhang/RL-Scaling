# s2_only run-03 Report

generated_at: 2026-07-17T17:51:54

## Timing

- T_signal_recv: 1784281446.9335911
- T_warmup_start: 1784281446.9335911
- T_ready: 1784281633.4718144
- T_burst_arrival: 1784281635.1616604
- Signal-to-Ready(s): 186.53822326660156
- Burst Safety Margin(s): 1.6898460388183594

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 19.22 | 3.33 | 5.19 | 4898.93 | 13.32 |
| balanced_decode | 24 | 100.00 | 0 | 7.24 | 3.32 | 2.59 | 2607.19 | 318.43 |
| decode_tail | 17 | 100.00 | 0 | 40.53 | 0.42 | 30.30 | 143.09 | 600.00 |
| total | 105 | 100.00 | 0 | 149.90 | 0.70 | 5.27 | 792.70 | 179.32 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 586.24
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [427.5889880955219, 394.13405023515224]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 11.63

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
