# S3 E2E switch-routing report — 20260509-163824

DGD: `vllm-v1-disagg-router` | ns: `dynamo-system` | target: `vllm-v1-disagg-router-vllmdecodeworker-4c44b2c0-b9cb9b958-8fgbn`

## Summary

|                                    | decode -> prefill   | prefill -> decode (revert) |
|------------------------------------|---------------------|----------------------------|
| client wall-clock (ms)             | 424.378          | 438.429               |
| server total switch_time_ms        | 391.21723594143987     | 400.07412107661366          |
| t_first_off_target (ms)            | 2125.005| -                          |
| t_target_rejoin (ms)               | -                   | 2747.633        |
| target hits over 30 probes | 0 (expect 0) | 15 (expect >0) |
| PASS                               | **true**     | **true**            |

## /switch_role response (decode -> prefill)
```json
{"status": "ok", "new_role": "prefill", "switch_time_ms": 391.21723594143987, "timings_ms": {"sleep": 54.04, "unregister_mdc": 13.435, "reconfig_nixl": 0.094, "reset_prefix_cache": 1.562, "register_mdc": 294.057, "wake": 28.003}}
```

## /switch_role response (prefill -> decode)
```json
{"status": "ok", "new_role": "decode", "switch_time_ms": 400.07412107661366, "timings_ms": {"sleep": 65.654, "unregister_mdc": 11.39, "reconfig_nixl": 0.097, "reset_prefix_cache": 1.001, "register_mdc": 299.914, "wake": 21.964}}
```

## Attribution

### pre-switch (6 probes)
- `vllm-v1-disagg-router-vllmdecodeworker-4c44b2c0-b9cb9b958-8fgbn` -> 3
- `vllm-v1-disagg-router-vllmdecodeworker-4c44b2c0-b9cb9b958-j4v7m` -> 3

### post-switch decode->prefill (30 probes)
- `vllm-v1-disagg-router-vllmdecodeworker-4c44b2c0-b9cb9b958-8fgbn` -> 0
- `vllm-v1-disagg-router-vllmdecodeworker-4c44b2c0-b9cb9b958-j4v7m` -> 30

### post-revert prefill->decode (30 probes)
- `vllm-v1-disagg-router-vllmdecodeworker-4c44b2c0-b9cb9b958-8fgbn` -> 15
- `vllm-v1-disagg-router-vllmdecodeworker-4c44b2c0-b9cb9b958-j4v7m` -> 15
