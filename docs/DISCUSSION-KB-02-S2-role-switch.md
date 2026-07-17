# Discussion KB 02 — S2 Elastic PD Role Switch: implementation deep dive

> Knowledge base from the 2026-07-14 walkthrough. Key questions, key steps, key Q&A — not a full spec.
> Series: KB-01 = resource model + S1 · **KB-02 = S2 `switch_role`** · KB-03 = S3 migration (todo).
> Companions: `IMPLEMENTATION-full-picture-2026-07.md`, `MASTERS-EVALUATION-2026-07.md`.

---

## 1. Code organization — the `role_switch/` folder is **not** the sidecar

S2 spans **two repos**, with a deliberate split of responsibility.

**Controller side — `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/role_switch/`** (the *decision* layer):

| file | role |
|---|---|
| `controller.py` (303 L) | **Decides** whether to switch and **who** to switch |
| `dual_mode_client.py` (~60 L) | **Thin httpx wrapper**: `POST {worker_url}/switch_role`, `GET /v1/role`. Docstring: *"purposefully has no knowledge of Kubernetes"* |
| `strategy.py` (~730 B) | small policy helper |

**Worker side — `dynamo/components/src/dynamo/vllm/`** (the *execution* layer):

| file | role |
|---|---|
| `rl_scaling_sidecar.py` (609 L) | aiohttp shell on `:9091` — thin HTTP surface, no switch logic |
| `dual_mode.py` (574 L) | **`DualModeWorker.switch_role`** — the actual protocol |
| `main.py` (1439 L) | `VllmReregistrar` (ModelCard publish/withdraw) + `_generate_dispatch` (role-aware dispatcher) |

**Principle: the controller decides *who* and *when*; the worker decides *how* to do it safely.**
The protocol must live next to the engine — only the worker can sequence sleep/reset/wake against its own vLLM state. The controller has zero engine knowledge; it just posts a role name.

---

## 2. The actual steps (the docstring says 8; the code runs more)

```
lock  (per-worker async lock; concurrent call → status="busy"; target==current → ok no-op)
 0a. _flush_kv_connector()        ← added fix (NIXL pending sends)
 0.  _drain_inflight(30s)         ← added fix (block release)
 1.  handler.sleep({"level":2})   pause_generation + free GPU KV blocks
 1b. unregister previous role's *endpoint instance* (if ≠ handler.generate_endpoint)
 2.  reregistrar.unregister(previous_role)     ← withdraw old ModelCard
 3.  _reconfig_nixl(target)       drop cached connector handle
 4.  _reconfig_kv_pool(target)    reset_prefix_cache()   ← INSIDE the sleep window
 5.  set_disaggregation_mode(target); self._current_role = target
 6.  reregistrar.register(target) ← publish new ModelCard
 7.  handler.wake_up({})
 7b. register target role's *endpoint instance* (unregister handler's if ≠)
 8.  _emit_role_changed           pod label + event (best effort)
except: → re-register previous role, wake, restore role flag  (never left half-flipped)
```
Response carries `switch_time_ms` + per-phase `timings_ms`.
Drain window: `DYNAMO_RL_SWITCH_DRAIN_TIMEOUT` (default 30 s).

---

## 3. Trigger path & frontend/backend correctness

**Trigger:** controller tick → `evaluate_and_execute()` reads Prometheus queue/util → decides D→P or P→D, picks the worker with **fewest in-flight** → `DualModeClient` → `POST pod_ip:9091/switch_role` → sidecar → `switch_role`.

**How the frontend learns — no in-process coordination at all:**
```
worker mutates its OWN DWMD CR (reregistrar → apply_cr)
  → kube-apiserver (etcd write) → informer watch event
  → frontend ModelWatcher → rebuild WorkerSet → invalidate KvRouter / PrefillRouter
```
Correctness rests entirely on the cluster control plane. Convergence is eventual (≪200 ms single-node).

### The four ordering rules that make it safe

1. **Unregister early (2), register late (6).** Withdrawing the old ModelCard starts the watcher's convergence clock as early as possible, so the router stops choosing this worker for old-role traffic while slow work continues. The new card is published only once the engine is in a consistent target state.
2. **Pause before unpublish.** Withdrawing a ModelCard only stops *new router decisions* — it cannot abort requests already on the wire. `sleep` → `pause_generation()` rejects new local submits **before** the engine sleeps, killing the "request lands on a half-asleep engine" race.
3. **Flip the role flag (5) *before* publishing the new card (6).** The single TCP slot's dispatcher reads `dual_mode.current_role` **at request time**; publish-first would let a prefill request be served by the decode path.
4. **Gotcha in 7/7b:** `handler.wake_up()` *always* re-registers `handler.generate_endpoint` (= the **backend** endpoint). Correct for `target=decode`, **wrong for `target=prefill`** — so 7b immediately unregisters it and registers the prefill endpoint instead.

### Why the single-TCP-slot dispatcher exists (`main.py:1249`)
```python
async def _generate_dispatch(request, context):
    if dm.current_role == "prefill" and partner_prefill_handler is not None:
        async for chunk in _partner_prefill_generate(request, context): yield chunk
        return
    async for chunk in handler.generate(request, context): yield chunk
```
Dynamo's `SharedTcpServer` keys handlers by `{connection_id:x}/{endpoint_name}`, and `connection_id` is **process-level**. Registering both `backend.generate` and `prefill.generate` collides on `{cid:x}/generate` — the second insert **silently overwrites** the first. Hence **one TCP handler, dispatch at request time**.
→ Invariant: **one pod, one engine, one TCP slot, two ModelCards taking turns.**

### Two distinct registrations (easy to conflate)
- **ModelCard** (`register`/`unregister_model`) → *what role you offer* → router's WorkerSet. Steps 2 / 6.
- **Endpoint instance** (`register`/`unregister_endpoint_instance`) → the DWMD `endpoints` entry. Steps 1b / 7b.

---

## 4. Inference correctness across the switch

- **In-flight work is drained, not killed**: `_drain_inflight` waits for natural completion up to 30 s, then force-aborts stragglers.
- **After D→P**, `_partner_prefill_generate` wraps the prefill handler and **merges multi-chunk output**. Load-bearing: vLLM's `NixlConnector` publishes `kv_transfer_params` only on the **last** `RequestOutput` chunk, but Dynamo's Rust `PrefillRouter::execute_prefill` reads `disaggregated_params` only from the **first**. Without the merge the router never sees the KV coordinates and disaggregation silently breaks.
- **Residual defect (honest):** s2 measured **99.0% valid** — 1 of 64 prefill requests lost at the exact switch instant (the drain/abort boundary: mid-flight when the switch began, didn't finish inside the window). *Drained ≠ zero-loss* for requests caught precisely at the boundary.

---

## 5. KV block alignment — three hazards, three mechanisms

The most subtle part of the project.

**Hazard 1 — stale prefix-cache index → freed blocks.**
vLLM keeps the prefix-cache **index** in CPU memory and the **blocks** in GPU VRAM. `sleep(level=2)` returns blocks to the allocator but does **not** clear the index. Wake without resetting and a request can hit `prefix_cache[hash] → block #42` after #42 was reallocated → **silent corruption**.
→ **Mechanism:** `reset_prefix_cache()` **inside the sleep window** (step 4, between sleep and wake) — atomic from the scheduler's view:
```
before sleep: prefix_cache[hash("system: …")] → block #42
sleep(2):     block #42 → free pool
reset_pc:     index cleared        ← here
wake_up:      no stale hit possible
```
Resetting *after* wake is unsafe — the wake race could hand #42 to a new request before the flush.

**Hazard 2 — in-flight requests pin blocks, so the reset fails.**
`sleep(2)` pauses generation but does not guarantee running requests *finish*. Their blocks keep `ref_cnt>0`, so `reset_prefix_cache()` returns **`False`** and logs *"some blocks (N) are not freed yet"*. Leaked blocks shrink the **new** role's KV budget → long decode requests hang after P→D.
→ **Mechanism:** step 0 `_drain_inflight()` before sleep, **plus** a retry inside `_reconfig_kv_pool`: if `reset` returns `False` → `_drain_inflight(2.0)` → reset again.

**Hazard 3 — NIXL pending sends pin blocks *invisibly*.**
While serving prefill, the connector holds produced KV in `_reqs_to_send` until a decode worker **pulls** it — up to `VLLM_NIXL_ABORT_REQUEST_TIMEOUT` = **480 s**. These pin blocks (`ref_cnt>0`) but **never appear in the request registry** (they aren't requests anymore) — drain can't see them, reset can't free them.
→ **Mechanism:** step 0a `_flush_kv_connector()` → `AsyncLLM.collective_rpc(_flush_nixl_pending_sends)` runs **inside each engine worker process** (cloudpickled → this is why `VLLM_ALLOW_INSECURE_SERIALIZATION=1` is set in the DGD), reaches `get_kv_transfer_group().connector_worker._reqs_to_send`, and stamps every entry with `now` so they are **already expired** → next `get_finished()` reports finished-sending → scheduler frees the blocks.

**The NIXL handle itself:** `_reconfig_nixl` sets `handler._nixl_connector = None` (+ shutdown/close if present) so the next request lazily rebuilds it — no stale prefill→decode xfer slots leak across the flip. It **cannot** swap the connector (`kv_transfer_config` is fixed at engine construction) — which is exactly why the engine boots with `kv_role=kv_both`.

**Deliberately NOT done:** resizing `cache_config.num_gpu_blocks` at runtime — that needs `_initialize_kv_caches` re-execution, fragile on a sleeping engine. Instead **the block budget is shared**, and prefix-cache eviction lets each role saturate it on demand, despite opposite traffic shapes (decode = few long sequences; prefill = many short ones).

> **Honesty note:** hazards 2 & 3 were fixed in response to post-switch tail timeouts — but those timeouts turned out to be a **cluster transport limit** (no cross-pod RDMA), *not* a block leak. The drain and flush remain correct switch hygiene and should be kept, but they are **not** what fixed the timeouts. State this plainly rather than implying causation.

---

## 6. Test coverage — what the four-scenario suite actually proves

### 6.1 Is the high-level, strategy-driven decision covered? **Yes — positive and negative.**

Both switches were **autonomously decided from real telemetry**, reason recorded (`_s2_history`):
```
D→P: reason="prefill_queue=2>=1 and decode_util=0.00<=0.30"  executed=true  618 ms
P→D: reason="decode_queue=7>=2 and prefill_util=0.00<=0.30"  executed=true  403 ms
```
These are **measured Prometheus metrics**, not the harness's synthetic signals. (The harness's `prefill_pressure_signal` / `decode_pressure_signal` only move the **S1** state machine — they do **not** drive the S2 decision.)

**The negative case is covered too** — `s2_evaluation_summary`: **364 evaluations, only 2 executed**, with recorded skip reasons:

| skip reason | count |
|---|---:|
| `d_to_p_blocked:prefill_queue_depth=0>=1; p_to_d_blocked:decode_queue_depth=0>=2,…` | 134 |
| `d_to_p_blocked:prefill_queue_depth=0>=1,**decode_worker_count=1>1**; …` | 122 |
| `d_to_p_blocked:**decode_worker_count=1>1**; …` | 43 |
| `p_to_d_no_prefill_target` | 34 |

→ Direct evidence the controller **refuses to switch when it shouldn't**, and that the **`MIN_DECODE_REPLICAS` floor guard fires** (`decode_worker_count=1>1` → never drops decode to zero). Observed pressure range: `max_prefill_queue_depth=2`, `max_decode_queue_depth=8`.

**Caveats:** thresholds were **tuned down for the test** (`PREFILL_QUEUE_THRESHOLD=1`, `DECODE_QUEUE_THRESHOLD=2` vs. config defaults **10/10**), and max observed prefill backlog was only **2** — the workload never produced a large queue. So what's validated is *"the decision logic fires and declines correctly against its configured thresholds"*, **not** *"the default thresholds are calibrated for production."* The role gate is also non-fatal, so the test wouldn't *fail* had no switch occurred — but it did occur, so the evidence is positive, not assumed.

### 6.2 Is correct inference under the new topology confirmed? **Yes — both directions.**

- **Topology verified at runtime, not assumed:** `runtime_role_gate_after_d_to_p` polled **every worker's sidecar `/v1/role`** → `prefill=3, decode=1`; after revert → `prefill=2, decode=2`.
- **Under 3P1D:** prefill_burst = **63/64 valid, 0 timeout, 22.1 s vs baseline 34.4 s (−36%)**. The speedup *is itself proof* the switched worker genuinely serves — 2 workers cannot make prefill 36% faster if the 3rd isn't working.
- **Under restored 2P2D:** decode_tail = **100% valid, 0 timeout**, plus an explicit post-switch long-decode probe (`decode_readiness_after_switch`, `max_tokens=48`).

**Caveats:** 1/64 prefill lost at the switch instant (98.4%); and per-worker attribution in these runs is **indirect** (role counts + speedup). The **direct** proof — per-worker `vllm:prompt_tokens_total` Δ=+583 and the DWMD CRD diff — lives in the **midterm**, not the four-scenario suite.

---

## 7. Measured cost & claim boundary

| | D→P | P→D |
|---|---:|---:|
| server-side (midterm breakdown) | 453.5 ms | 428.0 ms |
| ↳ `register_mdc` (K8s apply RTT) — **dominates** | 326.7 ms | 328.1 ms |
| ↳ engine-side `sleep+wake` | ≈ 86 ms | ≈ 79 ms |
| client wall-clock | 497.3 ms | 465.7 ms |
| four-scenario runs (`_s2_history`) | 618 ms | 403 ms |

**Round-trip ≈ 963 ms (midterm) / ~1.02 s (perf run).**
**Cost is O(1)** — K8s-bound, independent of batch size/model — **benefit is O(batch)**: prefill saving 12.3 s (~12×), serving-wall saving 23.5 s (~23×).

| ✅ Can claim | ❌ Cannot claim |
|---|---|
| Switch is **autonomously decided from measured telemetry**, both directions, with recorded reasons | Default thresholds (10/10) are production-calibrated — we tested with 1/2 |
| Controller **correctly declines** 362/364 evaluations, incl. the replica-floor guard | Behaviour under large prefill backlog (max observed queue = 2) |
| Frontend **correctly infers under both topologies** (3P1D and 2P2D), verified per-worker via `/v1/role` | Zero request loss across the switch (1/64 lost at the boundary) |
| The switched worker **really serves prefill** (−36% prefill wall) | Direct per-worker attribution *in these runs* (indirect; direct proof is in the midterm) |

---

## 8. Open items

1. **Switch-instant request loss** (1/64): add an in-flight quiesce/migrate window before `sleep`, or hold the ModelCard withdrawal until in-flight reaches 0.
2. **Threshold calibration**: defaults are 10/10; tests ran 1/2. Either justify the defaults with a workload study or document them as workload-dependent tuning knobs.
3. **Direct attribution in the perf suite**: port the midterm's per-worker `vllm:prompt_tokens_total` delta check into the four-scenario harness so the suite proves attribution directly, not just via speedup.
4. Next: **KB-03 — S3 migration protocol** (three-phase block-hold, connector vs recompute, `pod-deletion-cost` scale-down fix).
