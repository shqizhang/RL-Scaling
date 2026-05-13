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
          │   E2E on cluster   │  ← test-scripts/test-s{2,3}*.sh   (this doc)
          ├────────────────────┤
          │ Component / smoke  │  ← deploy-controller.sh + /api/v1/status
          ├────────────────────┤
          │     Unit tests     │  ← pytest, 72 + 68 = 140 tests, run on every PR
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

**Goal:** a dual-mode decode worker can be switched to prefill role
(shrinking the decode WorkerSet) and back (re-growing it), all via the
in-pod sidecar, without losing in-flight requests.

The test uses the **sidecar** (`POST :9091/switch_role`) directly—it does
not go through the controller. This isolates the worker-side orchestration.

| Step | Stimulus | Expected | Assertion in [test-s2-elastic.sh](../test-scripts/test-s2-elastic.sh) |
| ---- | -------- | -------- | -------------------------------------------------- |
| 0 | Discover 2 Ready decode pods, 1 frontend | pods exist | label-selector + readiness filter |
| 1 | `GET :9090/metrics` on both decoders | baseline `generation_tokens_total` captured | `T0_baseline` |
| 2 | Submit streaming chat workload via frontend `/v1/chat/completions` | requests distributed to both decoders | metrics show `num_requests_running > 0` |
| 3 | `POST :9091/switch_role {"target_role":"prefill"}` on D1 | D1 sleeps, WorkerSet shrinks, D1 exits routing | response `status=ok`, CR diff shows D1 gone from discovery |
| 4 | Continue sending requests | only D2 receives new traffic | D1 `num_requests_running=0`, D2 increments |
| 5 | `POST :9091/switch_role {"target_role":"decode"}` on D1 | D1 wakes, re-joins WorkerSet | response `status=ok`, CR diff shows D1 back |
| 6 | Final workload burst | D1 receives traffic again | D1 `generation_tokens_total` grows |
| 7 | Verify all HTTP responses | every streaming request got HTTP 200 | `HTTP_ERRORS == 0` |

**Run:**

```bash
cd test-scripts && bash test-s2-elastic.sh
```

---

### 2.3 S3 — Request Consolidation

**Goal:** in-flight decode requests migrate from one decoder (D1) to another
(D2) via the coordinated `POST /migrate` endpoint, preserving KV consistency.
The test proves per-request ID movement and token continuity.

The test uses the **sidecar** (`POST :9091/migrate`) directly and tracks
individual request IDs before and after each migration.

| Step | Stimulus | Expected | Assertion in [test-s3-consolidation.sh](../test-scripts/test-s3-consolidation.sh) |
| ---- | -------- | -------- | -------------------------------------------------- |
| 0 | Discover 2 Ready decode pods, 1 frontend | pods exist | label-selector + readiness filter |
| 1 | Submit 80 long-running chats (`max_tokens=8000`) via frontend | 40 on D1, 40 on D2 (router distributes) | `T1 active: D1=40 D2=40` |
| 2 | For each of 6 migrations: snapshot D1/D2 active request IDs | pre-migration ID lists captured | `get_active_ids()` |
| 3 | `POST D1:9091/migrate {target_url=D2}` | D1 `migrate_out` → D2 `migrate_in` → `migration_complete` | `status=ok`, `path=recompute` |
| 4 | Verify request_id left D1’s active list | ID gone from D1 registry | `left_D1=true` |
| 5 | Verify D2 accepted (via `/migrate` response) | `migrate_in` returned ok | `D2_accepted=true` |
| 6 | After all migrations: D1 active count decreased | `T1=40 → T2≤34` | `PASS_GPU_RELEASE=true` |
| 7 | After drain: D2 `generation_tokens_total` grew | Δ > 0 | `PASS_DST_TOKENS=true` |
| 8 | Synthetic oversize `migrate_in` (9000 tokens) | declined by cost-benefit gate | `status=declined` |

**Run:**

```bash
cd test-scripts && bash test-s3-consolidation.sh
```

**Output:** A timestamped `REPORT.md` under `test-scripts/reports/` with:
- Full D1/D2 active request ID lists at T1
- Per-migration table (request_id, D1 decoded tokens, remaining, replay, left_D1, D2_accepted)
- ASCII diagram of the coordinated migration protocol
- Per-migration token evidence chain
- D1/D2 worker log excerpts (hold/release/decline events)
- Overall pass/fail verdict (6 criteria)

---

## 3. Master test runner

```bash
# unit tests only (CI-friendly, no cluster needed)
./test-scripts/run-all.sh unit

# E2E only (requires deployed cluster with dual-mode decode pods)
cd test-scripts
bash test-s2-elastic.sh         # S2 role switch
bash test-s3-consolidation.sh   # S3 migration

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
| S2 `switch_role` returns 503 during first ~60s | Worker still loading model (liveness probe returns 503) | Wait for pod to be Ready before starting test |
| S2 WorkerSet does not shrink | Discovery CR not patched; `DYNAMO_RL_DUAL_MODE=1` not set | Redeploy with dual-mode env vars |
| S3 `id_on_d2` always false | Migrated requests bypass `InProcessRequestRegistry` | Expected behaviour; use `D2_accepted` from `/migrate` response instead |
| S3 `migrate_in` returns `declined` | replay_total exceeds `max_replay_tokens=8192` | Use shorter prompts or lower the cost-benefit threshold |
| S3 pod discovery picks CrashLoopBackOff pods | `--field-selector=status.phase=Running` matches non-Ready pods | Use Python readiness filter (already fixed in test scripts) |
| RBAC denied on `dgdsa/scale` | wrong ServiceAccount | re-apply [01-rbac.yaml](deploy/manifests/01-rbac.yaml) |

---

## 6. Definition of done

A change is "done" when **all** of these are true:

1. `pytest rl-signal-sdk rl-scaling-controller -q` → green (72 tests).
2. `pytest dynamo/components/src/dynamo/vllm/tests/test_{dual_mode,migration,rl_scaling_sidecar}.py -q` → green (68 tests).
3. Affected scenario E2E script (`test-s2-elastic.sh` / `test-s3-consolidation.sh`)
   exits with `OVERALL=true` on a real cluster.
4. `kubectl logs` for all pods are clean during the test run.
5. The change is committed in the format `shengqi : <work>` (no force-push,
   no remote push without review).
