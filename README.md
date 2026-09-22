# Cloud-Native Autoscaling for Disaggregated LLM Inference

**Elastic prefill/decode role switching and in-flight request consolidation for reinforcement-learning inference workloads.**

![CI](https://github.com/shqizhang/RL-Scaling/actions/workflows/ci.yml/badge.svg)
&nbsp;License: Apache-2.0
&nbsp;Stack: Kubernetes · NVIDIA Dynamo · vLLM · NIXL

Reinforcement-learning post-training (RLHF, GRPO) drives inference in **phases**:
a prefill-heavy sampling burst, a long decode phase, then a sparse long tail — and
then the GPUs should be freed for the next rollout or a training step. A static
prefill/decode (PD) split wastes GPU-hours at every phase boundary, and Kubernetes
autoscaling reacts in *minutes* — an order of magnitude too slow to act *inside* a
rollout phase.

This project reshapes a **fixed** pool of GPUs to follow those phases, in
**sub-second** control time, through two mechanisms driven by an external RL signal:

- **S2 · Elastic PD role switching** — flip a single vLLM worker between prefill and
  decode *in place*, with no engine rebuild and no cold start (~0.9 s, zero request loss).
- **S3 · In-flight request consolidation** — live-migrate long-tail decode requests
  onto fewer decoders and release a GPU early, with an at-least-one-copy invariant.

Both are orchestrated by an **RL-signal-driven control plane** that closes the loop
over Prometheus metrics, Kubernetes discovery, worker sidecars, and vLLM engine state.

---

## Architecture

```mermaid
flowchart TB
    subgraph K8s["Kubernetes cluster (single node)"]
        FE["<b>Frontend</b><br/>OpenAI HTTP :8000<br/>ModelWatcher → KvRouter / PrefillRouter"]

        subgraph Pods["Dual-mode worker pods (fixed GPU count)"]
            W1["<b>Worker A</b><br/>vLLM engine (NixlConnector kv_both)<br/>one TCP slot · sidecar :9091<br/>ModelCard: <b>prefill</b>"]
            W2["<b>Worker B</b><br/>vLLM engine (NixlConnector kv_both)<br/>one TCP slot · sidecar :9091<br/>ModelCard: <b>decode</b>"]
        end

        CTRL["<b>RL-Scaling controller</b><br/>control loop: S3 → S2 → S1<br/>reads Prometheus + sidecars<br/>patches Deployments / mutates ModelCards"]
    end

    RL["RL rollout<br/>(phase signal)"] -->|"warm-up / batch meta"| CTRL
    FE -->|"prefill KV handoff (NIXL)"| W2
    FE -->|generate| W1
    FE -->|generate| W2
    W1 -. "DWMD ModelCard (role)" .-> FE
    W2 -. "DWMD ModelCard (role)" .-> FE
    CTRL -->|"/switch_role, /migrate"| W1
    CTRL -->|"/switch_role, /migrate"| W2

    classDef ctrl fill:#1f6feb,color:#fff,stroke:#1f6feb;
    classDef fe fill:#238636,color:#fff,stroke:#238636;
    class CTRL ctrl;
    class FE fe;
```

A worker's role is simply **which ModelCard it publishes** to its Kubernetes
`DynamoWorkerMetadata` CR; the frontend routes by *watching* those CRs. The
controller and the sidecars form a control plane that is entirely separate from the
request data path.

---

## The three levers, on three timescales

| Lever | Acts on | In one line |
|-------|---------|-------------|
| **S1** — signal-triggered scaling | replica count (K8s) | pre-warm and reclaim pods on the RL phase signal (a 4-state FSM). |
| **S2** — elastic PD role switch | a worker's *role* | in-place hand idle capacity to the bottleneck role — no engine rebuild. |
| **S3** — request consolidation | request *placement* | migrate long-tail requests onto fewer decoders, then release a GPU. |

> S1 changes **replicas**, S2 changes a worker's **role**, S3 changes a request's
> **placement** — all in sub-second control time, at a fixed GPU count.

### S2 — the switch protocol (zero-loss envelope + engine core)

A role flip runs as two nested layers so no request is lost across it:

```
E1 cordon          router stops sending this worker new work
E2 drain + settle  in-flight requests finish
E3 outbound-KV     wait until any peer still PULLING this worker's KV finishes
   ─────────────── (safe window) ───────────────
C1 sleep           free GPU KV blocks
C2 reconfig NIXL   drop + lazily rebuild the connector for the new direction
C3 reset prefix    clear the prefix-cache index while asleep (kills stale refs)
C4 register MDC    publish the new-role ModelCard
C5 wake            resume generation
```

Mean flip time **941 ms**, dominated by two *fixed* terms (a Kubernetes ModelCard
round-trip and a drain window); engine work is ~115 ms. Because the cost is O(1)
while the batch is O(n), it amortizes as rollouts grow.

### S3 — three-phase block-hold migration

`migrate_out` pins the most-progressed request's KV on the source (does **not**
abort it) → `migrate_in` has the target pull the KV over NIXL (recompute is the
fallback) and resume decoding → `migration_complete` releases the source. The
request's KV lives on ≥1 GPU at every instant (**at-least-one-copy**); any failure
rolls back and the request keeps running on the source. Zero KV loss, zero
in-flight request loss.

### The control loop

```mermaid
flowchart LR
    T["每 tick"] --> M["gather metrics<br/>(queue Q, occupancy U)"]
    M --> S3{"long tail?<br/>consolidate?"}
    S3 -->|yes| DO3["migrate → drain → scale down"]
    S3 -->|no| S2{"role imbalance?<br/>Q high &amp; other pool idle?"}
    S2 -->|yes| DO2["flip the emptiest worker"]
    S2 -->|no| S1["S1: warm-up / reclaim (FSM)"]
```

Each tick evaluates **S3 → S2 → S1** (draining first creates cheap re-role
candidates). Decisions use two quantities per pool — backlog `Q` and occupancy `U` —
plus a signal-derived term that folds the rollout's *known upcoming* prefill demand
into `Q` before it queues.

---

## Evaluation

A phased 96-request workload (prefill burst → dense decode → 3-request long tail)
on a real Kubernetes GPU cluster (Qwen3-0.6B on vLLM under Dynamo), five scenarios ×
three runs, compared against a same-topology **2P2D** control. GPU-seconds are
integrated **by the role each pod actually held** at each tick (a live census), not
by its static deployment. Prompts carry a per-run nonce so the prefix cache never
warms one scenario from another.

**S2 reallocates capacity at a fixed 4 GPUs** — capacity follows demand:

| Group | prefill GPU·s (2P2D → switch) | decode GPU·s (2P2D → switch) |
|-------|------------------------------|------------------------------|
| A prefill burst | 75.4 → **133.3 (+77%)** | 75.4 → 63.5 |
| B decode dense  | 45.8 → 50.6 | 45.8 → **50.4** |

Router prefill-queue wait 29.5 → 24.7 ms; decode-phase TTFT 327 → 291 ms.

**S3 reclaims GPU time** — pool contracts 2 → 1 decoders, GPU freed **12.2 s early**,
at the cost of a slightly longer tail (makespan 82.9 → 85.4 s).

### Honest finding

Each mechanism **does exactly what it is specified to do at the phase level**, but on
this workload the end-to-end **batch makespan does not improve** (S2: 82.9 → 83.1 s;
mixed: → 88.3 s). This is *structural*, not a mechanism failure: the makespan is set
by the decode tail, which neither primitive targets, and on this small batch the
fixed action costs stack without a phase to amortize them. The switch cost is O(1)
and the reallocation is +77%, so we expect this to invert into a net win at
production rollout scale (larger, genuinely prefill-bound bursts; more workers). This
result is reported as *when the mechanism helps*, not *whether it works*.

---

## Repository layout

```
rl-scaling-controller/   the control plane — S1 FSM, S2 role-switch decision engine,
                         S3 consolidation decision engine, metrics collector
rl-signal-sdk/           a small SDK for emitting RL rollout phase signals
deploy/                  Kubernetes manifests (dual-mode workers, RBAC, controller)
test-scripts/            the phased-workload evaluation harness + gate checks
dynamo-integration/      the worker-side (data-plane) changes: patch + explanation
tutorial/                deployment guides
```

The **worker-side** protocol (in-place role flip, live migration) lives in a fork of
[NVIDIA Dynamo](https://github.com/ai-dynamo/dynamo) — see
[`dynamo-integration/`](dynamo-integration/) for the self-contained patch and a full
explanation of what changed and why.

---

## Getting started

The control plane is standard Python:

```bash
cd rl-scaling-controller
pip install -e .
pytest                       # unit tests for the S1/S2/S3 decision logic
```

Running the full end-to-end evaluation needs a Kubernetes cluster with GPU nodes and
the Dynamo runtime built from the [fork branch](dynamo-integration/). The evaluation
harness and its quality gates are in [`test-scripts/`](test-scripts/); image-build
and CI/CD notes are in [`RL-SCALING-IMAGE-BUILD.md`](RL-SCALING-IMAGE-BUILD.md) and
[`CICD.md`](CICD.md).

---

## License

[Apache-2.0](LICENSE). The worker-side changes derive from NVIDIA Dynamo, which is
also Apache-2.0.
