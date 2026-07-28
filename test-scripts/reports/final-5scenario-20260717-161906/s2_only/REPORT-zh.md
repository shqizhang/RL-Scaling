# s2_only Aggregate

generated_at: 2026-07-17T17:51:54
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 157.7113 | 12.4603 | 149.8983 | 172.0810 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 0.6684 | 0.0505 | 0.6102 | 0.7005 |
| p95_latency_s | 8.3566 | 5.9747 | 4.5562 | 15.2432 |
| completion_tps | 171.1194 | 12.9373 | 156.2055 | 179.3215 |
| gpu_s | 614.4578 | 44.7610 | 586.2392 | 666.0682 |
| requests_per_gpu_s | 0.1715 | 0.0120 | 0.1576 | 0.1791 |
| tokens_per_gpu_s | 43.8950 | 3.0704 | 40.3562 | 45.8516 |
| serving_wall_s | 69.2341 | 5.5725 | 65.1343 | 75.5790 |
| orchestration_overhead_s | 88.4772 | 7.1217 | 82.9092 | 96.5021 |
| serving_gpu_s | 211.7481 | 11.1272 | 203.4975 | 224.4033 |
| serving_tokens_per_gpu_s | 127.1714 | 6.5137 | 119.7843 | 132.0900 |
| serving_requests_per_gpu_s | 0.4968 | 0.0254 | 0.4679 | 0.5160 |
| serving_spec_gpu_s | 211.7481 | 11.1272 | 203.4975 | 224.4033 |
| serving_spec_decode_gpu_s | 105.8741 | 5.5636 | 101.7488 | 112.2017 |
| min_spec_decode_replicas | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| s2_switch_total_ms | 971.6631 | 243.3635 | 821.7230 | 1252.4590 |
| prefill_wall_s | 21.1426 | 5.2577 | 17.1164 | 27.0909 |
| balanced_wall_s | 7.0290 | 0.6049 | 6.3479 | 7.5038 |
| tail_wall_s | 41.0625 | 0.5724 | 40.5333 | 41.6700 |
| tail_decode_gpu_s_savings_pct | 11.8558 | 0.3878 | 11.6297 | 12.3036 |
| tail_decode_gpu_s_saved | 9.7393 | 0.4489 | 9.4278 | 10.2538 |
| signal_to_ready_s | 191.1688 | 6.6960 | 186.5382 | 198.8465 |
| burst_safety_margin_s | 1.4045 | 0.2748 | 1.1417 | 1.6898 |

## Action Evidence

- total S2 executed: 6
- total S3 migrated requests: 0
- total drained source count: 0
