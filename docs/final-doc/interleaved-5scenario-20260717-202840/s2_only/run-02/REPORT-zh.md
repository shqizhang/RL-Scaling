# s2_only run-02 Report

generated_at: 2026-07-17T21:31:26

## Timing

- T_signal_recv: 1784294590.8898792
- T_warmup_start: 1784294590.8898792
- T_ready: 1784294781.9102933
- T_burst_arrival: 1784294783.2513075
- Signal-to-Ready(s): 191.0204141139984
- Burst Safety Margin(s): 1.3410141468048096

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 98.44 | 0 | 18.02 | 3.50 | 4.19 | 5144.47 | 13.99 |
| balanced_decode | 24 | 100.00 | 0 | 7.07 | 3.40 | 2.71 | 2669.51 | 326.05 |
| decode_tail | 17 | 100.00 | 0 | 37.47 | 0.45 | 31.73 | 154.78 | 648.99 |
| total | 105 | 99.05 | 0 | 172.03 | 0.60 | 4.37 | 682.15 | 156.23 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 99.04761904761905, 'timeout_count': 0, 'http_5xx_count': 1}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 685.50
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [421.14659771323204, 498.19342605769634]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 10.23

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
