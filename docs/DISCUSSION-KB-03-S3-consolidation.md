# Discussion KB 03 — S3 In-Flight Request Consolidation: implementation deep dive

> Knowledge base from the 2026-07-14 walkthrough. Key questions, key steps, key Q&A — not a full spec.
> Series: KB-01 = resource model + S1 · KB-02 = S2 `switch_role` · **KB-03 = S3 consolidation**.
> Companions: `IMPLEMENTATION-full-picture-2026-07.md`, `MASTERS-EVALUATION-2026-07.md`.
>
> **⚠ This KB contains two newly-found correctness gaps (§6) discovered by reading the code during this walkthrough. They do not invalidate the measured GPU-saving result, but they DO bound what S3 can claim about transparency.**

---

## 1. Code organization — same two-sided split as S2

**Controller side — `rl_scaling_controller/consolidation/`** (the *decision* layer):

| file | role |
|---|---|
| `decision_engine.py` (97 L) | **Pure function**: `evaluate(decode_workers, batch_completion_pct) → [MigrationPair]`. No I/O. Two-pointer source/target pairing + cost gate. |
| `controller.py` (216 L) | Orchestrates a tick: evaluate → migrate → wait-for-drain → scale down |
| `migration_client.py` | Thin httpx wrapper: `POST {source}/migrate {request_id, target_url}` |

**Worker side — `dynamo/components/src/dynamo/vllm/`** (the *execution* layer):

| file | role |
|---|---|
| `migration.py` (508 L) | `MigrationHandler`: `migrate_out / migrate_in / migration_complete / migration_rollback / sweep_stale_migrations` |
| `rl_scaling_sidecar.py` | `InProcessRequestRegistry` + HTTP surface (`/migrate*`, `/v1/active_requests`) |
| `handlers.py` | Registry hooks: `register` / `record_tokens` / `deregister` |
| `main.py` | Wires `MigrationHandler(block_index=RequestBlockIndex(kvbm_cm), nixl_meta_provider=…, connector_enabled=…)` |

Same principle as S2: **the controller decides *who moves where*; the worker decides *how to move it safely*.**

---

## 2. The three-phase block-hold protocol

```
Orchestrator            D_src                              D_dst
     │  POST /migrate_out │                                  │
     ├───────────────────►│ ① BLOCK-HOLD                     │
     │                    │   • lookup src_block_ids FIRST   │
     │                    │     (KVBM frees on abort!)       │
     │                    │   • _pending_migrations[rid]=now  │
     │                    │   • do NOT abort R               │
     │◄───────────────────┤ {prompt_tokens, generated_tokens,│
     │                    │  sampling_params, src_block_ids?, │
     │                    │  kv_transfer_params?}            │
     │      POST /migrate_in (that body)                     │
     ├──────────────────────────────────────────────────────►│ ② cost gate → submit R′
     │                                                        │   connector: NIXL READ pull
     │◄──────────────────────────────────────────────────────┤   recompute: re-prefill
     │                    │        {status, path, replay_tokens}
     │  POST /migration_complete                              │
     ├───────────────────►│ ③ RELEASE: abort R, unpin blocks │
     │◄───────────────────┤ {status: ok}                     │
   (on decline/error → POST /migration_rollback: release hold, R keeps running)
```

**Key implementation details actually in the code:**
- **`src_block_ids` lookup happens *before* any abort** — comment: *"KVBM frees blocks synchronously on abort, so the lookup must happen first."*
- **`use_block_hold = self._connector_enabled`** — block-hold is enabled by the connector flag **regardless of whether KV transfer is available**. So even on the recompute path we still get rollback safety.
- **`use_kv_transfer = connector_enabled AND src_block_ids is not None AND nixl_coords is not None`** — all three required for the NIXL path.
- **`request_id="*"`** → `_pick_most_progressed` over active IDs *excluding already-held ones*.
- **Sweeper** (`sweep_stale_migrations`) force-aborts holds older than `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` (default 10 s) → no block leak if the orchestrator dies.

**At-least-one-copy invariant** — R's KV exists on ≥1 GPU at every instant. Worst case (orchestrator crashes after `migrate_in` ok, before `migration_complete`) degrades to *at-most-once duplicate emission*, never KV loss. Why 3 phases can't collapse to 2: if `D_src` aborts first, its blocks may be reused before `D_dst`'s NIXL READ completes → **silent corruption**.

---

## 3. Decision layer

`decision_engine.evaluate()` gates, in order:
```
consolidation_enabled
batch_completion_pct >= MIN_BATCH_COMPLETION          (test: 0.92)
len(decode_workers)  >  MIN_DECODE_REPLICAS           (floor guard)
── two-pointer over workers sorted by in_flight ──
source = lowest in_flight,  must be 0 < in_flight <= CONSOLIDATION_THRESHOLD   (test: 1)
target = most spare capacity, needs available_capacity >= src.in_flight
_is_worth_migrating: migration_time < 0.5 × src.estimated_remaining_time
```
`controller.py` tick: migrate `request_count` requests → `_wait_for_drained_sources()` (poll until source in_flight==0, bounded by `CONSOLIDATION_DRAIN_TIMEOUT`) → **then** scale down.

**Destination-side cost gate** (`MigrationPolicy`, applied in `migrate_in` *before* committing engine state):
| knob | default | rationale (from the docstring) |
|---|---:|---|
| `max_replay_tokens` | 8192 | above this the recompute prefill exceeds ~200 ms even with cache hits |
| `min_generated_tokens` | 16 | too young — nothing saved |
| `min_remaining_tokens` | 32 | too old — finishes faster than the migration round-trip |
Declined → `{"status":"declined","reason":…}`. **Declined is a normal outcome, not a failure** — the source keeps running the request.

---

## 4. The scale-down fix (`pod-deletion-cost`)

Scaling a Deployment `2→1` **only sets a replica count — Kubernetes picks the victim pod.** Without a hint it can evict a *busy* decoder (in mixed, S2's P→D reshuffles decode ownership), killing in-flight long-tail requests with `Backend.EngineShutdown` 500 → mixed was **88% valid**.

**Fix** (controller `drainfix-1`): before scaling down, stamp the **drained** pod:
```python
controller.kubernetes.io/pod-deletion-cost = "-1000000"   # K8sDGDSAClient.prefer_delete via CoreV1Api
```
so the ReplicaSet controller evicts *that* (empty) pod first. Requires `pods: patch` RBAC (added to `deploy/manifests/01-rbac.yaml`). **Result: mixed 88% → 100% valid.**
Measured control action (mixed): `decision → migrate(20 ms) → mark pod(77 ms) → scale` ≈ **183 ms**.

---

## 5. Connector vs recompute — **why our runs took recompute** (precise root cause)

Not (only) the RDMA story. The chain in `main.py`:
```python
kvbm_cm = getattr(engine_client.engine_core, "kv_cache_manager", None)   # "best-effort"
migration_handler = MigrationHandler(..., block_index=RequestBlockIndex(kvbm_cm), ...)
```
In vLLM v1 the **EngineCore runs in a separate process**; `AsyncLLM.engine_core` is a client handle (`MPClient`) that has **no `kv_cache_manager` attribute** → `kvbm_cm = None` → `RequestBlockIndex.lookup()` returns `None` → `use_kv_transfer = False` → `migrate_out` omits `kv_transfer_params` → `migrate_in` takes **`path:"recompute"`**.

**Confirmed by the observed wire data**: our `/migrate` response contained **no `src_block_ids` and no `kv_transfer_params`**, and `migrate_in` reported `"path": "recompute"`.

The midterm's connector proof (188 ms, 109 blocks, `path:"connector"`) relied on a **`dynamo-block-bridge` ConfigMap overlay** that injected a KVBM bridge across that process boundary — an overlay we **deliberately removed** when moving to a clean, properly-built image. So:

> **The connector path is implemented and was proven once (midterm, with the bridge overlay). The current clean image cannot take it, because the block bridge is not part of the built image.** Cross-pod RDMA absence is a *second, independent* limitation.

---

## 6. ⚠ Two fidelity bugs found by reading the code (NEW)

Both live in the same registry-register block, `handlers.py` ~L1247–1260.

### 6.1 `ignore_eos` (and any param outside the whitelist) is silently dropped
```python
sp_dict = {}
for k in ("temperature", "top_p", "top_k", "max_tokens", "min_tokens",
          "presence_penalty", "frequency_penalty", "repetition_penalty",
          "stop", "stop_token_ids", "seed", "n"):        # ← no ignore_eos
    v = getattr(sampling_params, k, None)
    if v is not None: sp_dict[k] = v
registry.register(request_id, prompt_tokens_for_reg, sp_dict, stop_conditions={})
```
**This is the exact root cause** of the "migrated straggler stops at natural EOS" effect: the whitelist is a *closed list of 12 params*; `ignore_eos` isn't in it, so it never reaches `migrate_out`'s `sampling_params`, so the destination submits without it. Observed: migrated stragglers flip `finish_reason` `length → stop` (s3: 8000→3510; mixed: 8000→5965).
**Any** sampling param outside the 12 is lost the same way (`logprobs`, `bad_words`, `guided_*`, …).

### 6.2 `prompt_tokens` is empty in the disagg decode path → **the migrated request loses its prompt**
```python
prompt_tokens_for_reg = list(getattr(prompt, "prompt_token_ids", []) or [])
```
In our runs this yields `[]` — confirmed twice: `/v1/active_requests` reports `"prompt_tokens": 0`, and the `migrate_out` response carried `"prompt_tokens": []`.

Consequence, since `migrate_in` computes:
```python
replay_prompt = list(body["prompt_tokens"]) + list(body["generated_tokens"])
              = []                          + [3449 generated tokens]
```
→ the destination re-prefills **only the generated tokens** and the **original user prompt is not in the replayed context**. The migrated request continues conditioned on its own output alone.

**Why plausibly unnoticed:** for a long straggler the prompt is a tiny fraction (7 tokens vs 3449), so the continuation still *looks* fluent and scores `valid_decode=true` (`finish_reason ∈ {stop,length}`, tokens>0). Our quality gate cannot detect it.

### 6.3 Impact assessment (be precise in the report)
| Claim | Affected? |
|---|---|
| migrate → drain → **decode scaled 2→1 → GPU released** | ❌ **not affected** — measured result stands |
| tail decode-GPU-seconds saved (15% / 22%), control latency ~183 ms | ❌ not affected |
| 0 timeouts, source drains, rollback safety, no block leak | ❌ not affected |
| **"migration is transparent / semantically equivalent to running on the source"** | ✅ **AFFECTED — cannot be claimed in the current build** |
| Cross-scenario `completion_tokens` comparability | ✅ affected (this is *why* the token counts differ) |

**So: S3's resource-management claim is sound and measured; S3's transparent-continuation claim is not met in this build.** The midterm's stronger claim ("client SSE stream contained the original 1688 tokens seamlessly followed by D2's continuation") held for the *connector* path with the bridge — it should **not** be generalized to the current recompute build.

---

## 7. Test strategy — what it actually proves

**Design of the tail workload** (this took several iterations and is worth recording):
- The model hits EOS after ~1–2k tokens and decodes at ~2000 tok/s, so an ordinary `max_tokens=48` request finishes in ~0.02 s and is **never in-flight when the controller polls** → *this is why every early run showed `migrated=0`* — a workload artefact, not a broken mechanism.
- Fix: `ignore_eos=true` + `max_tokens=8000` → a genuine straggler in-flight ~50–80 s.
- Second fix: **launch stagger 0/4/8 s**, so the KV router spreads the 3 stragglers (a 3+0 split leaves no source with `in_flight==1` → the gate can never fire). With stagger → 2+1 split → valid source.
- `max_tokens` sizing matters: 30000 caused a 219 s tail (within 20 s of the timeout) and KV thrash; 8000 gives ~37–50 s with margin.

**Evidence obtained (clean run `…20260714-152929`):**

| proof point | evidence |
|---|---|
| straggler exists & is migratable | `/v1/active_requests` shows real token progress (`generated_tokens`, `remaining_tokens`) |
| decision is autonomous | controller log: `decision: completion=0.920>=0.920 source_active=1 target_capacity=62 request_count=1` |
| protocol succeeds | `executed: … migrated=1`; `/migrate` returns `migrate_out/migrate_in/migration_complete` all ok |
| source drains | `_wait_for_drained_sources` → `drained_sources=[…]`, source `/v1/active_requests` → `[]` |
| **GPU released** | `scaled decode replicas: 2 -> 1`; tail `avg_ready_workers` 4.00 → **3.70 (min 3)** in mixed |
| GPU saving quantified | observed vs counterfactual decode-GPU-s: **11.3 s (15%)** s3_only, **21.5 s (22%)** mixed |
| no quality loss | s3_only **100% valid, 0 timeout**; mixed **100% valid** after the `pod-deletion-cost` fix |
| cost gate works | (midterm) synthetic `prompt_tokens=9000` → `declined: replay_total=9050 exceeds max_replay_tokens=8192` |
| rollback path | implemented + swept; **not exercised in the four-scenario runs** |

**Not proven / weak:**
1. **Connector (NIXL-pull) path is not exercised** in the perf runs — recompute only (§5).
2. **Rollback and sweeper are untested end-to-end** in the perf suite (no induced decline/crash).
3. **n=1** per scenario; no confidence intervals.
4. **Only 1 request migrated per run** (`request_count=1`) — multi-request consolidation is untested here (the midterm has a 6-concurrent-migration orchestration run, but on the recompute path).
5. **Semantic equivalence of the migrated output is not checked at all** — the quality gate only tests `finish_reason ∈ {stop,length}` and `tokens>0`, which §6 shows is too weak to catch prompt/param loss.
6. Thresholds tuned for the test (`CONSOLIDATION_THRESHOLD=1` vs default 3; `MIN_BATCH_COMPLETION=0.92` vs default 0.6).

---

## 8. Is the implementation correct, reasonable, and does it improve performance?

**Correct — with a bounded exception.** The *resource* protocol is genuinely well-designed: the at-least-one-copy invariant, block-hold before abort, lookup-before-abort ordering, rollback on decline, sweeper against leaks, destination-side gate before committing state, and the `pod-deletion-cost` fix that makes the GPU release deterministic. That is a proper distributed-systems argument, and it is validated. **The exception is §6: request *fidelity* across migration is not preserved in the current build** (lost `ignore_eos`, lost prompt).

**Reasonable — yes.** Cost is **O(1)** (~183 ms control action) while benefit is **O(tail duration)** — which is exactly why the same mechanism saved 15% on a 37 s tail and 44% on a 219 s tail. The gates (batch completion, in-flight window, worth-migrating, min replicas, stable samples, min interval) are conservative and provably decline in the common case.

**Improves performance — yes, on the axis it targets.** S3 is a **GPU-thrift** mechanism, not a latency mechanism: it reclaimed a real decode GPU (workers 4.00→3.70) worth **15–22% of tail decode-GPU-seconds**, at 100% validity and 0 timeouts, without extending the tail. Judging it on wall time would be the wrong axis (and `s2_only`'s **−32.8 s** "saving" — i.e. holding 2 decoders all tail — is the counterfactual that shows what *not* consolidating costs).

---

## 9. Claim boundary

| ✅ Can claim | ❌ Cannot claim |
|---|---|
| Autonomous **migrate → drain → scale 2→1 → GPU released**, decided from live telemetry | The **connector/NIXL-pull path** carries the performance result (it's recompute; connector proven only in the midterm w/ bridge overlay) |
| **15–22% tail decode-GPU-seconds** reclaimed; ~183 ms control action; O(1) cost vs O(tail) benefit | Migration is **transparent / semantically equivalent** — `ignore_eos` and the prompt are lost (§6) |
| 100% valid, 0 timeouts; deterministic pod eviction via `pod-deletion-cost` | **Multi-request** consolidation, **rollback**, **sweeper** under fault — untested in the perf suite |
| Three-phase protocol prevents KV loss (at-least-one-copy, block-hold, lookup-before-abort) | Default thresholds are production-calibrated (tests used 1 / 0.92) |

---

## 10. Open items (ranked — first two are cheap and materially strengthen the report)

1. **Fix the sampling-params whitelist** (`handlers.py` ~L1248): pass through `ignore_eos` — ideally replace the closed 12-name list with a copy of the full `SamplingParams` (or an explicit deny-list). Restores migrated-request fidelity **and** makes `completion_tokens` comparable across scenarios.
2. **Fix `prompt_tokens`** in the disagg decode path so `replay_prompt` includes the original prompt — otherwise recompute migration silently changes request semantics.
3. **Strengthen the quality gate**: assert the migrated request's output is *prefix-consistent* with what the source had already emitted (currently nothing checks this).
4. **Re-wire the KVBM block bridge into the image** so the connector path is available without a ConfigMap overlay → then re-run so the *performance* result rides the NIXL path (this is midterm future-work #3).
5. Exercise **rollback + sweeper** (induce a decline / kill the orchestrator mid-hold) and **multi-request** consolidation (`request_count>1`).
6. Calibrate/justify defaults (`CONSOLIDATION_THRESHOLD` 3, `MIN_BATCH_COMPLETION` 0.6) vs the tuned test values (1, 0.92).
