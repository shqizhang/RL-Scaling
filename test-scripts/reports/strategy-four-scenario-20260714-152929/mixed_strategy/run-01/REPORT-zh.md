# mixed_strategy run-01 Report

generated_at: 2026-07-14T16:02:52

## Timing

- T_signal_recv: 1784015648.0913048
- T_warmup_start: 1784015648.0913048
- T_ready: 1784015844.9201334
- T_burst_arrival: 1784015846.3513389
- Signal-to-Ready(s): 196.82882857322693
- Burst Safety Margin(s): 1.4312055110931396

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 16.72 | 3.83 | 4.79 | 5635.45 | 15.31 |
| balanced_decode | 24 | 100.00 | 0 | 7.23 | 3.32 | 2.71 | 2612.67 | 318.70 |
| decode_tail | 17 | 100.00 | 0 | 49.52 | 0.34 | 37.05 | 117.46 | 450.00 |
| total | 105 | 100.00 | 0 | 172.59 | 0.61 | 4.81 | 689.07 | 143.95 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 668.09
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [470.57164181023836, 414.3298314884305]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-99f456c9-sphql']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 21.74

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
