# RL-Scaling — Final experimental results (round 2, 2026-07-18)

> Definitive results for the elastic PD role-switch (S2) and in-flight decode
> consolidation (S3) mechanisms on NVIDIA Dynamo. Supersedes the round-1
> dataset (`20260717-202840`) for reporting. Suite:
> `test-scripts/reports/interleaved-5scenario-20260718-083403/` (15/15 runs,
> 0 timeouts). Companion: `HANDOFF-2026-07-17-final-round.md`,
> `analyze_interleaved_suite.py`.

---

## 1. Executive summary

Two results are robust and are the reportable contributions of this round:

1. **S2 role switching is correctness-preserving.** After fixing a
   switch-instant request-loss bug, **all 15 runs are 100% valid with 0
   timeouts and 0 HTTP 5xx**, including the six runs that perform live D→P and
   P→D role switches. Previously 2 of 6 switching runs each dropped one request
   (99.05% valid). The switch is autonomous, driven by measured queue/utilisation
   telemetry, and completes in ~1.9 s end-to-end with zero request loss.

2. **S3 consolidation delivers a real, significant decode-GPU saving.** Measured
   against an equal-topology (2P2D) control, paired per round, S3 reclaims
   **−21.8% of tail decode-GPU-seconds (Welch/paired t = −6.14)**; the combined
   S2+S3 strategy reclaims **−26.3% (t = −21.7)**. This is a direct, measured
   consequence of the observed 2→1 decode scale-down (3/3 migrations drained and
   released a GPU in every S3 run).

One limitation is stated honestly and bounds what else can be claimed:

3. **Cross-scenario wall-time comparisons are not reportable** on this cluster.
   They are confounded by a within-round scenario-position effect, and — for S2
   specifically — the prefill phase is transport-bound, not compute-bound, so
   adding prefill capacity cannot reduce wall time here regardless. S2's
   contribution is elasticity + correctness, not latency; S3's is GPU efficiency.

---

## 2. Experimental design

- **Model / stack:** Qwen3-0.6B on Dynamo v1.0.1, vLLM 0.16, PD-disaggregated
  (KvRouter). 4 GPUs, no cross-pod RDMA (KV transfer falls back to TCP overlay).
- **Five scenarios × 3 repeats, round-major (interleaved):** every repeat runs
  all five scenarios once before the next repeat begins, so between-round
  cluster drift is common-mode within a round.
  - `baseline_minimal` (1P1D), `2p2d_static` (2P2D, both strategies off — the
    **equal-topology control**), `s2_only`, `s3_only`, `mixed_strategy`.
- **Identical workload** across scenarios (one shared `workload-manifest.jsonl`):
  a 64-request prefill burst (400-word prompts), a 24-request balanced decode
  phase, and a long-tail phase with 3 `ignore_eos` stragglers (max_tokens=9000)
  plus 14 short/medium requests. A per-request nonce at token 0 defeats KV-cache
  reuse across scenarios.
- **Abort-on-timeout:** any phase timeout aborts the whole suite (no polluted
  data). None fired.
- **Attribution:** strategy effects are measured **paired, within round**,
  against `2p2d_static` (isolating the strategy from the 1P1D→2P2D topology
  change). The topology change itself is measured as `2p2d_static` vs
  `baseline_minimal`.

### Fixes applied this round
- **Worker (`dynamo` `b0bc331dca`, image `rl-scaling-s2cordon-1`):** cordon-first
  ordering in `switch_role` — withdraw the ModelCard and let the router observe
  it *before* draining/sleeping the engine, closing the window in which a request
  could be routed onto a switching worker and 500'd.
- **Test harness (`RL-Scaling` `74afc31`):** (a) fixed the tail decode-GPU
  integral to cover the full measurement window (it previously spanned only
  first-sample→last-sample, ~78%, undercounting by ~9 s × replicas and burying
  the S3 reclaim); (b) report the reclaim measured-vs-measured (control minus S3,
  paired) rather than against an analytical counterfactual; (c) grew the
  stragglers 8000→9000 tokens to enlarge the reclaim window (peak KV 27k, below
  the 30k preemption-thrash budget).

---

## 3. Quality — S2 correctness fix validated

| scenario | valid % | timeouts | HTTP 5xx |
|---|---|---|---|
| baseline_minimal | 100.0 | 0 | 0 |
| 2p2d_static | 100.0 | 0 | 0 |
| s2_only | 100.0 | 0 | 0 |
| s3_only | 100.0 | 0 | 0 |
| mixed_strategy | 100.0 | 0 | 0 |

All 15 runs, every phase. The switch-instant loss (round 1: `s2_only` r2 and
`mixed_strategy` r3 each lost 1/105 requests to an HTTP 500 during the D→P switch
in `prefill_burst`) did **not** recur. Root cause and fix in §2.

## 4. Mechanism evidence (order-independent)

| scenario | S2 switches | avg switch | S3 migrated | S3 drained→released |
|---|---|---|---|---|
| s2_only | 6/6 | 1872 ms | 0 | 0 |
| s3_only | 0 | — | 3/3 | 3/3 (decode 2→1) |
| mixed_strategy | 6/6 | 1973 ms | 3/3 | 3/3 (decode 2→1) |

Both mechanisms fire reliably and autonomously from measured telemetry. Switch
time rose from ~0.9 s (round 1) to ~1.9 s — the deliberate cost of the
cordon-first fix (a 0.5 s propagation-settle window per switch plus a clean
drain). This trades ~1 s of switch latency for zero request loss.

## 5. S3 GPU reclaim — the quantitative result

Tail decode-GPU-seconds (`observed_tail_spec_decode_gpu_s`, integrated from the
authoritative desired-replica count over the tail window):

| scenario | round 1 | round 2 | round 3 | mean |
|---|---|---|---|---|
| 2p2d_static (control) | 85.2 | 92.3 | 92.3 | 90.0 |
| s3_only | 71.9 | 70.9 | 68.3 | 70.4 |
| mixed_strategy | 63.6 | 68.1 | 67.1 | 66.3 |

**Paired reclaim vs control: S3 = −19.6 GPU-s (−21.8%), t = −6.14, significant;
mixed = −23.7 GPU-s (−26.3%), t = −21.7.**

**Why this is robust to the §6 confound.** The reclaim is not a wall-time
comparison. It is the integral of *how many decode GPUs were held* over the tail,
and S3's tail is if anything slightly **longer** than the control's (46.8 vs 45.0
s), so the saving is achieved *despite* a small tail disadvantage — it comes
purely from running 1 decode GPU instead of 2 for the post-consolidation portion
of the tail, a directly observed scale-down (3/3 drained, `min_spec_decode` 2→1).
A warming/position effect would shorten S3's tail (favourable) and thus *inflate*
the apparent saving; the opposite is observed, so the result is conservative.

## 6. Limitation — why wall-time comparisons are NOT reported

The analyzer's confound gate failed, by design, and the cause is understood.

**Within-round position effect.** The five scenarios run in the *same fixed order*
every round (baseline, 2p2d, s2, s3, mixed). The cluster warms over the ~15-min
round, so later positions are systematically faster. In the two clean rounds
(round 2 had a separate transient anomaly, below), prefill wall for the
2P2D-topology scenarios is monotonic by position:

| position | scenario | prefill wall (rounds 1&3) |
|---|---|---|
| 2 | 2p2d_static (control) | 23.2 s |
| 3 | s2_only | 21.0 s |
| 4 | s3_only | 19.3 s |
| 5 | mixed_strategy | 17.0 s |

`2p2d_static` and `s3_only` are *topologically identical during prefill*, yet
differ by ~4 s purely because the control always occupies the coldest slot
(position 2). Round-major interleaving cancels between-round drift but **not**
within-round position; a clean wall comparison would require randomised or
counterbalanced ordering. Consequently the apparent S2/S3 prefill and serving-wall
"improvements" are not attributable to the strategies and are **not reported**.

**Transport-bound prefill (S2-specific).** Independently, prefill on this cluster
is transport-bound, not compute-bound: a 400-word prompt is ~0.19 s of prefill
compute but ~3.3 s per-request latency, the balance being KV transfer over the
no-RDMA TCP overlay (~32–54 MB/s). Measured prefill wall (~19.5 s for 64 requests)
is ~3× the compute prediction (6.2 s), and adding a third prefill worker via S2
D→P moves the compute prediction to 4.1 s — a change buried under the transport
cost. So S2 cannot reduce prefill wall here even absent the position confound.
This is a property of the cluster's interconnect, not of the S2 mechanism.

**Round-2 transient.** Independently of position, round 2 saw an anomalous fast
window (~09:40–09:47): `s2_only` and `s3_only` prefill dropped to ~7–8 s (vs ~19–21
elsewhere), same prompt sizes (not a cache hit). It inflates the round-2 variance
and is a further reason the wall numbers are not usable, but it does not affect
the tail decode-GPU reclaim (§5).

## 7. Threats to validity

- **Cluster scale (4 GPU) and no RDMA** bound the achievable effects: the prefill
  burst never builds a backlog large enough for S2 to relieve, and the tail is
  short enough that S3's reclaim, while significant, is ~1 GPU for part of a ~46 s
  tail. Both mechanisms would show larger effects on RDMA-capable, larger clusters.
- **n = 3 repeats.** Adequate for the large, consistent S3 reclaim (t = −6.1)
  and the categorical quality result, thin for anything subtle.
- **Fixed within-round order** (§6) — the reason wall comparisons are withheld.
- **Connector (NIXL-pull) migration path unavailable** in the clean image
  (`kvbm_cm = None`; vLLM v1 runs EngineCore out-of-process), so all S3 migrations
  use the recompute path — an upper bound on migration cost, not a best case.
- **S1 capacity planner untested** (topology is pinned by the harness;
  `SINGLE_PREFILL_TPS=50000` is a deliberate override, not a measured value).

## 8. What can be claimed

- ✅ S2 performs autonomous, sub-2-second, **loss-free** in-place PD role switches
  (6/6, 100% valid), enabling elastic re-balancing of prefill/decode capacity.
- ✅ S3 performs autonomous in-flight decode-request consolidation that **releases
  a decode GPU**, reclaiming a significant **~22%** of tail decode-GPU-seconds
  (~26% combined with S2) versus an equal-topology control, at 100% validity.
- ✅ The methodology itself — equal-topology control + interleaving + an honest
  confound gate — surfaced and quantified both a run-order confound (round 1) and
  a within-round position confound (round 2) that naive designs would have
  reported as strategy wins.
- ❌ No claim of S2/S3 wall-time or prefill-latency improvement on this cluster
  (position-confounded; and prefill is transport-bound for S2).

## 9. Reproduction

```
# analysis (gated: quality + confound)
python test-scripts/analyze_interleaved_suite.py \
  test-scripts/reports/interleaved-5scenario-20260718-083403
```
Worker image `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-s2cordon-1`;
controller `rl-scaling-controller:cordonfix-1`; operator held at 0; pre-warm the
workers before launching (they sit at 0/0 between suites; a cold first start
exceeds the 240 s readiness gate).
