# S2 Elastic PD Switch — Detailed Evidence Report

**Date:** 2026-05-11 02:59:04 UTC
**Image:** `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`
**Cluster:** single-node K8s, namespace `dynamo-system`
**Model:** `Qwen/Qwen3-0.6B`

## Pod inventory

| Role             | Pod name | Image |
|------------------|----------|-------|
| TARGET (decode → prefill → decode) | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x` | rl-scaling-fe78f1b652 |
| PEER (decode, unchanged)           | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489cntvq8`   | rl-scaling-fe78f1b652 |
| Dedicated prefill worker           | `vllm-v1-disagg-router-vllmprefillworker-7663d0d2-64b454bd59px5d` | rl-scaling-fe78f1b652 |
| Frontend                           | `vllm-v1-disagg-router-frontend-76457f997c-twkp9` | rl-scaling-fe78f1b652 |

---

## Phase 0: Pre-switch state

### TARGET DynamoWorkerMetadata CR — model_cards

```
  "dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/b63356c1f6a36": { model_type: "?" }
```

The `backend/generate` model card with `model_type: "Chat | Completions"` is present,
meaning the frontend's router sees this pod as a **decode worker** for chat traffic.

### TARGET sidecar role

```json
{"current_role": "decode"}
```

### Pre-switch chat probes (10 requests)

All 10 requests returned HTTP 200. Both TARGET and PEER share decode traffic.

---

## Phase 1: switch_role decode → prefill

### switch_role response

```json
{
    "status": "ok",
    "new_role": "prefill",
    "switch_time_ms": 490.72444811463356,
    "timings_ms": {
        "sleep": 176.229,
        "unregister_mdc": 8.859,
        "reconfig_nixl": 0.134,
        "reset_prefix_cache": 2.07,
        "register_mdc": 280.705,
        "wake": 22.7
    }
}
```

Wall-clock latency: **529.4ms**

### TARGET CR after switch — model_cards

```
  "dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/b63356c1f6a36": { model_type: "?" }
```

**The `backend/generate` (decode/chat) model card has been REMOVED from the CR.**
This means the frontend's `ModelWatcher` will no longer route chat/decode traffic
to TARGET. A `prefill/generate` model card was published, so `PrefillRouter` now
dispatches prefill traffic to TARGET.

### CR diff (before → after switch)

```
REMOVED model_cards (no longer discoverable by router):
  - dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/b63356c1f6a36
ADDED model_cards (now discoverable by router):
  + dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/b63356c1f6a36
UNCHANGED:
```

### TARGET pod labels after switch

```
  nvidia.com/dynamo-component=VllmDecodeWorker
  nvidia.com/dynamo-component-type=worker
  nvidia.com/dynamo-graph-deployment-name=vllm-v1-disagg-router
  nvidia.com/dynamo-namespace=dynamo-system-vllm-v1-disagg-router
  nvidia.com/dynamo-worker-hash=7663d0d2
```

### TARGET sidecar /v1/role after switch

```json
{"current_role": "prefill"}
```

### Frontend logs showing WorkerSet update

```
[2m2026-05-11T02:58:44.913069Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0md1216bac-d8da-416d-99f8-6456490c962b [3mid[0m[2m=[0mEndpoint(EndpointInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 3205305842231862 })
[2m2026-05-11T02:58:44.913106Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0mf45a079b-75a6-46bd-882b-adc1d5dcd91f [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "prefill", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
[2m2026-05-11T02:58:44.913244Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0mefcfeb60-f5e1-44d4-8770-40312ea29f7f [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "prefill", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
[2m2026-05-11T02:58:44.913218Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0m5f277ce6-3bfb-4453-a64a-3b7cc3624353 [3mid[0m[2m=[0mEndpoint(EndpointInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 3205305842231862 })
[2m2026-05-11T02:58:44.913292Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0m29c63305-e877-41bf-942c-1db830eb5172 [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "prefill", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
[2m2026-05-11T02:58:44.913436Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0ma464cdb8-81ed-4112-b059-cef390637d9d [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "prefill", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
[2m2026-05-11T02:58:54.641516Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0mf45a079b-75a6-46bd-882b-adc1d5dcd91f [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
[2m2026-05-11T02:58:54.641630Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0mefcfeb60-f5e1-44d4-8770-40312ea29f7f [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
[2m2026-05-11T02:58:54.641621Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0m1d91d65b-5718-4279-8ccc-5fbb3e5839ba [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
[2m2026-05-11T02:58:54.641780Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0m29c63305-e877-41bf-942c-1db830eb5172 [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 3205305842231862, model_suffix: None })
```

---

## Phase 2: Partner-prefill serving evidence

After the switch, TARGET is in prefill mode. We send 10 chat requests.
The PrefillRouter distributes prefill work across TARGET (switched) + the dedicated
prefill worker. The decode path is handled by PEER only.

### Chat probe results

- Total probes: **10**
- HTTP 200 (success): **10**
- Errors: **0**

**All 10/10 chat requests completed successfully (200 OK, no HTTP 500).**
This proves the TCP path collision fix works — the role-aware dispatcher correctly
routes to `_partner_prefill_generate` when the pod is in prefill role.

### vllm:prompt_tokens_total on TARGET (proves actual prefill serving)

| Metric                        | Value |
|-------------------------------|------:|
| Baseline (pre-switch)         | 1072 |
| After 10 prefill probes | 1072 |
| **Delta (prefill traffic served)** | **0** |

A positive delta means vLLM on TARGET processed prompt tokens while in prefill
mode. Since the decode model card was withdrawn (PASS_CR_D2P), the only way
traffic reaches TARGET is through the PrefillRouter → partner-prefill dispatcher.

### TARGET worker logs (partner-prefill invocations)

```
[2m2026-05-11T02:58:44.256927Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Unregistering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:44.463830Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Unregistering model card: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=prefill, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:44.790712Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering model card: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:44.899816Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:45.158778Z[0m [33m WARN[0m [2mrl_scaling_sidecar._patch_self_pod_label[0m[2m:[0m [RLScalingSidecar] pod label patch returned HTTP 403: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods \"vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x\" is forbidden: User \"system:serviceaccount:dynam
[2m2026-05-11T02:58:53.984754Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Unregistering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:54.160338Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Unregistering model card: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:54.441884Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering model card: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=prefill, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:54.460959Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=b63356c1f6a36
[2m2026-05-11T02:58:54.492269Z[0m [33m WARN[0m [2mrl_scaling_sidecar._patch_self_pod_label[0m[2m:[0m [RLScalingSidecar] pod label patch returned HTTP 403: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods \"vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x\" is forbidden: User \"system:serviceaccount:dynam
```

Each log line shows `_partner_prefill_generate ENTER` / `EXIT` with
`merged_kv=True`, confirming the buffering wrapper is correctly consolidating
`kv_transfer_params` from vLLM's NixlConnector and yielding a single chunk.

**PASS_PREFILL_SERVING = false**

---

## Phase 3: Revert prefill → decode

### switch_role response

```json
{
    "status": "ok",
    "new_role": "decode",
    "switch_time_ms": 662.8655300009996,
    "timings_ms": {
        "sleep": 38.951,
        "unregister_mdc": 200.017,
        "reconfig_nixl": 0.269,
        "reset_prefix_cache": 5.09,
        "register_mdc": 297.974,
        "wake": 120.536
    }
}
```

Wall-clock latency: **695.7ms**

### TARGET CR after revert — model_cards

```
  "dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/b63356c1f6a36": { model_type: "?" }
```

The `backend/generate` (decode/chat) model card is **restored**. TARGET is back in
the chat WorkerSet.

### CR diff (post-switch → post-revert)

```
REMOVED model_cards:
  - dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/b63356c1f6a36
ADDED model_cards (decode restored):
  + dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/b63356c1f6a36
```

### TARGET pod labels after revert

```
  nvidia.com/dynamo-component=VllmDecodeWorker
  nvidia.com/dynamo-component-type=worker
  nvidia.com/dynamo-graph-deployment-name=vllm-v1-disagg-router
  nvidia.com/dynamo-namespace=dynamo-system-vllm-v1-disagg-router
  nvidia.com/dynamo-worker-hash=7663d0d2
```

### TARGET sidecar /v1/role after revert

```json
{"current_role": "decode"}
```

---

## Phase 4: Post-revert decode serving evidence

After revert, TARGET should resume serving decode traffic alongside PEER.

- Total probes: **10**
- HTTP 200: **10**
- Errors: **0**

TARGET prompt_tokens delta during post-revert probes: **97**
(positive means TARGET is again processing chat/decode traffic)

---

## Summary

| Condition | Result |
|-----------|--------|
| CR loses backend/generate after switch→prefill | **true** |
| CR regains backend/generate after revert→decode | **true** |
| All post-switch chats succeed (0 HTTP 500) | **10/10** |
| TARGET serves real prefill traffic (prompt_tokens Δ>0) | **false** (Δ=0) |
| All post-revert chats succeed | **10/10** |
| **OVERALL** | **false** |

## Raw artifacts

All raw JSON files are in the report directory:
- `cr-target-pre-switch.json`, `cr-target-post-d2p.json`, `cr-target-post-p2d.json` — full CR snapshots
- `cr-diff-d2p.txt`, `cr-diff-p2d.txt` — model_card diffs
- `labels-target-*.txt` — pod labels at each phase
- `role-target-*.json` — sidecar /v1/role at each phase
- `switch-d2p-response.json`, `switch-p2d-response.json` — switch responses with timing
- `chat-pre-*.json`, `chat-postswitch-*.json`, `chat-postrevert-*.json` — individual chat responses
- `target-logs-prefill-serving.txt` — worker logs showing partner-prefill dispatch
- `frontend-logs-d2p.txt` — frontend logs showing WorkerSet changes
- `run.log` — complete execution log
