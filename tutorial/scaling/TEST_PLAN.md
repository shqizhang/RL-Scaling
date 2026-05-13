# RL-Scaling Test Plan — S1 / S2 / S3

> Companion to `RL_Scaling_Unified_Design.md` and `DEPLOYMENT_PIPELINE.md`.
> Scope: how to *prove* that each scenario's implementation is functionally
> correct on the deployed cluster, what to record before / during / after each
> run, and where to look on Grafana.

---

## 0. Cluster baseline (currently deployed)

| Component | Namespace | Image | Notes |
|---|---|---|---|
| RL-Scaling controller | `dynamo` | `ghcr.io/shqizhang/rl-scaling-controller:d5794b7` | FastAPI on `:8080` |
| Frontend (KV router) | `dynamo-system` | `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-6e4a559` | Service `vllm-v1-disagg-router-frontend:8000` |
| Prefill worker (DGDSA, replicas=1) | `dynamo-system` | same | `vllm-v1-disagg-router-vllmprefillworker-...` |
| Decode worker (DGDSA, replicas=1) | `dynamo-system` | same | `vllm-v1-disagg-router-vllmdecodeworker-...` |
| Prometheus | `monitoring` | `kube-prometheus-stack-84.1.0` | `prometheus-kube-prometheus-prometheus:9090` |
| Grafana | `monitoring` | bundled | NodePort `30030` (admin/prom-operator default) |

Smoke check passed with `prefill_worker_id` + `decode_worker_id` populated and TTFT ≈ 100 ms.

---

## 1. Test goal — what "correct" means per scenario

### S1 · Rollout-driven scale up/down
The controller **must drive the DGDSAs through `idle → warm_up → active → cool_down → idle`** in response to RL signals, and the K8s side must follow:
- DGDSA `.spec.replicas` increase on `warm_up` and drop to 0 on `idle`.
- Worker pods reach Ready before `active` is entered.
- GPUs are released and the local KV indexer is empty after `idle`.

This is the **most observable** scenario: every step has a K8s-level invariant.

### S2 · Elastic role switch (P ↔ D)
The sidecar asks a worker to flip its role. The worker must:
- accept `POST /switch_role` on the in-pod sidecar (port 9091),
- run the orchestrated *sleep → reconfig → wake* sequence,
- be removed from / re-added to the discovery WorkerSet,
- not lose / corrupt in-flight requests (drained before sleep).

The E2E test (`test-s2-elastic.sh`) validates WorkerSet shrink/grow and
routing attribution via per-pod Prometheus counters. The actual NIXL/KV
reconfig step is stubbed pending upstream Rust patches — the test verifies
the orchestration, not GPU-level memory layout.

### S3 · Request consolidation
When two decode workers are unevenly loaded, the sidecar's coordinated
`POST /migrate` endpoint moves an in-flight request from source (D1) to
target (D2). Per-request:
- D1 `migrate_out`: snapshot prompt+generated tokens, hold blocks (defer abort),
- D1 internally calls D2 `POST /migrate_in` with the state snapshot,
- D2 `migrate_in`: cost-benefit check (`max_replay_tokens=8192`), recompute-prefill,
- on success: D1 `migration_complete` aborts the held request and frees blocks,
- on failure: D1 `migration_rollback` releases the hold, request continues on D1.

The E2E test (`test-s3-consolidation.sh`) proves per-request KV consistency by:
1. recording D1/D2 active request ID lists before and after each migration,
2. verifying `left_D1=true` (ID gone from D1 registry) and `D2_accepted=true`
   (via `/migrate` response `path=recompute`),
3. verifying D2 `generation_tokens_total` grew after drain,
4. testing the cost-benefit gate with an oversize synthetic `migrate_in`.

---

## 2. What to record (pre / during / post)

For every run, capture into a timestamped run dir
`/tmp/rls-test/<scenario>-<YYYYmmdd-HHMMSS>/`:

### Pre-test snapshot (`pre.json`)
```bash
kubectl -n dynamo-system get dgd,dgdsa -o json
kubectl -n dynamo-system get pods -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
curl -s http://<controller>:8080/api/v1/status                          # state machine snapshot
curl -s http://<frontend>:8000/metrics > pre-frontend.metrics
for w in $(kubectl -n dynamo-system get pod -l ...); do
  kubectl -n dynamo-system exec "$w" -- curl -s 127.0.0.1:9090/metrics > pre-$w.metrics
done
```

### During-test event log (`events.log`)
- One line per controller state transition (tail `kubectl logs deploy/rl-scaling-controller -f`).
- One line per migrate / role-flip request (tail worker logs filtered by `[DualMode]` / `migration`).

### Post-test snapshot (`post.json`, `post-*.metrics`) — same as pre.

### Run summary (`summary.md`)
For each acceptance criterion below, mark PASS / FAIL with the metric/value
that supports the verdict and a Grafana panel link with `from`/`to` parameters.

---

## 3. Acceptance criteria + how to verify each on Grafana

Grafana is reachable at `http://<node>:30030`; pre-installed dashboards live in
`grafana_dashboards/` (loaded as ConfigMaps `grafana-disagg-dashboard`,
`grafana-dynamo-dashboard`, `grafana-operator-dashboard`,
`grafana-planner-dashboard`). The KVBM dashboard (`kvbm.json`) is bundled but
only shows numbers when the worker has `--enable-kvbm`; for S3 we use it for
the **negative** assertion (block-tier counters stay flat during recompute-prefill).

### S1 acceptance matrix

| Step | Source of truth | Where to look | Pass criterion |
|---|---|---|---|
| `idle → warm_up` | controller `/api/v1/status` | manual curl + log | `state` transitions within ≤ 5 s of POSTing `sampling_progress=0.85` |
| DGDSA replicas grow | `kubectl get dgdsa -w` | Operator dashboard panel **DGDSA replicas** (PromQL `kube_customresource_dynamographdeploymentscalingadapter_spec_replicas` if exposed, else use `kubectl`) | `prefill+decode replicas` increase before `active` |
| Worker pods Ready | `kube_pod_status_ready{condition="true"}` | Disagg dashboard panel **Worker pod state** | new pods reach `Ready=1` |
| GPUs allocated | `nvidia_gpu_num_devices` (DCGM exporter) or `kube_pod_container_resource_requests{resource="nvidia_com_gpu"}` | Dynamo dashboard **GPU allocation** | `Σ requested gpu` matches replicas |
| Inference works in `active` | `dynamo_frontend_requests_total` | Dynamo dashboard panel **Frontend RPS** | counter increments while load is sent |
| KV indexer non-empty | `dynamo_component_kv_cache_events_applied{event_type="stored"}` | Disagg dashboard **KV events** | rate > 0 during inference |
| `cool_down → idle` | controller `/api/v1/status` | logs | transitions after `batch_complete` + cooldown grace |
| GPUs released | same Dynamo panel | | drops back to baseline |
| KV indexer drained | `dynamo_component_kv_cache_events_applied{event_type="cleared"|"removed"}` rate = 0 *and* `kvbm_inflight_immutable` (if KVBM on) returns to 0 | KVBM dashboard | flat after `idle` |

### S2 acceptance matrix

S2 needs dual-mode decode pods (`DYNAMO_RL_DUAL_MODE=1`, `DYNAMO_RL_SIDECAR_PORT=9091`).

| Step | Source of truth | Where to look | Pass criterion |
|---|---|---|---|
| Discover pods | `kubectl get pod` with readiness filter | test script output | ≥2 decode pods Ready |
| Baseline metrics | `GET :9090/metrics` per pod | `T0_baseline` | `generation_tokens_total` captured |
| Role flip D→P | `POST :9091/switch_role {"target_role":"prefill"}` | sidecar response | `status=ok`, `switch_time_ms` populated |
| WorkerSet shrinks | Discovery CR diff | test script | D1 removed from CR |
| D1 not receiving traffic | `vllm:num_requests_running` on D1 | metrics | drops to 0 |
| Role flip P→D | `POST :9091/switch_role {"target_role":"decode"}` | sidecar response | `status=ok` |
| WorkerSet grows | Discovery CR diff | test script | D1 re-added to CR |
| D1 receives traffic again | `generation_tokens_total` on D1 | metrics | delta > 0 after re-join |
| No HTTP errors | all streaming requests | test script | `HTTP_ERRORS == 0` |

### S3 acceptance matrix

S3 needs dual-mode decode pods with `DYNAMO_RL_CONNECTOR_ENABLED=1` and ≥ 2 decode replicas.

| Step | Source of truth | Where to look | Pass criterion |
|---|---|---|---|
| ≥ 2 decode replicas, both serving | `kubectl get pod` + `vllm:num_requests_running` | test script | both > 0 after load |
| Pre-migration ID snapshot | `GET :9091/v1/active_requests` on D1, D2 | test script | ID lists captured |
| Migration triggered | `POST :9091/migrate {target_url=D2}` on D1 | sidecar response | `status=ok` |
| Request left D1 | D1 `active_requests` before vs after | test script | `left_D1=true` |
| D2 accepted | `/migrate` response `path=recompute\|connector` | test script | `D2_accepted=true` |
| Token state preserved | `/migrate` response `generated_token_count`, `replay_tokens` | test report | replay = prompt + generated |
| D1 active count decreased | `vllm:num_requests_running` T1→T2 | metrics | D1 count dropped |
| D2 generation tokens grew | `vllm:generation_tokens_total` T1→T3 | metrics | Δ > 0 |
| Cost-benefit gate works | synthetic oversize `migrate_in` (9000 tokens) | sidecar response | `status=declined` |
| Block hold timing | D1 worker logs: `hold` → `releasing` | `kubectl logs` | hold duration < 50ms |

#### About "recording each KV block ID"
Recompute-prefill is the default path. No KV blocks are transferred between
workers — D2 re-prefills the full prompt+generated sequence. The "correctness"
question is answered by:
- `left_D1=true` (D1 released the request),
- `D2_accepted=true` (D2 accepted and started decoding),
- D2 `generation_tokens_total` grew (D2 is actually generating tokens),
- hold time is short (blocks held only during the out→in→complete handshake).

A future phase with NIXL D2D will need block-id-level tracing (KVBM emits
`kvbm_*` per block move).

---

## 4. Grafana dashboards to keep open during a run

Open all four side-by-side:

1. **Disagg dashboard** (`grafana-disagg-dashboard`): per-worker inflight, TTFT, ITL, KV-events rate.
2. **Dynamo dashboard** (`grafana-dynamo-dashboard`): frontend RPS, queue depth, migration counter, model-config gauges.
3. **Operator dashboard** (`grafana-operator-dashboard`): DGD/DGDSA replica counts, scaling events.
4. **KVBM dashboard** (`kvbm.json`): cache hit-rate per tier, block offload/onboard counters (idle during S3 with recompute-prefill).

Set time range to "Last 15 minutes" and refresh every 5 s while the test runs.
After the run, copy the panel time range into the `summary.md` for archival.

---

## 5. Pre-flight: deploy with dual-mode decode

Before S2/S3 can be exercised, decode pods must run with dual-mode patches:

```bash
# Apply dual-mode env vars + kv-transfer config on decode workers
IMAGE=ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha> \
  ./test-scripts/apply-dual-mode-decode.sh
```

Required env vars on decode pods:
- `DYNAMO_RL_DUAL_MODE=1`
- `DYNAMO_RL_SIDECAR_PORT=9091`
- `DYNAMO_RL_CONNECTOR_ENABLED=1` (for S3 NIXL path, falls back to recompute)
- `DYN_SYSTEM_PORT=9090`

Verify:
```bash
kubectl -n dynamo-system get pod -l nvidia.com/dynamo-graph-deployment-name=vllm-v1-disagg-router -o wide
# Expect: ≥2 decode pods Ready, 1 prefill pod, 1 frontend
```

---

## 6. Run order & expected outputs

```bash
# S2 — role flip on a dual-mode decode pod
cd test-scripts && bash test-s2-elastic.sh
# expect: D→P→D flip, all requests HTTP 200, WorkerSet shrink/grow confirmed

# S3 — coordinated migration with per-request tracking
cd test-scripts && bash test-s3-consolidation.sh
# expect: 6/6 MIG_OK, OVERALL=true, REPORT.md generated under reports/
```

After each run, the test generates a timestamped report under
`test-scripts/reports/` with full evidence (ID lists, per-migration table,
worker logs, pass/fail verdict).
