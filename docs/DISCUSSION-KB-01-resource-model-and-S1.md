# Discussion KB 01 — K8s/Dynamo resource model & S1 autoscaling deep dive

> Knowledge base from the 2026-07-14 walkthrough. Captures the key questions, the answers, and the reasoning — not a full spec. Companion to `IMPLEMENTATION-full-picture-2026-07.md` (architecture) and `MASTERS-EVALUATION-2026-07.md` (evaluation).
> Series intent: KB-01 = resource model + S1. Later: KB-02 = S2 `switch_role`, KB-03 = S3 migration.

---

## 1. Requirement recap (confirmed)

- **Dynamo** = a business solution for **PD-disaggregated** LLM inference: split compute-bound prefill from bandwidth-bound decode onto separate GPU pools. Tuned for **near-stationary online serving** → a **relatively static topology**.
- **RL rollout traffic is phasic**, so a fixed topology + HPA wastes GPU-hours. Two *distinct* kinds of waste, one per solution:
  - **Cross-phase waste** — during the prefill burst, decode GPUs idle (and vice versa) → **S2**
  - **Intra-phase tail waste** — at batch end, a few long completions scattered across decoders each pin a whole GPU → **S3**
- **Why HPA can't fix it (two reasons, not one):** cold start is tens of seconds (a rollout phase is seconds), **and** every new pod starts with an empty prefix cache — discarding the reuse PD disaggregation exists to expose.
- Layer summary: **S1 changes replicas · S2 changes worker role · S3 changes request placement.**
- Metric split (deliberate): **S2 is judged on time** (`serving_wall`, `prefill_wall`); **S3 is judged on GPU allocation** (`tail_decode_gpu_s_saved`, `avg_ready_workers`) — *not* on speed, because reclaiming allocation is its whole point.

---

## 2. Resource model — DWMD vs CRD vs RC

**They are not peers; they sit at three different levels.**

| | What it is | Native or custom? | API group |
|---|---|---|---|
| **CRD** (`CustomResourceDefinition`) | K8s-native **meta-resource**: registers a *new kind*. A **type declaration**, not an instance. | **K8s-native** | `apiextensions.k8s.io/v1` |
| **RC** (`ReplicationController`) | K8s-native **legacy workload kind** ("keep N pods"). Superseded by ReplicaSet. **Dynamo does not use it.** | **K8s-native** (legacy) | `core/v1` |
| **DWMD** (`DynamoWorkerMetadata`) | A **custom kind** registered *via* a CRD; instances are **CRs**. Written by each worker pod's own Dynamo runtime. | **Custom — Dynamo-defined** | `nvidia.com` |

→ **CRD is the mechanism; DWMD is a kind defined by it; a DWMD object is a CR.** CRD is native; what it defines is custom. RC is unrelated — a built-in that never needed a CRD.

**Dynamo-defined CRDs (all `nvidia.com`, Namespaced)** — from `dynamo/deploy/operator/config/crd/bases/`:
`DynamoGraphDeployment` (DGD) · `DynamoComponentDeployment` (DCD) · `DynamoGraphDeploymentScalingAdapter` (DGDSA) · `DynamoWorkerMetadata` (DWMD) · `DynamoModel` · `DynamoCheckpoint` · `DynamoGraphDeploymentRequest`

**RL-Scaling defines ZERO CRDs.** Its "custom" surface is plain HTTP on the sidecar (`:9091`) + a normal Deployment for the controller. DWMD is defined in `dynamo/lib/runtime/src/discovery/kube/crd.rs` (group `nvidia.com`, plural `dynamoworkermetadatas`) — Dynamo-native, **not** self-defined by this project.

### The two axes (the key insight)

**Axis A — desired state, flows *downward*, operator-reconciled:**
```
DGD  "the whole graph"          ← human writes
 ↓ operator
DCD  "one component"
 ↓ operator
Deployment (apps/v1)  →  ReplicaSet (apps/v1)  →  Pod (core/v1)     ← all native
```
`DGDSA` sits beside this chain: a scaling adapter exposing a `/scale` subresource so an external autoscaler can resize a component without knowing DGD internals.

**Axis B — published runtime facts, flows *upward*, worker-written:**
```
DWMD  spec.data.{endpoints, event_channels, model_cards}
  ↑ written by the worker pod's OWN Dynamo runtime (sole writer)
  ↓ list+watch'd by frontend ModelWatcher → WorkerSet → KvRouter / PrefillRouter
```

**Difference that matters:** DGD/DCD/DGDSA = *"what should exist"* (desired state, reconciled). DWMD = *"who is alive and what role do they serve right now"* (published fact, nothing reconciles it). DWMD is the Kubernetes-CR substitute for an **etcd registration entry** — that's what `DYN_DISCOVERY_BACKEND=kubernetes` replaces.

**Two consequences that drive this project:**
1. **S2's role switch edits DWMD, never the DGD.** Editing the DGD = operator re-creates pods (tens of seconds, engine rebuild, cold cache). Editing your own DWMD ModelCard (`backend/generate` ↔ `prefill/generate`) changes what the router believes you serve — instantly, same pod, same engine. *That is the entire trick behind sub-second elasticity.*
2. **The operator must be held at 0** — see §4.

---

## 3. S1 implementation

### 3.1 Where it lives — and what it isn't
All in the **RL-Scaling controller**, an independent Python service in its own pod (ns `dynamo`), separate from Dynamo:

| file | role |
|---|---|
| `signal_receiver.py` | FastAPI HTTP surface — where RL signals arrive |
| `state_machine.py` | IDLE/WARM_UP/ACTIVE/COOL_DOWN machine |
| `capacity_planner.py` | batch metadata → (prefill, decode) replicas |
| `dgdsa_client.py` | applies the replica change to Kubernetes |

**No database, no etcd, no "Dynamo DB."** Entire state = one in-memory Python object (`state` + `current_target`); persists nothing. External interactions only: K8s API, Prometheus, worker sidecars.

### 3.2 State machine
Explicit transition table (illegal transitions logged + ignored):
```
IDLE → {WARM_UP}         WARM_UP → {ACTIVE, COOL_DOWN}
ACTIVE → {COOL_DOWN}     COOL_DOWN → {IDLE, WARM_UP}
```
Two non-obvious edges are deliberate: `WARM_UP → COOL_DOWN` (pre-warm cancelled, or batch finished before metrics promoted us to ACTIVE); `COOL_DOWN → WARM_UP` (new batch mid-cooldown → re-scale up).

| event | behaviour |
|---|---|
| `on_sampling_progress(progress, batch_meta)` | **Only from IDLE.** If `progress ≥ PRE_WARM_THRESHOLD` → plan → `_scale_to()` → WARM_UP. *(pre-warm / scale-from-zero)* |
| `on_sampling_done(batch_meta)` | IDLE/COOL_DOWN → scale up → WARM_UP. From WARM_UP → **only scales up, never down** (a smaller follow-up plan can't drop in-flight warm-ups). ACTIVE → no-op. |
| `on_batch_complete()` | ACTIVE **or** WARM_UP → COOL_DOWN. Rejected from IDLE/COOL_DOWN. |
| `control_loop_tick()` | WARM_UP → ACTIVE when `ready_p ≥ target.prefill and ready_d ≥ target.decode`; COOL_DOWN → IDLE via the two-gate rule. |
| `training_done` signal | **no-op** — cooldown handles GPU release. |

**Two-gate scale-to-zero** (both must clear):
```python
cooldown_done = time_in_state >= cooldown_seconds
drain_done    = (prefill_queue_depth + decode_queue_depth) == 0
drain_forced  = time_in_state >= drain_timeout_seconds
if cooldown_done and (drain_done or drain_forced):
    dgdsa.patch("prefill", 0); dgdsa.patch("decode", 0)
```
Cooldown catches RL-loop stragglers; the drain gate avoids killing streaming requests (clean KV eviction + KVPublisher removal events to the router's indexer). `drain_timeout` bounds it so a stuck request can't pin GPUs forever.

### 3.3 Capacity planner — analytical, **open-loop**
```
total_tokens = batch_meta.total_tokens  or  batch_size × avg_isl
N_prefill = ceil( total_tokens / (SINGLE_PREFILL_TPS × TARGET_PREFILL_SECONDS) )
N_decode  = ceil( batch_size   /  MAX_CONCURRENT_PER_DECODE )
```
Then clamp with **prefill priority**:
```python
prefill = max(min_prefill, prefill);  decode = max(min_decode, decode)
prefill = min(prefill, max_gpus - min_decode)   # reserve decode's floor
decode  = min(decode,  max_gpus - prefill)      # prefill wins the remainder
decode  = max(min_decode, decode)
```
Plans **once from the declared batch shape**; never corrects against observed throughput.

### 3.4 Technical foundation
FastAPI + pydantic (signal HTTP + schema validation) · kubernetes python client (`CustomObjectsApi`, `AppsV1Api`, `CoreV1Api`) · httpx (Prometheus + sidecar probes) · asyncio background control loop (**S3 → S2 → S1** each tick) · deployed as ordinary Deployment + Service + SA + ClusterRole/Binding · trainer talks to it via `rl-signal-sdk`.
Designed for testability: `DGDSAClientProtocol` / `MetricsCollectorProtocol` structural interfaces, `InMemoryDGDSAClient`, injectable clock (`clock: Callable[[], float] = time.monotonic`).

---

## 4. Key Q&A

**Q: Where does `batch_meta` come from — DynamoWorker or frontend?**
**Neither — the RL training job**, via `rl-signal-sdk` → `POST /api/v1/signals/sampling_progress`. Fields (pydantic `_BatchMetaModel`): `batch_size` (>0, used), `avg_isl` (>0, used), `total_tokens` (optional, used; defaults `batch_size × avg_isl`), `avg_osl` (optional, **accepted but ignored**).
*Why it must be the trainer:* S1 is **feed-forward** — pre-warm happens *before* the load arrives, and you cannot measure load that hasn't been submitted. Only the trainer knows "I'm about to submit 128 prompts of ~3072 tokens."
**Architectural contrast worth stating in the thesis: S1 uses *declared* metadata (feed-forward); S2/S3 use *measured* telemetry (feedback — Prometheus + sidecar `/v1/active_requests`).**

**Q: Is `dgdsa_client.py` imported from a Dynamo client library?**
**No — it's our own 198-line file** using the **generic `kubernetes` Python client**. No Dynamo client library exists in the path. The name means *"a client **for** the DGDSA resource,"* not *"from Dynamo."* It writes to the **kube-apiserver** (which persists to etcd); we never touch etcd directly.

**Q: Two scale paths — which do we actually use?**
**The Deployment fallback.** `config.py` default is `K8S_SCALE_FALLBACK_ENABLED=False` (DGDSA path), but the deployed controller **and every `scenario_env`** set it to `true`. So every measurement used `patch_namespaced_deployment_scale` on the native `apps/v1` Deployment (discovered by label `nvidia.com/dynamo-component=…`), bypassing the DGDSA CR. **The DGDSA path was never exercised.**

**Q: Have we measured the PD switch action cost? Does the benefit cover it?**
Yes, on both axes. Server-side (midterm): D→P **453.5 ms**, P→D **428.0 ms**, round-trip **963 ms**; dominated by `register_mdc` ≈ **327 ms** (a K8s apply RTT) — engine-side `sleep+wake` is only ≈ 90 ms. Perf runs confirm: `s2_switch_total_ms` = **1021 ms** (s2_only), **885 ms** (mixed).
Benefit vs cost (clean run): switch **1.02 s** → prefill saving **12.3 s (~12×)**, serving-wall saving **23.5 s (~23×)**.
**Structural reason it's safe: the switch cost is O(1) (K8s-bound, independent of batch/model size); the benefit is O(batch size).** Bigger burst → better ROI. It only fails to pay for a burst so small it wasn't worth re-roling — which `PREFILL_QUEUE_THRESHOLD` / `MIN_SWITCH_INTERVAL` exist to prevent (also stops thrashing).
*Counterpart:* **S3's cost is also O(1) (~180 ms control) but its benefit is O(tail duration)** — hence 15% saved on a 37 s tail vs 44% on a 219 s tail. Same mechanism, ratio scales with straggler length.

**Q: Is the fixed prefill TPS the only weakness?**
**No — and it's not the worst one.**
1. **`on_sampling_progress` only fires from IDLE** + state is in-memory only. If the controller is in any other state the pre-warm signal **silently no-ops** — no scale-up, no error. This *actually broke real runs* (stale `warm_up` → warmup hung at 1P1D). A restart also loses `current_target`. This is a **robustness bug**, worse than the modeling issue below.
2. **Open-loop planner with an unvalidated constant** (below).
3. `avg_osl` is ignored — decode sizing keys purely on *concurrency*, not on how long streams run. A batch of 64×50-token and 64×5000-token requests get identical decode plans though their decode GPU-time differs ~100×. *This is exactly the gap S3 patches at runtime.*

**Q (measured): how wrong is `SINGLE_PREFILL_TPS`?**

| | value |
|---|---:|
| `SINGLE_PREFILL_TPS` (config) | **50,000** tok/s |
| Measured, 1 prefill worker (baseline) | **2,738** tok/s |
| Measured, 3 prefill workers (s2 burst) | 4,200 tok/s |

**≈18× optimistic.** For our warmup signal (393,216 total tokens) the planner computes `N_prefill = 2`; using measured throughput it should be **~31**. In a real deployment it would under-provision prefill by an order of magnitude.

**Q: Does "operator at 0 → DGDSA patch inert" mean our test isn't end-to-end?**
Production chain: `DGDSA CR --[operator]--> Deployment --> ReplicaSet --> Pod`. With the operator at 0 nobody performs the middle arrow, so a CR patch would sit in etcd and **nothing would act on it** — hence the fallback.
**But the test *is* genuinely end-to-end for what it claims:** pods are really created/terminated, **GPUs really allocated/released**, real requests flow through the real frontend/routers/vLLM/NIXL. **S2 and S3 never touch DGDSA or the operator at all.**
**The real, narrow gap:** we bypassed **one hop of S1's scale plumbing — and it happens to be the production-intended one.** DGDSA exists precisely as the "let an external autoscaler resize me" API (it has a `/scale` subresource for exactly this). Worse, the tested config is **mutually exclusive with a normal Dynamo install**: in production the operator runs, and we empirically confirmed it reverts a direct Deployment patch within **~8 s**. So `operator=0 + direct Deployment patch` is a **test-harness configuration, not a deployable one**. Root cause is mundane: the harness wants to force topology (`set_topology`) deterministically, and the operator would fight that.
**Scope of damage: S1's scale-application path only. S2 and S3 are unaffected.**

---

## 5. Claim boundaries (agreed)

S1 is **scaffolding**, not a claimed contribution — the contributions are the role switch, the dispatcher, the migration protocol, and the controller that dispatches them. Scoping S1 as *"the mechanism that gets the topology in place and demonstrates signal-triggered elasticity"* is legitimate, **provided the boundary is exact**:

| ✅ Can claim | ❌ Cannot claim |
|---|---|
| Signal-triggered scale-**from**-zero works (`idle → warm_up`, pods come up) | The capacity planner **sizes correctly** — it never drove the measured topology, and its constant is 18× off |
| Cooldown scale-**to**-zero works, gated on cooldown **+** in-flight drain (observed: prefill+decode → 0) | The **production** integration path (DGDSA + operator) works — implemented but untested |
| State machine transitions/gating are correct (unit-tested + observed) | S1 is production-deployable **as tested** (that config requires the operator off) |

**Critically: our four-scenario suite does not test S1's capacity planner at all** — the harness *forces* topology (`set_topology(1,1)` baseline, `warmup_forcing_topology → set_topology(2,2)` strategies). The planner *coincidentally* computes 2P2D for our signal (N_prefill=2, N_decode=2), which is why nothing looked wrong — **coincidence, not validation**.

**Viva answer for "how would this actually deploy?"** → flip `K8S_SCALE_FALLBACK_ENABLED=false`, run the operator, let the controller patch the DGDSA `/scale` subresource. The code path exists and is the intended design; it just wasn't exercised because the harness needed direct topology control. **One-sentence limitation, not a hole in the results.**

---

## 6. Open items / next

1. **Add the claim boundary + "production path = DGDSA" framing** to `IMPLEMENTATION-full-picture-2026-07.md` and `MASTERS-EVALUATION-2026-07.md` (the evaluation currently marks C4 "Partial" only for the synthetic-signal reason; it doesn't say the planner is untested/miscalibrated).
2. **Cheap experiment (~20 min) to upgrade S1 from "mechanism demonstrated" → "planner validated":** calibrate `SINGLE_PREFILL_TPS` from a prefill micro-benchmark, then send 2–3 signals with different `batch_size`/`avg_isl` and assert the planner produces (and the cluster reaches) the expected topology — **without** forced `set_topology`.
3. Consider making pre-warm **idempotent from any state** (or continuously reconcile `current_target`) instead of the IDLE-only event, and persisting state.
4. Next deep dives: **KB-02 — S2 `dual_mode.py::switch_role`** (the 8-step ordering is where the subtlety lives); **KB-03 — S3 migration protocol**.
