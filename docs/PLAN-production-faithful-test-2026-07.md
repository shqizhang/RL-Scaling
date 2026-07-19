# Plan (for review) — production-faithful RL-inference test

> **Status: DESIGN ONLY. Nothing is implemented from this yet.** This is for your
> review. Once we agree, I implement, then we run. Goal you set: measure as close
> to a real production RL-rollout deployment as possible; the more precise and
> real the metrics, the better. Every cross-scenario number must be uniform (same
> measurement for every scenario) and honestly attributable.

---

## 0. What changes vs the old test, and why

The old suite split the batch into three **gated phases** (`prefill_burst`,
`balanced_decode`, `decode_tail`) with topology-**verification waits** between
them. Those waits (only `s2_only`/`mixed` paid them) created the ~90 s
`wall_s`−`serving_wall_s` asymmetry and forced us to invent `serving_wall_s`. The
fixed scenario order also caused a within-round position confound.

This plan replaces that with **one continuous, realistic rollout batch, measured
uniformly end-to-end, with mechanism triggering driven by the real production
signals + live Prometheus metrics, and observed post-hoc** — no in-line
verification gates inside the measured window.

**Key reframing:** the RL lifecycle signals the controller already accepts
(`/api/v1/signals/sampling_progress|sampling_done|batch_complete`) are **not test
scaffolding** — they are the actual interface a real RL trainer (veRL, OpenRLHF,
etc.) uses to tell the serving layer "a rollout started / is ending". Keeping them
is *more* production-faithful, not less. What we drop is only the artificial
"confirm the topology changed before continuing" waits.

---

## 1. Preparation (test setup)

**1.1 Fixed deployment (identical for every scenario)**
- Dynamo PD-disaggregated, `MAX_GPUS=4`, operator held at 0 (tests own the
  worker Deployments; documented in memory).
- Worker image `rl-scaling-s2cordon-1` (S2 loss fix), controller
  `cordonfix-1`.
- Per-scenario *strategy flags* differ (S2 on/off, S3 on/off); the *topology*
  is the only structural variable and is held by the equal-topology control
  (see §3).

**1.2 Pre-warm (OUTSIDE the measured window)**
- Scale to the scenario's start topology, wait until the frontend is genuinely
  model-ready (`/v1/models` + one real completion routes through the disagg
  path), then send a small warmup batch and discard it.
- Rationale: a cold first request is 4–6 min (model load + CUDA graph + NIXL);
  including it would swamp T_batch. **Warmup time is never counted** — the clock
  starts only after readiness is confirmed. This is the one "check" we keep, and
  it sits entirely before T0, so it cannot distort any measured metric or differ
  across scenarios.

**1.3 Threshold calibration (one-time, per cluster)**
- Measure, on this exact deployment, the queue depths and utilisation the chosen
  batch actually produces, and set the controller's S2/S3 trigger thresholds to
  fire within that real operating range. (Per-deployment calibration is correct
  practice; the alternative — oversizing the batch to cross factory thresholds —
  hits the no-RDMA transport ceiling and causes timeouts.)
- Deliverable of this step: a short calibration note recording the measured
  ranges and the thresholds chosen, so triggering is organic AND documented.

**1.4 One shared workload, generated once (see §2), reused byte-for-byte by every
scenario**, with a per-request nonce at token 0 to defeat cross-scenario KV-cache
reuse.

## 2. Workload model — a realistic RL rollout batch

A real RL rollout (GRPO/PPO for reasoning LLMs) submits a **batch of B
generation requests at once** and must wait for **all** of them before the
training step — so the batch **makespan** is what matters, and the well-known
pain point is the **long right tail** of completion lengths (a few very long
traces hold GPUs while everything else is done).

We model exactly that, as ONE batch (not three phases):

- **Size:** B requests submitted with high concurrency (the whole rollout is
  dispatched, then the scheduler drains it) — calibrated in 1.3.
- **Prompt-length distribution:** drawn from a realistic distribution (mean/spread
  to be fixed in prep), **bounded** so each request's KV transfer stays within the
  no-RDMA TCP budget (the transport ceiling we characterised).
- **Completion-length distribution:** a **mixture** — the bulk finish at natural
  EOS (moderate length), plus a **tail fraction (~5–10%)** of long stragglers
  (`ignore_eos`, high `max_tokens`). This tail is what S3 exists to consolidate.
- **Arrival:** single dispatch at T0 (optionally a short ramp) — faithful to a
  trainer handing off a rollout.

The *lifecycle* of this one batch naturally passes through prefill-heavy → mixed →
tail-only, which is what the old three phases were faking. The mechanisms now react
to the **real** evolution, not to scripted phase boundaries.

**Open item for your review (2.A):** do you have completion-length statistics from
a real RL run you want matched, or should I use a documented synthetic heavy-tail
(e.g. lognormal bulk + fixed straggler fraction)? Realism of this distribution is
the single biggest lever on how faithful the result is.

## 3. Scenarios and confound control

Same five, keeping the equal-topology control (essential for honest attribution):

| scenario | topology | S2 | S3 | role |
|---|---|---|---|---|
| `baseline_1p1d` | 1P1D | off | off | minimal-resource reference |
| `static_2p2d` | 2P2D | off | off | **equal-topology control** |
| `s2_only` | 2P2D | on | off | isolate S2 |
| `s3_only` | 2P2D | off | on | isolate S3 |
| `mixed` | 2P2D | on | on | combined |

Confound controls (all three needed):
- **Round-major interleaving** — every repeat runs all five once → cancels
  *between-round* drift.
- **Counterbalanced order within each round** (Latin-square / rotated), so no
  scenario is always in the coldest slot → **fixes the within-round position
  confound** that invalidated round-2 wall numbers.
- **≥3 repeats** (I recommend 5 if time allows, given n=3 was thin).
- Identical workload + cache nonce; **paired within-round** analysis.

## 4. Triggering & execution (no gates in the measured window)

- **T0:** batch dispatched to the frontend (after 1.2 warmup, outside the clock).
- The test emulates the **RL trainer**: it sends the real signals
  (`sampling_progress` at dispatch, `sampling_done`/`batch_complete` as the batch
  drains) — the same calls a production trainer makes.
- The **controller autonomously** combines those signals with live Prometheus
  metrics (`dynamo_frontend_queued_requests{role}`,
  `dynamo_worker_gpu_utilization{role}`, worker in-flight counts) to decide S1/S2/S3
  actions. We do **not** block, poll-to-confirm, or pause between actions.
- **T_end:** the last request in the batch completes.
- Everything between T0 and T_end is pure serving + concurrent autonomous control.
  Switches/consolidations are read **after the fact** from the controller's event
  log and the continuous samplers (§5), never by an in-line wait.

## 5. Data collection during the run

Sampled continuously from T0 to T_end (plus a short post-window to catch
scale-down settle), all timestamped to a common clock:

1. **Per-request records** (from the load driver): submit ts, first-token ts,
   completion ts, prompt_tokens, completion_tokens, status, which worker served it.
2. **GPU allocation timeline** (pod sampler): ready + desired (`spec`) replica
   counts for prefill and decode, at ~1 s (as fast as kubectl allows), integrated
   over the *full* window (the fixed full-window integral).
3. **Cluster metrics timeline** (controller `/api/v1/status` + direct Prometheus):
   prefill/decode queue depth, prefill/decode GPU utilisation, worker states.
4. **Controller decision log**: every S2 switch (direction, trigger reason,
   latency, any request loss) and S3 action (migrate → drain → scale, timings,
   GPU released), with timestamps — the authoritative mechanism evidence.
5. **DCGM GPU utilisation** if available (see 5.A) — the most production-real
   utilisation signal.

**Open item for your review (5.A):** the controller falls back to an
in-flight/capacity *proxy* when `dynamo_worker_gpu_utilization` reads 0, which
suggests real per-GPU DCGM utilisation may not be scraped on this cluster. For a
truly "real" U_GPU I'd verify/enable DCGM scraping in prep; if it's unavailable we
fall back to the compute-throughput-based proxy and label it as such.

## 6. Metrics — definitions, meaning, and which we actually use

Tiered. **Only Tier 1–3 are reported as results;** the rest are diagnostic.

### Tier 1 — Primary outcomes (the thesis objectives)
| metric | definition | unit | why | cross-scenario valid? |
|---|---|---|---|---|
| **T_batch (makespan)** | T_end − T0, uniform for all scenarios | s | the RL objective: finish the rollout sooner | ✅ now uniform (no per-scenario gates) — **this replaces wall_s/serving_wall_s entirely** |
| **GPU-hours** = ∫ allocated GPUs dt | full-window integral of *desired* replicas over [T0,T_end], split **prefill-GPU-s** / **decode-GPU-s** | GPU·s | the cost objective; S3's saving lives here | ✅ desired-replica integral is lag-free; use measured-vs-measured, paired |
| **U_GPU** | useful GPU-time ÷ allocated GPU-time (DCGM if available, else throughput/capacity proxy) | % | shows S3 removing *idle* decode GPUs in the tail | ✅ with the 5.A caveat labelled |

### Tier 2 — Quality gates (must pass or nothing is interpretable)
`valid_decode_pct` (all requests correct & complete), `timeout_count`,
`http_5xx_count`. Gate: 100 % / 0 / 0.

### Tier 3 — Mechanism evidence (order-independent; the core contribution)
S2: switch count, direction, latency, **request-loss-during-switch** (=0 is the
S2 correctness result). S3: migrations, drains, **GPU released** + timing.

### Tier 4 — Efficiency ratios (context)
`tokens_per_GPU_s`, `requests_per_GPU_s` = throughput per allocated GPU.

### Tier 5 — Diagnostics only (NOT cross-scenario claims)
latency percentiles, per-window utilisation traces, queue-depth traces.

### Explicitly retired
- `wall_s` / `serving_wall_s` / `orchestration_overhead_s` — the split existed only
  because of the gated design; T_batch (uniform) supersedes all three.
- Analytical counterfactual `tail_decode_gpu_s_saved` — replaced by measured-vs-
  measured paired reclaim.

**Data strategy (which numbers we'll base the analysis on):**
1. Gate on Tier 2. If any scenario fails, stop, fix, rerun (your standing rule).
2. Headline the objectives: **T_batch**, **decode-GPU-hours reclaim**, **U_GPU** —
   each paired vs `static_2p2d`, within round, across the counterbalanced repeats.
3. Support with Tier 3 mechanism evidence (what physically happened).
4. Report topology effect (`static_2p2d` vs `baseline_1p1d`) as a sanity anchor.
5. Any metric whose paired within-round variance still swamps the effect is
   reported as "no significant effect", not massaged.

## 7. Expected results (honest predictions)

Stated up front so we're measuring, not fishing:

- **Quality:** 100 % valid, 0 timeouts (both mechanisms already validated).
- **Topology (2p2d vs 1p1d):** T_batch clearly lower for 2P2D (more parallelism) —
  a sanity check that the harness measures real effects.
- **S3:** **decode-GPU-hours materially lower** (releasing a decode GPU during the
  tail; round-2 measured ~22 % on the tail window — expected to hold or grow on
  full-batch makespan) and **U_GPU higher in the tail**; **T_batch roughly
  neutral** (consolidation shouldn't lengthen the batch). This is the strong,
  expected win.
- **S2:** **T_batch likely flat on this cluster** — prefill is transport-bound
  (proven: ~19.5 s wall vs 6.2 s compute), so adding prefill capacity can't shorten
  the batch here. S2's demonstrable result is **lossless sub-2 s elastic
  rebalancing** (Tier 3), and possibly a modest decode-side effect. We predict flat
  T_batch and will report it as such — S2's contribution is elasticity+correctness,
  and it would show T_batch gains on an RDMA/larger cluster.
- **Mixed:** S3's GPU reclaim + S2's rebalancing, no request loss.

If reality differs from these, that's a finding — we report it straight.

## 8. Risks / limitations (unchanged physics)
- No RDMA + 4 GPUs → transport ceiling and bounded effect sizes; the *reason* S2
  can't show T_batch gains here.
- Organic triggering depends on 1.3 calibration; if a mechanism doesn't fire in a
  scenario, that's reported honestly, not forced with artificial signals.
- n small; connector (NIXL-pull) path unavailable → S3 uses recompute (upper-bound
  cost); S1 planner still not exercised.

## 9. Implementation scope (once you approve)
New driver `run_rollout_batch_e2e.py` (continuous batch, counterbalanced order,
uniform T_batch, RL-signal emulation, no gates) + a workload generator for §2 +
an analyzer reporting Tier 1–3 with paired within-round stats. Reuses the fixed
pod-allocation integral and the controller decision-log parsing. Est. ~1 day to
build + calibrate, then a ~2–3 h suite.

## 10. Questions for your review
1. **(2.A)** Real RL completion-length data to match, or a documented synthetic
   heavy-tail?
2. **(5.A)** Do we invest in real DCGM GPU-utilisation scraping, or accept the
   throughput/capacity proxy (labelled)?
3. Repeats: 3 (faster) or 5 (tighter)?
4. Keep all five scenarios, or drop `baseline_1p1d` (topology anchor only)?
5. Is **T_batch + decode-GPU-hours + U_GPU** the right primary triple, or do you
   want another primary metric (e.g. time-to-first-token distribution)?
