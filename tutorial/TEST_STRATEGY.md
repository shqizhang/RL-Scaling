# RL-Scaling — Deployment & Test Strategy

This document is the **single source of truth** for how to deploy the
RL-Scaling control plane (controller + Dynamo dual-mode workers) to a real
cluster and how to verify, step-by-step, that S1, S2, and S3 are
functionally correct.

It complements [GUIDELINE.md](GUIDELINE.md), which covers package layout,
local dev, and env vars.

---

## 0. Test pyramid

```
          ┌────────────────────┐
          │   E2E on cluster   │  ← test-scripts/test-s{1,2,3}.sh   (this doc)
          ├────────────────────┤
          │ Component / smoke  │  ← deploy-controller.sh + /api/v1/status
          ├────────────────────┤
          │     Unit tests     │  ← pytest, 78 + 19 = 97 tests, run on every PR
          └────────────────────┘
```

| Layer | What it covers | Where |
| ----- | -------------- | ----- |
| **Unit** | Pure decision logic; no network, no K8s | `rl-scaling-controller/tests`, `rl-signal-sdk/tests`, `dynamo/components/src/dynamo/vllm/tests` |
| **Smoke** | Container starts, HTTP `/status` answers, RBAC works | [deploy-controller.sh](deploy/deploy-controller.sh) trailing curl |
| **E2E**  | Real signals → real DGDSA replica changes → real worker behaviour | [test-scripts/](test-scripts/) |

> **Rule of thumb**: never push a change without **both** the affected
> unit tests and the corresponding scenario E2E script passing.

---

## 1. Deploy to a server

### 1.1 Prerequisites on the cluster

| Component | Required version | Notes |
| --------- | ---------------- | ----- |
| Kubernetes | 1.28+ | tested on k3s & EKS 1.29 |
| `kubectl`  | matching minor   | configured against target cluster |
| Dynamo CRDs (DGD, DGDSA) | from `v1.0.1` of the fork | install via `dynamo-platform` Helm chart |
| Prometheus | kube-prometheus-stack | scrapes the `/metrics` endpoint of every Dynamo worker |
| (Optional) NVIDIA GPU operator | latest | for prefill/decode worker pods |
| Container registry | any | must be reachable from cluster nodes |

### 1.2 Build & push the controller image

```bash
export IMAGE=ghcr.io/<you>/rl-scaling-controller:v0.1.0
export NAMESPACE=dynamo
./deploy/deploy-controller.sh
```

`deploy-controller.sh`:
1. `docker build -f deploy/Dockerfile`
2. `docker push` (skipped when tag ends with `:dev`)
3. `kubectl apply` of [01-rbac.yaml](deploy/manifests/01-rbac.yaml),
   [02-configmap.yaml](deploy/manifests/02-configmap.yaml),
   [03-deployment.yaml](deploy/manifests/03-deployment.yaml)
4. `kubectl rollout status` + a self-health curl from inside the pod.

### 1.3 Verify the controller is healthy

```bash
kubectl -n dynamo port-forward svc/rl-scaling-controller 8080:8080 &
curl -s http://localhost:8080/api/v1/status | jq
```

Expected (initial state):

```json
{
  "state": "IDLE",
  "role_switch_enabled": false,
  "consolidation_enabled": false,
  "current_replicas": { "prefill": 1, "decode": 1 },
  "last_signal": null
}
```

### 1.4 Enable optional features

S2 and S3 are off by default. To enable them, edit the ConfigMap and
restart the deployment:

```bash
kubectl -n dynamo edit configmap rl-scaling-controller-config
# set ROLE_SWITCH_ENABLED=true and/or CONSOLIDATION_ENABLED=true
kubectl -n dynamo rollout restart deploy/rl-scaling-controller
```

### 1.5 Deploy / re-deploy Dynamo workers with dual-mode (S2)

Patch the DGD spec for at least one worker class:

```yaml
# excerpt
spec:
  decode:
    extraArgs:
      - "--dual-mode"
      - "--initial-role=decode"
      - "--enable-migration"      # for S3
```

`--enable-migration` enables the new `/v1/migration/{out,in}` endpoints
served by [`migration.py`](https://github.com/shqizhang/dynamo/blob/RL-Scaling/components/src/dynamo/vllm/migration.py).

### 1.6 Teardown

```bash
./deploy/teardown-controller.sh
```

This removes only the controller; the DGD/DGDSA workloads are untouched.

---

## 2. Per-scenario test strategy

Each scenario has the same shape:

1. **Pre-conditions** – env vars, replica counts, feature flags
2. **Stimulus** – exactly what we send to make the system act
3. **Expected behaviour** – measurable outcome
4. **Assertions** – concrete `kubectl` / `curl` checks
5. **Teardown** – return cluster to a clean state

The accompanying shell script automates steps 1–5 and exits non-zero on
any failed assertion.

---

### 2.1 S1 — Rollout Scale Up/Down

**Goal:** when the trainer signals `sampling_progress >= PRE_WARM_THRESHOLD`,
the controller pre-warms prefill+decode replicas; when `sampling_done`
arrives, it scales back to baseline after `COOLDOWN_SECONDS`.

| Step | Stimulus | Expected | Assertion in [test-s1.sh](test-scripts/test-s1.sh) |
| ---- | -------- | -------- | -------------------------------------------------- |
| 0 | `GET /api/v1/status` | `state == IDLE` | `wait_state IDLE` (no-op) |
| 1 | `POST /api/v1/signals/sampling_progress` `{progress:0.85,…}` | state → `WARM_UP`; DGDSA replicas grow | `wait_state WARM_UP 90`; `replicas grew` |
| 2 | (workers come up, Prometheus reports ready) | state → `ACTIVE` | `wait_state ACTIVE 180` |
| 3 | `POST /api/v1/signals/sampling_done` | state → `COOL_DOWN` then `IDLE` after grace | `wait_state COOL_DOWN 30 && wait_state IDLE 45` |
| 4 | (none) | replicas back to baseline | `(( P <= P0 && D <= D0 ))` |

**Run:**

```bash
CONTROLLER_URL=http://localhost:8080 \
NAMESPACE=dynamo \
DGD_NAME=rl-serving \
./test-scripts/test-s1.sh
```

**Negative tests** already covered by unit suite
([`test_state_machine.py`](rl-scaling-controller/tests/test_state_machine.py)):
illegal transitions, idempotent signals, history truncation.

---

### 2.2 S2 — Elastic Role Switch

**Goal:** a dual-mode worker can flip from `decode` → `prefill` (or vice
versa) at runtime, the controller observes the change, and inflight
generations are routed to the new role.

> **Reminder.** The actual NIXL/KV reconfig is stubbed pending the Rust
> patches in
> [RL_SCALING_RUST_CHANGES.md](https://github.com/shqizhang/dynamo/blob/RL-Scaling/RL_SCALING_RUST_CHANGES.md).
> The E2E here therefore validates **orchestration & observability**,
> not GPU-level memory layout. When the Rust pieces land, only step 4
> (routing) gains real teeth.

| Step | Stimulus | Expected | Assertion in [test-s2.sh](test-scripts/test-s2.sh) |
| ---- | -------- | -------- | -------------------------------------------------- |
| 0 | `GET worker /v1/role` | initial role reported | `INITIAL_ROLE in {prefill,decode}` |
| 1 | `GET controller /api/v1/status` | `role_switch_enabled == true` | env-flag check |
| 2 | `POST worker /v1/role {target_role}` | sleep → reconfig (stub) → wake; `/v1/role` returns new role within 30 s | `worker_role == TARGET_ROLE` |
| 3 | `GET controller /api/v1/events?type=WorkerRoleChanged` | event recorded with matching `target_role` | python assertion |
| 4 | new generate request | lands on a worker whose role == `TARGET_ROLE` | `LANDED == TARGET_ROLE` |
| 5 | flip back | original role restored | `worker_role == INITIAL_ROLE` |

**Run:**

```bash
CONTROLLER_URL=http://localhost:8080 \
NAMESPACE=dynamo \
TARGET_POD=rl-serving-decodeworker-0 \
./test-scripts/test-s2.sh
```

**Failure-injection tests** (covered by unit suite
[`test_dual_mode.py`](https://github.com/shqizhang/dynamo/blob/RL-Scaling/components/src/dynamo/vllm/tests/test_dual_mode.py)):
sleep failure rolls back; wake failure recovers; idempotent flips do no
work.

---

### 2.3 S3 — Request Consolidation

**Goal:** when a decode worker has been mostly idle for `MIN_BATCH_COMPLETION`
of the batch and a peer worker is loaded, the controller migrates the
remaining requests to the peer (recompute-prefill fallback) and scales the
decode DGDSA down.

> **Reminder.** Until NIXL D2D KV-block transfer lands, migration uses
> recompute-prefill: the decode worker exports `(prompt + generated)` and
> the target re-prefills. Cost-benefit is bounded by
> `migration_time = req_count * PER_REQUEST_MIGRATION_OVERHEAD < remaining * 0.5`.

| Step | Stimulus | Expected | Assertion in [test-s3.sh](test-scripts/test-s3.sh) |
| ---- | -------- | -------- | -------------------------------------------------- |
| 0 | (config) | `consolidation_enabled` and `>=2` decode replicas | env+kubectl checks |
| 1 | run baseline load `seed=42` on worker 0 | capture sha256 of outputs | `/tmp/s3-baseline.sha` |
| 2 | uneven load: 1 short req on w0, 6 long on w1 | source w0 has low inflight | `worker_inflight` shows gap |
| 3 | `POST /api/v1/admin/consolidation/tick` | source paired with target | (no direct check; observed via 4) |
| 4 | wait | `dgdsa-decode.spec.replicas` decremented | `(( D < D0 ))` |
| 5 | wait for in-flights | all background `wait` returns 0 | shell `wait` |
| 6 | replay seed=42 | sha256 unchanged when greedy decoding | `diff` |
| 7 | `GET /api/v1/events?type=ConsolidationCompleted` | event with `migrated_requests >= 1` | python assertion |

**Run:**

```bash
CONTROLLER_URL=http://localhost:8080 \
NAMESPACE=dynamo \
DGD_NAME=rl-serving \
./test-scripts/test-s3.sh
```

**Decision-engine tests** ([`test_consolidation.py`](rl-scaling-controller/tests/test_consolidation.py))
already cover: gating on completion %, two-pointer pairing, min-replicas
guard, cost-benefit ratio, debounce, disabled flag.

---

## 3. Master test runner

```bash
# unit tests only (CI-friendly, no cluster needed)
./test-scripts/run-all.sh unit

# E2E only (requires deployed cluster + port-forward)
./test-scripts/run-all.sh e2e

# everything
./test-scripts/run-all.sh all
```

Sample CI snippet (GitHub Actions):

```yaml
- name: Unit tests
  run: |
    python -m pip install -e ./rl-signal-sdk[test] -e ./rl-scaling-controller[test]
    ./test-scripts/run-all.sh unit
```

---

## 4. Observability checklist

Before declaring an environment "ready for E2E", verify:

| Signal | Where | Why |
| ------ | ----- | --- |
| `dynamo_controller_state` Prometheus gauge | grafana | confirms the state machine is publishing |
| `dynamo_controller_replica_target{role=…}` | grafana | matches `kubectl get dgdsa` |
| `dynamo_dual_mode_role{pod=…}` | grafana | S2 — should flip during test-s2 |
| `dynamo_migration_total{result="ok"}` | grafana | S3 — should increment during test-s3 |
| Controller pod logs | `kubectl logs` | look for `level=ERROR` lines |

If any of those is missing, fix **before** running scenario tests; the
shell scripts assume the metrics endpoints exist.

---

## 5. Common failure modes & how to triage

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| S1 stuck in `WARM_UP`, replicas grew but state never moves | Prometheus URL wrong → metrics collector returns 0 ready workers | Fix `PROMETHEUS_URL`, restart controller |
| S1 `state = IDLE` ignored signal | sampling_progress < `PRE_WARM_THRESHOLD` | lower threshold or send 0.85+ |
| S2 worker `/v1/role` 404 | worker not started with `--dual-mode` | redeploy DGD with `extraArgs` |
| S2 flips role but state did not actually change | stubbed reconfig (expected today) | wait for Rust patches |
| S3 controller never tries to migrate | `MIN_BATCH_COMPLETION` not yet met | lower it for the test or wait |
| S3 `migrate_in` 422 | request payload missing `sampling_params` | ensure source is on RL-Scaling branch (commit `e04726ad`) |
| RBAC denied on `dgdsa/scale` | wrong ServiceAccount | re-apply [01-rbac.yaml](deploy/manifests/01-rbac.yaml) |

---

## 6. Definition of done

A change is "done" when **all** of these are true:

1. `pytest rl-signal-sdk rl-scaling-controller -q` → green (97 tests).
2. Affected scenario E2E script (`test-s1.sh`/`test-s2.sh`/`test-s3.sh`)
   exits 0 on a real cluster.
3. `kubectl logs deploy/rl-scaling-controller` is clean for one full
   cool-down cycle.
4. Grafana dashboard shows expected gauges/counters moving.
5. The change is committed in the format `shengqi : <work>` (no force-push,
   no remote push without review).
