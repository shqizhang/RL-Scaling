# s3_only Aggregate

generated_at: 2026-07-17T18:20:38
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 81.4574 | 21.6007 | 67.9412 | 106.3697 |
| valid_decode_pct | 100.0000 | 0.0000 | 100.0000 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 1.3438 | 0.3097 | 0.9871 | 1.5455 |
| p95_latency_s | 5.1130 | 1.6234 | 4.0253 | 6.9790 |
| completion_tps | 301.2285 | 79.9681 | 210.3512 | 360.8408 |
| gpu_s | 310.4959 | 83.4460 | 249.3978 | 405.5702 |
| requests_per_gpu_s | 0.3532 | 0.0842 | 0.2589 | 0.4210 |
| tokens_per_gpu_s | 79.0577 | 20.6923 | 55.1692 | 91.4256 |
| serving_wall_s | 64.0685 | 1.9095 | 62.5544 | 66.2136 |
| orchestration_overhead_s | 17.3890 | 19.7266 | 5.3868 | 40.1561 |
| serving_gpu_s | 192.3307 | 9.7203 | 182.6583 | 202.0982 |
| serving_tokens_per_gpu_s | 121.7200 | 4.6670 | 116.3937 | 125.0927 |
| serving_requests_per_gpu_s | 0.5469 | 0.0277 | 0.5195 | 0.5748 |
| serving_spec_gpu_s | 176.1325 | 11.9011 | 164.7377 | 188.4824 |
| serving_spec_decode_gpu_s | 78.9319 | 7.4717 | 73.4085 | 87.4333 |
| min_spec_decode_replicas | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| s2_switch_total_ms | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| prefill_wall_s | 16.2355 | 2.1229 | 14.6877 | 18.6557 |
| balanced_wall_s | 6.9277 | 0.2212 | 6.7989 | 7.1831 |
| tail_wall_s | 40.9052 | 0.6017 | 40.3901 | 41.5666 |
| tail_decode_gpu_s_savings_pct | 13.3190 | 8.6359 | 5.0835 | 22.3062 |
| tail_decode_gpu_s_saved | 10.8539 | 7.0052 | 4.2260 | 18.1836 |
| signal_to_ready_s | 220.7889 | 53.8000 | 188.2301 | 282.8873 |
| burst_safety_margin_s | 1.5193 | 0.2163 | 1.2726 | 1.6763 |

## Action Evidence

- total S2 executed: 0
- total S3 migrated requests: 3
- total drained source count: 3
