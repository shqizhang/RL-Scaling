# Dynamo Worker-Side Integration

This project has two halves. The **control plane** — the RL-signal-driven
autoscaling controller and the evaluation harness — lives in this repository.
The **data plane** — the changes that make a vLLM worker able to flip its
prefill/decode role in place and hand off live requests — lives inside a fork of
[NVIDIA Dynamo](https://github.com/ai-dynamo/dynamo), because that code must sit
next to the engine it drives.

This directory makes that second half reviewable without cloning the whole
framework:

| File | What it is |
|------|------------|
| [`dynamo-vllm-rl-scaling.patch`](dynamo-vllm-rl-scaling.patch) | A self-contained `git diff` of every worker-side change (3,680 insertions across 8 files) against the upstream Dynamo base. |
| [`COMMITS.txt`](COMMITS.txt) | The 26 commit messages behind those changes, in order — the debugging story in one page. |

**Fork branch:** `github.com/shqizhang/dynamo` @ `RL-Scaling`
(base commit `5534a9d`).

## What the patch changes

All changes are confined to `components/src/dynamo/vllm/`:

| File | Δ | Role |
|------|---|------|
| `dual_mode.py` | **+871 (new)** | `DualModeWorker.switch_role` — the S2 protocol: a three-stage zero-loss envelope (cordon → drain → outbound-KV drain) around a five-stage engine core (sleep → reconfig NIXL → reset prefix cache → re-register ModelCard → wake). |
| `migration.py` | **+508 (new)** | The S3 three-phase block-hold migration (`migrate_out` / `migrate_in` / `migration_complete`) with the at-least-one-copy invariant and the cost/benefit gate. |
| `rl_scaling_sidecar.py` | **+673 (new)** | An in-process aiohttp sidecar on `:9091` exposing `/switch_role`, `/migrate_*`, `/v1/role`, `/v1/active_requests` — the control-plane surface, off the data path. |
| `main.py` | +432 | Role-aware request dispatcher (one TCP slot, two ModelCards) and the ModelCard re-registrar. |
| `handlers.py` | +141 | Per-request token-progress registry used by the migration cost/benefit gate and straggler detection. |
| `tests/` | **+1,057 (new)** | Unit tests for the switch protocol, the migration protocol, and the sidecar. |

## Why these changes must live in the engine

A role switch is not a Kubernetes operation — it is a precisely ordered sequence
against live vLLM state (pause generation, free KV blocks, reset the prefix-cache
index *while the engine is asleep*, rebuild the NIXL connector for the new
transfer direction, then wake). Only code running inside the worker process can
sequence that safely. The controller in this repo decides *who* switches and
*when*; the worker decides *how*, and that "how" is what this patch implements.

The load-bearing design choice is that every worker boots with
`NixlConnector kv_both`: the KV-transfer configuration is fixed at engine
construction, so a role change is a ModelCard re-registration plus a
sleep/reset/wake cycle — never an engine rebuild, and therefore sub-second.

## Applying the patch

```bash
git clone https://github.com/ai-dynamo/dynamo && cd dynamo
git checkout 5534a9d
git apply /path/to/dynamo-vllm-rl-scaling.patch
```

Or simply check out the fork branch directly:

```bash
git clone -b RL-Scaling https://github.com/shqizhang/dynamo
```
