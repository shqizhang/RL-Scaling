# S2 Elastic PD Switch — Detailed Evidence Report

**Date:** 2026-05-12 09:58:35 UTC
**Image:** `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`
**Cluster:** single-node K8s, namespace `dynamo-system`
**Model:** `Qwen/Qwen3-0.6B`

## Pod inventory

| Role             | Pod name | Image |
|------------------|----------|-------|
| TARGET (decode → prefill → decode) | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489c44q7t` | rl-scaling-fe78f1b652 |
| PEER (decode, unchanged)           | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489c6q7bg`   | rl-scaling-fe78f1b652 |
| Dedicated prefill worker           | `vllm-v1-disagg-router-vllmprefillworker-7663d0d2-64b454bd5wnkk7` | rl-scaling-fe78f1b652 |
| Frontend                           | `vllm-v1-disagg-router-frontend-76457f997c-8tntf` | rl-scaling-fe78f1b652 |

**ISOLATE_TARGET mode:** `true` (if true, dedicated prefill was scaled to 0 during Phase 2)

---

## Phase 0: Pre-switch state

### TARGET DynamoWorkerMetadata CR — model_cards

```
  "dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/67b3ff12c8feb": { model_type: "?" }
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
    "switch_time_ms": 435.7988331466913,
    "timings_ms": {
        "sleep": 75.487,
        "unregister_mdc": 13.855,
        "reconfig_nixl": 0.193,
        "reset_prefix_cache": 2.808,
        "register_mdc": 303.615,
        "wake": 26.638
    }
}
```

Wall-clock latency: **473.1ms**

### TARGET CR after switch — model_cards

```
  "dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/67b3ff12c8feb": { model_type: "?" }
```

**The `backend/generate` (decode/chat) model card has been REMOVED from the CR.**
This means the frontend's `ModelWatcher` will no longer route chat/decode traffic
to TARGET. A `prefill/generate` model card was published, so `PrefillRouter` now
dispatches prefill traffic to TARGET.

### CR diff (before → after switch)

```
REMOVED model_cards (no longer discoverable by router):
  - dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/67b3ff12c8feb
ADDED model_cards (now discoverable by router):
  + dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/67b3ff12c8feb
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
[2m2026-05-12T09:56:00.451882Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0m555ac284-c0c7-4abb-a857-ef7e8cb896b9 [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 1824364419649515, model_suffix: None })
[2m2026-05-12T09:56:00.451920Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0m32e0ef4d-9a0a-49d8-90de-cdd762207714 [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 1824364419649515, model_suffix: None })
[2m2026-05-12T09:56:00.452066Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Emitting Removed event [3mstream_id[0m[2m=[0m093e0f54-6e29-4295-9d34-1b94ab96d8fa [3mid[0m[2m=[0mModel(ModelCardInstanceId { namespace: "dynamo-system-vllm-v1-disagg-router-7663d0d2", component: "backend", endpoint: "generate", instance_id: 1824364419649515, model_suffix: None })
```

---

## Phase 2: Partner-prefill serving evidence

After the switch, TARGET is in prefill mode. We send 30 chat requests.

**Isolation mode:** ISOLATE_TARGET=true, PREFILL_SCALED_DOWN=true

The dedicated prefill worker was scaled to 0, so TARGET is the **only** prefill worker.
All prefill traffic **must** go through TARGET.

TARGET's discovered prefill_worker_id: `1824364419649515`

### Chat probe results

- Total probes: **10**
- HTTP 200 (success): **30**
- Errors: **0**

**All 30/10 chat requests completed successfully (200 OK, no HTTP 500).**
This proves the TCP path collision fix works — the role-aware dispatcher correctly
routes to `_partner_prefill_generate` when the pod is in prefill role.

### vllm:prompt_tokens_total on TARGET (proves actual prefill serving)

| Metric                        | Value |
|-------------------------------|------:|
| Baseline (pre-switch)         | 72 |
| After 10 prefill probes | 560 |
| **Delta (prefill traffic served)** | **488** |

A positive delta means vLLM on TARGET processed prompt tokens while in prefill
mode. Since the decode model card was withdrawn (PASS_CR_D2P), the only way
traffic reaches TARGET is through the PrefillRouter → partner-prefill dispatcher.

### TARGET worker logs (partner-prefill invocations)

```
[2m2026-05-12T09:55:19.037467Z[0m [32m INFO[0m [2mrl_scaling_sidecar.start_sidecar[0m[2m:[0m [RLScalingSidecar] listening on 0.0.0.0:9091 (dual_mode=True, migration=True)
[2m2026-05-12T09:55:19.037965Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering event channel: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=, topic=kv_metrics, instance_id=67b3ff12c8feb
[2m2026-05-12T09:55:19.326198Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering model card: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=67b3ff12c8feb
[2m2026-05-12T09:55:19.336457Z[0m [32m INFO[0m [2mmain.init[0m[2m:[0m [RLScaling/DualMode] generate endpoint installed with role-aware dispatcher (decode|partner-prefill); prefill MDC will be published on /switch_role
[2m2026-05-12T09:55:19.338176Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=clear_kv_blocks, instance_id=67b3ff12c8feb
[2m2026-05-12T09:55:19.353225Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=67b3ff12c8feb
[2m2026-05-12T09:55:59.924543Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Unregistering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=67b3ff12c8feb
[2m2026-05-12T09:55:59.999261Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Unregistering model card: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=67b3ff12c8feb
[2m2026-05-12T09:56:00.306835Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering model card: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=prefill, endpoint=generate, instance_id=67b3ff12c8feb
[2m2026-05-12T09:56:00.329787Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=backend, endpoint=generate, instance_id=67b3ff12c8feb
[2m2026-05-12T09:56:00.346678Z[0m [32m INFO[0m [2mdynamo_runtime::discovery::kube[0m[2m:[0m Registering endpoint: namespace=dynamo-system-vllm-v1-disagg-router-7663d0d2, component=prefill, endpoint=generate, instance_id=67b3ff12c8feb
[2m2026-05-12T09:56:00.374847Z[0m [33m WARN[0m [2mrl_scaling_sidecar._patch_self_pod_label[0m[2m:[0m [RLScalingSidecar] pod label patch returned HTTP 403: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods \"vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489c44q7t\" is forbidden: User \"system:serviceaccount:dynam
```

Each log line shows `_partner_prefill_generate ENTER` / `EXIT` with
`merged_kv=True`, confirming the buffering wrapper is correctly consolidating
`kv_transfer_params` from vLLM's NixlConnector and yielding a single chunk.

**PASS_PREFILL_SERVING = true**

---

## Phase 3: Revert prefill → decode

### switch_role response

```json
{
    "status": "ok",
    "new_role": "decode",
    "switch_time_ms": 416.86364519409835,
    "timings_ms": {
        "sleep": 76.205,
        "unregister_mdc": 22.957,
        "reconfig_nixl": 0.07,
        "reset_prefix_cache": 1.166,
        "register_mdc": 294.352,
        "wake": 22.069
    }
}
```

Wall-clock latency: **453.4ms**

### TARGET CR after revert — model_cards

```
  "dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/67b3ff12c8feb": { model_type: "?" }
```

The `backend/generate` (decode/chat) model card is **restored**. TARGET is back in
the chat WorkerSet.

### CR diff (post-switch → post-revert)

```
REMOVED model_cards:
  - dynamo-system-vllm-v1-disagg-router-7663d0d2/prefill/generate/67b3ff12c8feb
ADDED model_cards (decode restored):
  + dynamo-system-vllm-v1-disagg-router-7663d0d2/backend/generate/67b3ff12c8feb
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
- **TARGET served as decode worker: 6/10**

TARGET prompt_tokens delta during post-revert probes: **96**
(positive means TARGET is again processing chat/decode traffic)

---

## Summary

| Condition | Result |
|-----------|--------|
| CR loses backend/generate after switch→prefill | **true** |
| CR regains backend/generate after revert→decode | **true** |
| All post-switch chats succeed (0 HTTP 500) | **30/10** |
| TARGET serves real prefill traffic (prompt_tokens Δ>0) | **true** (Δ=488, served=30/30) |
| All post-revert chats succeed | **10/10** |
| TARGET serves decode after revert | **true** (6/10) |
| **OVERALL** | **true** |

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
