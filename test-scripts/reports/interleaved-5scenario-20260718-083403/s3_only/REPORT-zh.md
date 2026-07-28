# s3_only Aggregate

generated_at: 2026-07-18T10:39:49
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 75.2273 | 7.1208 | 67.0301 | 79.8828 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 1.4046 | 0.1405 | 1.3144 | 1.5665 |
| p95_latency_s | 4.8419 | 2.6749 | 1.9098 | 7.1489 |
| completion_tps | 352.3915 | 38.6744 | 325.7246 | 396.7470 |
| gpu_s | 290.8901 | 29.5394 | 257.0840 | 311.7223 |
| requests_per_gpu_s | 0.3636 | 0.0391 | 0.3368 | 0.4084 |
| tokens_per_gpu_s | 91.2175 | 10.6102 | 84.4358 | 103.4448 |
| serving_wall_s | 68.5986 | 7.6076 | 59.8275 | 73.4054 |
| orchestration_overhead_s | 6.6287 | 0.5152 | 6.2062 | 7.2026 |
| serving_gpu_s | 247.7728 | 36.5593 | 207.5756 | 279.0392 |
| serving_tokens_per_gpu_s | 108.0733 | 18.4003 | 91.9476 | 128.1172 |
| serving_requests_per_gpu_s | 0.4304 | 0.0674 | 0.3763 | 0.5058 |
| serving_spec_gpu_s | 234.4763 | 36.7608 | 194.0773 | 265.9584 |
| serving_spec_decode_gpu_s | 105.5803 | 18.6618 | 84.7713 | 120.8327 |
| min_spec_decode_replicas | 0.3333 | 0.5774 | 0.0000 | 1.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 15.1919 | 7.1573 | 6.9356 | 19.6400 |
| balanced_wall_s | 6.5664 | 1.2055 | 5.1745 | 7.2773 |
| tail_wall_s | 46.8402 | 0.7646 | 46.3152 | 47.7174 |
| tail_decode_gpu_s_savings_pct | 10.6891 | 2.0018 | 8.3986 | 12.1042 |
| tail_decode_gpu_s_saved | 10.0191 | 1.9163 | 7.8087 | 11.2121 |
| observed_tail_spec_decode_gpu_s | 70.3648 | 1.8198 | 68.3374 | 71.8569 |
| signal_to_ready_s | 189.3685 | 0.5391 | 188.7655 | 189.8040 |
| burst_safety_margin_s | 1.4539 | 0.2473 | 1.1738 | 1.6424 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 3
- total drained source count: 3
