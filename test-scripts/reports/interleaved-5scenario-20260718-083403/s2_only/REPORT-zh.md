# s2_only Aggregate

generated_at: 2026-07-18T10:39:49
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 157.3317 | 18.8076 | 136.0476 | 171.7110 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 0.6742 | 0.0857 | 0.6115 | 0.7718 |
| p95_latency_s | 5.9479 | 3.6249 | 1.8700 | 8.8039 |
| completion_tps | 191.8583 | 24.3739 | 174.0133 | 219.6290 |
| gpu_s | 629.3270 | 75.2305 | 544.1905 | 686.8439 |
| requests_per_gpu_s | 0.1686 | 0.0214 | 0.1529 | 0.1929 |
| tokens_per_gpu_s | 47.9646 | 6.0935 | 43.5033 | 54.9072 |
| serving_wall_s | 67.7389 | 8.0847 | 59.0019 | 74.9554 |
| orchestration_overhead_s | 89.5929 | 12.7058 | 77.0458 | 102.4517 |
| serving_gpu_s | 243.5309 | 52.3459 | 183.2107 | 277.0371 |
| serving_tokens_per_gpu_s | 127.1573 | 31.1480 | 107.8556 | 163.0909 |
| serving_requests_per_gpu_s | 0.4468 | 0.1095 | 0.3790 | 0.5731 |
| serving_spec_gpu_s | 243.5309 | 52.3459 | 183.2107 | 277.0371 |
| serving_spec_decode_gpu_s | 121.7655 | 26.1729 | 91.6054 | 138.5185 |
| min_spec_decode_replicas | 0.6667 | 1.1547 | 0.0000 | 2.0000 |
| s2_switch_total_ms | 1871.7625 | 35.5809 | 1831.5452 | 1899.1461 |
| prefill_wall_s | 16.5941 | 7.6116 | 7.8252 | 21.4943 |
| balanced_wall_s | 6.5056 | 1.0242 | 5.3740 | 7.3692 |
| tail_wall_s | 44.6391 | 2.2705 | 42.0228 | 46.0919 |
| tail_decode_gpu_s_savings_pct | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| tail_decode_gpu_s_saved | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| observed_tail_spec_decode_gpu_s | 89.2782 | 4.5409 | 84.0455 | 92.1839 |
| signal_to_ready_s | 192.1024 | 6.2523 | 188.3422 | 199.3198 |
| burst_safety_margin_s | 1.6604 | 0.2408 | 1.3824 | 1.8035 |

## Action Evidence

- total S2 executed: 6
- total S3 migrated requests: 0
- total drained source count: 0
