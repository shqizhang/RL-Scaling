# Pressure Window Baseline / S2 / S3 E2E 总结

生成时间：2026-07-05T17:00:17

## 为什么上一轮 Strategy Mix 没有触发有效窗口

这次先给 controller 增加了 S2 evaluation 观测字段，记录每次 tick 的 prefill/decode queue、worker active request、utilization、worker count 和 skip reason。这样可以区分两类问题：

- workload 没有制造出 controller 能看到的压力。
- workload 有压力，但某个 gating 条件不满足。

## 统一测试数据

- prefill_pressure：96 条超长 prompt、短 decode 请求，用于最大化 prefill 压力窗口。
- decode_head：48 条中等 decode 请求，用于形成正常 decode batch。
- decode_tail：24 条受控长尾 decode 请求，用于触发 S3 consolidation，同时避免 240s timeout 大面积污染。

## 对比结果

| scenario | requests | valid decode % | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s | request GPU s | GPU saved vs baseline | S2 exec | S3 migrated |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | 96 | 100.00 | 35.22 | 2.73 | 3.16 | 9641.38 | 568.90 | 198.14 | 0.00% | 0 | 0 |
| s2_only | 96 | 100.00 | 32.96 | 2.91 | 3.11 | 10301.76 | 598.37 | 139.67 | 29.51% | 0 | 0 |
| s3_only | 96 | 100.00 | 36.31 | 2.64 | 3.09 | 9352.40 | 534.66 | 175.35 | 11.51% | 0 | 1 |

## S2 触发窗口诊断

### baseline

- evaluation count: 0
- max prefill_queue_depth: 0
- max prefill_worker_active: 0
- max decode_worker_active: 0
- selected actions: []
- top skip reasons: []

### s2_only

- evaluation count: 62
- max prefill_queue_depth: 0
- max prefill_worker_active: 0
- max decode_worker_active: 12
- selected actions: []
- top skip reasons: [('d_to_p_blocked:prefill_queue_depth=0>=1;p_to_d_blocked:decode_queue_depth=0>=999,prefill_worker_count=1>1', 31), ('d_to_p_blocked:prefill_queue_depth=0>=1;p_to_d_blocked:decode_queue_depth=0>=999', 16), ('d_to_p_blocked:prefill_queue_depth=0>=1;p_to_d_blocked:decode_queue_depth=1>=999,prefill_worker_count=1>1', 3), ('d_to_p_blocked:prefill_queue_depth=0>=1;p_to_d_blocked:decode_queue_depth=5>=999,prefill_worker_count=1>1', 3), ('d_to_p_blocked:prefill_queue_depth=0>=1;p_to_d_blocked:decode_queue_depth=6>=999,prefill_worker_count=1>1', 2)]

### s3_only

- evaluation count: 0
- max prefill_queue_depth: 0
- max prefill_worker_active: 0
- max decode_worker_active: 0
- selected actions: []
- top skip reasons: []

## 结论口径

如果 S2 only 仍没有 selected action，但 evaluation 中 max prefill_queue_depth / prefill_worker_active 为 0，则说明 controller 仍看不到 prefill pressure；此时继续调 workload 没有意义，需要修 metrics。
如果 evaluation 能看到 prefill pressure，但 skip reason 指向 decode_utilization、min_decode_replicas 或 target_available，则下一步应调整对应 gating 或 workload。
S3 only 的结论以 migrated_requests、drained_sources、scaled_down_to 和 valid decode 为准。
