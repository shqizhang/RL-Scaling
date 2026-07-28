# 2p2d_static Aggregate

generated_at: 2026-07-17T16:53:40
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 77.5418 | 1.8517 | 75.8810 | 79.5385 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 1.3546 | 0.0322 | 1.3201 | 1.3837 |
| p95_latency_s | 9.6364 | 0.6751 | 8.8689 | 10.1382 |
| completion_tps | 346.7826 | 8.2314 | 337.9497 | 354.2388 |
| gpu_s | 280.5732 | 4.2265 | 275.6961 | 283.1643 |
| requests_per_gpu_s | 0.3743 | 0.0057 | 0.3708 | 0.3809 |
| tokens_per_gpu_s | 95.8185 | 1.4560 | 94.9272 | 97.4987 |
| serving_wall_s | 70.5148 | 1.6176 | 69.0893 | 72.2729 |
| orchestration_overhead_s | 7.0270 | 0.2370 | 6.7917 | 7.2656 |
| serving_gpu_s | 211.3105 | 20.3331 | 193.8620 | 233.6398 |
| serving_tokens_per_gpu_s | 127.9727 | 11.9617 | 115.0489 | 138.6553 |
| serving_requests_per_gpu_s | 0.4999 | 0.0467 | 0.4494 | 0.5416 |
| serving_spec_gpu_s | 211.3105 | 20.3331 | 193.8620 | 233.6398 |
| serving_spec_decode_gpu_s | 105.6553 | 10.1666 | 96.9310 | 116.8199 |
| min_spec_decode_replicas | 0.6667 | 1.1547 | 0.0000 | 2.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 21.9591 | 0.8702 | 21.3010 | 22.9457 |
| balanced_wall_s | 7.4365 | 0.4367 | 7.0755 | 7.9218 |
| tail_wall_s | 41.1193 | 0.3616 | 40.7128 | 41.4053 |
| tail_decode_gpu_s_savings_pct | 12.1946 | 4.3646 | 9.3705 | 17.2216 |
| tail_decode_gpu_s_saved | 10.0086 | 3.4871 | 7.7287 | 14.0228 |
| signal_to_ready_s | 196.2824 | 5.3461 | 190.1242 | 199.7334 |
| burst_safety_margin_s | 1.5781 | 0.1384 | 1.4187 | 1.6679 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 0
- total drained source count: 0
