# s3_only Aggregate

generated_at: 2026-07-17T22:31:00
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 78.7132 | 2.1374 | 77.3247 | 81.1745 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 1.3346 | 0.0357 | 1.2935 | 1.3579 |
| p95_latency_s | 8.0078 | 2.5691 | 5.6454 | 10.7430 |
| completion_tps | 306.4090 | 14.6206 | 290.9412 | 320.0015 |
| gpu_s | 291.8423 | 6.8873 | 287.5440 | 299.7861 |
| requests_per_gpu_s | 0.3599 | 0.0084 | 0.3502 | 0.3652 |
| tokens_per_gpu_s | 82.6300 | 3.7220 | 78.7795 | 86.2085 |
| serving_wall_s | 72.2514 | 2.2773 | 70.6960 | 74.8653 |
| orchestration_overhead_s | 6.4617 | 0.1603 | 6.3091 | 6.6288 |
| serving_gpu_s | 242.0724 | 6.4911 | 237.9848 | 249.5571 |
| serving_tokens_per_gpu_s | 99.6364 | 4.8853 | 94.6356 | 104.3974 |
| serving_requests_per_gpu_s | 0.4340 | 0.0115 | 0.4207 | 0.4412 |
| serving_spec_gpu_s | 229.1769 | 6.8440 | 224.8093 | 237.0645 |
| serving_spec_decode_gpu_s | 106.0282 | 0.2606 | 105.8169 | 106.3193 |
| min_spec_decode_replicas | 1.0000 | 0.0000 | 1.0000 | 1.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 21.4202 | 1.7362 | 19.4544 | 22.7439 |
| balanced_wall_s | 7.6580 | 0.1659 | 7.4828 | 7.8127 |
| tail_wall_s | 43.1732 | 3.8635 | 40.4692 | 47.5982 |
| tail_decode_gpu_s_savings_pct | 11.4090 | 7.1081 | 5.1420 | 19.1325 |
| tail_decode_gpu_s_saved | 10.2088 | 7.2275 | 4.1618 | 18.2135 |
| signal_to_ready_s | 192.4886 | 3.9543 | 189.6069 | 196.9968 |
| burst_safety_margin_s | 1.6364 | 0.0925 | 1.5296 | 1.6921 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 3
- total drained source count: 3
