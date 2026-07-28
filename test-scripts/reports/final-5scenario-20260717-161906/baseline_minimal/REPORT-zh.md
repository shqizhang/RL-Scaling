# baseline_minimal Aggregate

generated_at: 2026-07-17T16:32:30
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 97.0524 | 3.6468 | 93.4911 | 100.7791 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 1.0829 | 0.0406 | 1.0419 | 1.1231 |
| p95_latency_s | 7.8879 | 1.1101 | 6.9071 | 9.0931 |
| completion_tps | 277.2241 | 10.3976 | 266.7219 | 287.5140 |
| gpu_s | 181.9008 | 2.5296 | 179.8306 | 184.7204 |
| requests_per_gpu_s | 0.5773 | 0.0080 | 0.5684 | 0.5839 |
| tokens_per_gpu_s | 147.7918 | 2.0438 | 145.5172 | 149.4740 |
| serving_wall_s | 90.3706 | 3.7664 | 86.5222 | 94.0493 |
| orchestration_overhead_s | 6.6819 | 0.3137 | 6.3470 | 6.9689 |
| serving_gpu_s | 149.6561 | 7.9875 | 144.8106 | 158.8752 |
| serving_tokens_per_gpu_s | 179.9434 | 9.3181 | 169.1894 | 185.6218 |
| serving_requests_per_gpu_s | 0.7029 | 0.0364 | 0.6609 | 0.7251 |
| serving_spec_gpu_s | 149.6561 | 7.9875 | 144.8106 | 158.8752 |
| serving_spec_decode_gpu_s | 74.8280 | 3.9938 | 72.4053 | 79.4376 |
| min_spec_decode_replicas | 1.0000 | 0.0000 | 1.0000 | 1.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 33.3020 | 3.6342 | 29.6937 | 36.9615 |
| balanced_wall_s | 10.2089 | 0.3257 | 9.8333 | 10.4138 |
| tail_wall_s | 46.8597 | 0.1441 | 46.7082 | 46.9952 |
| tail_decode_gpu_s_savings_pct | 7.1946 | 2.0176 | 4.8713 | 8.5055 |
| tail_decode_gpu_s_saved | 3.3731 | 0.9529 | 2.2753 | 3.9870 |
| signal_to_ready_s | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| burst_safety_margin_s | 0.0001 | 0.0000 | 0.0001 | 0.0001 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 0
- total drained source count: 0
