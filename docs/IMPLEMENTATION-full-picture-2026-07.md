# RL-Scaling on NVIDIA Dynamo — Full Implementation & Architecture (current state, 2026-07)

> Companion to the existing `docs/` set. This document is a **from-the-codebase, current-state** full picture intended as the foundation of the final technical report. It does not replace `RL-Scaling-Dynamo-technical-architecture-zh.md`, `TECH-REPORT-architecture-and-implementation(.md/-zh.md)`, `test-strategy.md`, `S2-pd-role-switch-defect-analysis-zh.md`, or the midterm report — it consolidates them, corrects a few values that drifted from the code, and folds in the July-2026 end-to-end performance evaluation and the fixes made during it.
>
> Verified against the tree at repo state: worker `dynamo/components/src/dynamo/vllm/` (dual_mode 574L, migration 508L, rl_scaling_sidecar 609L, handlers 1702L, main 1439L); controller `RL-Scaling/rl-scaling-controller/src/rl_scaling_controller/` (state_machine 198L, capacity_planner 74L, dgdsa_client 198L, metrics_collector 308L, role_switch/controller 303L, consolidation/controller 216L + decision_engine 97L). Deployed images: worker `rl-scaling-3fc3e8fe6f-nixlfix`, controller `drainfix-1`.

---

## 1. Problem, goals, and the three scaling layers

RL post-training (RLHF / DPO / GRPO) drives inference in **phases**: a prefill-heavy sampling burst → a long decode phase → a sparse long-tail of a few slow completions → then the GPUs should be freed for training or the next rollout. Static prefill/decode (PD) partitioning wastes GPU-hours at every phase boundary (one pool idle while the other is the bottleneck), and horizontal pod scaling reacts in tens of seconds — too slow to act *inside* one rollout phase, and it throws away the prefix cache.

Formal targets (from the midterm):

- minimize batch completion time `T_batch = max_r T_complete(r)`
- minimize `GPU_hours = Σ_g T_allocated(g)`
- maximize GPU utilization `U_GPU = Σ_g T_compute(g) / Σ_g T_allocated(g)`

The lever is `U_GPU`: re-role idle GPUs into the bottleneck phase, and consolidate tail decode work onto fewer GPUs, both in **sub-second** control time. Three layers:

| Layer | Name | Acts on | Goal |
|---|---|---|---|
| **S1** | Rollout-driven Auto Scaling | K8s / DGDSA replicas | pre-warm & reclaim prefill/decode pods on RL signal |
| **S2** | Elastic PD Role Switch | a single vLLM worker's prefill/decode role | in-place hand idle capacity to the bottleneck role, no pod/engine rebuild |
| **S3** | Request Consolidation | in-flight decode requests | migrate long-tail requests onto fewer decoders, drain & release a GPU |

S1 changes **replica count**, S2 changes **worker role**, S3 changes **request placement**.

---

## 2. Deployment topology & port model

```
┌───────────────────────────── Kubernetes (single node gpu14, ns dynamo-system) ─────────────────────────────┐
│ CRDs: DynamoGraphDeployment (DGD) │ DynamoComponentDeployment │ DynamoWorkerMetadata (DWMD, 1 / worker pod)  │
│ Operator: dynamo-platform-…-controller-manager  → HELD AT 0 REPLICAS (tests own the Deployments directly)   │
└───────▲──────────────────────────────────────────────────────────────────────────▲─────────────────────────┘
        │ apply / watch DWMD                                                         │ patch Deployment scale
┌───────┴───────────────┐        ┌──────────────────────────────────┐     ┌─────────┴──────────────────────────┐
│ Frontend pod          │ watch  │ Worker pod (dual-mode)           │     │ RL-Scaling controller (ns: dynamo)  │
│  HTTP :8000 (OpenAI)  │◄─DWMD──┤  Dynamo runtime (Rust)           │     │  control loop: S3 → S2 → S1         │
│  ModelWatcher         │        │   ONE TCP slot: ip:<port>/{cid}/ │     │  reads Prometheus + sidecars        │
│   → WorkerSet         │        │     generate                     │     │  patches decode/prefill Deployments │
│   → KvRouter          │        │  vLLM (kv_both + NIXL + KVBM)    │     │  calls sidecar /switch_role,/migrate│
│   → PrefillRouter     │        │  :9090 system/Prometheus         │     │  K8S_SCALE_FALLBACK_ENABLED=true    │
└──────────┬────────────┘        │  :9091 RL-Scaling sidecar        │     └─────────────────────────────────────┘
           │ chosen slot URL     │       /switch_role /migrate       │
           ▼  (read from DWMD)   │       /v1/role /v1/active_requests│
    generate ───────────────────┼──►  ← control plane, not data path│
                                 └──────────────────────────────────┘
```

**Port/role invariant (most error-prone point):** a worker's role is encoded in the **published ModelCard**, not in a listening port. One pod = one engine = **one** TCP `generate` slot; a decode ModelCard and a prefill ModelCard take turns owning that same slot.

| Service | Port | Purpose |
|---|---|---|
| Frontend HTTP | `:8000` | OpenAI chat/completions intake |
| Request-serving slot | **dynamic** TCP, advertised in `DWMD.endpoints[…].transport.tcp = ip:port/{cid:x}/generate` | the actual `generate` endpoint routers connect to |
| System/Prometheus | `:9090` | worker metrics/health (not serving) |
| RL-Scaling sidecar | `:9091` | control plane: `/switch_role`, `/migrate*`, `/v1/role`, `/v1/active_requests` (not serving) |

**Operational invariant learned the hard way (2026-07):** the Dynamo **operator must be at 0 replicas**. If it runs, it reconciles each worker Deployment back to the DGD's declared `replicas` within ~8 s, silently reverting every controller/test scale-up (warmup then hangs at 1P1D). Tests manage the worker Deployments directly; the operator is only scaled to 1 transiently for DGD create/delete.

---

## 3. Discovery & request path (why role = ModelCard)

With `DYN_DISCOVERY_BACKEND=kubernetes`, each worker pod owns a **DWMD CR**; `spec.data.model_cards` *is* the worker's role registration. The frontend `ModelWatcher` `list+watch`es DWMDs to rebuild the WorkerSet. There is no etcd, no central registry, no Service on the chat path — membership is DWMD.

A chat request: `POST /v1/chat/completions` → `PrefillRouter` picks a prefill-role worker, gets back `kv_transfer_params` → `KvRouter` scores decoders by radix-tree prefix overlap + queue load + KV capacity (`softmax_sample`, argmin at temp 0) → frontend connects to the chosen worker's TCP slot (URL from DWMD) → worker `generate` handler runs vLLM, pulling prefill KV via NIXL when `kv_transfer_params` is present → tokens stream back as SSE.

S2 and S3 mutate **only** worker-side state and the worker's own DWMD; the router path is unchanged — it merely observes a different WorkerSet after each action.

---

## 4. S1 — Rollout-driven Auto Scaling (`state_machine.py`, `capacity_planner.py`)

State machine `IDLE → WARM_UP → ACTIVE → COOL_DOWN → IDLE`:

- `on_sampling_progress(progress, batch_meta)`: **only from IDLE**, if `progress ≥ PRE_WARM_THRESHOLD`, `CapacityPlanner.compute(batch_meta)` derives target `(prefill, decode)` replicas → `_scale_to(target)` patches the DGDSA/Deployment → `WARM_UP`.
- `control_loop_tick`: `WARM_UP → ACTIVE` once ready worker counts reach the target; `COOL_DOWN → IDLE` scales prefill+decode to 0 once `COOLDOWN_SECONDS` elapsed **and** in-flight drained (or `DRAIN_TIMEOUT_SECONDS` forces it).
- `CapacityPlanner` inputs: batch size, avg ISL, total prompt tokens, `SINGLE_PREFILL_TPS`, `TARGET_PREFILL_SECONDS`, `MAX_CONCURRENT_PER_DECODE`, `MAX_GPUS`, `MIN_{PREFILL,DECODE}_REPLICAS`.

The scaler (`K8sDGDSAClient`) can either patch the DGDSA custom object (needs the operator) or, with `K8S_SCALE_FALLBACK_ENABLED=true` (the mode used here), patch the Deployment `spec.replicas` **directly** — which is why the operator must be at 0.

> Note: the `on_sampling_progress`-only-from-IDLE rule means autonomous pre-warm can miss if the controller is not IDLE when the signal arrives; the test harness therefore also *forces* the 2P2D topology via the deployment scaler as a fallback (`warmup_forcing_topology`). Pre-warm-scaling reliability is not what S2/S3 measures; the scenarios only need to start at 2P2D.

---

## 5. S2 — Elastic PD Role Switch

### 5.1 Worker protocol (`dual_mode.py::DualModeWorker.switch_role`, 8 steps, per-worker async lock)

1. **sleep** — `registry.pause_generation()` (reject new submits) + `engine.sleep(level=2)` (free GPU KV blocks)
2. **unregister_mdc** — remove current-role ModelCard from DWMD (starts the frontend-watcher convergence timer early)
3. **reconfig_nixl** — drop cached NIXL connector for lazy re-init under the new role
4. **reset_prefix_cache** — `engine.reset_prefix_cache()` **while asleep** (the index holds block-IDs `sleep(2)` returned to the allocator; resetting after wake risks a stale hit)
5. **set_disaggregation_mode** — `handler.current_role = target`
6. **register_mdc** — publish the new-role ModelCard into DWMD
7. **wake** — `engine.wake_up()` + `registry.resume_generation()`
8. **emit_role_changed** — best-effort patch pod label `nvidia.com/dynamo-current-role`

Ordering constraints that make it safe: pause before unpublish; unregister (2) before cache-reset (4); reset cache inside the sleep window before wake; publish new ModelCard (6) only after the engine is in a consistent target state.

`kv_role=kv_both` is load-bearing: `kv_transfer_config` is fixed at engine construction, so the engine is built knowing both roles from boot; the "switch" is a DWMD registration change + an engine sleep/reset/wake cycle, never an engine rebuild.

**Partner-prefill** (`DYNAMO_RL_DUAL_PARTNER_PREFILL=1`, `main.py`): after D→P the pod is a first-class prefill worker. One TCP `{cid}/generate` slot is shared by both ModelCards; a request-time dispatcher routes on `current_role`. `_partner_prefill_generate` merges vLLM's multi-chunk output so `kv_transfer_params` (published by NIXL only on the last chunk) is visible on chunk #1, which is where the Rust `PrefillRouter` reads it.

### 5.2 Controller trigger (`role_switch/controller.py`)

- D→P: `prefill_queue_depth ≥ PREFILL_QUEUE_THRESHOLD` **and** `decode_util ≤ DECODE_IDLE_THRESHOLD` **and** `decode_count > MIN_DECODE_REPLICAS` **and** `since_last_switch ≥ MIN_SWITCH_INTERVAL`; picks the decode worker with the fewest in-flight.
- P→D: symmetric on `decode_queue_depth ≥ DECODE_QUEUE_THRESHOLD` **and** `prefill_util ≤ PREFILL_IDLE_THRESHOLD`. This is driven by **real decode-queue pressure**, which is why the P→D switch-back lands during the tail (when the long stragglers create sustained decode load with idle prefill), not before it.

### 5.3 Cost (midterm mechanism run): D→P 453 ms server / 497 ms wall; P→D 428 / 466 ms; round-trip 963 ms. `register_mdc` (~327 ms, a K8s apply round-trip) dominates; engine-side `sleep+wake ≈ 90 ms`. In the July four-scenario runs, controller-observed switch latencies were ~0.4–0.5 s each.

---

## 6. S3 — In-Flight Request Consolidation

### 6.1 Per-worker request registry (`handlers.py` + `rl_scaling_sidecar.py::InProcessRequestRegistry`)

Updated at three hooks: `register` (submit: prompt_tokens, sampling_params, t0), `record_tokens` (each streaming delta: extend generated_tokens), `deregister` (complete/abort/error). Exposed as `GET /v1/active_requests`, returning per-request **token progress** (`generated_tokens`, `max_tokens`, `remaining_tokens`) via `active_progress()` — the telemetry the controller's cost/benefit gate and the test's straggler detection rely on.

### 6.2 Three-phase block-hold protocol (`migration.py`)

`POST /migrate {request_id, target_url}` orchestrates:

1. **migrate_out** (source): pin R's KV blocks, register R in `_pending_migrations`, collect `(src_block_ids, kv_transfer_params, sampling_params, previously_emitted_tokens)`, **do NOT abort R**. `request_id="*"` → `_pick_most_progressed` selects the largest-`generated_tokens` request.
2. **migrate_in** (target): cost-benefit gate `_should_migrate` (`max_replay_tokens=8192`, `min_generated_tokens=16`, `min_remaining_tokens=32`); if accepted, submit R′.
   - **connector path** (`DYNAMO_RL_CONNECTOR_ENABLED=1` + KVBM block IDs + NIXL metadata available): inject `kv_transfer_params (do_remote_prefill=true, remote_engine_id, remote_block_ids, remote_host/port)`; `NixlConnectorScheduler` issues an RDMA READ pulling KV from the source GPU; decode resumes from `previously_emitted_tokens+1`. Response `path:"connector"`.
   - **recompute path** (fallback): `replay_prompt = prompt_tokens + generated_tokens` is re-prefilled on the target, then decode continues. Mathematically equivalent to R having run on the target from the start, paying one extra prefill (mostly the uncached suffix under prefix caching). Response `path:"recompute"`.
3. **migration_complete** (source): abort R, unpin blocks, remove from `_pending_migrations`. On target decline/error → **migration_rollback** (R keeps running on the source). A `sweep_stale_migrations` task force-completes pending entries older than `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` to prevent block leaks.

**At-least-one-copy invariant:** R's KV lives on ≥1 GPU at every instant; a crash between `migrate_in` ok and `migration_complete` degrades to at-most-once duplicate emission, never KV loss.

> **Connector vs recompute — the honest current state.** The **connector (NIXL RDMA-pull)** path is implemented and was validated in the midterm (188 ms, 109 physical blocks, `path:"connector"`, no re-prefill). The **July four-scenario performance runs took the recompute path** (`path:"recompute"`): this single-node deployment does not expose cross-pod RDMA to the pods (no `/dev/infiniband`, per-pod 1-GPU isolation blocks cross-pod `cuda_ipc`, flannel overlay), and KVBM block-ID exposure was not wired in this image. Recompute is correct and KV-loss-free; it just pays a re-prefill of already-generated tokens on the destination (which is why a migrated `ignore_eos` straggler stops at natural EOS — see §9).

### 6.3 Decision engine (`consolidation/decision_engine.py`) & controller (`consolidation/controller.py`)

`evaluate(decode_workers, batch_completion_pct)` gates: `consolidation_enabled`; `batch_completion_pct ≥ MIN_BATCH_COMPLETION`; `len(decode) > MIN_DECODE_REPLICAS`. Two-pointer over workers sorted by in-flight: **source** = lowest in-flight (must be `0 < in_flight ≤ CONSOLIDATION_THRESHOLD`), **target** = most spare capacity (`available_capacity ≥ src.in_flight`); `_is_worth_migrating` requires `migration_time < 0.5 × estimated_remaining_time`.

Controller tick: migrate `request_count` requests source→target; `_wait_for_drained_sources` confirms the source reaches 0 in-flight; then release a GPU by scaling decode down by the drained count (floored at `MIN_DECODE_REPLICAS`).

**Scale-down correctness fix (2026-07, controller `drainfix-1`):** scaling a Deployment `2→1` only sets the replica count — **Kubernetes picks which pod to terminate**. Without a hint it can evict a *busy* decoder (observed in mixed, where S2's P→D reshuffles decode ownership) and kill in-flight long-tail requests with `Backend.EngineShutdown`. Fix: before scaling down, the controller stamps `controller.kubernetes.io/pod-deletion-cost=-1000000` on the **drained** pod (`K8sDGDSAClient.prefer_delete` via `CoreV1Api`; needs `pods: patch` RBAC, added to `deploy/manifests/01-rbac.yaml`), so K8s evicts exactly that empty pod. Result: mixed went 88% → 100% valid.

---

## 7. Controller closed loop (`main.py`, `metrics_collector.py`)

Each tick (`CONTROL_LOOP_INTERVAL`, 1 s in tests): **S3 → S2 → S1** (drain the tail first to create low-cost re-role candidates; then rebalance roles; then coarse replica lifecycle). `PrometheusMetricsCollector`: reads queue/util from Prometheus; discovers prefill/decode pods by K8s label; probes each sidecar `/v1/role` and `/v1/active_requests`; estimates `available_capacity = MAX_CONCURRENT_PER_DECODE − active` and `estimated_remaining_time` from token progress; falls back to worker active-requests when Prometheus queue metrics are empty. `switch_capable` requires `dual_mode_capable` (only the dual-mode decode workers), excluding native prefill workers from S2 targeting.

---

## 8. Measurement methodology (corrected, 2026-07)

The four-scenario harness (`test-scripts/run_four_scenario_strategy_e2e.py`) runs each scenario as `prefill_burst → balanced_decode → decode_tail` at a fixed workload (105 requests: 64 prefill `max_tokens=4`; 24 balanced `max_tokens=96`; tail = 8×16 + 6×32 + **3 long stragglers** `ignore_eos, max_tokens=8000`, launched 0/4/8 s apart so the KV router spreads them so a source holds exactly 1 → S3 can find a valid migration source).

`wall_s` (first-request→last-request) bundles ~100 s of **test-harness orchestration** (inter-phase readiness probes + topology-flip verification) for S2/mixed. To measure the true post-warmup cost, the summary now emits:

- **`serving_wall_s`** = Σ phase walls (pure request serving; excludes warmup + inter-phase orchestration)
- **`serving_gpu_s`**, **`serving_tokens_per_gpu_s`**, **`serving_requests_per_gpu_s`**
- **`s2_switch_total_ms`** (S2 action cost), **`orchestration_overhead_s`** (the excluded scaffolding), plus **`tail_decode_gpu_s_saved`** (S3's decode-GPU-seconds reclaimed vs a 2-decoder counterfactual)

**Fair comparators:** S2 → `serving_wall`/`prefill_wall`; S3 → `tail_decode_gpu_s_saved`/ready-worker drop; cost → switch/consolidation action latency. **Do not** compare whole `wall_s` (orchestration-dominated) or `tokens_per_gpu_s` (confounded by migration changing output *and* by the 2× topology) across scenarios.

---

## 9. End-to-end evaluation results (clean run `strategy-four-scenario-20260714-152929`, all 0 timeouts)

| scenario | serving_wall (s) | vs base | valid% | prefill (s) | tail (s) | S2 switch | S3 migrated / scaled | tail decode GPU·s saved |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline (1P1D) | 91.1 | 0% | 100 | 34.4 | 46.4 | — | — | — |
| **s2_only** (2P2D) | **67.6** | **−26%** | 99.0 | **22.1** | 37.4 | 2× ≈1.0 s | — | — |
| **s3_only** (2P2D) | **64.4** | **−29%** | 100 | 20.5 | 37.1 | — | 1 / 2→1 | **11.3 (15%)** |
| **mixed** (2P2D) | **73.5** | **−19%** | **100** | 16.7 | 49.5 | 2× ≈0.9 s | 1 / 2→1 | **21.5 (22%)** |

- **S2 value = time**: D→P borrows an idle decode GPU as a 3rd prefill worker → prefill −36%, serving wall −26%; switch cost ~1 s (≈23× ROI).
- **S3 value = GPU**: consolidation migrates a straggler, drains the source, scales decode 2→1 (a GPU physically released; mixed tail avg ready workers 4.00→3.70, min 3); control action ~180 ms (decision 20 ms + mark-pod 77 ms + scale); no quality loss (migrated request resumes via recompute).
- **mixed** gets both, now **100% valid** after the drain fix — fastest prefill (16.7 s) *and* highest GPU saving (22%).

**Known, documented follow-ups this run surfaced:** (1) S2 loses ~1 of 64 requests at the exact D→P switch instant (s2 99%) — a switch-fidelity edge; (2) migration recompute drops `ignore_eos`, so a migrated straggler stops at natural EOS (makes token counts differ across scenarios — the reason `completion_tps`/`tokens_per_gpu_s` are not cross-scenario comparable).

---

## 10. Invariants & current boundaries

**Invariants:** router never sends old-role traffic to a switched worker (unregister-first); new role exposed only after engine-state-consistent (register-last); prefix cache never references freed blocks (reset-while-asleep); migration never silently drops a request (complete/rollback + block-hold); connector path never reads freed blocks (held to `migration_complete`); no role driven to 0 (`MIN_*_REPLICAS`); no S2 thrash (`MIN_SWITCH_INTERVAL`); no S3 on single-sample noise (`CONSOLIDATION_STABLE_SAMPLES`); **scale-down evicts the drained pod, not a busy one** (`pod-deletion-cost`).

**Boundaries:** single-node, no cross-pod RDMA → S3 uses the recompute path in the perf runs (connector path validated separately in the midterm); operator must be at 0; `estimated_remaining_time` is heuristic; GPU-seconds are allocation-based (ready-worker × time), not DCGM-integrated compute-busy; the RL-Signal SDK exists but the perf runs drive phase signals from the harness rather than a live GRPO loop.

---

## 11. Key config (defaults in `config.py`; four-scenario overrides in `scenario_env`)

Controller: `CONTROL_LOOP_INTERVAL`, `PRE_WARM_THRESHOLD`, `MAX_GPUS`, `MIN_{PREFILL,DECODE}_REPLICAS`, `MAX_CONCURRENT_PER_DECODE`, `K8S_SCALE_FALLBACK_ENABLED=true`; S2: `ROLE_SWITCH_ENABLED`, `{PREFILL,DECODE}_QUEUE_THRESHOLD`, `{DECODE,PREFILL}_IDLE_THRESHOLD`, `MIN_SWITCH_INTERVAL`; S3: `CONSOLIDATION_ENABLED`, `CONSOLIDATION_SCALE_DOWN_ENABLED`, `CONSOLIDATION_THRESHOLD` (test=1), `MIN_BATCH_COMPLETION` (test=0.92), `CONSOLIDATION_{STABLE_SAMPLES,MIN_INTERVAL}`, `PER_REQUEST_MIGRATION_OVERHEAD`.
Worker: `DYNAMO_RL_DUAL_MODE=1`, `DYNAMO_RL_SIDECAR_PORT=9091`, `DYNAMO_RL_DUAL_PARTNER_PREFILL=1`, `DYNAMO_RL_CONNECTOR_ENABLED=1`, `VLLM_ALLOW_INSECURE_SERIALIZATION=1`, `UCX_RCACHE_MAX_UNRELEASED=1024`, `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT`.

---

## 12. One-line summary

`S1 changes replicas · S2 changes worker role · S3 changes request placement` — a controller that reshapes the prefill/decode split in lockstep with RL phases, closing the loop over Prometheus metrics + K8s (DWMD) discovery + worker sidecars + vLLM engine state + NIXL/KVBM, with sub-second control actions and (measured) −26% serving wall from S2 and a reclaimed decode GPU (15–22% tail decode-GPU-seconds) from S3.
