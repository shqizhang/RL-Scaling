# S2 Elastic PD switch — E2E test report (20260512-135944)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
Target: `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-j96lb`
Peer:   `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-wqvrk`

## 1. Switch latency

| direction         | client wall (ms) | server total (ms) |
|-------------------|-----------------:|------------------:|
| decode → prefill  | 511.617      | 473.4436580911279     |
| prefill → decode  | 488.778      | 460.2377850096673     |

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
| prompt_tokens before probes | 202     |
| prompt_tokens after probes  | 785      |
| **delta (must be > 0)**     | **583**  |
| probes returned ok          | 30/30  |

**Analysis**: delta > 0 proves the target executed prefill compute.
Combined with HTTP 200 OK, the target is end-to-end serving as prefill.

* Prefill serving verified: **true**

## 4. Decode serving (after revert to decode)

30 chat requests sent after reverting to decode role.

| metric                      | value                    |
|-----------------------------|-------------------------:|
| gen_tokens before probes    | 428        |
| gen_tokens after probes     | 732         |
| **delta (must be > 0)**     | **304**     |
| probes returned ok          | 30/30  |

**Analysis**: delta > 0 proves the target generated decode tokens.
The full round-trip (decode → prefill → decode) is confirmed.

* Decode serving verified: **true**

## 5. Sustained-load impact

| metric          | value  |
|-----------------|--------|
| total requests  | 57 |
| HTTP 200        | 57|
| HTTP non-200    | 0|
| p50 latency (s) | 0.065049 |
| p99 latency (s) | 0.585130 |

* Sustained-load passes (errors ≤ 2): **true**

## 6. Switch responses

### decode → prefill
```json
{
    "status": "ok",
    "new_role": "prefill",
    "switch_time_ms": 473.4436580911279,
    "timings_ms": {
        "sleep": 60.931,
        "unregister_mdc": 9.397,
        "reconfig_nixl": 0.128,
        "reset_prefix_cache": 3.436,
        "register_mdc": 332.203,
        "wake": 51.439
    }
}
```
### prefill → decode
```json
{
    "status": "ok",
    "new_role": "decode",
    "switch_time_ms": 460.2377850096673,
    "timings_ms": {
        "sleep": 38.995,
        "unregister_mdc": 78.632,
        "reconfig_nixl": 0.222,
        "reset_prefix_cache": 1.547,
        "register_mdc": 315.635,
        "wake": 25.175
    }
}
```

## 7. Worker log excerpts (target)

### After prefill serving phase
```
[2m2026-05-12T13:55:36.372657Z[0m [32m INFO[0m [2margs.create_kv_events_config[0m[2m:[0m Decode worker detected (disaggregation_mode=decode): kv_events_config disabled (decode workers don't publish KV events)
[2m2026-05-12T13:55:55.142840Z[0m [32m INFO[0m [2mmain.init[0m[2m:[0m [RLScaling/DualMode] decode worker will also publish prefill endpoint URI for hot role flips: dynamo-system-vllm-v1-disagg-router-574b777c.prefill.generate
[2m2026-05-12T13:57:18.331623Z[0m [32m INFO[0m [2mmain.init[0m[2m:[0m Registered engine routes: /engine/sleep, /engine/wake_up
[2m2026-05-12T13:57:19.312896Z[0m [32m INFO[0m [2mmain.init[0m[2m:[0m [RLScaling/DualMode] generate endpoint installed with role-aware dispatcher (decode|partner-prefill); prefill MDC will be published on /switch_role
[2m2026-05-12T13:59:52.890532Z[0m [32m INFO[0m [2mhandlers.sleep[0m[2m:[0m [Sleep] Unregistered endpoint from discovery - worker removed from routing pool
(EngineCore_DP0 pid=685) INFO 05-12 13:59:52 [cumem.py:213] CuMemAllocator: sleep freed 0.00 GiB memory in total, of which 0.00 GiB is backed up in CPU and the rest 0.00 GiB is discarded directly.
(EngineCore_DP0 pid=685) INFO 05-12 13:59:52 [abstract.py:312] It took 0.025932 seconds to fall asleep.
[2m2026-05-12T13:59:52.939415Z[0m [32m INFO[0m [2mdual_mode._reconfig_nixl[0m[2m:[0m [DualMode] reconfig_nixl(prefill): no cached nixl connector; nothing to drop
[2m2026-05-12T13:59:52.942851Z[0m [32m INFO[0m [2mdual_mode._reconfig_kv_pool[0m[2m:[0m [DualMode] reconfig_kv_pool(prefill): reset_prefix_cache OK
(EngineCore_DP0 pid=685) INFO 05-12 13:59:53 [abstract.py:330] It took 0.010173 seconds to wake up tags {'weights', 'kv_cache'}.
[2m2026-05-12T13:59:53.326482Z[0m [32m INFO[0m [2mhandlers.wake_up[0m[2m:[0m [Wake] Re-registered endpoint to discovery - worker added back to routing pool
[2m2026-05-12T13:59:53.342385Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] registered prefill endpoint instance
[2m2026-05-12T13:59:53.342476Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] switch_role decode->prefill OK total=473.44ms timings={'sleep': 60.931, 'unregister_mdc': 9.397, 'reconfig_nixl': 0.128, 'reset_prefix_cache': 3.436, 'register_mdc': 332.203, 'wake': 51.439}
```
### After decode serving phase
```
[2m2026-05-12T13:57:18.331623Z[0m [32m INFO[0m [2mmain.init[0m[2m:[0m Registered engine routes: /engine/sleep, /engine/wake_up
[2m2026-05-12T13:57:19.312896Z[0m [32m INFO[0m [2mmain.init[0m[2m:[0m [RLScaling/DualMode] generate endpoint installed with role-aware dispatcher (decode|partner-prefill); prefill MDC will be published on /switch_role
[2m2026-05-12T13:59:52.890532Z[0m [32m INFO[0m [2mhandlers.sleep[0m[2m:[0m [Sleep] Unregistered endpoint from discovery - worker removed from routing pool
(EngineCore_DP0 pid=685) INFO 05-12 13:59:52 [cumem.py:213] CuMemAllocator: sleep freed 0.00 GiB memory in total, of which 0.00 GiB is backed up in CPU and the rest 0.00 GiB is discarded directly.
(EngineCore_DP0 pid=685) INFO 05-12 13:59:52 [abstract.py:312] It took 0.025932 seconds to fall asleep.
[2m2026-05-12T13:59:52.939415Z[0m [32m INFO[0m [2mdual_mode._reconfig_nixl[0m[2m:[0m [DualMode] reconfig_nixl(prefill): no cached nixl connector; nothing to drop
[2m2026-05-12T13:59:52.942851Z[0m [32m INFO[0m [2mdual_mode._reconfig_kv_pool[0m[2m:[0m [DualMode] reconfig_kv_pool(prefill): reset_prefix_cache OK
(EngineCore_DP0 pid=685) INFO 05-12 13:59:53 [abstract.py:330] It took 0.010173 seconds to wake up tags {'weights', 'kv_cache'}.
[2m2026-05-12T13:59:53.326482Z[0m [32m INFO[0m [2mhandlers.wake_up[0m[2m:[0m [Wake] Re-registered endpoint to discovery - worker added back to routing pool
[2m2026-05-12T13:59:53.342385Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] registered prefill endpoint instance
[2m2026-05-12T13:59:53.342476Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] switch_role decode->prefill OK total=473.44ms timings={'sleep': 60.931, 'unregister_mdc': 9.397, 'reconfig_nixl': 0.128, 'reset_prefix_cache': 3.436, 'register_mdc': 332.203, 'wake': 51.439}
[2m2026-05-12T13:59:59.557984Z[0m [32m INFO[0m [2mhandlers.sleep[0m[2m:[0m [Sleep] Unregistered endpoint from discovery - worker removed from routing pool
(EngineCore_DP0 pid=685) INFO 05-12 13:59:59 [cumem.py:213] CuMemAllocator: sleep freed 0.00 GiB memory in total, of which 0.00 GiB is backed up in CPU and the rest 0.00 GiB is discarded directly.
(EngineCore_DP0 pid=685) INFO 05-12 13:59:59 [abstract.py:312] It took 0.008705 seconds to fall asleep.
[2m2026-05-12T13:59:59.644249Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] unregistered prefill endpoint instance
[2m2026-05-12T13:59:59.654869Z[0m [32m INFO[0m [2mdual_mode._reconfig_nixl[0m[2m:[0m [DualMode] reconfig_nixl(decode): no cached nixl connector; nothing to drop
[2m2026-05-12T13:59:59.656434Z[0m [32m INFO[0m [2mdual_mode._reconfig_kv_pool[0m[2m:[0m [DualMode] reconfig_kv_pool(decode): reset_prefix_cache OK
(EngineCore_DP0 pid=685) INFO 05-12 13:59:59 [abstract.py:330] It took 0.006800 seconds to wake up tags {'weights', 'kv_cache'}.
[2m2026-05-12T13:59:59.997232Z[0m [32m INFO[0m [2mhandlers.wake_up[0m[2m:[0m [Wake] Re-registered endpoint to discovery - worker added back to routing pool
[2m2026-05-12T13:59:59.997389Z[0m [32m INFO[0m [2mdual_mode.switch_role[0m[2m:[0m [DualMode] switch_role prefill->decode OK total=460.24ms timings={'sleep': 38.995, 'unregister_mdc': 78.632, 'reconfig_nixl': 0.222, 'reset_prefix_cache': 1.547, 'register_mdc': 315.635, 'wake': 25.175}
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
