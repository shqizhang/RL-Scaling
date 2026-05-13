# RL-Scaling — Runnable Guideline

End-to-end implementation of the three RL-driven scaling scenarios described
in [`tutorial/scaling/RL_Scaling_Unified_Design.md`](tutorial/scaling/RL_Scaling_Unified_Design.md):

| Scenario | Name | Status |
| -------- | ---- | ------ |
| **S1** | Rollout Scale Up/Down | ✅ Fully implemented & tested |
| **S2** | Elastic Role Switch | ✅ Implemented & E2E tested on cluster (sidecar-based `switch_role`, WorkerSet shrink/grow verified) |
| **S3** | Request Consolidation | ✅ Implemented & E2E tested on cluster (coordinated `/migrate` with recompute-prefill; per-request ID tracking proves KV consistency) |

**Hard constraint preserved**: every Dynamo edit lives behind a feature flag
or in a new module. Existing single-mode workers behave unchanged.

---

## 1. Repository Layout

```
RL-Scaling/                                  ← this repo (git branch: main)
├── rl-signal-sdk/                           ← lightweight signal emitter for the RL trainer
│   └── src/rl_signal/{events,emitter,transport}.py
├── rl-scaling-controller/                   ← cluster-wide control plane (FastAPI)
│   └── src/rl_scaling_controller/
│       ├── state_machine.py                 ← S1: IDLE/WARM_UP/ACTIVE/COOL_DOWN
│       ├── capacity_planner.py              ← S1: total_tokens → (P, D)
│       ├── signal_receiver.py               ← S1: HTTP API for trainer signals
│       ├── dgdsa_client.py                  ← S1: K8s DGDSA scale subresource client
│       ├── metrics_collector.py             ← S1/S2: Prometheus client
│       ├── role_switch/                     ← S2 controller logic
│       ├── consolidation/                   ← S3 controller logic
│       └── main.py                          ← uvicorn entrypoint + control loop
└── tutorial/scaling/RL_Scaling_Unified_Design.md   ← original design doc

dynamo/                                      ← sibling repo (branch: RL-Scaling, base: v1.0.1)
└── components/src/dynamo/vllm/
    ├── handlers.py                          ← S2: + set_disaggregation_mode()
    ├── dual_mode.py                         ← S2: DualModeWorker orchestrator (NEW)
    ├── migration.py                         ← S3: MigrationHandler (NEW)
    ├── rl_scaling_sidecar.py                ← S2+S3: aiohttp sidecar on :9091 (NEW)
    └── tests/{test_dual_mode,test_migration,test_rl_scaling_sidecar}.py
RL_SCALING_RUST_CHANGES.md                   ← pending Rust patches (NEW)
```

---

## 2. Local development

### 2.1 Set up venv & install both Python packages

```bash
cd ~/IP/RL-Scaling
python -m venv .venv
source .venv/bin/activate
pip install -e "./rl-signal-sdk[test]" -e "./rl-scaling-controller[test]"
```

### 2.2 Run the test suite

| Command | Coverage |
| ------- | -------- |
| `pytest rl-signal-sdk -q` | 13 tests (emitter, events, transport) |
| `pytest rl-scaling-controller -q` | 59 tests (state machine, planner, DGDSA, signal API, role-switch, consolidation) |

Total: **72 passing** controller-side unit tests.

Dynamo-side tests (require a Linux dev env with vLLM installed):

```bash
cd ~/IP/dynamo
pytest components/src/dynamo/vllm/tests/test_dual_mode.py -q       # 14 tests
pytest components/src/dynamo/vllm/tests/test_migration.py -q       # 31 tests
pytest components/src/dynamo/vllm/tests/test_rl_scaling_sidecar.py -q  # 23 tests
```

Total: **68 passing** Dynamo-side RL-Scaling unit tests.

### 2.3 Run the controller against an in-memory cluster (smoke)

```bash
export DYNAMO_NAMESPACE=dynamo
export DGD_NAME=rl-serving
python -m rl_scaling_controller.main
# In another shell:
curl -X POST http://localhost:8080/api/v1/signals/sampling_progress \
     -H "Content-Type: application/json" \
     -d '{"progress":0.85,"batch_meta":{"batch_size":128,"avg_isl":500}}'
curl http://localhost:8080/api/v1/status
```

If no Kubernetes config is reachable, `main.py` automatically falls back
to `InMemoryDGDSAClient` so the API is fully exercisable without a cluster.

---

## 3. Production deployment

### 3.1 Build & push the controller image

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY rl-signal-sdk rl-scaling-controller ./
RUN pip install ./rl-signal-sdk ./rl-scaling-controller[k8s]
EXPOSE 8080
CMD ["python","-m","rl_scaling_controller.main"]
```

### 3.2 Required configuration (env vars)

| Var | Default | Notes |
| --- | ------- | ----- |
| `DYNAMO_NAMESPACE` | `dynamo` | Where the DGD lives |
| `DGD_NAME` | `rl-serving` | DGDSAs are named `{DGD_NAME}-prefill` / `…-decode` |
| `PROMETHEUS_URL` | `http://prometheus-kube-prometheus-prometheus.monitoring:9090` | |
| `PRE_WARM_THRESHOLD` | `0.8` | S1 trigger |
| `COOLDOWN_SECONDS` | `30` | S1 idle grace before scale-to-zero |
| `MAX_GPUS` | `8` | Hard cap |
| `ROLE_SWITCH_ENABLED` | `false` | **S2 master switch** |
| `MIN_SWITCH_INTERVAL` | `30.0` | Debounce between role flips |
| `CONSOLIDATION_ENABLED` | `false` | **S3 master switch** |
| `CONSOLIDATION_THRESHOLD` | `3` | Max in-flight to consider a worker drainable |
| `MIN_BATCH_COMPLETION` | `0.6` | Skip consolidation early in the batch |

### 3.3 RBAC

The controller patches DGDSA scale subresources, so it needs:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: rl-scaling-controller }
rules:
- apiGroups: [dynamo.nvidia.com]
  resources: [dynamographdeploymentscalingadapters/scale]
  verbs: [get, patch]
- apiGroups: [dynamo.nvidia.com]
  resources: [dynamographdeploymentscalingadapters]
  verbs: [get, list, watch]
```

### 3.4 Enabling S2 / S3 on the worker side

S2 needs Dynamo workers launched with `--dual-mode --initial-role <prefill|decode>`
*and* the Rust reconfig APIs from
[`RL_SCALING_RUST_CHANGES.md`](https://github.com/shqizhang/dynamo/blob/RL-Scaling/RL_SCALING_RUST_CHANGES.md).
Until those are merged, the controller's role-switch loop will issue the
HTTP call but the worker will only sleep/wake (no actual NIXL/KV reconfig);
that is the *documented stubbed* behaviour, not a defect.

S3 needs the coordinated migration sidecar, enabled by
`DYNAMO_RL_DUAL_MODE=1` and `DYNAMO_RL_SIDECAR_PORT=9091` on decode
workers. The sidecar exposes `POST /migrate` (coordinated out→in→complete)
and `POST /migrate_in` endpoints. The recompute-prefill fallback works
against the stock vLLM v1 engine; NIXL D2D transfer is wired but falls
back to recompute when block metadata is unavailable.

---

## 4. Test matrix

### Unit tests

| Design test ID | File | Tests |
| -- | ---- | ---- |
| S1-T1..T7 | `rl-scaling-controller/tests/test_state_machine.py` | 14 tests (transitions, illegal moves, history) |
| S1-T8 | `rl-scaling-controller/tests/test_capacity_planner.py` | 7 tests |
| S1-T9 | `rl-scaling-controller/tests/test_dgdsa_client.py` | 6 tests |
| S1-T10 | `rl-scaling-controller/tests/test_signal_receiver.py` | 8 tests |
| S2-T1..T7 | `rl-scaling-controller/tests/test_role_switch.py` | 10 tests (strategy, debounce, disabled, client) |
| S2-T8..T14 | `dynamo/components/src/dynamo/vllm/tests/test_dual_mode.py` | 14 tests (flip orchestration, sleep/wake rollback, idempotency) |
| S3-T1..T10 | `rl-scaling-controller/tests/test_consolidation.py` | 14 tests (decision engine, controller) |
| S3-T11..T31 | `dynamo/components/src/dynamo/vllm/tests/test_migration.py` | 31 tests (migrate_out, migrate_in, cost-benefit, rollback, roundtrip) |
| Sidecar | `dynamo/components/src/dynamo/vllm/tests/test_rl_scaling_sidecar.py` | 23 tests (HTTP endpoints, registry, migration coordination) |

### E2E tests (on-cluster)

| Scenario | Script | Pass criteria |
| -- | ---- | ---- |
| S2 | `test-scripts/test-s2-elastic.sh` | Role flip D→P→D, all requests HTTP 200, routing attribution shifts |
| S3 | `test-scripts/test-s3-consolidation.sh` | 6/6 migrations OK, all `left_D1=true`, all `D2_accepted=true`, D1 active ↓, D2 gen_tokens ↑, oversize declined |

---

## 5. Known limitations

* **RTX 3090 single-node**: `cuda-checkpoint` is not supported, so S1 falls
  back to `sleep_mode=2` (full re-init). Works, just slower.
* **S2 Rust reconfig is stubbed**: the Python orchestration and sidecar
  are fully implemented; flipping the stubs to real NIXL/KV-pool reconfig
  requires upstream-vLLM patches tracked in `RL_SCALING_RUST_CHANGES.md`.
  The E2E test validates WorkerSet shrink/grow and routing attribution.
* **S3 uses recompute-prefill by default**: NIXL D2D KV-block transfer is
  wired (`DYNAMO_RL_CONNECTOR_ENABLED=1`) but falls back to recompute when
  KVBM block IDs are unavailable. Recompute-prefill is bounded by
  `max_replay_tokens=8192` (cost-benefit gate).
* **InProcessRequestRegistry does not track migrated-in requests**: the D2
  registry only tracks requests from the normal routing path.  Migrated
  requests are submitted directly to the engine. The E2E test proves D2
  acceptance via the `/migrate` response (`path=recompute`), not the registry.
* **No K8s deployment manifests for the controller are committed yet** — the
  controller is designed as a single-replica `Deployment`; sample YAMLs to
  be added in a follow-up.

---

## 6. Commit log (this work)

* `RL-Scaling` repo (`main`):
  * `shengqi : S1 rollout scale up/down — rl-signal-sdk + rl-scaling-controller (state machine, capacity planner, signal receiver, DGDSA client, metrics collector) with unit tests`
  * `shengqi : S2 role switch controller module (decision engine + dual-mode HTTP client + strategy) with async unit tests`
  * `shengqi : S3 consolidation controller module (decision engine + migration HTTP client) with unit tests`
  * `shengqi : E2E test scripts (test-s2-elastic.sh, test-s3-consolidation.sh) with per-request KV migration proof`
* `dynamo` repo (`RL-Scaling`, base `v1.0.1`):
  * `shengqi : S2 elastic role switch — DualModeWorker + rl_scaling_sidecar (switch_role, WorkerSet shrink/grow) + 14 unit tests`
  * `shengqi : S3 request consolidation — coordinated /migrate endpoint (migrate_out→migrate_in→complete/rollback), recompute-prefill + NIXL connector, 31+23 unit tests`

No commits were pushed to remotes per instruction.
