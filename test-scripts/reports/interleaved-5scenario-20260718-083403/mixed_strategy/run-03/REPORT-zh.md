# mixed_strategy run-03 Report

generated_at: 2026-07-18T10:39:49

## Timing

- T_signal_recv: 1784341880.2962735
- T_warmup_start: 1784341880.2962735
- T_ready: 1784342069.6635923
- T_burst_arrival: 1784342071.46532
- Signal-to-Ready(s): 189.36731886863708
- Burst Safety Margin(s): 1.8017277717590332

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 16.27 | 3.93 | 4.41 | 5783.69 | 15.74 |
| balanced_decode | 24 | 100.00 | 0 | 6.88 | 3.49 | 2.54 | 2740.28 | 335.12 |
| decode_tail | 17 | 100.00 | 0 | 46.82 | 0.36 | 36.27 | 123.53 | 493.89 |
| total | 105 | 100.00 | 0 | 173.34 | 0.61 | 4.41 | 684.89 | 148.16 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 680.91
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [1048.6438982188702, 884.0423943474889]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-6d4cfd48d7cz6w8']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 13.30

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
