# Stage Report: s3-tail-drain

## What This Stage Measures

This stage isolates the effect of **S3 Request Consolidation** on a decode-tail
workload.

- `pre` phase: the first wave of requests is sent while the system is still in
	its original topology. These metrics show the baseline pressure before any
	migration happens.
- `post` phase: the second wave of requests is sent after the strategy run has
	had a chance to consolidate tail requests from one decode worker to another.
	These metrics are the most important signal for whether consolidation improved
	the remaining service capacity.
- `req/s`: completed requests per second for that phase. Higher means the
	frontend workload is being drained faster.
- `wall time (s)`: elapsed end-to-end time from the first request in that phase
	to the last completed request in that phase. Lower is better.
- `p95 latency (s)`: the 95th percentile single-request latency. This captures
	tail performance rather than average performance.
- `overall generation tok/s`: aggregate generation-token throughput over the
	whole scenario. Higher means the decode side produced more tokens per second
	across the cluster.

## Comparison

| metric | baseline | strategy | strategy vs baseline |
|---|---:|---:|---:|
| pre req/s | 1.251 | 1.248 | -0.215% |
| pre wall time (s) | 19.190 | 19.231 | -0.216% |
| pre p95 latency (s) | 4.906 | 4.852 | 1.114% |
| post req/s | 1.259 | 1.386 | 10.046% |
| post wall time (s) | 19.058 | 17.318 | 9.129% |
| post p95 latency (s) | 4.553 | 4.588 | -0.767% |
| overall wall time (s) | 25.096 | 23.572 | 6.075% |
| overall generation tok/s | 1190.969 | 1269.191 | 6.568% |

## Interpretation

The `pre` phase is intentionally close between baseline and strategy. That is
expected: before consolidation takes effect, the system topology is almost the
same, so the first wave mainly serves as a control slice. The tiny differences
in `pre req/s`, `pre wall time`, and `pre p95 latency` are within the normal
run-to-run variation for a live cluster.

The useful signal appears in the `post` phase.

- `post req/s` improves from `1.259` to `1.386`, which means the cluster drains
	the second wave faster after consolidation.
- `post wall time` drops from `19.058s` to `17.318s`, which means the second
	wave completes earlier once one decode tail has been consolidated away.
- `overall generation tok/s` rises by `6.568%`, which shows the decode-side
	token production became more efficient after the migration.

The `post p95 latency` is roughly flat, with a very small regression
(`4.553s -> 4.588s`). That means S3 in this run mostly improved **throughput and
drain efficiency**, but did not materially improve single-request tail latency.
This is a reasonable outcome for consolidation: the main benefit is that fewer
decode workers stay partially occupied by small tails, so the cluster regains
usable capacity sooner.

In other words, this stage demonstrates the following effect:

- S3 does not have to make every request individually faster.
- It is still beneficial if it shortens the lifetime of fragmented decode tails
	and increases the useful throughput of the remaining cluster capacity.

## Strategy Evidence

Baseline events: `{"phase_boundary": 1}`
Strategy events: `{"request_consolidation": 1}`

The strategy event count shows that this stage exercised the intended mechanism:
one real request-consolidation action happened in the strategy run, while the
baseline run only crossed the phase boundary with no migration action.

## Artifacts

- `baseline/REPORT.md`
- `strategy/REPORT.md`
