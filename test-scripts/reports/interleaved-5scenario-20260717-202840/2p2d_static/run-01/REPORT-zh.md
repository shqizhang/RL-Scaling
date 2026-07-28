# 2p2d_static run-01 Report

generated_at: 2026-07-17T20:41:39

## Timing

- T_signal_recv: 1784291732.5896602
- T_warmup_start: 1784291732.5896602
- T_ready: 1784291922.8488169
- T_burst_arrival: 1784291924.3454795
- Signal-to-Ready(s): 190.25915670394897
- Burst Safety Margin(s): 1.4966626167297363

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 18.65 | 3.43 | 5.32 | 5055.94 | 13.73 |
| balanced_decode | 24 | 100.00 | 0 | 6.50 | 3.69 | 2.39 | 2907.68 | 354.23 |
| decode_tail | 17 | 100.00 | 0 | 41.32 | 0.41 | 31.33 | 141.19 | 588.58 |
| total | 105 | 100.00 | 0 | 72.98 | 1.44 | 5.87 | 1631.01 | 368.31 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 262.94
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 21.80

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
