# 2p2d_static run-02 Report

generated_at: 2026-07-18T09:31:45

## Timing

- T_signal_recv: 1784337934.3594139
- T_warmup_start: 1784337934.3594139
- T_ready: 1784338124.340073
- T_burst_arrival: 1784338125.8474653
- Signal-to-Ready(s): 189.9806592464447
- Burst Safety Margin(s): 1.507392168045044

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 18.53 | 3.45 | 5.36 | 5087.15 | 13.81 |
| balanced_decode | 24 | 100.00 | 0 | 6.77 | 3.54 | 2.72 | 2793.29 | 340.30 |
| decode_tail | 17 | 100.00 | 0 | 46.16 | 0.37 | 36.41 | 126.40 | 591.92 |
| total | 105 | 100.00 | 0 | 78.11 | 1.34 | 6.29 | 1523.98 | 382.55 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 312.43
- S2 executed count: 0
- S2 directions: []
- S2 switch latencies(ms): []
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
