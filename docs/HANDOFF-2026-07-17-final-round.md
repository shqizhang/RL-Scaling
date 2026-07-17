# HANDOFF — Final experimental round (2026-07-17)

> **Read this first in the next session.** It captures (a) what is implemented and proven, (b) the
> confound that invalidated the last dataset and the fix now running, (c) the process traps that cost
> hours, and (d) exactly what to do next.
>
> Series: KB-01 (resource model + S1) · KB-02 (S2) · KB-03 (S3) · `IMPLEMENTATION-full-picture-2026-07.md`
> · `METRICS-reference.md` · `MASTERS-EVALUATION-2026-07.md`.

---

## 0. STATE RIGHT NOW — a run is in flight

A **detached** interleaved suite was launched at 20:28 and survives session end:

| | |
|---|---|
| suite dir | `test-scripts/reports/interleaved-5scenario-20260717-202840/` |
| PID | 38772 (Windows, detached — not tied to any tool session) |
| log | `C:\Windows\Temp\interleaved_suite.log` (+ `.err`) |
| design | **5 scenarios × 3 repeats, round-robin**, aborts on any timeout |
| ETA | ~2.5 h from 20:28 |

**First action next session:** check it finished, then analyse. Do **not** re-run unless it aborted.
```bash
D=RL-Scaling/test-scripts/reports/interleaved-5scenario-20260717-202840
for s in baseline_minimal 2p2d_static s2_only s3_only mixed_strategy; do
  echo "$s: $(ls -d $D/$s/run-*/summary.json 2>/dev/null | wc -l)/3"; done
grep -aE "REPORT=|suite aborted|Traceback" /c/Windows/Temp/interleaved_suite.log | tail -2
```

---

## 1. Deployed / committed state

| component | version | contains |
|---|---|---|
| worker image | `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fidelity-1` | prompt+sampling fidelity fixes, `/cordon`,`/uncordon` |
| controller image | `ghcr.io/shqizhang/rl-scaling-controller:cordonfix-1` | cordon-before-scale-down, `pod-deletion-cost`, recalibrated constants |
| dynamo repo | `637bda1517` (branch `RL-Scaling`) | worker fixes — **committed, NOT yet pushed** |
| RL-Scaling repo | `380ce17` (branch `RL-Scaling`) | controller + test fixes — **committed, NOT yet pushed** |

**TODO next session:** `git push origin RL-Scaling` in **both** repos.

---

## 2. What is PROVEN (safe to claim)

These do **not** depend on the confounded performance numbers.

**S3 mechanism — reliable.** 3/3 runs: `migrated=1 → source drained → decode scaled 2→1`, each draining a
*different* pod (`w6csk`, `tc76m`, `jd7bk`). Control action ≈180 ms (decision 20 ms → migrate → mark pod
77 ms → scale). Rollback/sweeper implemented (untested under fault).

**S2 mechanism — reliable.** 6/6 switches executed (2 per run × 3), ~970 ms per D→P+P→D round trip,
both directions, decisions taken from *measured* Prometheus telemetry with reasons recorded
(`prefill_queue=2>=1 and decode_util=0.00<=0.30`). The negative case is also covered: in an earlier
suite the controller evaluated **364 times and declined 362**, with explicit skip reasons including the
`MIN_DECODE_REPLICAS` floor guard firing.

**Quality — perfect.** **15/15 runs: 100% valid, 0 timeouts, 0 aborts, 0 tracebacks.** Notably the S2
switch-instant request loss (1–2/64 in earlier rounds) **did not recur** on `fidelity-1`.

**Migration fidelity — fixed and verified in-cluster** (see §3).

---

## 3. The three real bugs found and fixed this round

**(a) `prompt_tokens` was always empty — migrated requests lost the user's prompt.**
vLLM's `TokensPrompt` is a **TypedDict**, so `prompt` is a plain dict and
`getattr(prompt, "prompt_token_ids", [])` could never match → always `[]`. Since
`replay_prompt = prompt_tokens + generated_tokens`, the destination re-prefilled **only generated
tokens**. Fixed via `Mapping` handling (`handlers.py::_extract_prompt_token_ids`).
*Verified live:* `/v1/active_requests` now shows `prompt_tokens: 7`, and `migrate_out` ships real IDs
`[840, 20772, 22670, 37852, 304, 7716, 13]` (was `[]`).

**(b) `ignore_eos` silently dropped — migrated stragglers stopped early.**
The registry copied sampling params through a **closed 12-name whitelist** that omitted `ignore_eos`.
Replaced with real field enumeration (msgspec `__struct_fields__` → dataclass → `__dict__`), JSON-safe,
excluding `extra_args`/`logits_processors` so stale `kv_transfer_params` cannot leak
(`handlers.py::_sampling_params_to_dict`).
*Verified live:* snapshot now carries **22 params incl. `"ignore_eos": true`** (was 12, no `ignore_eos`).

**(c) S3 drained but never cordoned — router could feed a doomed pod.**
`drain → scale` is insufficient: until the pod terminates it is still in the frontend's WorkerSet, so
`KvRouter` can route a NEW request onto a decoder about to be deleted (→ `EngineShutdown`). The
`batch_completion>=0.92` trigger merely *masked* this. Added `DualModeWorker.cordon()/uncordon()` +
sidecar `POST /cordon`,`/uncordon`; controller now does **cordon → re-verify drain → mark → scale**,
with uncordon-and-abandon if the source refills. *Verified live:* both endpoints 200, role intact.

**Trap that nearly voided the round:** `Dockerfile.pyfix` never COPYed `handlers.py`/`migration.py` —
the fixes would have "built successfully" and never reached the image. Now copied. **Any new worker
file must be added there.**

---

## 4. ⚠ THE FINDING THAT MATTERS — last dataset is uninterpretable

`2p2d_static` and `s3_only` are **functionally identical during `prefill_burst`**: both 2P2D, both
`ROLE_SWITCH=false`, and consolidation is inert (its `batch_completion>=0.92` gate cannot be met yet).
They must produce the same number.

| | prefill (n=3) |
|---|---|
| `2p2d_static` | **22.0 ± 0.9** |
| `s3_only` | **16.2 ± 2.1** |

Non-overlapping, **t≈4.4, p≈0.01** — a **26% systematic error** between identical configs. Cause:
**run-order / session drift**. Scenario-major execution + a mid-suite process kill split the run into two
sessions (baseline+2p2d at 16:19–17:12; s2+s3+mixed at 17:24–18:20) on a cluster running for hours.

**Consequence:** the effect being attributed to S2 is ~1 s (~4%); the confound is ~6 s (26%). **Every
cross-scenario performance comparison in that dataset — including the −34% topology claim — is
uninterpretable.** `serving_spec_gpu_s` inherits it (GPUs × wall).

**Fix (implemented, `380ce17`, now running):** round-robin execution — `for repeat: for scenario:` — so
drift is **common-mode** within a round, and rounds support a paired comparison.

### Dataset for reference only (do NOT quote as results)
| scenario | serving_wall | prefill | tail | spec_gpu_s | valid | timeouts |
|---|---:|---:|---:|---:|---:|---:|
| baseline (1P1D) | 90.4±3.8 | 33.3±3.6 | 46.9±0.1 | 149.7 | 100% | 0 |
| 2p2d_static | 70.5±1.6 | 22.0±0.9 | 41.1±0.4 | 211.3 | 100% | 0 |
| s2_only | 69.2±5.6 | 21.1±5.3 | 41.1±0.6 | 211.7 | 100% | 0 |
| s3_only | 64.1±1.9 | 16.2±2.1 | 40.9±0.6 | 176.1 | 100% | 0 |
| mixed | 70.0±5.6 | 17.9±1.6 | 44.6±5.1 | 175.4 | 100% | 0 |

Legit read even so: **S2 adds variance** (σ 5.3 vs control 0.9) — plausibly switch timing landing
mid-burst.

---

## 5. Metrics: which to trust

| metric | verdict |
|---|---|
| `serving_wall_s`, `prefill_wall_s`, `tail_wall_s` | ✅ trust (**only within a round / interleaved**) |
| `valid_decode_pct`, `timeout_count` | ✅ trust |
| `s2_executed_count`, `s2_switch_total_ms`, `s3_migrated_requests`, `s3_scaled_down_to` | ✅ trust — the mechanism evidence |
| **`tail_decode_gpu_s_saved(_pct)`** | ❌ **DO NOT USE.** Reported "13–18% saved" in runs with `migrated=0`. Compares ready-based `decode_allocated_seconds` to an analytical `tail_wall×2`; any sampling dip manufactures a phantom saving. |
| `min_spec_decode_replicas` | ⚠ direction right (1 when S3 fired, 2 when not) but **also catches cooldown scale-to-zero** (`=0` seen). Window it to the tail phase strictly. |
| `serving_spec_gpu_s` | ⚠ concept right (the `GPU_hours` objective) but inherits wall drift + the cooldown artifact |
| `wall_s`, `tokens_per_gpu_s`, `completion_tps` | ❌ never cross-scenario (orchestration + migration-changes-output + topology) |

**A real subtlety:** S3's scale-down fires *late in the tail*, so the tail window barely contains it —
`min_spec_decode` read 1/2/2 even though all 3 runs genuinely scaled 2→1. Consistent with **S3 cost is
O(1), benefit is O(tail duration)** (44% saved on a 219 s tail; near-nothing on a 40 s tail).

---

## 6. Process traps (each cost real time — avoid)

1. **A long `Monitor` killed the suite.** The run died at exactly 17:20:01 = monitor expiry. **Launch
   long runs detached** (PowerShell `Start-Process`; `setsid` does not exist in Git Bash) and poll with
   short checks.
2. **Do not read `summary.json` mid-write.** I twice drew wrong conclusions (“S3 fired 1/3”, “s3 prefill
   21.9”) from partially-written files. **`aggregate-summary.json` is authoritative** (written from
   in-memory summaries after all repeats); cross-check mtimes.
3. **Operator must be 0.** If it runs it reverts every scale-up within ~8 s and warmup hangs at 1P1D:
   `kubectl -n dynamo-system scale deploy dynamo-platform-dynamo-operator-controller-manager --replicas=0`
4. **SSH tunnel drops.** Use the auto-reconnect loop + `kubectl` retry (already in `rls_strategy_common`).
5. **Docker Desktop dies.** Needed GUI/WSL restart; `docker-desktop` distro must be `Running`.
6. **`SINGLE_PREFILL_TPS=50000` in `scenario_env` is LOAD-BEARING — do not "fix" it.** With the honest
   2700 the planner computes `N_prefill=ceil(393216/(2700×5))=30` → capped to **3P1D**, which fights the
   intended 2P2D. The override pins the planner to the experiment's topology; 2700 is the correct
   *production* default (now in `config.py`).

---

## 7. Known-open issues (documented, not fixed)

1. **S1 capacity planner is untested** — the harness forces topology, so it never drove sizing;
   `SINGLE_PREFILL_TPS` was 18× off measured (2738). Claim only "signal-triggered scale-from-zero and
   cooldown scale-to-zero work", never "the planner sizes correctly".
2. **`on_sampling_progress` only fires from IDLE** + state is in-memory → a stale `warm_up` silently
   no-ops pre-warm (this broke real runs). Robustness bug.
3. **Connector (NIXL-pull) path unavailable in the clean image.**
   `kvbm_cm = getattr(engine_client.engine_core, "kv_cache_manager", None)` → `None`, because vLLM v1
   runs EngineCore in a separate process (`AsyncLLM.engine_core` is an `MPClient`). The midterm's
   connector proof relied on the `dynamo-block-bridge` ConfigMap overlay we removed. **All perf runs use
   `path:"recompute"`.**
4. **Worth-migrating gate never declined a migration** — decorative. `_DECODE_TOKENS_PER_SEC` recalibrated
   20→150; `WORTH_MIGRATING_GATE_ENABLED` added to disable it explicitly.
5. S2 switch-instant request loss (concurrency-dependent; absent on `fidelity-1`, present earlier).
6. Rollback/sweeper and multi-request consolidation (`request_count>1`) untested end-to-end.

---

## 8. Next session — do this, in order

1. **Check the in-flight suite** (§0). If aborted → diagnose, fix, rebuild, rerun (the standing rule).
2. **Push both repos** (`637bda1517`, `380ce17`).
3. **Analyse interleaved data.** Sanity check first: **`2p2d_static` vs `s3_only` prefill must now agree**
   (they are identical in that phase). *If they still differ significantly, the confound is not fixed —
   stop and investigate before writing anything.*
4. Prefer the **paired within-round** comparison (round *i* strategy vs round *i* control).
5. **Then** write the report, using only §5-trusted metrics.

### The honest thesis framing (regardless of the numbers)
- **Contributions are the mechanisms**, and they are demonstrated: sub-second in-place PD role switch
  (~970 ms, both directions, autonomous, correctly declining 362/364) and live decode-request
  consolidation with GPU reclaim (3/3, ~180 ms control action), both at 100% validity / 0 timeouts.
- **Be upfront that the workload is transport-constrained.** Prompts were downsized (400 words) to fit a
  cluster with no cross-pod RDMA, so the prefill burst never builds the backlog S2 exists to relieve
  (`max_prefill_queue_depth=2` vs a default threshold of 10). Prefill saturates ≈2 workers (1 worker
  2738 tok/s → 3 workers only 4200), so D→P's third worker has little headroom. **S2 showing no large
  gain here is a property of the workload, not a defect of the mechanism** — say so plainly.
- Same for S3: the reclaim is real and reliable, but a 40 s tail leaves little to bank. Its benefit
  scales with tail duration.
- **The strongest experimental contribution may be the methodology itself**: adding the equal-topology
  control and interleaving exposed a 26% order confound that a naive design would have reported as a
  strategy win. That is a legitimate and defensible result.
