# S2 — Elastic PD Role Switch (decode pool flip)

> Scope: Path A. This document describes what the current Dynamo + RL-Scaling
> code actually does for **scenario S2 — elastic shrink/grow of the chat
> WorkerSet on a running disagg-PD deployment**, and the E2E test that
> proves it on a single-node Kubernetes cluster.
>
> Status: implemented and passing (image
> `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-f817b8e5d5`).

---

## 1. Scenario

A disagg-PD deployment with `D` decoders and `P` prefills serves chat
traffic through a `KvRouter` + `PrefillRouter` frontend. Operationally,
we want to **mutate the effective decode pool size at runtime**, without
deleting/recreating pods, so we can:

- temporarily remove a decoder for maintenance, profiling, or failure
  isolation,
- shift a decoder into a "warm-spare prefill" mode when prefill becomes
  the bottleneck,
- pre-warm a future scale-out target before it actually receives traffic.

Concretely, sending `POST /switch_role {"target_role":"prefill"}` to the
in-pod sidecar of decode pod `D_i` must:

1. cause the chat router to stop sending requests to `D_i` ("WorkerSet
   shrink");
2. release `D_i`'s decode KV state (sleep level=2, prefix cache reset);
3. on `POST /switch_role {"target_role":"decode"}` later, cause `D_i` to
   re-join the chat WorkerSet ("WorkerSet grow"); and
4. complete fast enough that an in-flight ~2 RPS chat workload sees no
   visible disruption other than a brief routing transient.

We measure the switch latency end-to-end and verify routing decisions
both directly (CR diff at the discovery layer) and indirectly (per-pod
chat attribution via Prometheus counters).

---

## 2. Technical background

### 2.1 What `switch_role` is and is not

The current implementation supports two operating modes, selected at
deploy-time per-pod by `DYNAMO_RL_DUAL_PARTNER_PREFILL`:

| capability                                              | this build |
|---------------------------------------------------------|------------|
| Re-publish/withdraw the decode `ModelCard` at runtime    | yes        |
| Pause and resume the engine; free GPU KV (sleep=2)       | yes        |
| Reset prefix cache to keep KV consistent post-resume     | yes        |
| Serve as a *first-class* prefill worker after switch     | yes (when `DYNAMO_RL_DUAL_PARTNER_PREFILL=1`) |

When `DYNAMO_RL_DUAL_PARTNER_PREFILL=1`, the pod boots with vLLM's
`kv_role=kv_both` NixlConnector, registers a prefill `ModelCard` in
addition to the decode one, and after `switch_role -> prefill`
actually serves prefill traffic dispatched by the frontend's
`PrefillRouter` (see test PASS_PREFILL_SERVING in §5).

Getting partner-prefill to work end-to-end required two fixes against
vLLM 0.16 and dynamo's TCP request plane respectively:

1. **Multi-chunk consolidation (commit `a82816c3d6`).** vLLM's
   `NixlConnector.request_finished()` publishes `kv_transfer_params`
   only on the FINAL `RequestOutput` chunk, but Rust
   `kv_router/prefill_router.rs::execute_prefill` reads
   `disaggregated_params` from the FIRST chunk only. The wrapper
   `_partner_prefill_generate` consumes the entire stream, captures
   the last `kv_transfer_params` it sees, and yields ONE consolidated
   chunk so the router observes the field on chunk #1.
2. **Single TCP slot dispatcher (commit `fe78f1b652`).** dynamo's
   `SharedTcpServer` (`lib/runtime/src/pipeline/network/ingress/`
   `shared_tcp_endpoint.rs`) keys handlers by
   `{connection_id:x}/{endpoint_name}` where `connection_id` is
   process-scoped. Registering both `<ns>.backend.generate` (decode)
   and `<ns>.prefill.generate` (partner-prefill) in the same process
   collides at key `cid/generate`; the second `handlers.insert(...)`
   silently overwrites the first via `DashMap`. The MDC TransportType
   built in `component/endpoint.rs` also encodes only
   `host:port/{cid:x}/{endpoint_name}`, so the prefill MDC ended up
   pointing at the same TCP slot as the decode MDC -- and the decode
   handler (which has no concept of `kv_transfer_params`) ended up
   serving prefill requests, returning HTTP 500. The fix registers
   exactly ONE `generate` handler per `(cid, endpoint_name)` and
   dispatches at request time based on `dual_mode.current_role`.

The `_dual_partner_endpoint` Endpoint object is still constructed (the
MDC publishing path in `VllmReregistrar.register('prefill')` still uses
it) but no separate `serve_endpoint` call is made on it.

### 2.2 Discovery is K8s-CRD-based, not etcd-based

The deployment we use sets `DYN_DISCOVERY_BACKEND=kubernetes`. Each
worker (frontend, decoders, prefill) writes its registration to a
**`DynamoWorkerMetadata`** custom resource named after its own pod, and
the frontend's `ModelWatcher` (Rust) reconstructs the WorkerSet by
listing/watching those CRs in the deployment namespace.

A decoder's CR looks like:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoWorkerMetadata
metadata:
  name: vllm-v1-disagg-router-vllmdecodeworker-...-wmrpf
spec:
  data:
    endpoints:
      .../backend/generate/<instance_id>:    {type: Endpoint, ...}
      .../backend/clear_kv_blocks/<inst>:    {type: Endpoint, ...}
    event_channels:
      .../kv_metrics/<instance_id>:          {type: EventChannel, ...}
    model_cards:
      .../backend/generate/<instance_id>:    {card_json: {...}}
```

The Rust path is `lib/runtime/src/discovery/kube.rs:92-200`, which
calls `DiscoveryMetadata::register_endpoint` /
`unregister_endpoint` and persists the resulting set into the CR via a
strategic-merge `apply_cr`. This is the surface the test asserts on
directly: if the chat `model_card` key disappears from the target's CR,
the frontend's WorkerSet provably shrinks; if it reappears, the
WorkerSet provably grows.

### 2.3 Eight-step orchestration

`DualModeWorker.switch_role(target)` in
`components/src/dynamo/vllm/dual_mode.py` runs the following sequence
under a per-worker lock; each step is timed and returned in the JSON
response under `timings_ms`:

```
sleep             -> handlers.sleep()         # pause + engine.sleep(level=2)
unregister_mdc    -> reregistrar.unregister   # remove ModelCard from CR
reconfig_nixl     -> drop _nixl_connector     # force lazy re-init
reset_prefix_cache-> engine.reset_prefix_cache # while asleep -> KV consistency
set_disaggregation_mode -> handler bookkeeping
register_mdc      -> reregistrar.register     # publish new role's ModelCard
wake              -> handlers.wake_up()       # engine.wake_up + resume
emit_role_changed -> sidecar event for label patch
```

Critically `reset_prefix_cache` runs *after* `engine.sleep(2)` (so the
prefix-pool flush sees a quiesced engine and cannot race with new
schedules) and *before* `wake_up`. The `VllmReregistrar` is wired with
an `endpoints_by_role` map keyed by role, so register/unregister become
**no-ops with an info log** when the requested role has no endpoints
locally — that is exactly how a switch to `prefill` cleanly removes the
decode `ModelCard` from the CR without erroring (`main.py:590-670`).

### 2.4 KV / prefix-cache consistency

`reset_prefix_cache` is mandatory because vLLM's prefix cache holds
references to KV blocks that are about to be returned to the GPU
allocator by `sleep(level=2)`. Without the reset, a wake-up serving a
new-role request could hit a stale prefix-cache hit pointing at freed
blocks. With the reset issued during the asleep window, the cache index
is empty by the time we call `wake_up`.

---

## 3. Implementation map

| concern                          | file                                                          | symbol / lines           |
|----------------------------------|---------------------------------------------------------------|--------------------------|
| sidecar HTTP surface (port 9091) | `components/src/dynamo/vllm/rl_scaling_sidecar.py`            | `build_app`, L235-360    |
| `/switch_role` orchestration     | `components/src/dynamo/vllm/dual_mode.py`                     | `DualModeWorker.switch_role` |
| sleep / wake_up wrappers         | `components/src/dynamo/vllm/handlers.py`                      | L353-427                 |
| MDC re-registration              | `components/src/dynamo/vllm/main.py`                          | `VllmReregistrar`, L590-670 |
| dual-mode init + gating          | `components/src/dynamo/vllm/main.py`                          | L820-870, L1108-1145     |
| CR write path                    | `lib/runtime/src/discovery/kube.rs`                           | L92-200                  |
| Pod-label echo on success        | `components/src/dynamo/vllm/rl_scaling_sidecar.py`            | `_patch_self_pod_label`  |

Deployed manifest:
[RL-Scaling/tutorial/dynamo-auto-deploy/1.0.1/manifests/dgd-vllm-disagg-router.yaml](../tutorial/dynamo-auto-deploy/1.0.1/manifests/dgd-vllm-disagg-router.yaml)
sets `DYNAMO_RL_DUAL_MODE=1` and `DYNAMO_RL_SIDECAR_PORT=9091` on the
decode container, plus
`--kv-transfer-config NixlConnector kv_both --kv-events-config zmq` so
that the engine is built with NIXL ready for both roles.

---

## 4. Verification strategy

The previous E2E ([test-s3-e2e.sh](../test-scripts/test-s3-e2e.sh))
proved the flip indirectly via per-pod chat attribution. For Path A we
add a stronger, direct assertion plus a sustained-load measurement.
The new harness is
[test-s2-elastic.sh](../test-scripts/test-s2-elastic.sh).

Four pass conditions, all of which must hold for OVERALL=true:

| code   | meaning                                                                                                              |
|--------|----------------------------------------------------------------------------------------------------------------------|
| `PASS_CR_D2P`  | `kubectl get dynamoworkermetadata <target>` loses the `*/backend/generate/*` `model_card` key after switch -> prefill |
| `PASS_CR_P2D`  | the same CR regains the `*/backend/generate/*` `model_card` key after revert -> decode                                |
| `PASS_PROBE`           | 30 chat probes after the switch attribute **0** to TARGET and **>0** to PEER                                          |
| `PASS_PREFILL_SERVING` | TARGET's `vllm:prompt_tokens_total` grows during the post-switch probe window (proves partner-prefill is actually serving)  |
| `PASS_LOAD`            | a background 2 RPS / 30 s chat load spanning the whole switch+revert sequence sees `error_count <= 2`                |

The CR assertion gives ground-truth visibility into the discovery layer.
`PASS_PREFILL_SERVING` is the one that proves the role-aware dispatcher
fix actually works end-to-end: a positive vLLM `prompt_tokens` delta on
the target while it is in prefill role can only come from
`partner_prefill_handler.generate` (because the chat WorkerSet has
already withdrawn the decode `ModelCard`).

---

## 5. Test report

Test environment:

- single-node K8s 1.34.1 on `gpu14`, namespace `dynamo-system`
- DGD `vllm-v1-disagg-router`, model `Qwen/Qwen3-0.6B`
- 1 frontend, 2 decoders, 1 prefill (all `Running`)
- decoder pods launched with `DYNAMO_RL_DUAL_MODE=1` AND
  `DYNAMO_RL_DUAL_PARTNER_PREFILL=1`
- image `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`
  (single-TCP-slot dispatcher fix)

### 5.1 Switch latency

|                              | decode -> prefill | prefill -> decode |
|------------------------------|-------------------|-------------------|
| client wall-clock (ms)       | 433.3             | 457.6             |
| server total `switch_time_ms`| 388.1             | 418.4             |
| `sleep`                      | 55.4              | 87.1              |
| `unregister_mdc`             | 8.0               | 10.2              |
| `reconfig_nixl`              | 0.1               | 0.2               |
| `reset_prefix_cache`         | 2.5               | 2.5               |
| `register_mdc`               | 296.4             | 290.1             |
| `wake`                       | 25.6              | 28.3              |

Both directions now publish a fresh `ModelCard` (the d->p direction
publishes the prefill MDC; the p->d direction publishes the decode
MDC), so both round-trips include `register_mdc` cost (~290ms in our
single-node cluster).

### 5.2 Router awareness (CR diff on the target)

|                         | model_cards w/ `backend/generate` | endpoints w/ `backend/generate` |
|-------------------------|----------------------------------:|---------------------------------:|
| pre-switch              | 1                                 | 1                                |
| after switch -> prefill | **0**                             | 1                                |
| after revert -> decode  | **1**                             | 1                                |

The `backend/generate` endpoint key remains in `spec.data.endpoints` in
both phases (because the underlying Rust endpoint object is reused;
only the public chat `ModelCard` is added/removed). What the router
keys off is the `model_cards` dict — and that flips 1 -> 0 -> 1
exactly as required.

### 5.3 Routing attribution (30 chat probes per phase)

After switch -> prefill (target should be 0, peer >0):

- `vllmdecodeworker-...-ccjp8x` (TARGET) -> **0**
- `vllmdecodeworker-...-cntvq8` (PEER)   -> **30**

After revert -> decode (target should be >0, peer >0):

- TARGET -> **17**
- PEER   -> **13**

The post-revert split reflects the KvRouter's prefix-aware decision:
TARGET's prefix cache is empty after the reset, so the router prefers
TARGET for fresh prompts to balance cache warmness across the pool.

### 5.4 Partner-prefill serving (the fix's smoking gun)

| sample on TARGET                | `vllm:prompt_tokens_total` |
|---------------------------------|---------------------------:|
| pre-switch baseline             | 16                         |
| post 30 prefill probes          | 1265                       |
| **delta**                       | **1249**                   |

A positive delta during a window in which the chat WorkerSet has
withdrawn the target's decode `ModelCard` (PASS_CR_D2P=true) can only
come from `_partner_prefill_generate` being invoked by
`PrefillRouter`. Combined with PASS_PROBE (30 chat probes returned
HTTP 200, attributed entirely to PEER) this proves end-to-end that the
switched pod is now a real prefill worker.

### 5.5 Sustained-load impact (2 RPS, 30 s, spans the whole switch+revert)

| metric                 | value     |
|------------------------|-----------|
| total chat completions | 58        |
| HTTP 200               | 58        |
| HTTP non-200           | **0**     |
| error rate             | 0.00 %    |
| p50 latency            | 0.069 s   |
| p99 latency            | 0.721 s   |

Zero errors during a flip+revert cycle.

### 5.5 Overall

**PASS** — all five conditions hold.

Raw artifacts:
[reports/s2-elastic-20260511-020123/REPORT.md](../test-scripts/reports/s2-elastic-20260511-020123/REPORT.md),
plus `cr-before.json`, `cr-after_d2p.json`, `cr-after_p2d.json`,
`switch_d2p.json`, `switch_p2d.json`, `load.csv`,
`probes_post_d2p.csv`, `probes_post_p2d.csv` in the same directory.

---

## 6. Limitations (what S2 explicitly does not claim)

1. **In-flight requests on the switched pod are aborted.** The S3 work
   ([S3-request-consolidation.md](S3-request-consolidation.md))
   addresses the orthogonal problem of moving in-flight long requests
   off a pod that is about to switch or be drained.
2. **Single-node measurements.** Switch latency is dominated by the
   local kube-apiserver round-trip; multi-node clusters with remote
   apiservers will see proportionally higher `register_mdc` cost.
3. **Partner-prefill is per-pod opt-in.** A decoder pod must be
   launched with `DYNAMO_RL_DUAL_MODE=1` AND
   `DYNAMO_RL_DUAL_PARTNER_PREFILL=1` AND a `kv_both` kv-transfer
   config to use the role-aware dispatcher; otherwise `switch_role`
   only flips the chat WorkerSet membership and the pod sleeps idle
   while in the prefill role.
