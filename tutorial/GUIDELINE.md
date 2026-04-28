# RL-Scaling — Runnable Guideline

End-to-end implementation of the three RL-driven scaling scenarios described
in [`tutorial/scaling/RL_Scaling_Unified_Design.md`](tutorial/scaling/RL_Scaling_Unified_Design.md):

| Scenario | Name | Status |
| -------- | ---- | ------ |
| **S1** | Rollout Scale Up/Down | ✅ Fully implemented & tested |
| **S2** | Elastic Role Switch | ✅ Python orchestration done; Rust reconfig stubbed (see [`RL_SCALING_RUST_CHANGES.md`](https://github.com/shqizhang/dynamo/blob/RL-Scaling/RL_SCALING_RUST_CHANGES.md) on the dynamo fork) |
| **S3** | Request Consolidation | ✅ Recompute-prefill fallback implemented & tested; full NIXL D2D migration documented as future Rust work |

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
    └── tests/{test_dual_mode,test_migration}.py
RL_SCALING_RUST_CHANGES.md                   ← pending Rust patches (NEW)
```

---

## 2. Local development

### 2.1 Set up venv & install both Python packages

```powershell
cd c:\projects\RL-Scaling
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e ".\rl-signal-sdk[test]" -e ".\rl-scaling-controller[test]"
```

### 2.2 Run the test suite

| Command | Coverage |
| ------- | -------- |
| `.\.venv\Scripts\python.exe -m pytest rl-signal-sdk -q` | 24 tests (events, emitter, transport) |
| `.\.venv\Scripts\python.exe -m pytest rl-scaling-controller -q` | 54 tests (state machine, planner, DGDSA, signal API, role-switch, consolidation) |

Total: **78 passing** controller-side unit tests.

Dynamo-side tests (require a Linux/CUDA dev env with vLLM installed):

```bash
cd dynamo
pytest components/src/dynamo/vllm/tests/test_dual_mode.py -q   # 10 tests
pytest components/src/dynamo/vllm/tests/test_migration.py -q   #  9 tests
```

(Both files were verified to pass against stub handlers on Windows during
development; see commit `shengqi : S2 …` and `shengqi : S3 …` on the
`RL-Scaling` branch of the fork.)

### 2.3 Run the controller against an in-memory cluster (smoke)

```powershell
$env:DYNAMO_NAMESPACE="dynamo"
$env:DGD_NAME="rl-serving"
.\.venv\Scripts\python.exe -m rl_scaling_controller.main
# In another shell:
curl -X POST http://localhost:8080/api/v1/signals/sampling_progress `
     -H "Content-Type: application/json" `
     -d '{\"progress\":0.85,\"batch_meta\":{\"batch_size\":128,\"avg_isl\":500}}'
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

S3 only needs `--enable-migration` on decode workers; the recompute-prefill
fallback works against the stock vLLM v1.0.1 engine.

---

## 4. Test matrix

| Design test ID | File | Test |
| -- | ---- | ---- |
| S1-T1..T7 | `rl-scaling-controller/tests/test_state_machine.py` | `TestSamplingProgressTriggersPreWarm`, `TestSamplingDone`, `TestControlLoop`, `TestIllegalTransitions`, `TestHistory` |
| S1-T8 | `rl-scaling-controller/tests/test_capacity_planner.py` | `TestCapacityPlanner` (7 cases) |
| S1-T9 | `rl-scaling-controller/tests/test_dgdsa_client.py` | `TestK8sDGDSAClient` (3 cases) |
| S1-T10 | `rl-scaling-controller/tests/test_signal_receiver.py` | `TestSignalReceiverEndpoints` (8 cases) |
| S2-T1..T7 | `rl-scaling-controller/tests/test_role_switch.py` | `TestStrategy`, `TestDecodeToPrefill`, `TestPrefillToDecode`, `TestDebounce`, `TestDisabled`, `TestNoTriggerConditions`, `TestClientFailure`, `TestDualModeClient` |
| S2-T8..T11 | `dynamo/components/src/dynamo/vllm/tests/test_dual_mode.py` | `TestDualModeWorker` (full-flip orchestration order, sleep failure rollback, wake failure recovery, idempotency, no-publisher) + `TestSetDisaggregationMode` |
| S3-T1..T7 | `rl-scaling-controller/tests/test_consolidation.py` | `TestDecisionEngine` (10 cases) |
| S3-T8..T11 | `rl-scaling-controller/tests/test_consolidation.py` | `TestConsolidationController` (4 cases) |
| S3-T12..T14 | `dynamo/components/src/dynamo/vllm/tests/test_migration.py` | `TestMigrateOut`, `TestMigrateIn`, `TestRoundtrip` |

---

## 5. Known limitations

* **RTX 3090 single-node**: `cuda-checkpoint` is not supported, so S1 falls
  back to `sleep_mode=2` (full re-init). Works, just slower.
* **S2 Rust reconfig is stubbed**: the Python orchestration is correct and
  unit-tested; flipping the stubs to real reconfig requires
  upstream-vLLM patches tracked in `RL_SCALING_RUST_CHANGES.md`.
* **S3 KV-D2D migration is stubbed**: Python uses recompute-prefill (~1
  prefill of overhead per migrated request). Acceptable for the design
  threshold (only migrate when remaining runtime ≫ migration cost).
* **No K8s deployment manifests are committed yet** — the controller is
  designed as a single-replica `Deployment` behind a `ClusterIP` Service
  on port 8080; sample YAMLs to be added in a follow-up.

---

## 6. Commit log (this work)

* `RL-Scaling` repo (`main`):
  * `shengqi : S1 rollout scale up/down — rl-signal-sdk + rl-scaling-controller (state machine, capacity planner, signal receiver, DGDSA client, metrics collector) with 54 unit tests`
  * `shengqi : S2 role switch controller module (decision engine + dual-mode HTTP client + strategy) with 10 async unit tests`
  * `shengqi : S3 consolidation controller module (decision engine + migration HTTP client) with 14 unit tests`
* `dynamo` repo (`RL-Scaling`, base `v1.0.1`):
  * `shengqi : S2 elastic role switch — DualModeWorker (Python) reusing sleep/wake_up + set_disaggregation_mode on BaseWorkerHandler + tests; Rust reconfig stubbed`
  * `shengqi : S3 request consolidation fallback — migrate_out/migrate_in (recompute-prefill) MigrationHandler with 9 tests; full NIXL D2D documented as future work`

No commits were pushed to remotes per instruction.
