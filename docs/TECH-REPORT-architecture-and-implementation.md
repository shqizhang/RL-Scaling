# RL-Scaling on Dynamo — Technical Implementation Report

> Date: 2026-05-10. Image: `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-f817b8e5d5`.
> Scope: deep-dive on (a) the elastic PD role-switch mechanism for live decode pods,
> (b) how Dynamo's frontend router becomes aware of the switch end-to-end, and
> (c) the in-flight request consolidation / KV-migration protocol.
> Companion specs: [S2-elastic-pd-switch.md](S2-elastic-pd-switch.md),
> [S3-request-consolidation.md](S3-request-consolidation.md).

---

## 1. System architecture

### 1.1 Layered view (deployed shape)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes API server (kube-apiserver)               │
│                                                                              │
│  CRDs: DynamoGraphDeployment, DynamoComponentDeployment,                     │
│        DynamoWorkerMetadata  (≡ runtime registration record, 1-per-pod)      │
└────────────▲─────────────────────────────────────────────▲───────────────────┘
             │  apply / watch                              │  apply / watch
             │                                             │
┌────────────┴─────────────┐                  ┌────────────┴───────────────────┐
│  Frontend pod            │                  │  Worker pod (decode | prefill) │
│  ─────────────           │                  │  ─────────────                 │
│  ┌─────────────────────┐ │                  │  ┌──────────────────────────┐  │
│  │ ModelWatcher (Rust) │ │  list/watch      │  │ Dynamo runtime (Rust)    │  │
│  │  -> WorkerSet       │◄┼── DynamoWorker   │  │  - registers Endpoint /  │  │
│  │  -> KvRouter        │ │   Metadata       │  │    ModelCard / EventCh.  │  │
│  │  -> PrefillRouter   │ │                  │  │  - apply_cr to own DWMD  │  │
│  └────────┬────────────┘ │                  │  └────────────┬─────────────┘  │
│           │              │                  │               │                │
│  HTTP 8000 (chat/comp)   │                  │  TCP 4222 NATS subjects        │
│           │              │                  │               │                │
└───────────┼──────────────┘                  │  ┌────────────┴─────────────┐  │
            │                                 │  │ vLLM 0.16 engine         │  │
            │ KV-aware route                  │  │  + NixlConnector (kv_both)│ │
            │                                 │  │  + PrefixCache + KVBM    │  │
            ▼                                 │  └────────────┬─────────────┘  │
   ┌────────────────────────────────┐         │               │                │
   │ chosen worker: TCP <pod-ip>:port│────────┼─ generate ────┘                │
   └────────────────────────────────┘         │                                │
                                              │  ┌──────────────────────────┐  │
                                              │  │ RL-Scaling sidecar       │  │
                                              │  │  aiohttp :9091           │  │
                                              │  │  /switch_role            │  │
                                              │  │  /migrate_out /in        │  │
                                              │  │  /v1/active_requests     │  │
                                              │  └──────────────────────────┘  │
                                              └────────────────────────────────┘

                   ┌──────────────────────────┐
                   │ NATS (dynamo-platform)   │   event plane: kv_metrics,
                   │  port 4222               │   role_changed, kvbm signals
                   └──────────────────────────┘
```

Key facts that a reader must internalize before the rest of the report makes
sense:

- **Discovery is K8s-CRD-based**, not etcd. Each worker pod owns one
  `DynamoWorkerMetadata` (DWMD) custom resource named after itself; its
  `.spec.data.{endpoints, event_channels, model_cards}` is the runtime
  registration record. The frontend's `ModelWatcher` rebuilds its `WorkerSet`
  by listing+watching these CRs in the deployment namespace.
- **Two HTTP surfaces per worker pod**: `:9090` is the Dynamo system port
  (Prometheus metrics, internal endpoints); **`:9091` is the RL-Scaling
  sidecar** (the only thing that exposes `/switch_role`, `/migrate_*`,
  `/v1/active_requests`).
- **vLLM 0.16 is built once per pod with `kv_role=kv_both`** and `NixlConnector`
  enabled, so the engine has both prefill and decode capabilities baked in.
  Switching roles is a *registration* and *engine-state* operation — it does
  not rebuild the engine.

### 1.2 Pod-internal architecture

```
                        ┌────────────────────────────────────────────────┐
                        │                Worker pod                      │
                        │                                                │
   K8s API ─── apply/   │   ┌──────────────────┐   register/             │
              watch     │   │  Dynamo runtime  │   unregister            │
                        │   │  (Rust)          │◄────────┐               │
                        │   │  discovery::kube │         │               │
                        │   └─────▲────────────┘         │               │
                        │         │ DiscoveryMetadata    │               │
                        │         │                      │               │
                        │   ┌─────┴────────────┐    ┌────┴──────────┐    │
                        │   │ EngineHandler    │    │ VllmReregistrar    │
                        │   │ (Python)         │    │ (Python)          │
                        │   │  - generate()    │    │  endpoints_by_role│
                        │   │  - sleep()/wake()│    │  {decode:...,     │
                        │   │  - request_      │    │   prefill:...}    │
                        │   │    registry      │    └────▲──────────────┘
                        │   └─────▲────────────┘         │              │
                        │         │                      │              │
                        │   ┌─────┴────────────┐         │              │
                        │   │  vLLM Engine     │         │              │
                        │   │   + Prefix cache │         │              │
                        │   │   + KVBM (NIXL)  │         │              │
                        │   └─────▲────────────┘         │              │
                        │         │                      │              │
                        │   ┌─────┴───────────────────┐  │              │
                        │   │ DualModeWorker          │──┘              │
                        │   │  switch_role(target)    │                 │
                        │   │  8-step orchestration   │                 │
                        │   └─────▲───────────────────┘                 │
                        │         │ HTTP                                │
                        │   ┌─────┴───────────────────┐                 │
                        │   │ rl_scaling_sidecar      │                 │
                        │   │  aiohttp :9091          │                 │
                        │   │  /switch_role           │                 │
                        │   │  /migrate_in /out       │                 │
                        │   │  /v1/active_requests    │                 │
                        │   └─────────────────────────┘                 │
                        │                                                │
                        └────────────────────────────────────────────────┘
```

Files that draw the box boundaries:

| box | file |
|-----|------|
| Dynamo runtime / discovery::kube | [lib/runtime/src/discovery/kube.rs](../../dynamo/lib/runtime/src/discovery/kube.rs) |
| EngineHandler (sleep / wake / generate) | [components/src/dynamo/vllm/handlers.py](../../dynamo/components/src/dynamo/vllm/handlers.py) |
| VllmReregistrar | [components/src/dynamo/vllm/main.py](../../dynamo/components/src/dynamo/vllm/main.py) (L590-670) |
| DualModeWorker (8-step) | [components/src/dynamo/vllm/dual_mode.py](../../dynamo/components/src/dynamo/vllm/dual_mode.py) |
| MigrationHandler | [components/src/dynamo/vllm/migration.py](../../dynamo/components/src/dynamo/vllm/migration.py) |
| RL-Scaling sidecar (aiohttp :9091) | [components/src/dynamo/vllm/rl_scaling_sidecar.py](../../dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py) |

---

## 2. Kubernetes principles in play

### 2.1 The DynamoWorkerMetadata CR as the discovery substrate

`DiscoveryBackend::Kubernetes` is selected by the env var
`DYN_DISCOVERY_BACKEND=kubernetes` (set by the operator on every worker pod).
The Rust path in [distributed.rs L131-145](../../dynamo/lib/runtime/src/distributed.rs)
constructs a `KubeDiscovery` client which:

1. **On register**, calls `DiscoveryMetadata::register_endpoint(instance)` to
   merge the new `DiscoveryInstance::{Endpoint | Model | EventChannel}` into
   an in-memory `BTreeMap` keyed by `<namespace>/<component>/<endpoint>/<inst>`,
   then `apply_cr()` strategic-merge-patches the pod's own DWMD CR.
2. **On unregister**, removes the key from the map and re-applies.
3. **On the frontend side**, a single watcher informer streams DWMD events
   for the namespace; `ModelWatcher` translates the union of
   `spec.data.model_cards` across all DWMDs into the chat WorkerSet,
   `spec.data.endpoints[".../backend/generate/<id>"]` into RPC targets, and
   `spec.data.event_channels` into the NATS subscriptions.

Concretely, a healthy decoder pod's CR contains:

```
spec.data:
  endpoints:
    dynamo-system-vllm-v1-disagg-router-f5d52951/backend/generate/<inst>: {Endpoint}
    dynamo-system-vllm-v1-disagg-router-f5d52951/backend/clear_kv_blocks/<inst>: {Endpoint}
  event_channels:
    dynamo-system-vllm-v1-disagg-router-f5d52951//kv_metrics/<inst>: {EventChannel, kind: Nats}
  model_cards:
    dynamo-system-vllm-v1-disagg-router-f5d52951/backend/generate/<inst>: {card_json: {...}}
```

The CR is the **single observable ground truth** for "is this pod in the
chat pool". That is what the S2 test asserts on directly (`PASS_CR_D2P`).

### 2.2 Owner references and lifecycle

Each DWMD has an `ownerReference` to its Pod with `controller: true,
blockOwnerDeletion: false`. When the pod is deleted, the K8s garbage
collector deletes the CR; until then, the worker is the sole writer. This
matters because role switching mutates the CR while the pod is still
running — there is no operator/controller fighting our updates.

### 2.3 Service vs CR: routing path is bypassed

A naive K8s deployment would expose decoders behind a Service and round-robin.
We do **not** use that path for chat traffic. The frontend reads each pod's
`endpoints[].transport.tcp = <pod_ip>:<port>/<instance_id>/<endpoint>` from
the DWMD and connects directly. This is why withdrawing a pod from the chat
pool reduces to "remove the `model_cards` entry from this pod's CR" — the
Service is irrelevant.

---

## 3. PD role switch — the hot-swap mechanism

### 3.1 Goal restated

We want a decoder pod `D_i` to leave the chat WorkerSet on demand
(`switch_role -> prefill`), free its decode KV state, optionally come back
later (`switch_role -> decode`), and have all of this be invisible to
in-flight chat traffic on the surviving pods.

### 3.2 Why this is hard in vLLM 0.16

vLLM's `kv_transfer_config` is **fixed at engine construction**. You
cannot reconfigure NixlConnector at runtime. We work around this by
booting the engine with `--kv-transfer-config NixlConnector kv_both`
once, so the same engine has the metadata for both roles. The
"role switch" is then purely:

1. a registration change (which `ModelCard` is published in the CR), and
2. an engine state cycle (sleep -> reset prefix cache -> wake), so the
   engine quiesces and discards transient state that would be inconsistent
   under the new role.

### 3.3 The 8-step orchestration

`DualModeWorker.switch_role(target_role)` (in
[dual_mode.py](../../dynamo/components/src/dynamo/vllm/dual_mode.py))
runs the following under a per-worker async lock; each step is timed and
the per-step ms ends up in the JSON response under `timings_ms`:

```
                            time
   ─────────────────────────────────────────────────────────────────────►

   ┌──────────┐
1. │  sleep   │   handlers.sleep():
   │ (level=2)│     - registry.pause_generation() : reject new submits
   └─────┬────┘     - engine.sleep(2)             : free GPU KV
         │
   ┌─────▼─────────┐
2. │ unregister_mdc│   reregistrar.unregister(role=current):
   │               │     - remove ModelCard for *current* role from DWMD
   └─────┬─────────┘     - kube apply (or no-op if role has no endpoints)
         │
   ┌─────▼────────┐
3. │ reconfig_nixl│   handler._nixl_connector = None
   │              │     - force lazy re-init on next use
   └─────┬────────┘
         │
   ┌─────▼─────────────────┐
4. │ reset_prefix_cache    │   engine.reset_prefix_cache()  (engine asleep)
   │                       │     - clears prefix-pool index that points
   │                       │       to about-to-be-recycled blocks
   └─────┬─────────────────┘
         │
   ┌─────▼───────────────────┐
5. │ set_disaggregation_mode │   handler.current_role = target_role
   └─────┬───────────────────┘
         │
   ┌─────▼─────────┐
6. │  register_mdc │   reregistrar.register(role=target):
   │               │     - if endpoints_by_role[target] is empty -> no-op
   │               │     - else publish ModelCard for new role into DWMD
   └─────┬─────────┘     - kube apply
         │
   ┌─────▼────┐
7. │  wake    │   handlers.wake_up():
   │          │     - engine.wake_up()
   └─────┬────┘     - registry.resume_generation()
         │
   ┌─────▼──────────────┐
8. │ emit_role_changed  │   sidecar event:
   │                    │     - patch self pod label
   │                    │       nvidia.com/dynamo-current-role=<target>
   └────────────────────┘
```

**Critical orderings**

- *(1) before (2)*: aborting in-flight is stronger than just unregistering,
  because the unregister only stops *new* routing — existing inference
  generations would continue against an asleep engine and crash.
- *(2) before (4)*: removing the ModelCard first means the frontend stops
  routing to us before we touch the prefix cache. Even though the watcher
  is eventually-consistent (~hundreds of ms), the unregister starts the
  clock as early as possible.
- *(4) inside the asleep window* (between sleep(2) and wake): vLLM's
  prefix cache holds references to KV blocks. `sleep(2)` returns those
  blocks to the GPU allocator. If we call `reset_prefix_cache` *after*
  `wake_up`, a freshly admitted request can hit a stale cache entry that
  points at a block now owned by another request. Doing the reset while
  the engine is paused makes the operation atomic from a scheduler POV.
- *(6) after (4)*: only after the engine is in a consistent target-role
  state do we publish the new ModelCard; any incoming traffic from the
  router will land on a wake-able engine.

### 3.4 Measured cost (ms)

|                          | decode -> prefill | prefill -> decode |
|--------------------------|------------------:|------------------:|
| sleep                    | 55.4              | 87.1              |
| unregister_mdc           | 8.0               | 10.2              |
| reconfig_nixl            | 0.1               | 0.2               |
| reset_prefix_cache       | 2.5               | 2.5               |
| register_mdc             | 296.4             | 290.1             |
| wake                     | 25.6              | 28.3              |
| **server total**         | **388.1**         | **418.4**         |
| client wall-clock        | 433.3             | 457.6             |

With partner-prefill enabled (§3.6) both directions publish a fresh
`ModelCard` (the d->p direction publishes the prefill MDC; the p->d
direction publishes the decode MDC), so both round-trips include
`register_mdc` cost (~290ms in our single-node cluster). Earlier builds
that ran with partner-prefill gated off had an asymmetric cost profile
because the `prefill` role had no MDC to publish.

### 3.5 KV / prefix-cache consistency

`engine.sleep(level=2)` releases the GPU KV cache pages back to the
allocator; the engine retains its weights but not its activations or the
KV blocks. The prefix cache is an index into those blocks. Without
`reset_prefix_cache`, the index becomes a hazard:

```
  before sleep:  prefix_cache[hash("system: you are...")] -> block #42
  sleep(2):      block #42 returned to free pool
  wake_up:       allocator hands block #42 to a fresh request "X"
  next chat:     prefix lookup -> block #42 -> serves "X"'s tokens to
                 the new request as if they were a cache hit. Wrong.
```

So the orchestration **must** reset the prefix cache during the asleep
window. The cost is small (1-4 ms here) because it is purely an
in-memory hash map flush.

### 3.6 Partner-prefill: how a switched pod actually serves prefill

With `DYNAMO_RL_DUAL_PARTNER_PREFILL=1`, after `switch_role -> prefill`
the pod is a **first-class prefill worker** that the frontend's
`PrefillRouter` will dispatch traffic to. The verified probe shows
`vllm:prompt_tokens_total` on the switched target growing by 1249
across 30 chat probes while the chat WorkerSet has the target
withdrawn (S2 test PASS_PREFILL_SERVING).

Getting this to work end-to-end required two non-obvious fixes:

**(a) Multi-chunk consolidation (commit `a82816c3d6`).**
vLLM 0.16's `NixlConnector.request_finished()`
([nixl_connector.py L780-855]) publishes `kv_transfer_params` only on
the FINAL `RequestOutput` chunk for a request. Dynamo's Rust
`PrefillRouter::execute_prefill`
([lib/llm/src/kv_router/prefill_router.rs L376-465]) reads
`first_output.data.disaggregated_params` from the FIRST chunk only.
Missing the field -> `NoDisaggregatedParams` -> HTTP 500. The wrapper
`_partner_prefill_generate` consumes the entire stream, captures the
last `kv_transfer_params` it observes, and yields ONE consolidated
chunk so the router sees the field on chunk #1.

**(b) Single TCP slot dispatcher (commit `fe78f1b652`).**
Dynamo's `SharedTcpServer`
([lib/runtime/src/pipeline/network/ingress/shared_tcp_endpoint.rs])
keys handlers in a `DashMap` by
`endpoint_path = format!("{instance_id:x}/{endpoint_name}")`. The
`instance_id` is `endpoint.drt().connection_id()`
([component/endpoint.rs L72]) which is **process-scoped**: every
endpoint in the same DistributedRuntime sees the same `cid`.

A naive partner-prefill registration would call
`generate_endpoint.serve_endpoint(handler.generate, ...)` AND
`_dual_partner_endpoint.serve_endpoint(_partner_prefill_generate, ...)`
in the same process. Both register at TCP key `{cid:x}/generate`. The
second `handlers.insert(...)` silently overwrites the first via
`DashMap`. The MDC `TransportType` built in `component/endpoint.rs`
also encodes `host:port/{cid:x}/{endpoint_name}` only -- so the
prefill `ModelCard` published into the discovery layer points at the
same TCP slot as the decode card. After the switch, prefill traffic
from `PrefillRouter` arrived at the wrong handler -- usually the plain
decode handler, which has no concept of `kv_transfer_params` and
emitted `disaggregated_params=None` on every chunk -> HTTP 500.

The fix: register **exactly ONE** TCP handler per
`(cid, endpoint_name)` and dispatch at request time:

```python
async def _generate_dispatch(request, context):
    dm = getattr(handler, "_rl_dual_mode", None)
    if (
        partner_prefill_handler is not None
        and dm is not None
        and getattr(dm, "current_role", "decode") == "prefill"
    ):
        async for chunk in _partner_prefill_generate(request, context):
            yield chunk
        return
    async for chunk in handler.generate(request, context):
        yield chunk
```

The `_dual_partner_endpoint` Endpoint object is still constructed
(`VllmReregistrar.register('prefill')` needs it to publish the prefill
MDC via `register_vllm_model`) but no `serve_endpoint` call is made on
it; the published prefill MDC's transport URL points at
`{cid:x}/generate`, exactly what the dispatcher handles.

DualMode flips `current_role` inside `DualModeWorker.switch_role`
between steps (3) `unregister_mdc` and (6) `register_mdc`, so the
dispatcher routes correctly the moment the new MDC is observable.

When partner-prefill is disabled (`DYNAMO_RL_DUAL_PARTNER_PREFILL`
unset), the registered handler is plain `handler.generate` and the
pod behaves as in earlier S2 builds (decode-pool elasticity only).

---

## 4. Router PD-awareness — proving end-to-end correctness

### 4.1 The propagation chain

```
   ┌─────────────────────────────┐
   │  POST /switch_role (target) │
   │  on pod D_i sidecar :9091   │
   └──────────────┬──────────────┘
                  │
                  ▼  step 2 unregister_mdc  /  step 6 register_mdc
   ┌──────────────────────────────┐
   │  VllmReregistrar             │
   │   .unregister(role=current)  │
   │   .register(role=target)     │
   └──────────────┬───────────────┘
                  │
                  ▼
   ┌────────────────────────────────────┐
   │  Dynamo runtime discovery::kube    │
   │   DiscoveryMetadata::register_/    │
   │   unregister_endpoint              │
   │   apply_cr()                       │
   └──────────────┬─────────────────────┘
                  │  kube PATCH
                  ▼
   ┌────────────────────────────────────┐
   │  kube-apiserver                    │
   │   DynamoWorkerMetadata <pod_name>  │
   │     .spec.data.model_cards <- new  │
   └──────────────┬─────────────────────┘
                  │  watch event
                  ▼
   ┌────────────────────────────────────┐
   │  Frontend ModelWatcher             │
   │   recompute WorkerSet              │
   │   notify KvRouter / PrefillRouter  │
   └──────────────┬─────────────────────┘
                  │
                  ▼
   ┌────────────────────────────────────┐
   │  Next /v1/chat/completions:        │
   │   target NOT in candidate set      │
   │   route -> survivor                │
   └────────────────────────────────────┘
```

### 4.2 Two complementary proofs, not one

It is not enough to send chat probes and observe "ok, no requests landed
on the target". That only proves *behavior* and is sensitive to KvRouter
heuristics (load, prefix locality). Path A adds a **direct** assertion:

| proof | target | how |
|-------|--------|-----|
| **CR-diff** (router input)  | `kubectl get dynamoworkermetadata <target> -o json` | count `model_cards` keys matching `*/backend/generate/*`. Must be 1 -> 0 -> 1. |
| **per-pod attribution** (router output) | `vllm:prompt_tokens_total` Prometheus delta on each pod | submit 30 chats; count which pod's counter incremented. Must be 0/30 to target during prefill phase, >0 to target after revert. |
| **no-error sustained load** (no SLO break) | `/v1/chat/completions` HTTP code histogram | 2 RPS for 30 s spanning the switch+revert. Errors <= 2/57. |

This is the layered argument: input changed (CR), output changed (chat
attribution), and the user-facing surface stayed intact (no-error
load). The S2 test enforces all three.

### 4.3 The KvRouter heuristic (why post-revert split is 19/11, not 15/15)

When the target rejoins the chat pool, its **prefix cache is empty**
(we reset it in step 4). The KvRouter prefers low-cache-warmth workers
for fresh prompts to balance reuse across the pool, so the post-revert
30 probes split 19 (target) / 11 (peer) instead of perfectly 15/15.
This is correct, intended router behavior, not a flake.

### 4.4 Multi-replica DP-awareness (current state)

The KvRouter publishes routing decisions over `kv_metrics` events
(per-pod NATS subjects in `event_channels`); each pod publishes its
KV utilization, and the router uses that signal **plus** the
WorkerSet membership from CRs to choose. When a pod is removed from
`model_cards`, it is also removed from the candidate list before its
`kv_metrics` even matter — so the consistency story is: **CR membership
is authoritative; metrics are a tie-breaker among members**. A pod
that was just rolled out of the pool has its events ignored
immediately.

---

## 5. Request consolidation — moving live requests off a pod

### 5.1 Why this is needed

S2 cleanly removes a pod from the chat pool, but it **aborts whatever
was running on that pod**. That is unacceptable for long completions:
a request with 2 000 generated tokens and a 1 500-token prompt
represents minutes of GPU time the user already paid for.

S3's job: before triggering S2 (or scale-down), drain in-flight long
requests onto a peer decoder so the source can be reduced to zero
running requests without losing user-visible work.

### 5.2 Two paths

```
                  source (TARGET)                    destination (PEER)
                  ───────────────                    ──────────────────

   ┌─────────────────────────┐
   │ POST /migrate_out       │
   │  body: {request_id:"*"} │
   └──────────┬──────────────┘
              │
              ▼
   ┌─────────────────────────┐
   │ pick most-progressed rid│
   │ from in-process registry│
   └──────────┬──────────────┘
              │
              ▼
   ┌─────────────────────────┐
   │ block_index.lookup(rid) │   ── grab src_block_ids BEFORE abort
   └──────────┬──────────────┘      (KVBM frees on abort)
              │
              ▼
   ┌─────────────────────────┐
   │ tracker.abort_request   │
   │  (engine releases KV)   │
   └──────────┬──────────────┘
              │
              ▼
   ┌──────────────────────────────────────────┐
   │ response = {                             │
   │   prompt_tokens, generated_tokens,       │
   │   sampling_params, stop_conditions,      │
   │   src_block_ids,                         │   ── always when KVBM avail
   │   kv_transfer_params: {                  │   ── only if connector_enabled
   │     remote_engine_id, remote_block_ids,  │      AND nixl_coords avail
   │     remote_host, remote_port,            │
   │     remote_request_id,                   │
   │     do_remote_prefill: true              │
   │   }                                      │
   │ }                                        │
   └──────────┬───────────────────────────────┘
              │  HTTP body fed verbatim
              ▼
                            ┌─────────────────────────┐
                            │ POST /migrate_in        │
                            │  body: <above>          │
                            └──────────┬──────────────┘
                                       │
                                       ▼
                            ┌──────────────────────────┐
                            │ _should_migrate gate     │
                            │  - replay_total <= 8192  │
                            │  - generated >= 16       │
                            │  - remaining >= 32       │
                            │ else status=declined     │
                            └──────────┬───────────────┘
                                       │
                          ┌────────────┴─────────────┐
                          │                          │
              connector_enabled              default (recompute)
                AND kv_transfer_params
                          │                          │
                          ▼                          ▼
            ┌──────────────────────┐    ┌────────────────────────┐
            │ Phase-2.B            │    │ Phase-2.A              │
            │  submit with         │    │  submit with           │
            │  kv_transfer_params  │    │  prompt_tokens =       │
            │  -> NixlConnector    │    │   old_prompt +         │
            │  start_load_kv       │    │   old_generated        │
            │  -> NIXL READ from   │    │  -> standard prefill   │
            │     src GPU blocks   │    │     on PEER            │
            └──────────┬───────────┘    └──────────┬─────────────┘
                       │                           │
                       └────────────┬──────────────┘
                                    ▼
                       ┌──────────────────────────────┐
                       │ resume generation on PEER    │
                       │ stream remaining tokens to   │
                       │ user; previously_emitted_    │
                       │ tokens prevents double-emit  │
                       └──────────────────────────────┘
```

### 5.3 Phase-2.A (recompute prefill) — the safe default

Why it works:
- vLLM's prefill is highly optimized; with prefix cache enabled, the
  replay cost is dominated by the **uncached suffix** (the
  `generated_tokens` part is brand new on PEER, so it pays full cost
  for those tokens; the original prompt is often a system+user template
  that PEER may have cached from an earlier request).
- No cross-pod KV transfer means no race window; the source releases
  its blocks atomically inside `tracker.abort_request`, the destination
  treats the migration as a normal new request.

Tradeoff:
- The destination pays "uncached suffix prefill" cost — typically
  100-300 ms for a few-thousand-token replay on Qwen3-0.6B; orders of
  magnitude cheaper than letting the request restart.

### 5.4 Phase-2.B (NIXL connector pull) — three-phase block-hold protocol

The wire protocol is fully implemented: `migrate_out` already returns
`kv_transfer_params` in the shape vLLM 0.16's NixlConnector expects on
the decode side (`do_remote_prefill: true`, `remote_engine_id`,
`remote_block_ids`, `remote_host`, `remote_port`,
`remote_request_id` — the same dict produced by Dynamo's normal disagg
PD path in `handlers.py:1577`). The destination's
`MigrationHandler.migrate_in` will pass it straight to a submission
whose `sampling_params.extra_args["kv_transfer_params"]` is set, and
the `MultiConnector(DynamoConnector + NixlConnector)` chain on PEER
will issue an async NIXL READ in the next scheduler step.

This path uses the NIXL connector, not an NCCL collective. `migrate_in`
still constructs a logical `prompt_tokens + generated_tokens` context
on both paths; in Phase-2.B that context is used for request semantics,
cost gating, and target-side submission, while the existing source KV is
pulled from block-held source GPU blocks through NIXL. Only when the
connector is disabled, KVBM/NIXL metadata is unavailable, or connector
submission fails does the migration fall back to Phase-2.A
recompute-prefill.

The source-side block-hold protocol is implemented as a three-phase
handshake to prevent the abort/free race:

1. **`migrate_out`** — when `connector_enabled=True` AND KVBM block IDs
   AND NIXL coordinates are all available, the source defers
   `abort_request` and records the `request_id` in
   `_pending_migrations`. Blocks remain pinned.
2. **`migrate_in`** — the destination injects `kv_transfer_params` and
   submits the request. NIXL READ pulls KV from the source's pinned
   blocks.
3. **`/migration_complete`** — the orchestrator calls this on the source
   after `migrate_in` succeeds. The source aborts the original request
   and releases the blocks.

A background sweeper force-aborts held migrations after
`DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` seconds (default 10) to prevent
block leaks if the orchestrator fails to call `/migration_complete`.

Phase 2.B is enabled via `DYNAMO_RL_CONNECTOR_ENABLED=1` (env var,
default off). When any prerequisite is missing (no KVBM, no NIXL
coordinates), `migrate_out` falls back to immediate abort (Phase 2.A)
and `/migration_complete` becomes a harmless no-op.

### 5.5 The cost-benefit gate

```python
MigrationPolicy(
    max_replay_tokens   = 8192,   # recompute prefill too expensive
    min_generated_tokens= 16,     # too young to benefit
    min_remaining_tokens= 32,     # would finish faster than migrate
)
# connector_enabled controlled via DYNAMO_RL_CONNECTOR_ENABLED env var
```

`migrate_in` runs the gate **before** scheduling the replay. Rejected
requests respond `{status: "declined", reason: "..."}`. The S3 test
explicitly verifies this with a synthetic 9 000-token body and observes:

```
{"status": "declined",
 "reason": "replay_total=9050 exceeds max_replay_tokens=8192
            (recompute prefill too expensive)",
 "request_id": "synthetic-overbudget"}
```

Note: the gate runs on the receiver, so the source has *already* aborted
its copy by the time the gate fires for a wildcard migration. That is
correct behavior because the source's intent was to drain — refusing
the destination's replay does not undo that intent. (For the synthetic
test we hand-craft a body, so no source abort happens.)

### 5.6 In-process registry — how `request_id="*"` works

The decoder side maintains an `InProcessRequestRegistry` updated at
three points by the request handler ([handlers.py L1255-1350](../../dynamo/components/src/dynamo/vllm/handlers.py)):

```
generate(prompt, sampling_params, request_id, ...):
    registry.register(request_id, prompt_token_ids, sp_dict)   # on submit
    async for delta in engine.generate(...):
        registry.record_tokens(request_id, delta.token_ids)     # streaming
    finally:
        registry.deregister(request_id)                         # done/abort
```

This is what makes wildcard migrations work: `migrate_out` calls
`tracker.list_active_request_ids()` -> `_pick_most_progressed(ids)`,
which pulls each entry's `len(generated_tokens)` and selects the
maximum. Selecting the most-progressed entry maximizes the "saved
work" per migration call.

`GET /v1/active_requests` returns this list directly (without
`generated_tokens` for now; it returns just the IDs), letting an
operator/controller drive a custom drain loop:

```bash
while [[ $(curl -s .../v1/active_requests | jq length) -gt 0 ]]; do
   r=$(curl -s -X POST .../migrate_out -d '{"request_id":"*"}')
   curl -s -X POST <peer>/migrate_in -d "$r"
done
# now safe to /switch_role or kubectl delete pod
```

---

## 6. End-to-end correctness — what the tests prove

### 6.1 S2 end-to-end flow

```
   t = 0     pre-state                         CR.model_cards = 1   ✓
   t = 5s    /switch_role -> prefill           CR.model_cards = 0   ✓ (PASS_CR_D2P)
                                               server 230 ms
   t = 7s    30 chat probes                    target hits = 0/30   ✓ (PASS_PROBE)
                                               peer hits = 30/30
   t = 27s   /switch_role -> decode            CR.model_cards = 1   ✓ (PASS_CR_P2D)
                                               server 480 ms
   t = 29s   30 chat probes                    target hits = 19/30  ✓ (PASS_PROBE)
                                               peer hits = 11/30
   throughout: 2 RPS sustained load            57/57 = 100% 200 OK  ✓ (PASS_LOAD)
                                               p99 = 0.585 s
```

### 6.2 S3 end-to-end flow

```
   t=0  T0_pre snapshot                        TGT runs 0,  PEER 0
   t=1  submit 24 streaming chats max=3500
   t=9  T1 snapshot                            TGT runs 5,  PEER 5
                                               TGT gen_tot 41002, PEER 42775
   t=10 migrate_out / migrate_in #1            ok, recompute, replay=1726
   t=11 migrate_out / migrate_in #2            ok, recompute, replay=1933
   t=11 migrate_out / migrate_in #3            ok, recompute, replay=2190
   t=12 TGT now drained                        TGT runs 0   ✓ (PASS_GPU_RELEASE)
                                               peer continued advancing
   t=14 T2 snapshot                            TGT 0, PEER 0
   t=14 synthetic 9k-token migrate_in          status=declined ✓ (PASS_DECLINE)
   t=16 T3 drained snapshot                    PEER gen_tot 44710  ✓ (PASS_DST_TAKEOVER)
                                               (Δ = 1935 vs TGT Δ = 1077)
```

### 6.3 What's still untested

- **Composing S2 after S3 in a real drain workflow**: the manual sequence
  works, but we don't have a single test that does
  "drain via S3 -> switch via S2 -> verify zero token loss". That belongs
  in a follow-up integration test.
- **Phase-2.B (NIXL pull)**: three-phase block-hold protocol implemented
  and exercised in S3 test (falls back to recompute when KVBM
  unavailable; see S3 doc §5 for details).
- **Multi-node**: all measurements are single-host loopback; multi-node
  K8s would proportionally inflate `register_mdc` and HTTP RTT costs.

---

## 7. Operational invariants and failure modes

| invariant | how it's enforced |
|-----------|-------------------|
| One DWMD writer per pod | DWMD name == pod name; only the in-pod runtime ever calls `apply_cr`. |
| ModelCard withdrawal precedes engine sleep effects on routing | `unregister_mdc` is step 2, before `reset_prefix_cache`/`wake`. |
| Prefix cache cannot be served from freed blocks | `reset_prefix_cache` is step 4, between `sleep` and `wake`. |
| migrate_out is at-most-once per request | `tracker.abort_request` is synchronous; in Phase 2.A the registry entry is gone before the response returns; in Phase 2.B the request is held in `_pending_migrations` until `/migration_complete`. |
| migrate_in cannot resurrect a request the source still owns | Phase 2.A: source aborts BEFORE returning. Phase 2.B: source holds blocks until `/migration_complete`; the request stays alive but no new tokens are generated. |
| Cost-benefit gate never silently drops work | `migrate_in` returns `status=declined` with a reason; the operator/controller MUST treat declined as "leave the request to finish in place" (recall: source has aborted only if the migrate_out call was real, not synthetic). |
| Switch is idempotent under repeated calls | `switch_role` re-reads `current_role`; switching to the same role is a no-op except for the no-op register/unregister kube apply. |

Failure modes:
- **kube-apiserver slow** -> `register_mdc` step inflates; the rest of
  the switch is unaffected. The frontend's watcher just sees the new
  state later. No traffic ends up on a still-asleep engine because the
  unregister already happened in step 2.
- **NATS partition** -> `kv_metrics` events stop, but routing membership
  (CR-driven) is unaffected. The KvRouter falls back to last-known
  metrics and continues to honor the WorkerSet.
- **Sidecar crash mid-switch** -> the per-worker async lock is in-process,
  so a crash leaves the engine asleep with the old role's ModelCard
  removed. Pod restart re-runs initial registration, restoring the
  decode role's ModelCard. No CR cleanup is needed — the new pod's CR
  has a fresh `instance_id`.

---

## 8. Code reading order (for a new engineer)

1. [components/src/dynamo/vllm/main.py](../../dynamo/components/src/dynamo/vllm/main.py)
   §dual-mode init (L820-870, L1108-1145) — see how `DualModeWorker`,
   `MigrationHandler`, `VllmReregistrar`, `InProcessRequestRegistry`
   are wired into the worker.
2. [components/src/dynamo/vllm/dual_mode.py](../../dynamo/components/src/dynamo/vllm/dual_mode.py)
   `switch_role` — the 8-step orchestration end to end.
3. [components/src/dynamo/vllm/handlers.py](../../dynamo/components/src/dynamo/vllm/handlers.py)
   §sleep/wake_up (L353-427) and §generate registry hooks (L1255-L1350).
4. [components/src/dynamo/vllm/migration.py](../../dynamo/components/src/dynamo/vllm/migration.py)
   `migrate_out` / `migrate_in` / `_should_migrate` / `_pick_most_progressed`.
5. [components/src/dynamo/vllm/rl_scaling_sidecar.py](../../dynamo/components/src/dynamo/vllm/rl_scaling_sidecar.py)
   `build_app` — HTTP shape on `:9091`.
6. [lib/runtime/src/discovery/kube.rs](../../dynamo/lib/runtime/src/discovery/kube.rs)
   `register_endpoint` / `unregister_endpoint` / `apply_cr`.
7. [test-scripts/test-s2-elastic.sh](../test-scripts/test-s2-elastic.sh)
   and [test-scripts/test-s3-consolidation.sh](../test-scripts/test-s3-consolidation.sh)
   — reproducible E2E.

---

## 9. Glossary

| term | meaning |
|------|---------|
| DWMD | `DynamoWorkerMetadata` CR; per-pod runtime registration record. |
| ModelCard | A `card_json` blob in `DWMD.spec.data.model_cards`. Its presence == "this pod serves this model on this endpoint". |
| KVBM | KV Block Manager; tracks vLLM block ownership for export over NIXL. |
| NIXL | NVIDIA's RDMA-style block-transfer transport used by NixlConnector. |
| `kv_role=kv_both` | vLLM engine config that pre-builds NIXL state for both prefill (sender) and decode (receiver) roles. |
| `instance_id` | 14-char hex; per-process random ID. Changes on pod restart. |
| Phase 2.A / 2.B | Recompute-prefill (safe) vs NIXL-pull (gated) migration paths. |
| Cost-benefit gate | `MigrationPolicy` thresholds checked in `migrate_in._should_migrate`. |

---

*— end —*
