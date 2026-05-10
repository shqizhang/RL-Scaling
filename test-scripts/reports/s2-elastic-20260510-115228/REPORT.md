# S2 Elastic PD switch — E2E test report (20260510-115228)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
Target pod: `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5wmrpf`
Peer pod  : `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5zh2df`

## Switch latency

|                              | decode -> prefill | prefill -> decode |
|------------------------------|-------------------|-------------------|
| client wall-clock (ms)       | 270.208      | 516.621      |
| server total switch_time_ms  | 229.91984500549734    | 479.5785180758685    |

## Router awareness (DynamoWorkerMetadata CR diff on target)

The frontend's WorkerSet is rebuilt from `DynamoWorkerMetadata` CRs
watched in the deployment namespace. We assert directly on the target's
own CR:

|                        | model_cards w/ `backend/generate` | endpoints w/ `backend/generate` |
|------------------------|------------------------------------:|----------------------------------:|
| pre-switch             | 1 | 1 |
| after switch -> prefill| 0 | 1 |
| after revert -> decode | 1 | 1 |

* CR loses chat ModelCard after switch -> prefill: **true**
* CR regains chat ModelCard after revert       : **true**

## Routing attribution (30 chat probes per phase)

After switch -> prefill (target should be **0**, peer should be **>0**):
- `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5wmrpf` -> 0
- `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5zh2df` -> 30

After revert -> decode (target should be **>0**, peer **>0**):
- `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5wmrpf` -> 19
- `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5zh2df` -> 11

* Routing flipped off target then back: **true**

## Sustained-load impact (2 rps, 30 s)

| metric                 | value     |
|------------------------|-----------|
| total chat completions | 57    |
| HTTP 200               | 57   |
| HTTP non-200           | 0   |
| error rate             | 0.00% |
| p50 latency (s)        | 0.069590    |
| p99 latency (s)        | 0.584903    |

* Sustained-load passes (errors <= 2 out of 57): **true**

## Switch responses

```json
{"status": "ok", "new_role": "prefill", "switch_time_ms": 229.91984500549734, "timings_ms": {"sleep": 56.441, "unregister_mdc": 36.794, "reconfig_nixl": 0.24, "reset_prefix_cache": 4.119, "register_mdc": 0.14, "wake": 132.123}}
```

```json
{"status": "ok", "new_role": "decode", "switch_time_ms": 479.5785180758685, "timings_ms": {"sleep": 63.293, "unregister_mdc": 0.147, "reconfig_nixl": 0.058, "reset_prefix_cache": 2.419, "register_mdc": 276.475, "wake": 137.128}}
```

## Overall
**true**
