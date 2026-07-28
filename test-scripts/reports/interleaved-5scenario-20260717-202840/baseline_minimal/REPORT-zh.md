# baseline_minimal Aggregate

generated_at: 2026-07-17T22:31:00
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 94.6533 | 2.9414 | 91.7255 | 97.6080 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 1.1100 | 0.0345 | 1.0757 | 1.1447 |
| p95_latency_s | 6.8009 | 0.2033 | 6.6371 | 7.0284 |
| completion_tps | 284.1668 | 8.8310 | 275.3872 | 293.0482 |
| gpu_s | 178.6649 | 7.3452 | 171.5016 | 186.1794 |
| requests_per_gpu_s | 0.5884 | 0.0241 | 0.5640 | 0.6122 |
| tokens_per_gpu_s | 150.6185 | 6.1791 | 144.3769 | 156.7332 |
| serving_wall_s | 88.0337 | 2.5239 | 85.2899 | 90.2563 |
| orchestration_overhead_s | 6.6196 | 0.6597 | 6.0714 | 7.3518 |
| serving_gpu_s | 149.7139 | 9.0771 | 142.6899 | 159.9633 |
| serving_tokens_per_gpu_s | 179.9715 | 10.6190 | 168.0386 | 188.3805 |
| serving_requests_per_gpu_s | 0.7030 | 0.0415 | 0.6564 | 0.7359 |
| serving_spec_gpu_s | 149.7139 | 9.0771 | 142.6899 | 159.9633 |
| serving_spec_decode_gpu_s | 74.8570 | 4.5386 | 71.3450 | 79.9816 |
| min_spec_decode_replicas | 1.0000 | 0.0000 | 1.0000 | 1.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 30.9321 | 2.2393 | 28.8698 | 33.3140 |
| balanced_wall_s | 10.0897 | 0.7019 | 9.4494 | 10.8402 |
| tail_wall_s | 47.0118 | 0.0782 | 46.9627 | 47.1020 |
| tail_decode_gpu_s_savings_pct | 8.0750 | 6.0526 | 4.5626 | 15.0639 |
| tail_decode_gpu_s_saved | 3.7945 | 2.8405 | 2.1431 | 7.0744 |
| signal_to_ready_s | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| burst_safety_margin_s | 0.0014 | 0.0009 | 0.0007 | 0.0025 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 0
- total drained source count: 0
