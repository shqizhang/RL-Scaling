# baseline_minimal Aggregate

generated_at: 2026-07-18T10:39:49
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 105.9388 | 3.3726 | 103.3317 | 109.7478 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 0.9918 | 0.0311 | 0.9567 | 1.0161 |
| p95_latency_s | 8.2496 | 1.9926 | 6.9909 | 10.5469 |
| completion_tps | 282.2375 | 8.8553 | 272.2607 | 289.1659 |
| gpu_s | 211.8776 | 6.7453 | 206.6634 | 219.4955 |
| requests_per_gpu_s | 0.4959 | 0.0156 | 0.4784 | 0.5081 |
| tokens_per_gpu_s | 141.1188 | 4.4276 | 136.1303 | 144.5830 |
| serving_wall_s | 99.2062 | 3.4544 | 96.4633 | 103.0857 |
| orchestration_overhead_s | 6.7326 | 0.1176 | 6.6621 | 6.8684 |
| serving_gpu_s | 184.3247 | 11.1915 | 173.8828 | 196.1392 |
| serving_tokens_per_gpu_s | 162.5007 | 9.7754 | 152.3408 | 171.8399 |
| serving_requests_per_gpu_s | 0.5710 | 0.0344 | 0.5353 | 0.6039 |
| serving_spec_gpu_s | 184.3247 | 11.1915 | 173.8828 | 196.1392 |
| serving_spec_decode_gpu_s | 92.1623 | 5.5958 | 86.9414 | 98.0696 |
| min_spec_decode_replicas | 0.3333 | 0.5774 | 0.0000 | 1.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 35.1598 | 2.4416 | 33.3869 | 37.9446 |
| balanced_wall_s | 10.4539 | 1.0617 | 9.5219 | 11.6096 |
| tail_wall_s | 53.5925 | 0.0865 | 53.5315 | 53.6916 |
| tail_decode_gpu_s_savings_pct | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| tail_decode_gpu_s_saved | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| observed_tail_spec_decode_gpu_s | 53.5925 | 0.0865 | 53.5315 | 53.6916 |
| signal_to_ready_s | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| burst_safety_margin_s | 0.0015 | 0.0009 | 0.0005 | 0.0020 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 0
- total drained source count: 0
