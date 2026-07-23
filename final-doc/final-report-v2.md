# Cloud-Native Autoscaling for Disaggregated LLM Inference: Elastic Role Switching and In-Flight Request Consolidation for Reinforcement Learning Workloads

**Shengqi ZHANG** — `szhanggd@connect.ust.hk` (21209697)

> This is the final report. It supersedes the mid-term report by (i) keeping the
> verified system design, (ii) adding an end-to-end autoscaling implementation
> section, and (iii) replacing the correctness-only verification with a rigorous,
> phase-attributed efficacy evaluation on a real Dynamo + vLLM cluster. The LaTeX
> double-column version is `final-report.lex`.

---

## Part 0 — Review of the mid-term report and change log

Task 1–2 of the report guide ask to first review the mid-term report (content and
figures), confirm what is correct, and list — item by item — what should be
improved. This part records that review and the exact changes carried into the
final report. It is engineering front-matter; the academic paper itself begins at
Part 1.

### 0.1 What is correct and kept unchanged

| # | Mid-report content | Verdict |
|---|---|---|
| D1 | Introduction: Dynamo overview, RL GPU-waste taxonomy (cross-phase + intra-phase tail), cold-start mismatch argument, `U_GPU` objective | Correct, kept |
| D2 | Background: PD disaggregation, Dynamo CR-based discovery, KV/prefix-cache coherence target, related-systems table | Correct, kept |
| D3 | System design: dual-mode "one pod / one engine / one TCP slot / two ModelCards", port model, request path | Correct, kept |
| D4 | Elastic role switch: 8-step state machine, `kv_both` rationale, partner-prefill single-slot dispatcher, CR-based e2e correctness | Correct as the *engine core*; Section 4 now wraps it in the zero-loss envelope and revises the ordering constraints (see I3) |
| D5 | Consolidation: 3-phase block-hold NIXL-pull protocol, at-least-one-copy invariant, victim/peer selection, safety-net sweep, client continuity | Correct, kept |

The design half of the mid-report is technically sound and is retained. The
weaknesses are all in the **claims** and the **evaluation**, fixed below.

### 0.2 Item-by-item improvements (content)

- **I1 — Abstract over-claims relative to what was measured.** The mid-report
  abstract promises the system "raises useful work per allocated GPU-hour", but the
  mid-report never measures a GPU-hour, a makespan, or an occupancy. *Change:* the
  final abstract reports the measured efficacy — topology makespan −21.2%, tail-phase
  decode-GPU·s −44.5%, 100% validity — and separates it from what the data does not
  support, namely any queue-timing or wall-clock benefit from role switching on this
  transport-bound cluster (Section 7.5).

- **I2 — The NIXL-connector migration result needs an honesty caveat.** The
  mid-report's `path=connector`, 188 ms, 109-block, 1688-token evidence is real, but
  it was obtained in a dedicated micro-benchmark with the KVBM block-bridge overlay
  wired in. The default clean image does not expose the KVBM index, so in the
  production phased runs migration can fall back to recompute. *Change:* Section 5
  states this explicitly and makes the load-bearing point that **the GPU-reclamation
  benefit of consolidation is independent of the transfer path** — it comes from
  releasing idle decoders, not from how the KV is moved.

- **I3 — Switch cost was measured only under a light 2 RPS load (963 ms), and the
  mid-report's state machine describes only the engine core.** Under a realistic
  in-flight decode load a *zero-loss* switch must also close the intake, drain, and let
  peers finish pulling the KV this worker produced. *Change:* Section 4 is restructured
  into two layers (engine core + zero-loss envelope) with a fourth ordering constraint
  (never sleep while a peer is pulling our KV), and Section 7.5 gives the measured
  per-step decomposition of the deployed protocol (941 ms per flip).

- **I4 — Correctness ≠ efficacy.** The mid-report proves the mechanisms *work*
  (5/5 and 6/6 pass conditions) but never shows they *help*. *Change:* the whole
  evaluation (Part 6) is rewritten around a phased workload designed so each
  mechanism's regime is isolated in time, and it measures per-phase timing and
  per-phase GPU occupancy — the quantities that actually reflect the objective.

- **I5 — Report the measurement confounds honestly.** *Change:* Part 6 documents a
  real cross-session drift (static A-phase 33.2 s vs 23.4 s) and states plainly that
  the S2 wall-clock benefit is *not resolvable* at n = 3 under that drift — a limit
  of the cluster/scale, not a failure of the mechanism.

### 0.3 Figure audit against the deployed implementation (task 2)

Every mid-report figure was re-checked line-by-line against the code that produced the
final measurements, not against the design intent. Two of the six no longer describe the
system, and one is correct but incomplete:

| Figure | Verdict | Action |
|---|---|---|
| GPU-hour pattern | Correct | Kept |
| Dynamo architecture | Correct | Kept |
| RL-controller loop | Correct, but the trigger input is under-specified | Caption extended: the phase signal carries the *remaining* rollout shape (Section 6.2) |
| K8s deployment topology | Correct | Kept |
| **Role-switch state machine** | **Contradicts the implementation** | **Replaced** (Figure 5) |
| Consolidation sequence | Correct for the handshake, but stops before the GPU is reclaimed | Extended with the release stage (Figure 7) |

**Why the role-switch figure had to be replaced.** The mid-report figure shows
`sleep(2)` as step (1) and `unregister_mdc` as step (2) — pause first, unpublish second.
The deployed protocol does the opposite (cordon-first), and the reason is not cosmetic:
draining behind a still-published ModelCard lets the router keep refilling the worker,
which is precisely the race that produced switch-instant HTTP 500s. The figure also omits
the three steps that account for **89%** of the measured switch cost — drain, settle, and
the outbound-KV wait — so a reader who costed the figure would predict ~115 ms and then
find 941 ms in Section 7.5 with no bridge between them. The replacement in Section 4 is
drawn from the same `timings_ms` field the measurements come from, so figure and table
are two views of one record.

**Data figures.** Three figures are rendered from the released dataset: the phased
workload timeline (Figure 8), per-phase decode-GPU occupancy for static / s3 / mixed
(Figure 9, which visually carries the tail-reclaim result), and the makespan bar chart
(Figure 10).

---

## Part 1 — Introduction

### 1.1 The NVIDIA Dynamo serving framework

NVIDIA Dynamo is an open-source runtime for disaggregated LLM inference. It is a
Rust runtime hosting (i) a KV-aware router, (ii) any number of worker pods each
wrapping a vLLM engine, and (iii) a discovery layer that uses Kubernetes Custom
Resources (CRs) as the single observable source of truth for worker membership. The
frontend embeds two stateful routers — `KvRouter` for decode dispatch and
`PrefillRouter` for prefill dispatch — and a `ModelWatcher` that maintains the
WorkerSet by `list+watch`ing worker metadata CRs. KV-cache transfer between prefill
and decode workers is performed by the NIXL connector over NVLink / RDMA. This is
the de-facto mainstream stack for PD-disaggregated serving and is the baseline our
extensions build on.

### 1.2 The RL workload and its GPU-waste problem

Inference cost is dominated by GPU-hours. In online chat serving, traffic is
near-stationary and static PD partitioning works because both pools stay busy. The
RL rollout loop that drives modern post-training (RLHF, DPO, GRPO) submits inference
traffic in a fundamentally different, **bursty** pattern. Each phase boundary leaves
one of Dynamo's GPU pools fully busy and the other idle, producing two compounded
sources of waste:

1. **Cross-phase pool waste.** During the prompt-processing burst only prefill GPUs
   are active; during the long-tail generation only decode GPUs are active. The idle
   pool keeps its allocation the whole time — cost without work.
2. **Intra-phase tail waste.** As a batch nears completion the active request count
   on each decoder asymptotically approaches zero, yet the GPU cannot be released
   until the last long completion finishes.

Standard elasticity is structurally mismatched. Horizontal pod scaling costs tens of
seconds of cold start — one to two orders of magnitude longer than the phase it
would react inside — and each new pod starts with an empty prefix cache and must
re-establish NIXL connectivity, discarding the very benefit PD disaggregation
exposes. Static over-provisioning lower-bounds cost at peak demand even while a pool
is idle. Both fail the RL controller's requirement to act **within a single rollout
phase**.

### 1.3 Optimization objective

The primary lever is GPU utilization:

```
U_GPU = ( Σ_g T_compute(g) ) / ( Σ_g T_allocated(g) )
```

By re-rolling idle GPUs into the currently-bottlenecked phase, and by consolidating
tail-end decode work onto fewer GPUs, the system raises useful work per allocated
GPU-hour. The operations must be fast enough (sub-second to a few seconds) that an RL
controller can act inside one rollout phase.

### 1.4 Contributions

- **(C1)** A two-layer in-place role-switch protocol — an eight-step engine-core state
  machine wrapped in a zero-loss safety envelope (cordon-first, drain + settle,
  hold-during-switch, bounded outbound-KV drain) — that atomically transitions a worker
  between decode and prefill roles. Measured cost **941 ms** per flip under in-flight
  load (engine steps ~115 ms; `register_mdc` control-plane round-trip ~309 ms; drain +
  settle ~502 ms), at 100% request validity.
- **(C2)** A single-TCP-slot dispatcher for partner-prefill that lets one vLLM engine
  serve both decode and prefill traffic at run-time with no socket re-binding.
- **(C3)** A three-phase block-hold NIXL-pull migration protocol that consolidates
  running decoders with zero KV loss, bounded by a safety-net sweep timer.
- **(C4)** An RL-signal-driven autoscaling controller that consumes rollout-phase
  signals and dispatches the above primitives, with a cordon-first quiesce/settle
  discipline that makes the primitives composable without dropping requests.
- **(C5)** A rigorous, phase-attributed end-to-end evaluation on a Kubernetes
  deployment of `Qwen3-0.6B`, gated by eight automated acceptance checks that rejected
  six suites before one was analysed. It establishes **correctness** (100% valid, zero
  5xx, zero timeouts across 15/15 runs) and **efficacy where efficacy exists** —
  topology makespan −21.2%, tail-phase decode-GPU·s −44.5% from reclaiming drained
  decoders — while reporting, with its measured cause, that role switching yields **no**
  queue-timing benefit on a cluster whose prefill phase is bounded by KV transport
  rather than by prefill compute.

---

## Part 2 — Background and Related Work

**PD disaggregation.** Every request runs two serial phases sharing weights but with
different bottlenecks: prefill processes all N prompt tokens in one compute-bound
forward pass; decode generates one token at a time and is memory-bandwidth-bound.
Co-locating them causes head-of-line blocking (one long prefill stalls a batch of
decodes). PD-disaggregated serving — Splitwise, DistServe, now Dynamo / vLLM-disagg /
SGLang-disagg — splits the phases onto separate pools connected by a high-bandwidth
KV fabric (NVLink / RDMA via NIXL). The split inherits one structural inefficiency:
the workload's compute:bandwidth ratio may not match the operator's provisioned
prefill:decode ratio, so one pool idles while the other bottlenecks. RL bursts
amplify this — it is the central leverage point of this work.

**Dynamo runtime.** Discovery uses one CR per worker as the single source of truth;
each worker strategic-merge-patches its own CR and the frontend's `ModelWatcher`
reconstructs the WorkerSet via `list+watch` (no etcd registry). Routing is stateful:
`KvRouter` holds a radix-tree KV index and per-worker cost model; `PrefillRouter`
fans to prefill-role workers. A role change must propagate through CR mutation and
reconverge router state without disrupting in-flight requests. The NIXL connector
plus the KV-Block Manager (KVBM) let a decoder pull KV blocks directly from another
worker's VRAM — the mechanism consolidation builds on.

**Related systems.** Splitwise/DistServe: static PD partition, no run-time flip.
vLLM-native replicate: ~30 s cold start, loses prefix cache. Mooncake: KV pool
offload, orthogonal, no role switch. ServerlessLLM: cold-start-optimized serverless,
no PD topology. SpotServe: instance-level migration, not request-level. **This work
is, to our knowledge, the first to combine sub-second in-place PD role flipping with
live decoder-to-decoder NIXL-pull migration, both driven by an external RL signal.**

---

## Part 3 — System Design: RL-Signal-Driven Autoscaling

Two RL scaling scenarios demand different primitives:

1. **Elastic PD role switch.** At phase transitions the prefill:decode demand ratio
   shifts abruptly — early a rollout burst is prefill-dominated (all prompts arrive
   together), later it is decode-dominated (long completions accumulate). An in-place
   role flip re-roles idle workers to the bottlenecked pool without cold start.
2. **Decode request consolidation.** Near the end of a decode phase a shrinking set
   of long completions is scattered across many decoders, each holding one or two
   active requests. Aborting them wastes thousands of generated tokens; live
   migration consolidates them onto fewer decoders, freeing the rest.

Three layered primitives address these:

| Scenario | Layer | Goal | Primitive |
|---|---|---|---|
| Cluster scaling | Pod replicas | Pre-warm / drain | Patch replicas |
| PD role switch | In-place flip | Re-balance P/D | `/switch_role` |
| Consolidation | Live migration | Free target | `/migrate` |

Rollout-driven cluster scaling is the foundation: it pre-warms pods before a rollout
so that role-switch and consolidation operate on already-running engines. Each
dual-mode worker pod exposes an inference intake (`:8000`), a dynamic request-serving
slot, a Prometheus/system port (`:9090`), and the RL-Scaling sidecar control plane
(`:9091`). The dual-mode invariant is **one pod, one engine, one TCP slot; two
ModelCards (decode + prefill) take turns owning the slot.** The engine boots with
`--kv-transfer-config NixlConnector kv_both` so it carries NIXL metadata for both
roles; `switch_role` never reopens a socket — it only renames the entry the
`ModelWatcher` observes in the worker CR.

---

## Part 4 — Elastic PD Role Switching

**Problem.** Instruct a specific decoder `D_i` to become a prefill worker (and later
revert) without restarting the pod, without dropping in-flight requests elsewhere,
and fast. `POST <D_i>/switch_role` must: withdraw `D_i` from the decode WorkerSet;
release its decode KV state; serve prefill traffic dispatched by `PrefillRouter`;
support a symmetric reverse; and keep pod name / IP / engine identity / prefix-cache
infrastructure unchanged.

The protocol is best understood as **two layers**: an engine-core flip wrapped in a
zero-loss safety envelope. This layering is what reconciles the switch-cost numbers
reported across this project: 453 ms (mid-term, light load, no envelope) → 3.4 s
(first zero-loss envelope, 3.0 s settle) → **941 ms measured in the final round**.

**Layer 1 — engine-core flip (~115 ms, load-independent).** Six timed steps cycle the
engine and swap the published ModelCard: `sleep(2)` → unregister old MDC →
reconfig-NIXL → reset-prefix-cache → register new MDC → wake, flipping `current_role`
before the new MDC is published. Excluding the `register_mdc` control-plane round-trip
(~309 ms, a Kubernetes `apply`, which is a physical floor rather than engine work),
the engine steps themselves total ~115 ms: sleep 58, wake 27, cordon 16, flush 7,
reconfig-NIXL 5, reset-prefix-cache 2. Two ordering constraints make this safe:
*reset cache while asleep* — `sleep(2)` returns prefix-cache blocks to the allocator,
so resetting after wake would race a new request onto a stale block; the reset is done
atomically inside the sleep window. *publish only in a consistent target state* —
traffic on the new ModelCard must land on an engine already in the target role.

**Layer 2 — zero-loss safety envelope (cordon-first + drain + KV-drain, load-dependent).**
The core alone drops requests if a flip is issued mid-flight: the router keeps
dispatching to the worker until it observes the ModelCard withdrawal, so a request can
land on a half-asleep engine (observed: switch-instant HTTP 500s under concurrency). The
deployed protocol therefore wraps the core with, in order:

- **cordon-first** — withdraw the old-role ModelCard *before* anything else, so the
  intake is closed as early as possible. (This supersedes the midterm's *pause-before-
  unpublish* ordering: unpublish now comes first.)
- **drain to idle + settle window (0.5 s)** — wait for in-flight requests on this
  worker to finish naturally, then require the engine to stay idle for a continuous
  window before sleeping, confirming the router has stopped routing here; any arrival
  re-drains. Load-dependent; ≈0 under light load.
- **hold-during-switch (dispatcher)** — between cordon and re-registration the router
  can only be acting on the *old* card, so any arrival in that window is old-role
  traffic by construction. Instead of letting `sleep` reject it, the request-time
  dispatcher **holds** it until the switch completes and then serves it under the
  pre-switch role. This is what makes the short 0.5 s settle safe: zero loss no longer
  depends on out-waiting the router, so the window shrank 3.0 s → 0.5 s with validity
  unchanged.
- **outbound KV drain (bounded, 8 s)** — wait until no peer is still pulling KV that
  this worker produced while it held the prefill role, then sleep. See the fourth
  ordering constraint below.

**A fourth ordering constraint: never sleep while a peer is pulling our KV.**
`sleep(level=2)` frees GPU memory. If this worker served prefill and a peer decoder's
NIXL READ against its KV is still in flight, sleeping destroys that transfer and the
peer's request hangs until its client timeout. This was measured directly: a P→D
switch-back issued 5 s into the decode phase left 646 blocks permanently pinned
(`Failed to reset prefix cache because some blocks are not freed yet`) and hung 34
peer requests to their 600 s timeout. The earlier 3.0 s quiesce window had been
*accidentally* safe — it happened to outlast typical pull times — so the defect only
surfaced once the switch was fast. Note also that force-expiring the connector's
pending sends (the original `flush`-first ordering) is equally destructive for a send
a peer is about to pull. The deployed protocol therefore **waits** (polling the
connector's pending-send registry and the block pool's pinned-block state, bounded at
8 s) and force-expires only what nobody claimed within that window — a true orphan.
At a phase boundary with no handoff in flight this passes on the first poll at ~0 cost;
under an active handoff it is the honest, load-dependent price of losslessness.

The measured decomposition of the deployed protocol is in Table 7.5-A.

**Figure 5 — the deployed protocol (replaces the mid-report state machine).** The
figure below is generated from the same `timings_ms` record the measurements come from;
the annotations are the 10-switch means of Table 7.5-A.

```
        ┌──────────────────── Layer 2: zero-loss envelope ────────────────────┐
        │                                                                     │
  (1) cordon ──▶ (2) drain to idle ──▶ (3) settle window ──▶ (4) outbound-KV  │
      16 ms          load-dep.             0.5 s fixed          wait, ≤8 s    │
      withdraw       in-flight             no arrival =         no peer still │
      old MDC        finish                router converged     pulling our KV│
        │                                                                     │
        │   ┌───────────── Layer 1: engine core, 115 ms ─────────────┐        │
        └──▶│ (5) sleep(2) ─▶ (6) reconfig_nixl ─▶ (7) reset_prefix   │        │
            │      58 ms            5 ms             cache, 2 ms     │        │
            │            flip current_role in the sleep window       │        │
            └───────────────────────────┬───────────────────────────-┘        │
                                        ▼                                     │
                       (8) register_mdc ──▶ (9) wake ──▶ (10) label            │
                            309 ms            27 ms        best-effort         │
        └─────────────────────────────────────────────────────────────────────┘
             total 941 ms (884–1005 over 10 switches); dispatcher HOLDS any
             arrival between (1) and (8) and serves it under the pre-switch role
```

Three differences from the mid-report figure are load-bearing rather than cosmetic:
(i) the cordon moved from step (2) to step (1); (ii) steps (2)–(4), which did not exist,
account for 89% of the cost; (iii) the hold path is what makes the 0.5 s settle safe, so
it belongs in the protocol rather than in a footnote.

**Why `kv_both` is load-bearing.** `kv_transfer_config` is fixed at engine
construction; a run-time change would rebuild the engine (≥5 s + prefix-cache loss).
Building one engine that knows both roles reduces the switch to (i) a CR registration
change and (ii) an engine-state cycle (sleep, reset, wake).

**Partner-prefill: one TCP slot, two ModelCards.** Two non-obvious fixes: (a) a
wrapper merges `kv_transfer_params` from the last stream chunk into chunk #1, because
vLLM's `NixlConnector` publishes it last but Dynamo's `PrefillRouter` reads it first;
(b) a single request-time dispatcher (`_generate_dispatch`) avoids the process-level
`connection_id` collision that would occur if decode and prefill registered two
handlers on one engine.

**Correctness via K8s discovery.** The propagation chain is worker-mutates-CR → API
server → informer watch → frontend `ModelWatcher` re-converges the WorkerSet. Pod
identity is invariant, the CR is the single observable truth, no K8s Service is on
the chat path, and eventual consistency is bounded (<200 ms single-node). A flip is
confirmed by composing three independent observations: CR diff, frontend `Removed`
event, and post-switch workload attribution (`prompt_tokens_total` grows while
decode attribution is zero).

---

## Part 5 — In-Flight Decoder Request Consolidation

**Problem.** A `switch_role` mid-flight terminates whatever was running; for long
completions this throws away thousands of generated tokens. We need an
operator-callable primitive that migrates a running request from one decoder to
another, leaving the source drainable, with no KV loss.

**Three-phase block-hold NIXL-pull.** The source keeps the request alive and the KV
blocks pinned across the whole handshake, releasing only after the destination
confirms acceptance:

- **Phase 1 (Block-Hold):** `migrate_out` on `D_src` pins KV blocks, records source
  block IDs / NIXL coords / sampling params / emitted-token count, and returns them —
  **without** aborting.
- **Phase 2 (NIXL READ pull):** `migrate_in` on `D_dst` applies the cost-benefit
  gate, injects `kv_transfer_params`, submits the request; the `NixlConnectorScheduler`
  issues an RDMA READ from `D_src`'s GPU, populates local KV blocks, and decodes from
  `emitted+1`.
- **Phase 3 (Release):** `migration_complete` on `D_src` aborts the request, unpins
  KV blocks, clears the pending entry.

This satisfies an **at-least-one-copy invariant**: no step leaves the request without
an authoritative KV copy. A two-phase (abort-then-submit) variant is unsafe under
NIXL pull — freeing source blocks before the destination READ completes risks reuse
and silent corruption.

**Strategy.** A per-pod request registry (updated at submit / delta / completion)
answers which requests a decoder owns and how progressed each is. Source-side victim
selection picks the **most-progressed** request (maximizes marginal cost saved per
migration). Destination-side admission declines when replay cost exceeds threshold or
too few tokens remain. The controller ranks peers by load score and picks the
least-loaded eligible peer with spare KV capacity. A `sweep_stale_migrations`
background task force-completes any hold older than 10 s. `previously_emitted_tokens`
gives the client exactly one logical stream across the boundary.

**Figure 7 — what happens after the handshake (extends the sequence diagram).** The
mid-report sequence ends when the source unpins its blocks, but the GPU is not reclaimed
until the controller acts on the drained decoder. The deployed chain continues:

```
  migration_complete           controller decision loop            Deployment
        │                              │                               │
        ├─ source unpins KV ──▶ active_requests == 0                   │
        │                              ├─ mark is_release              │
        │                              ├─ cordon (withdraw MDC)        │
        │                              ├─ settle 1.5 s  ◀── router converges
        │                              └─ scale down ─────────────────▶│ replicas 2→1
        │                                                              │
        └──────────────── GPU released 12.2 s before T_end ────────────┘
```

The settle interval between cordon and scale-down is not decorative: without it, requests
routed during the propagation window returned 5xx (Section 6.3). This stage is what turns
a successful migration into a reclaimed GPU, and it is the stage the −44.5% measures.

**Honesty note on the transfer path (I2).** In a dedicated micro-benchmark with the
KVBM block-bridge wired, `migrate_in` demonstrably takes `path=connector` (188 ms;
109 physical blocks; 1688 tokens transferred without recomputing the prefix). The
default clean image does not expose the KVBM index, so in the production phased runs
migration may fall back to recompute. **Crucially, the efficacy result below — freeing
decode GPUs during the tail — does not depend on which transfer path is used; it
comes from releasing idle decoders after consolidation.** The connector path improves
per-migration latency; it does not create the GPU-occupancy saving.

---

## Part 6 — Implementation: The End-to-End Autoscaling Controller

This section (new in the final report) describes how the three primitives are driven
end-to-end by an autoscaling controller, and why the control discipline matters for
RL.

### 6.1 Control loop

The RL-Scaling controller is a cluster-level service that runs a periodic decision
loop over three inputs: (i) **RL phase signal** — the training job posts
`send_progress(frac, batch_size, avg_isl, avg_osl)` marking where in a rollout it is;
(ii) **cluster state** — the WorkerSet and per-pod roles read from the worker CRs;
(iii) **live load** — per-pod active-request counts and generation throughput scraped
from the sidecar and Prometheus. From these it maintains a small state machine
(`IDLE → WARM_UP → REBALANCE → CONSOLIDATE → DRAIN`) and dispatches the primitives:
`patch replicas` to pre-warm, `/switch_role` to re-balance P:D, and `/migrate` +
scale-down to consolidate and reclaim.

### 6.2 Role-switch dispatch and the quiesce discipline

When the phase signal indicates a prefill-dominated burst, the controller re-roles a
decoder to prefill (D→P); when it flips to decode-dominated, it reverts (P→D). Under
in-flight load a naive flip drops requests, so the controller uses the **cordon-first
handshake** of Section 4: withdraw the target's ModelCard, drain to idle and confirm a
stable settle window, wait for outbound KV pulls to finish, then perform the
sleep/reset/wake cycle. The envelope — not the engine — dominates the 941 ms cost, and
it buys **zero request loss** (Section 7 shows 100% valid).

**Trigger design is part of the contribution.** Which signal fires the switch turned
out to matter as much as how fast the switch is. On this stack the *prefill* queue
never builds a backlog — prefill is fast enough that `dynamo_frontend_queued_requests
{role="prefill"}` stays at 0 through a 44-prompt burst while the decode queue climbs
to 44 — so a reactive queue-depth trigger can never fire D→P in time. The controller
therefore drives D→P from the **RL phase signal itself**: the training job posts the
rollout's shape at dispatch, and the controller derives a prefill-pressure hint from
it. Two disciplines make that safe: the signal reports the *remaining* work (once the
prompts are sampled the residual is decode-shaped, the hint dies, and D→P stops
re-firing), and P→D additionally requires the prefill backlog to be clear, so the
revert cannot take capacity away from a phase the RL loop has declared in progress.
Without these the pair oscillates at the minimum-switch-interval cadence — observed,
then fixed, during the final round.

### 6.3 Consolidation dispatch, idle-release, and cordon settle

For consolidation the decision engine forms migration pairs from the most-progressed
requests on the least-loaded decoders, and — once a decoder reaches
`active_requests = 0` — marks it `is_release` so the controller can cordon and
scale it down. Two safety additions were required to make this composable with role
switch:

- **`consolidation_cordon_settle` (1.5 s).** After cordoning a source decoder (removing
  its ModelCard) the controller now sleeps a settle interval before re-checking and
  scaling down, so the router has propagated the removal before the pod disappears.
  Without it, requests routed in the propagation window returned 5xx.
- **S2/S3 desync (`STABLE_SAMPLES = 3`, `MIN_INTERVAL = 10 s`).** In the mixed
  scenario a P→D switch rebuilds an empty decoder that S3 would immediately
  idle-release; requiring more consecutive stable samples de-conflicts the two
  primitives.

### 6.4 Why this matters for RL

RL rollouts are the workload where these mechanisms pay off, because the demand ratio
is *known in advance* from the training loop's phase, not merely observed after the
fact. The controller can therefore act **proactively at the phase boundary** rather
than reactively after a queue builds. The autoscaling contribution is thus not just
the primitives but the **discipline** — cordon-first, quiesce, settle, desync — that
lets an external RL signal reshape a live PD deployment without dropping a single
request. Section 7 quantifies both the benefit and the one real trade-off this
discipline introduces.

---

## Part 7 — Evaluation

The mid-report proved the mechanisms *work*. This section proves whether — and by how
much — they *help*, using a workload designed so that each mechanism's regime is
isolated in time, and metrics chosen to reflect the `U_GPU` objective directly.

### 7.1 How the test data is constructed (and why)

A single **phased workload of 59 requests** is generated once from a fixed seed and
reused **byte-for-byte** by every scenario (verified by a shared workload manifest).
Phases are separated by **per-request launch offsets, not gates**, so the measured
`business_wall` equals the batch makespan `T_batch = last_completion − dispatch`, with
zero harness/gate contamination. The three phases each target one mechanism:

| Phase | # req | Prompt (words) | Output (`max_tokens`) | Launch offset | Regime it creates | Mechanism it probes |
|---|---|---|---|---|---|---|
| **A_prefill** | 32 | ~1200 (≈1560 tok ISL) | short: 64 / 96 / 128 | t0 (all together) | prefill burst — all prompts arrive at once | **D→P** role switch (need more prefill) |
| **B_decode** | 24 | ~450 (≈585 tok ISL) | long: 1200 | +22 s | decode-heavy — no new prompts, long generations | **P→D** role switch (need more decode) |
| **C_tail** | 3 | ~50 | very long: 6000, `ignore_eos` | +40 / 43 / 46 s | a few long stragglers scattered on decoders | **S3** consolidation + idle-release |

**Design rationale.** The counts (32 / 24 / 3) and offsets are chosen so the three
regimes do not overlap: the A burst front-loads prefill demand; by +22 s the A
prompts are decoding and the B batch adds decode pressure with no new prefill; by
+40 s only the 3 `ignore_eos = 6000` stragglers remain, each pinning a decoder at ~1
active request — exactly the intra-phase tail waste S3 exists to reclaim. Using
`ignore_eos` on C guarantees the stragglers actually run to `max_tokens` and produce a
long, measurable tail rather than terminating early. The scale (59) is deliberately
small enough to run five scenarios × three repeats affordably while still exhibiting
all three regimes; Section 7.6 projects what the same structure implies at production
RL batch sizes.

**Five scenarios**, each × 3 repeats: `baseline_1p1d` (1 prefill + 1 decode),
`static_2p2d` (2 + 2, the equal-topology control), `s2_only` (2p2d + role switch),
`s3_only` (2p2d + consolidation), `mixed` (2p2d + both). The equal-topology control
is essential: it isolates the *mechanism* effect from the *more-GPUs* effect.

### 7.2 Quality gate (all scenarios pass)

| Scenario | valid % | 5xx | timeout |
|---|---|---|---|
| baseline / static / s3_only | 100.0 | 0 | 0 |
| static (new session) / **s2_only** / **mixed** | 100.0 | **0** | 0 |

`mixed` went from **86.4% (24×5xx) → 100% (0×5xx), 3/3 stable** after the cordon-settle
+ desync fixes of Section 6.3. All efficacy numbers below are therefore computed on
**valid, complete** runs only.

### 7.3 A measurement confound stated up front (honesty prerequisite)

Under identical workload and config, `static_2p2d`'s A-phase serving time drifted
**33.2 s (old session) vs 23.4 s (new session)** — a 30% swing — because the new-session
static was run *after* s2/mixed (warmer cluster), not interleaved. Consequence: A/B
wall-clock is sensitive to session/order, and the drift (~10 s) is **≥** the D→P/P→D
effect size (~3–15 s). Therefore:

- **Topology and S3** use the **old, interleaved, counterbalanced** session → clean,
  trustworthy.
- **S2 D→P/P→D wall-clock** can only use the new-session control (order-confounded) →
  reported but **not** used for a strong claim.

This is an honest boundary of the cluster/scale, not a result.

### 7.4 Per-phase metrics

Per-phase serving wall (s) and average GPU occupancy (GPUs), 3-repeat means:

| Scenario | A wall | A avg dec-GPU | B wall | B avg dec-GPU | C wall | C avg dec-GPU | `T_batch` |
|---|---|---|---|---|---|---|---|
| `baseline_1p1d` | — | — | — | — | — | — | 88.1 |
| `static_2p2d` (old) | 33.2 | 2.00 | 17.4 | 2.00 | 29.4 | 2.00 | 69.4 |
| `s3_only` (old) | 24.2 | 2.00 | 12.3 | 2.00 | 32.6 | **1.00** | 72.6 |
| `static_2p2d` (new) | 23.4 | 2.00 | 12.8 | 2.00 | 29.4 | 2.00 | 69.4 |
| `s2_only` (new) | 37.9 | 2.00 | 23.5 | 2.00 | 30.9 | 2.00 | 70.9 |
| `mixed` (new) | 37.7 | 2.00 | 23.5 | 2.00 | 33.6 | **1.84** | 73.6 |

Whole-run: decode-GPU·s — baseline 88.1, static 138.7, **s3 113.0**, mixed 142.0;
average total GPUs — static 4.00, **s3 3.56**, mixed 3.93; p95 latency (s) — baseline
48.5, static 32.3, **s3 23.6**, s2 37.9, mixed 37.7.

### 7.5 Per-mechanism analysis

**Topology elasticity (S1), clean.** `static_2p2d` vs `baseline_1p1d`: `T_batch`
**−18.7 s (−21.2%), paired t = −9.98**. Doubling both pools cuts makespan 21% — the
expected, stable baseline that the elastic mechanisms operate on top of.

**PD role switch (S2).** Two switches fire per run — D→P at the phase-A boundary, P→D
inside phase B. Every step of the deployed protocol is timed and returned in the
`/switch_role` response, so the cost is fully attributable rather than a single opaque
number (Table 7.5-A, 10 switches).

**Table 7.5-A — where a 941 ms switch goes.**

| Step | Mean | Share | Nature |
|---|---|---|---|
| drain to idle + settle window | 501.6 ms | 53.3% | load-dependent; the price of zero loss |
| `register_mdc` (K8s `apply` round-trip) | 308.7 ms | 32.8% | control-plane floor, not engine work |
| `sleep(2)` | 58.2 ms | 6.2% | engine core |
| `wake` | 27.2 ms | 2.9% | engine core |
| cordon (withdraw ModelCard) | 16.1 ms | 1.7% | engine core |
| flush NIXL pending sends | 6.6 ms | 0.7% | engine core |
| `reconfig_nixl` | 4.8 ms | 0.5% | engine core |
| `reset_prefix_cache` | 2.3 ms | 0.2% | engine core |
| **total** | **941 ms** (884–1005) | | |

Read against the mid-term's 453 ms (light load, no envelope) and this project's first
zero-loss build at 3.4 s, the table settles the question the mid-report could not
answer: the *engine* was never the cost. Engine steps total ~115 ms; `register_mdc` is
a ~309 ms control-plane floor; the remaining ~502 ms is the drain + settle window,
which is **tunable safety margin, not physics**. Shortening it from 3.0 s to 0.5 s cut
the flip from 3.4 s to 941 ms **with validity unchanged at 100%**, because the
hold-during-switch dispatcher (Section 4) makes losslessness a property of the
protocol rather than of out-waiting the router.

**Queue timing: the mechanism is correct, the benefit is not there (negative result).**
The report guide asks specifically whether the switch improves prefill-burst queue
timing, so the final harness promotes the frontend's `nvext` timings into every request
row and measures it directly instead of inferring it from wall clock. Against the
same-round `static_2p2d` control, phase-A time-to-first-token does **not** improve:

| Round | `static_2p2d` TTFT p50 / p95 | `s2_only` TTFT p50 / p95 | A-phase window |
|---|---|---|---|
| r1 | 1466 / 2878 ms | 1490 / 2870 ms | 38.2 s → 53.9 s |
| r2 | 1472 / 2656 ms | 1421 / 2628 ms | 35.5 s → 44.0 s |
| r3 | 1157 / 2597 ms | 1402 / 2609 ms | 39.4 s → 49.7 s |

p95 differs by under 1% in every round, and the A-phase service window is 8–16 s
**longer** with the switch. The earlier, order-controlled interleaved suite
(`interleaved-5scenario-20260717-202840`, a different workload and a different phase
design) reaches the same verdict independently: `s2_only`'s prefill-phase wall is
−3.8% versus its equal-topology control, i.e. no gain.

**Per-phase comparison against the equal-topology control.** The phased workload gives
each mechanism a phase in which it is the only actor, so the switch can be judged phase
by phase rather than on a single makespan number. All values are 3-run means from the
accepted suite; `static_2p2d` is the equal-topology control, so every difference is the
*mechanism*, not the GPU count.

| Phase | Metric | `static_2p2d` | `s2_only` | Δ |
|---|---|---|---|---|
| **A prefill burst** | router prefill-queue wait p50 | 29.5 ms | **24.7 ms** | **−16.2%** |
| | TTFT p95 | 2710 ms | 2702 ms | −0.3% |
| | service window | 37.7 s | 49.2 s | **+30.5%** |
| | request latency p95 | 37.6 s | 46.9 s | +25.0% |
| **B decode dense** | TTFT p50 | 327 ms | **291 ms** | **−10.8%** |
| | service window | 22.9 s | 25.3 s | +10.3% |
| | request latency p50 | 18.9 s | 20.3 s | +7.3% |
| **C long tail** | request latency p50 | 33.8 s | **27.9 s** | **−17.5%** |
| | TTFT p95 | 415 ms | **262 ms** | **−36.8%** |
| | service window | 37.9 s | 37.1 s | −1.9% |

Read together these rows tell a more precise story than a single verdict. **The mechanism
does what it is designed to do**: in phase A the router's prefill-queue wait — the one
quantity a decode→prefill switch can influence — falls 16.2%, and in phase B, after the
revert restores the decoder, TTFT falls 10.8%. **But the quantity it improves is
negligible in this deployment's time budget**: 29.5 ms of router queueing sits inside a
request whose end-to-end latency is ~34 s, so a 4.8 ms saving is 0.014% of that request.
Meanwhile the cost of borrowing the decoder is not negligible: under 2P2D→3P1D the
A-phase window grows 30.5%, because the KV handoff those 44 requests need is then served
by one decoder instead of two. Phase C shows the mirror image — after the revert the
topology is back to 2P2D and the tail clears 17.5% *faster* than the control, the one
phase in which `s2_only` leads.

The conclusion is therefore sharper than "no effect": **on a fabric where prefill routing
costs tens of milliseconds and the KV handoff costs tens of seconds, prefill capacity is
the wrong thing to buy.** The primitive is sound; this deployment does not have the
bottleneck it addresses.

**Why — and it is not a measurement artefact.** Phase A is not prefill-bound on this
cluster. Per-request A-phase server time stays ~33–35 s regardless of whether the A
cohort generates 1, 8–16, or 64–128 tokens, while TTFT is only ~1 s: the other 30+ s
is the request waiting on the decode side for its KV to arrive over a fabric with no
RDMA. Re-roling a decoder into prefill therefore adds capacity to a stage that is not
the constraint while **removing** capacity from the stage that is — which is exactly
what the longer A-phase window shows. The honest conclusion is that D→P is *correct
and cheap* (Table 7.5-A) but *does not pay off in this deployment*; the regime where
it should pay off is one where prefill compute, not KV transport, is the bottleneck —
larger models, larger prompt batches, or an RDMA fabric.

**Switch overhead versus batch makespan, and how it amortizes.** The two switches in an
`s2_only` run cost **2.01 s** of protocol time in total (Table 7.5-A), yet `s2_only`'s
makespan exceeds the control's by only **0.27 s** (83.14 s vs 82.87 s, run-to-run
σ = 1.95 s and 0.50 s). The switch cost is therefore **not additive to the makespan**: it
is absorbed by concurrency, because a switch removes *one* worker from service while the
other three keep serving. Of 2.01 s of protocol time, ~87% is hidden; the marginal
makespan cost is ≈ 0.13 s per switch, an order of magnitude below the protocol cost and
well inside the noise of a single run.

This is what makes the primitive viable rather than merely correct, and it strengthens
with scale. For a rollout of `N` prompts whose phase lasts `T_batch`, with `k` switches
per rollout (k = 2 here — one per phase transition) and a fixed per-switch cost
`t_switch` ≈ 0.94 s:

```
overhead_protocol = k · t_switch / T_batch      = 2 × 0.94 / 82.9  = 2.42%   (measured)
overhead_makespan = k · t_absorbed / T_batch    = 2 × 0.13 / 82.9  = 0.33%   (measured)
```

Both numerators are **fixed** — the switch protocol does not grow with batch size, since
its dominant terms are a Kubernetes round-trip (309 ms) and a fixed settle window
(500 ms) — while `T_batch` grows roughly linearly with `N` once the pools are saturated.
Extrapolating the measured makespan of 82.9 s at N = 96 to production RL rollouts:

| Rollout size | `T_batch` (linear extrapolation) | protocol overhead | makespan overhead |
|---|---|---|---|
| 96 (measured) | 82.9 s | 2.42% | 0.33% |
| 1,024 | ~15 min | 0.21% | 0.03% |
| 8,192 | ~2.0 h | 0.03% | <0.01% |

At production batch sizes the switch is effectively free — which is the necessary
condition for the mechanism to be worth deploying, though as Section 7.5 shows it is not
by itself a sufficient one. We deliberately do not extrapolate a *benefit* to that scale:
the benefit depends on where the bottleneck sits, and the amortization argument only
retires the cost objection.

**In-flight consolidation (S3) — the strongest result, with one honest boundary.**
With the tail regime isolated in phase C, S3 collapses the tail decoders:

- **`C_tail` decode-GPU·s: −26.1 (−44.5%), paired t = −103.9.**
- **Average decode-GPU count: −0.44 (−22.1%), paired t = −94.9.**
- Whole-run decode-GPU·s −25.7 (−18.5%); average total GPUs 4.00 → 3.56.

The per-phase table shows why: in phase C, `static` holds **2.00** decode GPUs busy on
3 stragglers, while `s3_only` consolidates them and releases a decoder to **1.00**.
p95 latency also improves (32.3 → 23.6 s) because consolidation clears the scattered
tail faster. Decode-phase GPU occupancy is directly and significantly lowered — this is
the efficacy result for the tail-waste half of the objective.

**The consolidation evidence chain.** For consolidation the claim has two halves — the
request must survive the move, and the move must actually free a GPU — so we record the
chain end to end rather than a single ratio. All values are 3-run means of `s3_only`
against the same-round `static_2p2d` control:

| Link in the chain | Evidence | `static_2p2d` | `s3_only` |
|---|---|---|---|
| 1. A migration really happened | `s3_migrated_requests` | 0.00 | **1.00** |
| 2. The source decoder drained | `s3_drained_source_count` | 0.00 | **1.00** |
| 3. The migrated request completed | `finish_reason`, tokens | n/a | terminated normally, one continuous client stream |
| 4. The pool actually shrank | `min_spec_decode_replicas` | 2.00 | **1.00** |
| 5. The GPU was freed *early* | `s3_release_lead_time_s` | 0.00 s | **12.23 s** |
| 6. GPU time was actually saved | whole-run `total_gpu_s` | 331.49 | **321.60 (−9.89)** |

Links 4–6 close arithmetically, which is the check that matters: releasing exactly one
decoder 12.23 s before the batch ends predicts a saving of 1 × 12.23 = 12.2 GPU·s, and
the independently integrated occupancy series measures **9.89 GPU·s** — the residual is
the pod-sampling granularity, not an unexplained term. The average decode-GPU count falls
2.000 → 1.891 over the whole run, i.e. the reclaimed GPU is idle for 5.5% of the batch.
In the tail-isolated workload of the earlier suite the same mechanism reaches
2.00 → 1.56 average decode GPUs and −18.5% whole-run decode-GPU·s, because there the
straggler phase does not overlap the dense decode phase and the reclaimed window is
correspondingly longer. **The mechanism's yield is set by how long the drained decoder
can stay released, which is a property of the workload's tail, not of the protocol.**

**Which half of S3 this proves.** The consolidation scenario chains two mechanisms:
*live migration* moves running requests off a decoder, and *idle-release* cordons and
scales down a decoder once it reaches zero active requests. In the suite these numbers
come from, `s3_migrated_requests = 0` in all three runs — the decoders reached zero on
their own and the reclaim came entirely from **idle-release plus scale-down**. So what
the −44.5% proves is that *releasing drained decoders inside a rollout phase reclaims
GPU time*, not that live migration is what reclaimed it. The migration primitive is
proven separately: it is correct in the dedicated micro-benchmark (Section 5,
`path=connector`, 188 ms, 109 blocks), and in the final acceptance suite it fires in
3/3 `s3_only` runs with a measured 12.2 s GPU-release lead. What is *not* yet measured
is the GPU reclaim attributable to migration alone under a tail heavy enough to require
it. Section 8 records this as the first item of future work rather than folding it into
the headline number.

**A migration-fidelity defect found by the final gate (fixed, not re-measured).** The
acceptance suite's fidelity gate compares every `ignore_eos` straggler's finish reason
against `length@max_tokens`. It failed in exactly the runs where a migration occurred:
4 of 4 migrating runs ended their migrated straggler at `finish_reason=stop` after
1557–4578 of 5000 tokens, while 0 of 11 non-migrating runs did. Root cause: the source
snapshotted every sampling field faithfully, but the destination rebuilt `SamplingParams`
from a hand-written 12-name whitelist that omitted `ignore_eos` — so migration silently
changed the request's stopping policy. The two lists are now derived from one source of
truth, and the fix ships in the worker image; re-measuring its effect on the reclaim
numbers is part of the same future-work item. We report the defect rather than the
patched-and-unverified state because a migrated request that stops early would *flatter*
a GPU-saving number.

**Mixed (S2 + S3).** After the fixes, the two primitives compose with **100% valid,
zero side-effects**, and consolidation still fires (phase-C decode-GPU 2.00 → **1.84**;
vs new static −0.07, t = −5.3). The one honest **trade-off**: the S2/S3 desync makes
S3 more conservative (only 1 of 3 runs completed the 2→1 scale-down), so mixed's
average decode-GPU (1.93) is higher than `s3_only`'s (1.56) — correctness was bought
with roughly half the GPU reclaim. This is a real "quality vs. efficiency" trade-off,
recorded rather than hidden. Likely improvement (not re-split this round to save time):
cordon-settle alone may suffice for quality, allowing `STABLE_SAMPLES` back to 1–2 to
recover the full reclaim.

### 7.6 Projection to production RL batch sizes

The 59-request experiment deliberately isolates the mechanism regimes at small scale;
the structure is what generalizes. For a decode pool of `D` decoders where the tail
occupies a fraction `f` of the makespan with per-decoder utilization approaching
`1/D`, consolidation can reclaim up to `((D−1)/D)·f` of decode-GPU-time. At our scale
(`D = 2`, `f ≈ 0.42` from the phase-C share of `T_batch`) this ceiling is ~21% of the
whole run and −44.5% *within* the tail phase — matching the measurement. Two facts
make the production case **stronger**, not weaker: (i) real RL rollouts use much larger
`D`, raising the `(D−1)/D` ceiling toward 1 (a single consolidated decoder can free
many peers); and (ii) RL generations are long and heavy-tailed (`ignore_eos`-like
completions are the norm), enlarging `f`. Meanwhile role switch's fixed ~941 ms cost is
amortized over a phase that lasts tens of seconds to minutes at production batch sizes,
so its *relative* overhead shrinks as the batch grows. Whether it also becomes
*beneficial* at that scale is a separate question this deployment cannot answer: the
switch pays off only where prefill compute is the constraint, and here KV transport is
(Section 7.5). Larger models, larger prompt batches, or an RDMA fabric shift the
constraint toward prefill; that is the regime in which the primitive should be
re-evaluated, and we do not extrapolate a benefit we did not measure.

### 7.7 Validation summary

| Mechanism | Result | Evidence strength |
|---|---|---|
| **S1 topology** | makespan −21.2% (2p2d vs 1p1d); reproduced in all three suites | clean, t = −9.98 |
| **S2 role switch** | correct + lossless (100% valid across 15/15 runs) at **941 ms** per loaded flip | quality strong; **no efficacy** — TTFT within 1% of control, A-phase window 8–16 s longer, in two independent suites |
| **S3 consolidation** | tail decode-GPU·s −44.5%, avg decode-GPU −22% — attributable to **idle-release + scale-down**; migration fires 3/3 with 12.2 s release lead but its own reclaim is unmeasured | efficacy clean (t ≈ −100); attribution bounded |
| **Mixed (S2+S3)** | 100% valid, composable, no side-effects; GPU reclaim halved by desync (trade-off) | quality strong; trade-off explicit |
| **Method** | `business_wall == T_batch` (0 contamination); 8 automated gates, 6 suites rejected before one was analysed | — |

---

## Part 8 — Discussion and Future Work

**What is settled.** Reclaiming drained decoders inside a rollout phase is the clean
win: it lowers decode-phase GPU occupancy by −44.5% in the tail (t ≈ −100), exactly the
intra-phase tail waste the project set out to remove. Topology elasticity (−21%) is the
stable substrate under it. Both role switch and live migration are proven **correct and
lossless** — 15/15 runs at 100% validity, zero 5xx, zero timeouts, with a switch cost of
941 ms that decomposes into named steps.

**What is not settled, stated plainly.** Two claims a reader might expect are absent
because the data does not support them. (i) *Role switch shows no efficacy here.* Its
prefill-queueing benefit is within 1% of the equal-topology control and its phase-A
window is 8–16 s longer, reproduced independently in two suites with different workloads
and phase designs. The cause is measured, not assumed: phase A is bounded by KV
transport on a fabric without RDMA, so moving a decoder into prefill adds capacity away
from the actual constraint. (ii) *The −44.5% is attributable to idle-release, not to
live migration* — the runs producing it performed zero migrations. Migration is proven
correct, and proven to fire, but the GPU time attributable to migration alone remains
unmeasured. Reporting these as wins would have been the easy path and the wrong one.

**The switch-cost floor, and what is still tunable.** Table 7.5-A separates the three
kinds of cost. `register_mdc` (~309 ms, a Kubernetes `apply` round-trip) is a genuine
control-plane floor — the CR must be written and observed. The engine steps (~115 ms)
are already negligible. The drain + settle window (~502 ms) is the only large term that
is *policy*, and this round showed it is compressible: 3.0 s → 0.5 s with validity
unchanged, once the dispatcher holds switch-window arrivals instead of relying on the
window to out-wait the router. A deterministic frontend routing-epoch ACK would remove
the residual heuristic entirely (Future Work). The outbound-KV drain is load-dependent
and irreducible in principle: it is the peer's transfer, not ours, and cutting it short
would trade losslessness for latency.

**The transfer-path caveat.** The connector path is verified fast when KVBM is exposed;
the GPU-reclaim efficacy does not depend on it. Exposing the KVBM index by default
(upstream vLLM cooperation) would make the connector the common path and cut
per-migration latency.

**Future work.** (1) **Isolate migration's own GPU reclaim** — re-run the tail scenario
with the fidelity fix in place and a tail heavy enough that decoders cannot drain on
their own, so the saving attributable to live migration is separated from idle-release.
(2) **Re-evaluate role switch where prefill is the constraint** — a larger model, a
larger prompt batch, or an RDMA fabric; on this cluster the primitive is correct but
inert. (3) Move the outbound-KV wait out of the switch's critical path into a
pre-cordon precondition with controller retry, so a switch issued while a peer is
mid-pull defers by a tick instead of blocking (measured worst case 9.1 s vs. a 941 ms
median). (4) Replace the settle heuristic with a deterministic frontend routing-epoch
ACK. (5) Close the loop: drive `switch_role` / `migrate` from a real GRPO rollout signal
instead of a harness. (6) Multi-engine support (SGLang, TRT-LLM).

---

## References

Splitwise (ISCA'24), DistServe (OSDI'24), NVIDIA Dynamo, vLLM/PagedAttention (SOSP'23),
NIXL, LMCache, Mooncake (FAST'25), ServerlessLLM (OSDI'24), SpotServe (ASPLOS'24). Full
citations in `final-report.lex`.

## Reproducibility

Merged dataset: `test-scripts/reports/FINAL-phased-merged-20260720/` (raw per-run
logs included; workload-manifest identity verified across all five sources).

```
python test-scripts/aggregate_final_dataset.py reports/FINAL-phased-merged-20260720 \
  baseline_1p1d=reports/phased-5scenario-20260720-165132 \
  static_2p2d=reports/phased-5scenario-20260720-165132 \
  s3_only=reports/phased-5scenario-20260720-165132 \
  s2_only=reports/phased-fix-s2mixed-20260720-213359 \
  mixed=reports/phased-fix-s2mixed-20260720-213359
```
