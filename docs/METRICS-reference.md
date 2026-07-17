# Metrics Reference — RL-Scaling four-scenario suite

> Run-independent reference for every metric emitted by `test-scripts/run_four_scenario_strategy_e2e.py`
> (`<suite>/<scenario>/aggregate-summary.json` → `runs[]` / `metrics{}`).
> Kept in `docs/` deliberately: report directories under `test-scripts/reports/` are disposable and get cleaned.

## A. Metric dictionary

> **Note on "PTC":** there is no field named `PTC`. The throughput / per-unit-resource metrics are
> `req_s`, `completion_tps`, `requests_per_gpu_s`, `tokens_per_gpu_s` — all four defined below.

| metric | unit | definition (how it is computed) | what it indicates / how to read | better |
|---|---|---|---|---|
| `wall_s` | s | first request **sent** → last request **completed**, across all 3 phases (client-side) | End-to-end serving span. **Includes inter-phase orchestration** (readiness probes + topology-flip verification). **Excludes** warmup. | lower — but **not a fair S2/S3 comparator** (see §B) |
| `serving_wall_s` | s | **Σ of the 3 phase walls** (`prefill_burst + balanced_decode + decode_tail`) | **Pure request serving.** Excludes warmup *and* inter-phase orchestration. **This is the fair time metric.** | lower |
| `orchestration_overhead_s` | s | `wall_s − serving_wall_s` | Test-harness scaffolding that was excluded (serial waits for role flips + frontend readiness). ~100 s for s2/mixed, ~6 s for baseline/s3. | n/a (diagnostic) |
| `valid_decode_pct` | % | share of requests with `finish_reason ∈ {stop,length}` **and** `completion_tokens > 0` | **Correctness / quality gate.** 100% = all returned correctly. ⚠ Too weak to catch semantic drift (see KB-03 §6). | 100 |
| `timeout_count` | count | requests that hit the client timeout | **Stability red line.** >0 ⇒ something hung. Suite aborts on timeout. | 0 |
| `req_s` | req/s | successful requests ÷ `wall_s` | Request-level throughput. | higher |
| `p95_latency_s` | s | 95th percentile of per-request end-to-end latency | Tail latency experience; long stragglers dominate it. | lower |
| `completion_tps` | tok/s | Σ completion (output) tokens ÷ `wall_s` | **Decode throughput.** ⚠ Not cross-scenario comparable when migration changes output (KB-03 §6). | higher |
| `gpu_s` | GPU·s | ∫(ready GPU workers) dt over the request window | **Resource cost**: how much "GPU × time" was held. Larger topology / longer hold ⇒ higher. | lower, but read with output |
| `serving_gpu_s` | GPU·s | Σ of per-phase `gpu_allocated_seconds` | GPU·s during **serving only** (excludes idle inter-phase gaps). **The fair GPU denominator.** | lower |
| `requests_per_gpu_s` | req/GPU·s | successful requests ÷ `gpu_s` | Request output per unit GPU resource. | higher |
| `tokens_per_gpu_s` | tok/GPU·s | Σ completion tokens ÷ `gpu_s` | GPU efficiency. ⚠ **Double-confounded** — see §B. | higher |
| `serving_tokens_per_gpu_s` | tok/GPU·s | Σ completion tokens ÷ `serving_gpu_s` | Same, over serving only. Still output-confounded. | higher |
| `prefill_wall_s` | s | wall of the `prefill_burst` phase | **S2's main battlefield** (D→P adds a 3rd prefill worker). | lower |
| `balanced_wall_s` | s | wall of the `balanced_decode` phase | Mid-phase decode pressure. | lower |
| `tail_wall_s` | s | wall of the `decode_tail` phase | Long-tail phase; **S3's battlefield**. | lower |
| `tail_decode_gpu_s_saved` | GPU·s | `counterfactual_2d_decode_gpu_s − observed_tail_decode_gpu_s` | **S3's headline: decode GPU-seconds reclaimed** by consolidating + scaling down (i.e. the released GPU's would-be occupancy over the rest of the tail). Negative ⇒ held 2 decoders all tail (no consolidation). | higher (S3 only) |
| `tail_decode_gpu_s_savings_pct` | % | above ÷ counterfactual | Saving ratio. **Scales with tail duration** (15% on a 37 s tail; 44% on a 219 s tail). | higher |
| `s2_switch_total_ms` | ms | Σ of `s2_switch_latencies_ms` | **S2's action cost** (both switches ≈ 0.9–1.0 s). | lower |
| `s2_executed_count` | count | role switches actually executed | Should be 2 (D→P, P→D) in s2/mixed; 0 elsewhere. | — |
| `s3_migrated_requests` | count | requests successfully migrated | S3 evidence. 0 ⇒ consolidation never fired. | ≥1 (S3 only) |
| `s3_drained_source_count` | count | source workers confirmed drained to 0 in-flight | Precondition for scale-down. | ≥1 (S3 only) |
| `signal_to_ready_s` | s | pre-warm signal → 2P2D ready | **Cold-start warmup latency** (pod schedule + model load + NIXL init). `null` for baseline (static 1P1D). **Occurs before `wall_s` — not included in it.** | lower |
| `burst_safety_margin_s` | s | slack before burst arrival | Timing safety (>0 ⇒ the load didn't jump the gun). | >0 |

**Supporting objects** (in `<scenario>/run-01/summary.json`):
- `tail_gpu_efficiency`: `{tail_wall_s, observed_tail_decode_gpu_s, counterfactual_2d_decode_gpu_s, tail_decode_gpu_s_saved, tail_decode_gpu_s_savings_pct}`
- `phase_allocations.<phase>`: `{gpu_allocated_seconds, prefill_allocated_seconds, decode_allocated_seconds, avg_ready_workers, min/max_ready_workers}` — **`avg_ready_workers` dropping below full topology is the direct proof a GPU was released** (mixed: 4.00 → 3.70, min 3).
- `_s2_history`: per-switch `{from_role, to_role, reason, executed, result{switch_time_ms}}` — the **decision reason** is recorded here.
- `s2_evaluation_summary`: `{count, max_*_queue_depth, selected_actions, top_skip_reasons}` — includes **decisions NOT taken** and why.

## B. Two traps when reading these

**Trap 1 — `wall_s` is not a fair S2/S3 comparator.** For s2/mixed it contains ~100 s of *test scaffolding* (the harness serially waits for topology flips + frontend readiness between phases to isolate them). s3_only warms up identically yet has only ~6 s of overhead, because it runs no role switches. Use **`serving_wall_s`**.

**Trap 2 — `tokens_per_gpu_s` is double-confounded.** (a) The denominator scales with topology — strategy scenarios hold **4 GPUs** vs baseline's **2**, so baseline always looks "efficient" regardless of strategy. (b) The numerator changes when a request is migrated (KB-03 §6: migration drops `ignore_eos` and the prompt, so a migrated straggler stops early and produces fewer tokens). **Do not compare it across scenarios.**

## C. The fair comparators (use these)

| judging | use | why |
|---|---|---|
| **S2** | `serving_wall_s`, `prefill_wall_s`; cost = `s2_switch_total_ms` | S2 buys **time**. Cost is O(1) (K8s-bound); benefit is O(batch). |
| **S3** | `tail_decode_gpu_s_saved(_pct)`, `phase_allocations.decode_tail.avg_ready_workers`; cost = consolidation control latency (~180 ms) | S3 buys **GPU allocation**, not speed. Cost is O(1); benefit is O(tail duration). |
| **Quality** | `timeout_count` (must be 0), `valid_decode_pct` | Any perf claim is void if these fail. |
| **Never** | `wall_s`, `tokens_per_gpu_s`, `completion_tps` across scenarios | See §B. |
