# s2_only run-02 Report

generated_at: 2026-07-18T09:40:11

## Timing

- T_signal_recv: 1784338346.3180406
- T_warmup_start: 1784338346.3180406
- T_ready: 1784338534.6602283
- T_burst_arrival: 1784338536.4637454
- Signal-to-Ready(s): 188.34218764305115
- Burst Safety Margin(s): 1.8035171031951904

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 7.83 | 8.18 | 1.75 | 12032.95 | 32.71 |
| balanced_decode | 24 | 100.00 | 0 | 5.37 | 4.47 | 1.85 | 3510.22 | 428.73 |
| decode_tail | 17 | 100.00 | 0 | 45.80 | 0.37 | 34.59 | 126.63 | 596.47 |
| total | 105 | 100.00 | 0 | 136.05 | 0.77 | 1.87 | 873.40 | 219.63 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 544.19
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [947.5442441180348, 951.6018396243453]
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
