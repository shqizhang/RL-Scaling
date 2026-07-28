# 2p2d_static Aggregate

generated_at: 2026-07-18T10:39:49
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 80.5096 | 2.6457 | 78.1073 | 83.3451 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 1.3051 | 0.0426 | 1.2598 | 1.3443 |
| p95_latency_s | 6.4624 | 0.4356 | 6.1389 | 6.9577 |
| completion_tps | 371.4011 | 12.1151 | 358.5092 | 382.5508 |
| gpu_s | 322.0385 | 10.5827 | 312.4291 | 333.3806 |
| requests_per_gpu_s | 0.3263 | 0.0106 | 0.3150 | 0.3361 |
| tokens_per_gpu_s | 92.8503 | 3.0288 | 89.6273 | 95.6377 |
| serving_wall_s | 74.2695 | 2.7787 | 71.4603 | 77.0167 |
| orchestration_overhead_s | 6.2401 | 0.4575 | 5.7449 | 6.6470 |
| serving_gpu_s | 266.5284 | 8.5439 | 258.7589 | 275.6786 |
| serving_tokens_per_gpu_s | 112.1844 | 3.5707 | 108.3871 | 115.4743 |
| serving_requests_per_gpu_s | 0.3942 | 0.0125 | 0.3809 | 0.4058 |
| serving_spec_gpu_s | 266.5284 | 8.5439 | 258.7589 | 275.6786 |
| serving_spec_decode_gpu_s | 133.2642 | 4.2720 | 129.3795 | 137.8393 |
| min_spec_decode_replicas | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 21.6481 | 2.7349 | 18.5345 | 23.6623 |
| balanced_wall_s | 7.6374 | 0.7512 | 6.7705 | 8.0971 |
| tail_wall_s | 44.9840 | 2.0433 | 42.6246 | 46.1722 |
| tail_decode_gpu_s_savings_pct | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| tail_decode_gpu_s_saved | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| observed_tail_spec_decode_gpu_s | 89.9680 | 4.0866 | 85.2492 | 92.3445 |
| signal_to_ready_s | 193.1164 | 5.4019 | 189.9807 | 199.3540 |
| burst_safety_margin_s | 1.6422 | 0.1263 | 1.5074 | 1.7579 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 0
- total drained source count: 0
