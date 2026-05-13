# S2 Elastic PD switch — E2E test report (20260513-120223)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
Target: `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-j96lb`
Peer:   `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-wqvrk`

## 1. Switch latency

| direction         | client wall (ms) | server total (ms) |
|-------------------|-----------------:|------------------:|
| decode → prefill  | 497.286      | 453.5000640898943     |
| prefill → decode  | 465.650      | 427.9955530073494     |

## 2. Router awareness (DynamoWorkerMetadata CR)

| state                    | model_cards w/ `backend/generate` | endpoints w/ `backend/generate` |
|--------------------------|------------------------------------:|----------------------------------:|
| pre-switch               | 1 | 1 |
| after switch → prefill   | 0 | 1 |
| after revert → decode    | 1 | 1 |

* CR loses decode card after switch: **true**
* CR regains decode card after revert: **true**

## 3. Prefill serving (after switch to prefill)

30 chat requests sent.  If the target is active as a prefill
worker, its `vllm:prompt_tokens_total` counter will grow.

| metric                      | value                    |
|-----------------------------|-------------------------:|
| prompt_tokens before probes | 39350     |
| prompt_tokens after probes  | 39933      |
| **delta (must be > 0)**     | **583**  |
| probes returned ok          | 30/30  |

**Analysis**: delta > 0 proves the target executed prefill compute.
Combined with HTTP 200 OK, the target is end-to-end serving as prefill.

* Prefill serving verified: **true**

## 4. Decode serving (after revert to decode)

30 chat requests sent after reverting to decode role.

| metric                      | value                    |
|-----------------------------|-------------------------:|
| gen_tokens before probes    | 363828        |
| gen_tokens after probes     | 364052         |
| **delta (must be > 0)**     | **224**     |
| probes returned ok          | 30/30  |

**Analysis**: delta > 0 proves the target generated decode tokens.
The full round-trip (decode → prefill → decode) is confirmed.

* Decode serving verified: **true**

## 5. Sustained-load impact

| metric          | value  |
|-----------------|--------|
| total requests  | 58 |
| HTTP 200        | 58|
| HTTP non-200    | 0|
| p50 latency (s) | 0.065530 |
| p99 latency (s) | 0.105177 |

* Sustained-load passes (errors ≤ 2): **true**

## 6. Switch responses

### decode → prefill
```json
{
    "status": "ok",
    "new_role": "prefill",
    "switch_time_ms": 453.5000640898943,
    "timings_ms": {
        "sleep": 65.842,
        "unregister_mdc": 22.801,
        "reconfig_nixl": 0.148,
        "reset_prefix_cache": 4.333,
        "register_mdc": 326.655,
        "wake": 20.196
    }
}
```
### prefill → decode
```json
{
    "status": "ok",
    "new_role": "decode",
    "switch_time_ms": 427.9955530073494,
    "timings_ms": {
        "sleep": 50.332,
        "unregister_mdc": 19.397,
        "reconfig_nixl": 0.103,
        "reset_prefix_cache": 1.182,
        "register_mdc": 328.103,
        "wake": 28.845
    }
}
```

## 7. Worker log excerpts (target)

### After prefill serving phase
```
[2m2026-05-13T12:02:31.295016Z[0m [32m INFO[0m [2mhandlers.sleep[0m[2m:[0m [Sleep] Unregistered endpoint from discovery - worker removed from routing pool
(EngineCore_DP0 pid=685) INFO 05-13 12:02:31 [cumem.py:213] CuMemAllocator: sleep freed 0.00 GiB memory in total, of which 0.00 GiB is backed up in CPU and the rest 0.00 GiB is discarded directly.
(EngineCore_DP0 pid=685) INFO 05-13 12:02:31 [abstract.py:312] It took 0.028313 seconds to fall asleep.
[2m2026-05-13T12:02:31.361767Z[0m [32m INFO[0m [2mdual_mode._reconfig_nixl[0m[2m:[0m [DualMode] reconfig_nixl(prefill): no cached nixl connector; nothing to drop
[2m2026-05-13T12:02:31.366103Z[0m [32m INFO[0m [2mdual_mode._reconfig_kv_pool[0m[2m:[0m [DualMode] reconfig_kv_pool(prefill): reset_prefix_cache OK
(EngineCore_DP0 pid=685) INFO 05-13 12:02:31 [abstract.py:330] It took 0.005755 seconds to wake up tags {'weights', 'kv_cache'}.
[2m2026-05-13T12:02:31.712930Z[0m [32m INFO[0m [2mhandlers.wake_up[0m[2m:[0m [Wake] Re-registered endpoint to discovery - worker added back to routing pool
[2m2026-05-13T12:02:31.726431Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] registered prefill endpoint instance
[2m2026-05-13T12:02:31.726608Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] switch_role decode->prefill OK total=453.50ms timings={'sleep': 65.842, 'unregister_mdc': 22.801, 'reconfig_nixl': 0.148, 'reset_prefix_cache': 4.333, 'register_mdc': 326.655, 'wake': 20.196}
```
### After decode serving phase
```
[2m2026-05-13T12:02:31.295016Z[0m [32m INFO[0m [2mhandlers.sleep[0m[2m:[0m [Sleep] Unregistered endpoint from discovery - worker removed from routing pool
(EngineCore_DP0 pid=685) INFO 05-13 12:02:31 [cumem.py:213] CuMemAllocator: sleep freed 0.00 GiB memory in total, of which 0.00 GiB is backed up in CPU and the rest 0.00 GiB is discarded directly.
(EngineCore_DP0 pid=685) INFO 05-13 12:02:31 [abstract.py:312] It took 0.028313 seconds to fall asleep.
[2m2026-05-13T12:02:31.361767Z[0m [32m INFO[0m [2mdual_mode._reconfig_nixl[0m[2m:[0m [DualMode] reconfig_nixl(prefill): no cached nixl connector; nothing to drop
[2m2026-05-13T12:02:31.366103Z[0m [32m INFO[0m [2mdual_mode._reconfig_kv_pool[0m[2m:[0m [DualMode] reconfig_kv_pool(prefill): reset_prefix_cache OK
(EngineCore_DP0 pid=685) INFO 05-13 12:02:31 [abstract.py:330] It took 0.005755 seconds to wake up tags {'weights', 'kv_cache'}.
[2m2026-05-13T12:02:31.712930Z[0m [32m INFO[0m [2mhandlers.wake_up[0m[2m:[0m [Wake] Re-registered endpoint to discovery - worker added back to routing pool
[2m2026-05-13T12:02:31.726431Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] registered prefill endpoint instance
[2m2026-05-13T12:02:31.726608Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] switch_role decode->prefill OK total=453.50ms timings={'sleep': 65.842, 'unregister_mdc': 22.801, 'reconfig_nixl': 0.148, 'reset_prefix_cache': 4.333, 'register_mdc': 326.655, 'wake': 20.196}
[2m2026-05-13T12:02:37.907700Z[0m [32m INFO[0m [2mhandlers.sleep[0m[2m:[0m [Sleep] Unregistered endpoint from discovery - worker removed from routing pool
(EngineCore_DP0 pid=685) INFO 05-13 12:02:37 [cumem.py:213] CuMemAllocator: sleep freed 0.00 GiB memory in total, of which 0.00 GiB is backed up in CPU and the rest 0.00 GiB is discarded directly.
(EngineCore_DP0 pid=685) INFO 05-13 12:02:37 [abstract.py:312] It took 0.022906 seconds to fall asleep.
[2m2026-05-13T12:02:37.945986Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] unregistered prefill endpoint instance
[2m2026-05-13T12:02:37.955640Z[0m [32m INFO[0m [2mdual_mode._reconfig_nixl[0m[2m:[0m [DualMode] reconfig_nixl(decode): no cached nixl connector; nothing to drop
[2m2026-05-13T12:02:37.956811Z[0m [32m INFO[0m [2mdual_mode._reconfig_kv_pool[0m[2m:[0m [DualMode] reconfig_kv_pool(decode): reset_prefix_cache OK
(EngineCore_DP0 pid=685) INFO 05-13 12:02:38 [abstract.py:330] It took 0.006982 seconds to wake up tags {'weights', 'kv_cache'}.
[2m2026-05-13T12:02:38.313739Z[0m [32m INFO[0m [2mhandlers.wake_up[0m[2m:[0m [Wake] Re-registered endpoint to discovery - worker added back to routing pool
[2m2026-05-13T12:02:38.313943Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] switch_role prefill->decode OK total=428.00ms timings={'sleep': 50.332, 'unregister_mdc': 19.397, 'reconfig_nixl': 0.103, 'reset_prefix_cache': 1.182, 'register_mdc': 328.103, 'wake': 28.845}
```

## Overall

| condition                            | result          |
|--------------------------------------|-----------------|
| CR loses decode card after switch    | **true** |
| CR regains decode card after revert  | **true** |
| Target served prefill (delta > 0)    | **true** |
| Target served decode (delta > 0)     | **true**  |
| Sustained load ≤ 2 errors           | **true**    |
| **OVERALL**                          | **true**         |
