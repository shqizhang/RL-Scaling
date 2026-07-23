# 8-Minute Final Presentation — Speaker Guideline

**Cloud-Native Autoscaling for Disaggregated LLM Inference: Elastic Role Switching
and In-Flight Request Consolidation for RL Workloads**
Shengqi ZHANG (21209697) · `szhanggd@connect.ust.hk`

> How to use this file: the left column of each section is what you **say**; the
> boxed lines are what must be **on the slide**. Timings are cumulative — if you
> are past the marker, cut the *italic* sentences first; they are elaboration,
> not argument. Total 8:00 with ~30 s of slack before Q&A.

---

## Slide plan at a glance

| # | Section | Slide | Budget | Cumulative |
|---|---|---|---|---|
| 1 | Background | GPU-hour waste pattern in RL rollouts | 1:15 | 1:15 |
| 2 | Existing approaches | Why current elasticity fails here | 0:45 | 2:00 |
| 3 | Our technical approach | Two primitives + the controller | 2:00 | 4:00 |
| 4 | Test strategy | Phased workload + gates | 1:15 | 5:15 |
| 5 | Data analysis | Two results, one negative result, one non-claim | 2:00 | 7:15 |
| 6 | Conclusion | What is settled, what is next | 0:45 | 8:00 |

---

## 1 — Background (0:00 → 1:15)

> **Slide:** the rollout GPU-hour timeline (`GPU-hour.png`), with the two waste
> regions shaded and labelled *cross-phase* and *intra-phase tail*.

Open with the economics, not the architecture:

"LLM inference cost is GPU-hours. Prefill–Decode disaggregation — Dynamo,
Splitwise, DistServe — splits compute-bound prefill and bandwidth-bound decode
onto separate GPU pools. That works when traffic is stationary, like chat. **The
reinforcement-learning rollout loop is not stationary.** Every training step
submits a burst of prompts, then waits for long generations."

Then name the two wastes, pointing at the slide:

1. **Cross-phase.** "When all the prompts arrive, the decode pool is idle. When
   the generations run, the prefill pool is idle. You pay for both the whole time."
2. **Intra-phase tail.** "At the end of a batch a handful of long completions are
   scattered one-per-decoder. Each pins a whole GPU to finish one request."

Close the section with the objective on screen:
`U_GPU = Σ T_compute / Σ T_allocated` — "everything in this talk raises this ratio."

*Optional if ahead of time: mention that RL post-training (RLHF/DPO/GRPO) is now a
dominant inference consumer, so this waste is not a niche case.*

---

## 2 — Existing approaches (1:15 → 2:00)

> **Slide:** three-row comparison — *horizontal scaling* / *static
> over-provisioning* / *this work*, with a "reacts within a rollout phase?" column.

Keep this fast and structural — the point is that the failure is *structural*, not
a tuning problem:

- "Horizontal pod scaling takes **tens of seconds** to cold-start, and the new pod
  starts with an **empty prefix cache** and no NIXL connectivity. The phase it was
  meant to help is already over."
- "Static over-provisioning sizes both pools for peak and pays for peak even when a
  pool is idle."
- "Related systems don't cover this: Splitwise and DistServe partition PD **at
  deploy time**; Mooncake offloads KV but never changes a role; SpotServe migrates
  **instances**, not requests."

One sentence to land it: "So the gap is a primitive that re-balances the PD ratio
**inside** a phase, on already-warm engines."

---

## 3 — Our technical approach (2:00 → 4:00)

This is the section to protect. Budget it as 40 s / 40 s / 40 s.

### 3a. Elastic PD role switch (0:40)

> **Slide:** the two-layer protocol diagram — engine core inside, envelope outside.

"We flip a running worker's role in place. No pod restart, no engine rebuild: the
engine boots with `NixlConnector kv_both` so it already carries NIXL metadata for
both roles, and the switch is a **ModelCard change in the worker's Kubernetes CR**
plus an engine sleep/reset/wake cycle. Same pod, same IP, same warm engine."

Then the honest part — say this explicitly, it is where the engineering depth is:

"The engine flip is the easy half. The hard half is doing it **without dropping a
request**, and it took three iterations. The deployed protocol is the core wrapped
in an envelope: **cordon first** — withdraw the ModelCard before anything else;
**drain and confirm idle**; **hold** any request that arrives during the switch
window and serve it under the pre-switch role; and **wait for peers to finish
pulling the KV this worker produced** before we sleep."

### 3b. In-flight consolidation (0:40)

> **Slide:** the three-phase block-hold sequence (`request-consolidation.png`).

"For the tail we migrate a *running* request between decoders. The invariant is
**at-least-one-copy**: the source pins its KV blocks and keeps the request alive
until the destination confirms it has pulled them over NIXL, and only then does the
source release. A two-phase abort-then-submit version is unsafe — freeing the
source blocks before the destination's READ finishes risks silent corruption. The
client sees one continuous stream because the destination resumes from
`previously_emitted_tokens + 1`."

### 3c. The RL-driven controller — and why the *trigger* matters (0:40)

> **Slide:** controller loop with the RL phase signal as input.

This is a differentiator; do not skip it:

"Both primitives are driven by the training job's own phase signal. And **which
signal you use turned out to matter as much as how fast the switch is.** On our
stack the prefill queue *never* builds a backlog — prefill is fast enough that the
prefill queue depth stays at zero through a 44-prompt burst while the decode queue
climbs to 44. A reactive queue-depth trigger can therefore never fire the
decode→prefill switch in time. So we drive it from the RL signal itself: the
training job announces the rollout's shape when it dispatches it. That is the
'demand is known in advance' property that makes RL the right workload for this."

---

## 4 — Test strategy (4:00 → 5:15)

> **Slide:** the phased workload timeline — three cohorts with their launch offsets
> — plus the five scenarios and the gate list.

"Correctness is not efficacy, so the evaluation was designed so that **each
mechanism has a phase where it is the only thing that can act**."

- **Workload.** "96 requests, one fixed seed, reused byte-for-byte by every
  scenario. Phase A: 44 long prompts at t0 — a prefill burst, which is the
  decode→prefill regime. Phase B at +45 s: 49 long generations — the prefill→decode
  regime. Phase C: three `ignore_eos` stragglers — the consolidation regime."
- **No gates inside the measurement.** "Phases are separated by per-request launch
  *offsets*, not by waiting on the system, so the measured wall clock equals the
  batch makespan with zero harness contamination — we verify `business_wall ==
  T_batch` on every run."
- **Five scenarios × 3 repeats, interleaved and counterbalanced**: baseline 1P1D,
  static 2P2D (the equal-topology control), s2_only, s3_only, mixed. "The
  equal-topology control is what separates the *mechanism* effect from the
  *more-GPUs* effect."
- **Acceptance gates.** "Eight automated gates decide whether a suite may be
  reported at all: 100% valid / zero 5xx / zero timeout; the switch must fire
  inside its intended phase window; migration must actually migrate; and so on.
  **A suite that fails a gate is not analysed — it is diagnosed.**"

If asked or if you have 10 s spare: "In this final round that discipline rejected
six consecutive suites before one passed, and each rejection found a real defect."

---

## 5 — Data analysis (5:15 → 7:15)

> **Slide:** three result blocks + one grey "not claimed" block. Put the numbers on
> the slide so you can talk instead of read.

### Result 1 — the switch is fast, and every millisecond is accounted for (0:35)

"Per flip: **941 ms**, at 100% validity. And we can say where it goes, because
every step is timed inside the response:"

| Step | Mean | What it is |
|---|---|---|
| drain + settle | 502 ms | the price of zero loss (tunable) |
| `register_mdc` | 309 ms | Kubernetes round-trip (a floor) |
| engine steps | 115 ms | sleep, wake, reset, reconfig |

"The mid-term reported 453 ms under no load with no safety envelope; our first
lossless build cost 3.4 s. This round we cut it to 941 ms **with validity
unchanged**, by making losslessness a property of the protocol — the hold window —
instead of a long conservative wait."

### Result 2 — and an honest negative result (0:30)

"We then asked the question the report guide asks: does the switch improve prefill
queueing? We measured it directly from the frontend's own timing fields. **It does
not.** Time-to-first-token is within one percent of the equal-topology control in every
round, and the prefill phase actually runs 8 to 16 seconds longer. Two independent
suites, different workloads, same verdict."

"And we know why, because we measured that too: this phase is not prefill-bound. A
request spends about one second on time-to-first-token and thirty more waiting for its
KV to cross a fabric with no RDMA. Moving a decoder into prefill adds capacity where
there is no queue and takes it away from where the queue is."

**Say this without flinching.** A measured negative result with an identified cause is
a stronger slide than a borrowed positive one.

### Result 3 — consolidation is the strongest result (0:35)

"In the tail phase, reclaiming drained decoders cuts decode-GPU-seconds by **44.5%**,
paired t = −103.9. The mechanism is visible in the occupancy trace: the control holds two
decode GPUs busy on three stragglers; with consolidation the requests are migrated
onto one and the other GPU is released. Whole-run average GPU count drops 4.00 to
3.56, and p95 latency *also* improves, because the scattered tail clears faster."

*And the substrate: topology elasticity alone (2P2D vs 1P1D) cuts makespan 21.2%.*

### The honest non-claim (0:20)

> **Slide:** grey box — "What we do **not** claim: phase-A wall clock."

"We do not claim a wall-clock win for role switching, and we can say why with
data: phase-A per-request time stays around 33–35 seconds regardless of how many
output tokens the A cohort generates, while TTFT is only about one second. The
remaining thirty seconds is the request waiting for its KV to arrive — this cluster
has **no RDMA**, so transport, not prefill compute, bounds that phase. Claiming a
wall-clock gain there would be attributing a fabric limit to a scheduling
mechanism."

**Deliver this as strength, not apology.** It is the line that shows you understand
your own measurement.

---

## 6 — Conclusion (7:15 → 8:00)

> **Slide:** three bullets — settled / limits / next.

"To conclude. **Settled:** in-place PD role switching works, is lossless, and costs
under a second; reclaiming drained decoders inside a phase directly removes tail GPU
waste — 44.5%, t around 100. **Limits:** this is a single node
without RDMA, at n = 3 repeats, on a 0.6B model, so transport-bound quantities are
not resolvable here. **Next:** close the loop with a real GRPO rollout instead of a
harness, and repeat on a multi-node RDMA cluster where the transport ceiling lifts."

Final line: "The broader point is that in an RL rollout the demand ratio is known
*before* the phase starts — so the serving system should be told, not left to
discover it from a queue."

---

## Appendix — prepared answers

**"Why is the switch 941 ms and not 453 ms like your mid-term?"**
Different protocols and different loads. 453 ms was the engine core under light
load with no safety envelope. 941 ms is the deployed zero-loss protocol under
in-flight load: engine ~115 ms, Kubernetes round-trip ~309 ms, drain+settle
~502 ms. The engine was never the bottleneck.

**"Can you make it faster?"**
Yes, one term. `register_mdc` (~309 ms) is a control-plane floor. The engine steps
(~115 ms) are negligible. The drain+settle window is policy — we already cut it
3.0 s → 0.5 s with validity unchanged, and a deterministic routing-epoch ACK from
the frontend would remove the remaining heuristic. The outbound-KV wait is
irreducible in principle: it is the *peer's* transfer, and cutting it short trades
losslessness for latency.

**"What was the hardest bug?"**
Sleeping while a peer was still pulling our KV. `sleep(level=2)` frees GPU memory,
so a switch-back issued during an active KV handoff destroyed the peer's transfer:
646 blocks stayed permanently pinned and 34 requests hung to their timeout. What
makes it interesting is that the *slow* protocol had been only **accidentally**
safe — its 3-second window happened to outlast typical pull times. Speeding the
switch up is what exposed the missing constraint, and it is now the fourth ordering
constraint in the design.

**"Isn't 96 requests too small?"**
For the tail mechanism the structure is what generalises: with D decoders and a
tail fraction f, consolidation can reclaim up to ((D−1)/D)·f of decode-GPU time. At
D = 2 that ceiling is ~21% of the run, matching what we measured. Production uses
larger D, which raises the ceiling toward 1, and RL generations are more heavy-
tailed, which raises f. The small scale understates the effect.

**"Why not just use more GPUs / autoscale pods?"**
That is the baseline we measure against — and cold start is tens of seconds against
a phase of tens of seconds, plus every new pod starts with a cold prefix cache. Our
switch is sub-second on an already-warm engine.

**"How do you know the numbers aren't measurement artefacts?"**
Three defences: an equal-topology control isolates the mechanism from the extra
GPUs; scenarios are interleaved and counterbalanced within a round, so drift is
common-mode and comparisons are paired; and eight automated gates must pass before
a suite is analysed at all. We rejected six suites in this round on those gates.
