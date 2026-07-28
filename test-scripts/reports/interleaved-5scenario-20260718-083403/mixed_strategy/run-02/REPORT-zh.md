# mixed_strategy run-02 Report

generated_at: 2026-07-18T09:58:33

## Timing

- T_signal_recv: 1784339402.7836459
- T_warmup_start: 1784339402.7836459
- T_ready: 1784339592.4141378
- T_burst_arrival: 1784339594.029416
- Signal-to-Ready(s): 189.6304919719696
- Burst Safety Margin(s): 1.6152782440185547

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 18.12 | 3.53 | 4.50 | 5191.55 | 14.12 |
| balanced_decode | 24 | 100.00 | 0 | 6.79 | 3.53 | 2.49 | 2774.47 | 339.30 |
| decode_tail | 17 | 100.00 | 0 | 42.60 | 0.40 | 37.58 | 135.76 | 495.67 |
| total | 105 | 100.00 | 0 | 171.42 | 0.61 | 4.69 | 692.57 | 138.11 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 674.98
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [1004.775233566761, 1002.9047066345811]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-6d4cfd48d7gx9kw']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 12.55

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
