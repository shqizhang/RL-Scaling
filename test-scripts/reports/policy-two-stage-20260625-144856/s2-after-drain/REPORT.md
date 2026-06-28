# Stage Report: s2-after-drain

## What This Stage Measures

This stage measures the combined effect of:

- first using **S3 Request Consolidation** to drain a decode worker tail, then
- using **S2 PD Role Switch** to convert the drained decode worker into an
	additional prefill worker.

The stage is split into two waves so the report can distinguish
"before strategy benefit is available" from "after strategy benefit becomes
available".

- `pre` phase: first wave, before the topology has been improved for the next
	batch. This phase includes the cost of preparing the strategy actions.
- `post` phase: second wave, after the source decode tail has been drained and
	the source worker has been switched to `prefill`. This phase is the clearest
	measurement of whether the new topology helps under high frontend pressure.
- `req/s`: completed requests per second in that phase. Higher means better
	end-to-end throughput.
- `wall time (s)`: time from the first request start to the last request finish
	within that phase. Lower is better.
- `p95 latency (s)`: tail latency for that phase. Lower means the slowest
	requests improved.
- `overall generation tok/s`: aggregate generation throughput across the full
	scenario. It summarizes whether the whole cluster processed useful model work
	more efficiently.

## Comparison

| metric | baseline | strategy | strategy vs baseline |
|---|---:|---:|---:|
| pre req/s | 1.457 | 1.239 | -14.977% |
| pre wall time (s) | 16.474 | 19.376 | -17.616% |
| pre p95 latency (s) | 4.326 | 4.802 | -11.003% |
| post req/s | 1.934 | 3.144 | 62.514% |
| post wall time (s) | 16.543 | 10.179 | 38.467% |
| post p95 latency (s) | 4.267 | 2.559 | 40.031% |
| overall wall time (s) | 33.112 | 30.239 | 8.677% |
| overall generation tok/s | 618.723 | 727.676 | 17.609% |

## Interpretation

The `pre` phase is worse in the strategy run, and that is expected for this
stage design. During `pre`, the strategy run is paying the cost of two control
plane/data-plane actions:

- first a consolidation step to drain a decode tail, and
- then a role switch to turn that drained decode worker into a prefill worker.

So the `pre` phase should not be read as "strategy is worse overall". It should
be read as "strategy is spending time to reshape topology for the next wave".

The important result is the `post` phase, because that is where the new topology
is already in effect.

- `post req/s` improves from `1.934` to `3.144`, a `62.514%` increase. This is
	the clearest sign that the cluster handles the second wave much more
	efficiently after the role switch.
- `post wall time` drops from `16.543s` to `10.179s`, a `38.467%` reduction.
	This means the second wave finishes substantially sooner once an extra prefill
	worker is available.
- `post p95 latency` drops from `4.267s` to `2.559s`, a `40.031%` improvement.
	This shows the tail of the latency distribution improves significantly, not
	just the average case.

The overall metrics also move in the expected direction.

- `overall wall time` improves by `8.677%` even though the strategy run paid the
	one-time setup cost during `pre`.
- `overall generation tok/s` improves by `17.609%`, showing that the cluster as
	a whole sustained more useful model throughput across the scenario.

This is the strongest result in the two-stage experiment because it matches the
intended RL-scaling story:

- S3 first removes fragmented decode tails.
- S2 then repurposes the newly freed GPU worker into extra prefill capacity.
- The next frontend-heavy wave benefits from that new topology immediately.

So this stage does not just show that the mechanisms work. It shows that the
mechanisms create a topology change that improves both throughput and completion
time for the following workload wave.

## Strategy Evidence

Baseline events: `{"phase_boundary": 1}`
Strategy events: `{"request_consolidation": 1, "role_switch": 1}`

These event counts are important to the interpretation:

- the baseline run had no scaling action at all,
- the strategy run executed both the consolidation step and the role-switch
	step,
- and the large `post`-phase improvement appears only after both actions were
	applied.

## Artifacts

- `baseline/REPORT.md`
- `strategy/REPORT.md`
