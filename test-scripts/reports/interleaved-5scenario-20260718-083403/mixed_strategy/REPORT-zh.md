# mixed_strategy Aggregate

generated_at: 2026-07-18T10:39:49
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 174.2029 | 3.3026 | 171.4177 | 177.8514 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 0.6029 | 0.0114 | 0.5904 | 0.6125 |
| p95_latency_s | 4.7060 | 0.3016 | 4.4106 | 5.0134 |
| completion_tps | 139.4760 | 8.0869 | 132.1609 | 148.1600 |
| gpu_s | 684.2260 | 11.2777 | 674.9816 | 696.7913 |
| requests_per_gpu_s | 0.1535 | 0.0025 | 0.1507 | 0.1556 |
| tokens_per_gpu_s | 35.5081 | 2.0273 | 33.7332 | 37.7174 |
| serving_wall_s | 69.3214 | 1.5889 | 67.5125 | 70.4915 |
| orchestration_overhead_s | 104.8815 | 2.1623 | 103.3795 | 107.3599 |
| serving_gpu_s | 255.4342 | 14.3257 | 239.5547 | 267.3873 |
| serving_tokens_per_gpu_s | 95.1486 | 3.5081 | 91.2784 | 98.1195 |
| serving_requests_per_gpu_s | 0.4119 | 0.0236 | 0.3927 | 0.4383 |
| serving_spec_gpu_s | 244.1925 | 15.4547 | 226.3477 | 253.2670 |
| serving_spec_decode_gpu_s | 110.1826 | 9.7311 | 99.2632 | 117.9377 |
| min_spec_decode_replicas | 0.6667 | 0.5774 | 0.0000 | 1.0000 |
| s2_switch_total_ms | 1973.3825 | 37.9041 | 1932.6863 | 2007.6799 |
| prefill_wall_s | 17.4017 | 0.9933 | 16.2692 | 18.1248 |
| balanced_wall_s | 6.8716 | 0.0794 | 6.7905 | 6.9493 |
| tail_wall_s | 45.0480 | 2.1907 | 42.5972 | 46.8157 |
| tail_decode_gpu_s_savings_pct | 13.9419 | 1.8035 | 12.5470 | 15.9785 |
| tail_decode_gpu_s_saved | 12.5856 | 1.9658 | 10.6894 | 14.6143 |
| observed_tail_spec_decode_gpu_s | 66.2687 | 2.3354 | 63.6409 | 68.1071 |
| signal_to_ready_s | 189.1311 | 0.6504 | 188.3956 | 189.6305 |
| burst_safety_margin_s | 1.6580 | 0.1279 | 1.5569 | 1.8017 |

## Action Evidence

- total S2 executed: 6
- total S3 migrated requests: 3
- total drained source count: 3
