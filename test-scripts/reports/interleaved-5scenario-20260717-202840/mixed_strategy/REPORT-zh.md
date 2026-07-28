# mixed_strategy Aggregate

generated_at: 2026-07-17T22:31:00
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 169.7845 | 1.9825 | 167.6331 | 171.5375 |
| valid_decode_pct | 99.6825 | 0.5499 | 99.0476 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 0.6165 | 0.0042 | 0.6121 | 0.6204 |
| p95_latency_s | 5.1924 | 0.2023 | 5.0406 | 5.4221 |
| completion_tps | 136.5753 | 1.6068 | 135.0958 | 138.2847 |
| gpu_s | 646.7963 | 11.9680 | 637.9153 | 660.4061 |
| requests_per_gpu_s | 0.1619 | 0.0025 | 0.1590 | 0.1635 |
| tokens_per_gpu_s | 35.8519 | 0.0589 | 35.8078 | 35.9188 |
| serving_wall_s | 66.1142 | 1.2304 | 64.8429 | 67.2991 |
| orchestration_overhead_s | 103.6703 | 0.7729 | 102.7902 | 104.2384 |
| serving_gpu_s | 187.0959 | 7.3838 | 178.5733 | 191.5707 |
| serving_tokens_per_gpu_s | 124.0524 | 4.7201 | 119.3085 | 128.7483 |
| serving_requests_per_gpu_s | 0.5601 | 0.0244 | 0.5429 | 0.5880 |
| serving_spec_gpu_s | 173.8165 | 8.0360 | 164.5386 | 178.5863 |
| serving_spec_decode_gpu_s | 80.2686 | 4.3446 | 75.2519 | 82.8009 |
| min_spec_decode_replicas | 0.3333 | 0.5774 | 0.0000 | 1.0000 |
| s2_switch_total_ms | 916.7607 | 79.5935 | 859.4773 | 1007.6445 |
| prefill_wall_s | 17.7900 | 0.7453 | 17.0545 | 18.5448 |
| balanced_wall_s | 7.3756 | 0.2184 | 7.1408 | 7.5725 |
| tail_wall_s | 40.9486 | 0.3556 | 40.6475 | 41.3409 |
| tail_decode_gpu_s_savings_pct | 21.3052 | 3.0267 | 17.8114 | 23.1293 |
| tail_decode_gpu_s_saved | 17.4519 | 2.5191 | 14.5545 | 19.1237 |
| signal_to_ready_s | 190.0455 | 0.3513 | 189.7218 | 190.4191 |
| burst_safety_margin_s | 1.6708 | 0.2342 | 1.4341 | 1.9023 |

## Action Evidence

- total S2 executed: 6
- total S3 migrated requests: 3
- total drained source count: 3
