# s2_only run-03 Report

generated_at: 2026-07-18T10:21:14

## Timing

- T_signal_recv: 1784340776.5072963
- T_warmup_start: 1784340776.5072963
- T_ready: 1784340975.8270867
- T_burst_arrival: 1784340977.2094502
- Signal-to-Ready(s): 199.31979036331177
- Burst Safety Margin(s): 1.3823635578155518

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 21.49 | 2.98 | 6.05 | 4380.70 | 11.91 |
| balanced_decode | 24 | 100.00 | 0 | 7.37 | 3.26 | 2.87 | 2559.84 | 312.65 |
| decode_tail | 17 | 100.00 | 0 | 46.09 | 0.37 | 35.54 | 125.84 | 592.73 |
| total | 105 | 100.00 | 0 | 164.24 | 0.64 | 7.17 | 723.49 | 181.93 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 656.95
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [958.374846726656, 873.1703385710716]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 0.00

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
