# mixed_strategy run-01 Report

generated_at: 2026-07-11T18:24:56

## Timing

- T_signal_recv: 1783764670.9813554
- T_warmup_start: 1783764670.9813554
- T_ready: 1783764857.6216967
- T_burst_arrival: 1783764858.7224383
- Signal-to-Ready(s): 186.64034128189087
- Burst Safety Margin(s): 1.1007416248321533

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 80 | 100.00 | 0 | 172.98 | 0.46 | 50.86 | 5131.91 | 22.20 |
| balanced_decode | 32 | 100.00 | 0 | 16.96 | 1.89 | 4.72 | 2688.10 | 724.34 |
| decode_tail | 18 | 77.78 | 4 | 251.40 | 0.06 | 120.02 | 19.94 | 1.27 |
| total | 130 | 96.92 | 4 | 488.04 | 0.26 | 53.17 | 1922.66 | 33.70 |

## Evidence And Gates

- performance_valid: False
- quality_gate: {'passed': False, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 96.92307692307692, 'timeout_count': 4, 'http_5xx_count': 0}
- scenario_gate: {'passed': False, 'reasons': ['S3 migration/drain evidence missing']}
- request-window GPU seconds: 1929.44
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [490.39132706820965, 443.58168356120586]
- S3 migrated requests: 0
- S3 drained sources: []
- S3 scaled down to: []
- tail decode GPU-second savings pct: 1.96

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
