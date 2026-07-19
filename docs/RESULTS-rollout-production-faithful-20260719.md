# Production-faithful RL-rollout results & detailed analysis (2026-07-19)

> Suite: `test-scripts/reports/rollout-5scenario-20260719-103243/`. Design:
> `PLAN-production-faithful-test-2026-07.md`. Analysis follows that plan's metric
> tiers and data strategy (gate → primary objectives paired within-round →
> mechanism support → topology anchor → honest n.s.). Consolidated source of
> record: `consolidated-data.json` (all 15 runs + aggregates).

---

## 0. Data provenance & completeness (verified)

- **Deployment verified byte-for-byte against live pods** before/around the run:
  every worker source `.py` (`components/src/dynamo/vllm/`) is md5-identical in
  the running pod (image `rl-scaling-s2cordon-1`; the only extra file is the
  build-generated `_version.py`); all 16 controller `.py` identical (image
  `cordonfix-1`); no ConfigMap overlays; both repos git-clean. So the results
  reflect the complete local implementation (S2 cordon-first switch, S3
  consolidation, migration fidelity, sidecars, decision engine).
- **Suite complete:** 5 scenarios × 3 rounds = **15/15 runs**, every run with
  `summary.json` + `requests.csv` + `pod_samples.csv` + `prom_samples.json` +
  `logs/` + 96 response bodies. **1440/1440 requests** (15×96), 96-line shared
  workload manifest, 5/5 per-scenario aggregates, `aborted=None`.

## 1. Design recap (why the numbers are comparable)

One continuous **RL-rollout batch** per scenario (96 requests: 93 natural-EOS
bulk of 64–256 tokens + 3 long `ignore_eos` stragglers of 7000 tokens — the
heavy RL tail), submitted at concurrency 48, measured **uniformly** as
`T_batch = last_completion − dispatch` with **no in-line verification gates**.
Mechanism triggering is organic (controller reacts to live Prometheus queue/util
+ the real `sampling_progress` signal reflecting actual completion fraction).
Scenario order is **counterbalanced** (rotation) across rounds. Attribution is
**paired within round** vs the equal-topology control `static_2p2d`.

## 2. Tier 2 — Quality gate: PASS

| scenario | valid % | timeouts | 5xx |
|---|---|---|---|
| all 5 × 3 runs | **100.0** | **0** | **0** |

1440/1440 requests valid, zero timeouts, zero 5xx. The S2 switch-instant
request-loss fix holds under the new continuous-batch load (s2_only and mixed
perform live role switches yet stay 100% valid).

## 3. Position-confound check: counterbalancing worked

Each scenario ran at spread positions across the three rounds (vs the fixed
order that confounded round 2):

| scenario | positions | mean |
|---|---|---|
| baseline_1p1d | 1, 5, 4 | 3.33 |
| static_2p2d | 2, 1, 5 | 2.67 |
| s2_only | 3, 2, 1 | 2.00 |
| s3_only | 4, 3, 2 | 3.00 |
| mixed | 5, 4, 3 | 4.00 |

No scenario is pinned to the cold/warm slot; the control and s3 now sit at
comparable mean positions (2.67 vs 3.00), so the paired makespan comparison is
not position-biased the way the fixed-order round 2 was.

## 4. Tier 1 — Primary outcomes (mean, n=3)

| scenario | T_batch (s) | prefill GPU·s | decode GPU·s | total GPU·s | tokens/GPU·s | p95 lat (s) | min decode |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline_1p1d | 82.1 | 82.1 | 82.1 | 164.3 | 212.2 | 25.5 | 1 |
| **static_2p2d (control)** | 58.0 | 116.0 | 116.0 | 232.1 | 151.2 | 23.3 | 2 |
| s2_only | 63.8 | 127.5 | 127.5 | 255.1 | 137.9 | 23.2 | 2 |
| **s3_only** | 52.4 | 104.8 | **87.0** | 191.8 | 153.1 | **15.1** | **1** |
| mixed | 68.6 | 137.2 | 137.2 | 274.4 | 126.9 | 27.8 | 2 |

## 5. Paired analysis (strategy − control, per round; t_crit df=2 ≈ 4.30)

**Topology (static_2p2d vs baseline_1p1d) — the scale-up capability anchor**
- `T_batch`: **−24.1 s (−29.4%), t = −4.61 → significant.** Doubling to 2P2D
  finishes the rollout 29% faster.
- `total GPU·s`: **+67.8 (+41.3%)** — 2P2D spends more GPU-seconds for that speed
  (2 GPUs × 0.71× time). The expected latency/throughput trade; it is exactly
  what S3 then claws back.
- Confirms the basic elastic scale-up/down works and the harness measures real
  effects.

**S3 (s3_only vs control) — the GPU-efficiency contribution**
- `decode GPU·s`: **−29.0 (−25.0%), t = −5.68 → SIGNIFICANT.** Per round:
  −23.4%, −20.3%, −30.5% (all negative, tight). Consolidation released one
  decode GPU for the post-consolidation tail in **3/3 runs** (min decode 2→1).
- `T_batch`: **−5.6 s (−9.7%), t = −2.33 → n.s. but negative** — S3 did **not**
  slow the batch; if anything it finished slightly sooner (lower p95, 15.1 vs
  23.3 s). So the GPU saving comes at **no makespan cost**.
- `total GPU·s`: −40.3 (−17.3%), t = −4.14 (just under the strict bar) — the
  decode saving carries into the total.
- **This is the headline result**: on a production-faithful continuous rollout,
  S3 reclaims ~25% of decode-GPU-seconds with neutral makespan, reproducing (and
  slightly exceeding) the ~22% seen in the phase-based round 2, now measured
  uniformly.

**S2 (s2_only vs control) — elasticity, not makespan**
- `T_batch`: **+5.8 s (+9.9%), t = +0.79 → n.s.** No makespan gain (marginally
  worse), exactly as predicted for this **transport-bound** cluster (prefill is
  KV-transfer-limited over the no-RDMA TCP overlay, so adding prefill capacity
  cannot shorten the batch). S2's demonstrated value is **lossless sub-second
  role switching** (§6), not latency.

**Mixed (S2+S3 vs control) — a real interaction limitation**
- `T_batch`: **+10.6 s (+18.3%)** and `decode GPU·s` **+18.3%** — mixed is
  *worse* than the control on both. Cause is mechanistic, not noise (§6): **S3
  never fired in any of the 3 mixed runs** (0 migrations, min decode stayed 2),
  so mixed paid S2's switching cost with none of S3's reclaim.

## 6. Tier 3 — Mechanism evidence (order-independent)

| scenario | S2 switches (3 runs) | S2 switch time* | S3 migrated | S3 drained→released | min decode |
|---|---|---|---|---|---|
| s2_only | 5 (2/2/1) | ~934 ms | 0 | 0 | 2 |
| s3_only | 0 | — | **3/3** | **3/3** | **1** |
| mixed | 6 (2/2/2) | ~1058 ms | **0/3** | 0 | 2 |

\* From controller logs. NOTE a metric bug: `s2_switch_total_ms` reads 0 in the
run summaries (the `switch_time_ms` field is not carried through `s2_history`
into the summary); the real per-switch times above are parsed from the
controller decision log. Switch **counts** and 100% validity are unaffected.

**Why S3 didn't fire in mixed (root-caused from `mixed/run-*/logs/controller.log`):**
S2's D→P switch fires early (`prefill_queue=2≥1, decode_util idle`), driving the
topology to **3P1D** (decode_workers=1) during the prefill-heavy start. When the
P→D switch-back restores 2P2D (~60 s later), the stragglers are already all on
the surviving decoder while the re-created decoder is empty — a **3+0 split**. S3
consolidation needs a *source decoder with a migratable in-flight straggler* to
empty; a 3+0 split offers none (the empty decoder has nothing to migrate away),
so the consolidation gate is never met and no GPU is reclaimed. This is a genuine
**S2↔S3 coordination gap**: the two controllers act on the same decode pool
without a shared plan, and S2's reshuffling can dissolve the split S3 relies on.

## 7. Tier 4 — Efficiency & latency (context)

- `tokens/GPU·s`: baseline 212 (one GPU packed densely) > s3 153 ≈ control 151 >
  s2 138 > mixed 127. S3 nudges throughput-per-GPU above the control (fewer GPUs,
  same work); S2/mixed lower it (switch overhead).
- `p95 latency`: **s3 lowest at 15.1 s** (shorter, consolidated tail); mixed
  highest at 27.8 s. Time-to-first-token was **not** captured (the load path is
  non-streaming) — a diagnostic left for future work.

## 8. U_GPU (KV-cache occupancy)

Decode KV-cache occupancy (`dynamo_component_gpu_cache_usage_percent`, the real
exported signal since DCGM per-GPU util is not scraped) ran **very low (~0.1–0.2%)**
for all scenarios — the 96-request batch barely fills the KV cache — so this
signal is too weak to separate the strategies (S3 effect n.s.). The **GPU-hours**
metric (§5), not occupancy, is the load-bearing GPU measure here. Only the
topology effect on occupancy is significant (2P2D halves per-GPU occupancy by
splitting load), which is expected and not the story.

## 9. What can be claimed

- ✅ **Correctness:** 1440/1440 requests valid, 0 timeouts, across live role
  switches and consolidations — the S2 loss fix holds under production-faithful load.
- ✅ **Elastic scale-up/down works:** 2P2D vs 1P1D is −29% makespan (significant).
- ✅ **S3 GPU efficiency (headline):** −25% decode-GPU-seconds (t=−5.68) with
  neutral makespan and lower p95, on a uniformly-measured continuous rollout;
  3/3 clean consolidations releasing a GPU.
- ✅ **S2 elasticity:** autonomous, lossless, ~0.9–1.1 s in-place role switches.
- ⚠️ **No S2 makespan gain here** — a property of the no-RDMA transport ceiling,
  not the mechanism.
- ⚠️ **S2+S3 do not yet compose** — S2's role churn dissolves the decode split S3
  needs; mixed reclaimed nothing. Reportable as a limitation + future work
  (a shared S2/S3 plan, or gating S3's source-selection on the post-switch layout).

## 10. Threats to validity / limitations

- **n = 3** — adequate for the large S3 reclaim (t=−5.7) and the categorical
  quality/mechanism results; thin for small effects.
- **No RDMA / 4 GPUs** — bounds effect sizes and is *why* S2 shows no makespan
  gain (transport-bound prefill) and why the reclaim is ~1 GPU over a ~50 s tail.
- **U_GPU occupancy weak** (batch under-fills KV) — GPU-hours is the primary GPU
  metric instead.
- **TTFT not captured** (non-streaming load path); **`s2_switch_total_ms` summary
  field bug** (real times recovered from logs). Both are measurement gaps, not
  result-affecting.
- **Mixed S2/S3 interaction** (§6) — a real coordination gap, documented, not a
  deployment or data error.
- Connector (NIXL-pull) migration path unavailable → S3 uses recompute (cost
  upper bound); S1 capacity planner still not exercised (topology forced by prewarm).

## Appendix — reproduce
```
python test-scripts/analyze_rollout_suite.py \
  test-scripts/reports/rollout-5scenario-20260719-103243
```
Gate passed: quality_ok=True; consolidated-data.json is the analysis source of record.
