# mixed_strategy Aggregate

generated_at: 2026-07-17T18:58:43
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 166.8497 | 22.7285 | 141.8417 | 186.2482 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 0.6376 | 0.0917 | 0.5638 | 0.7403 |
| p95_latency_s | 4.9065 | 0.5756 | 4.2825 | 5.4168 |
| completion_tps | 148.2255 | 18.0972 | 130.0415 | 166.2346 |
| gpu_s | 631.0520 | 95.6539 | 521.8483 | 699.9919 |
| requests_per_gpu_s | 0.1692 | 0.0279 | 0.1500 | 0.2012 |
| tokens_per_gpu_s | 39.3026 | 5.3892 | 34.6004 | 45.1836 |
| serving_wall_s | 69.9617 | 5.6205 | 64.1289 | 75.3426 |
| orchestration_overhead_s | 96.8880 | 17.1869 | 77.7128 | 110.9056 |
| serving_gpu_s | 186.3432 | 16.0397 | 167.8835 | 196.8775 |
| serving_tokens_per_gpu_s | 131.7053 | 8.0259 | 124.6727 | 140.4486 |
| serving_requests_per_gpu_s | 0.5664 | 0.0512 | 0.5333 | 0.6254 |
| serving_spec_gpu_s | 175.3880 | 17.3461 | 155.4327 | 186.8579 |
| serving_spec_decode_gpu_s | 79.9304 | 7.4208 | 71.4909 | 85.4346 |
| min_spec_decode_replicas | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| s2_switch_total_ms | 905.8168 | 106.8878 | 837.5870 | 1029.0020 |
| prefill_wall_s | 17.8505 | 1.5768 | 16.4941 | 19.5806 |
| balanced_wall_s | 7.5381 | 0.6905 | 6.8704 | 8.2494 |
| tail_wall_s | 44.5731 | 5.1032 | 40.7644 | 50.3715 |
| tail_decode_gpu_s_savings_pct | 21.6912 | 11.4181 | 10.1786 | 33.0124 |
| tail_decode_gpu_s_saved | 19.9223 | 12.4259 | 8.6688 | 33.2577 |
| signal_to_ready_s | 268.9492 | 136.3087 | 189.8717 | 426.3443 |
| burst_safety_margin_s | 1.5352 | 0.1656 | 1.3557 | 1.6820 |

## Action Evidence

- total S2 executed: 6
- total S3 migrated requests: 3
- total drained source count: 3
