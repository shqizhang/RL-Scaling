# s2_only Aggregate

generated_at: 2026-07-17T22:31:00
run_count: 3

| metric | mean | stdev | best | worst |
|---|---:|---:|---:|---:|
| wall_s | 170.0303 | 1.8313 | 168.4386 | 172.0317 |
| valid_decode_pct | 99.6825 | 0.5499 | 99.0476 | 100.0000 |
| timeout_count | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| req_s | 0.6156 | 0.0099 | 0.6045 | 0.6234 |
| p95_latency_s | 6.4709 | 1.8518 | 4.3683 | 7.8587 |
| completion_tps | 158.0939 | 1.7097 | 156.2270 | 159.5834 |
| gpu_s | 665.1288 | 17.8633 | 652.1182 | 685.4956 |
| requests_per_gpu_s | 0.1575 | 0.0050 | 0.1517 | 0.1610 |
| tokens_per_gpu_s | 40.4305 | 1.0745 | 39.2067 | 41.2195 |
| serving_wall_s | 67.5455 | 4.3548 | 62.5571 | 70.5884 |
| orchestration_overhead_s | 102.4848 | 6.0535 | 98.9478 | 109.4746 |
| serving_gpu_s | 223.7629 | 20.9540 | 199.6586 | 237.6331 |
| serving_tokens_per_gpu_s | 120.8662 | 11.9347 | 113.1156 | 134.6098 |
| serving_requests_per_gpu_s | 0.4705 | 0.0438 | 0.4419 | 0.5209 |
| serving_spec_gpu_s | 223.7629 | 20.9540 | 199.6586 | 237.6331 |
| serving_spec_decode_gpu_s | 111.8814 | 10.4770 | 99.8293 | 118.8165 |
| min_spec_decode_replicas | 1.3333 | 1.1547 | 0.0000 | 2.0000 |
| s2_switch_total_ms | 871.0556 | 51.3774 | 817.0622 | 919.3400 |
| prefill_wall_s | 20.2004 | 1.9361 | 18.0170 | 21.7078 |
| balanced_wall_s | 7.2754 | 0.3421 | 7.0665 | 7.6702 |
| tail_wall_s | 40.0696 | 2.2536 | 37.4737 | 41.5246 |
| tail_decode_gpu_s_savings_pct | 9.9624 | 0.3735 | 9.5365 | 10.2346 |
| tail_decode_gpu_s_saved | 7.9761 | 0.3371 | 7.6705 | 8.3377 |
| signal_to_ready_s | 189.8946 | 0.9943 | 189.1366 | 191.0204 |
| burst_safety_margin_s | 1.4368 | 0.2629 | 1.2352 | 1.7342 |

## Action Evidence

- total S2 executed: 6
- total S3 migrated requests: 0
- total drained source count: 0
