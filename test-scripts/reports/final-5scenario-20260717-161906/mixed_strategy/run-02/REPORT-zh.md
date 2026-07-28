# mixed_strategy run-02 Report

generated_at: 2026-07-17T18:47:03

## Timing

- T_signal_recv: 1784284715.5570035
- T_warmup_start: 1784284715.5570035
- T_ready: 1784284906.188587
- T_burst_arrival: 1784284907.8705387
- Signal-to-Ready(s): 190.63158345222473
- Burst Safety Margin(s): 1.6819517612457275

## Serving

| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| prefill_burst | 64 | 100.00 | 0 | 19.58 | 3.27 | 5.02 | 4805.57 | 13.07 |
| balanced_decode | 24 | 100.00 | 0 | 8.25 | 2.91 | 3.22 | 2283.81 | 279.29 |
| decode_tail | 17 | 100.00 | 0 | 42.58 | 0.40 | 32.35 | 135.80 | 540.89 |
| total | 105 | 100.00 | 0 | 172.46 | 0.61 | 5.02 | 688.39 | 148.40 |

## Evidence And Gates

- performance_valid: True
- quality_gate: {'passed': True, 'min_valid_decode_pct': 99.0, 'valid_decode_pct': 100.0, 'timeout_count': 0, 'http_5xx_count': 0}
- scenario_gate: {'passed': True, 'reasons': []}
- request-window GPU seconds: 671.32
- S2 executed count: 2
- S2 directions: ['decode->prefill', 'prefill->decode']
- S2 switch latencies(ms): [443.62824130803347, 407.23312087357044]
- S3 migrated requests: 1
- S3 drained sources: ['vllm-v1-disagg-router-vllmdecodeworker-41888dc2-b7ccc9b77-2kj2m']
- S3 scaled down to: [1]
- tail decode GPU-second savings pct: 10.18

## Raw Data

- requests.csv
- pod_samples.csv
- controller_status.jsonl
- events.csv
- logs/
