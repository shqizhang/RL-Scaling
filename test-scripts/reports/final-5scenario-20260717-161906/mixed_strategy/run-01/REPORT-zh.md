# mixed_strategy run-01 Report

generated_at: 2026-07-17T18:35:35

## Timing

- T_signal_recv: 1784283816.9694662
- T_warmup_start: 1784283816.9694662
- T_ready: 1784284243.3137195
- T_burst_arrival: 1784284244.6694205
- Signal-to-Ready(s): 426.3442533016205
- Burst Safety Margin(s): 1.355700969696045

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 16.49 | 3.88 | 4.28 | 5704.83 | 15.52 |
| balanced_decode | 24 | 100.00 | 0 | 6.87 | 3.49 | 2.48 | 2742.20 | 335.35 |
| decode_tail | 17 | 100.00 | 0 | 40.76 | 0.42 | 30.52 | 141.86 | 515.62 |
| total | 105 | 100.00 | 0 | 141.84 | 0.74 | 4.28 | 836.98 | 166.23 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 521.85
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [551.2773105874658, 477.7247104793787]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-7bwtd']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 21.88

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
