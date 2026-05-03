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
The controller asks a worker to flip its role. The worker must:
- accept `POST /switch_role` (registered when launched with `--dual-mode`),
- run the orchestrated *sleep → reconfig → wake* sequence,
- end up reporting the new role on its handler (`get_disaggregation_mode()`),
- not lose / corrupt in-flight requests (drained by `sleep(level=2)`).

⚠️ **Known stub:** `_reconfig_nixl()` and `_reconfig_kv_pool()` in
`components/src/dynamo/vllm/dual_mode.py` log a warning and return — the
underlying Rust APIs don't exist yet. So "after the flip the worker actually
serves the new role" can only be observed *logically* (handler field +
publish-event), not via routing changes in vLLM. We mark this in the test
expectations explicitly.

### S3 · Request consolidation
When two decode workers are unevenly loaded the controller picks `(source, target)`,
issues `migrate_one("*")` per request, and shrinks the DGDSA. Per-request:
- source's `RequestTracker.abort_request()` runs (engine drops the request),
- target receives a **resubmitted prompt = `prompt_tokens + generated_tokens`** (recompute-prefill),
- generation continues without the client seeing an error,
- final completion is byte-identical when the model is greedy and the seed is fixed.

⚠️ **No KV-block transfer** happens. The recompute-prefill fallback is
intentional (see design doc S3 feasibility note). Therefore we *do not* track
individual KV-block IDs during migration — there's nothing to track. We instead
validate by:
1. comparing migrated-vs-baseline output hashes (correctness),
2. confirming `frontend.dynamo_frontend_model_migration_total` increments,
3. confirming the `kvbm_*` block-tier counters do **not** show D2H/D2D activity
   attributable to the migration (negative assertion — there should be no KV
   transfer because we don't move blocks).

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

S2 needs `--dual-mode --initial-role decode` set on at least one worker pod.
The current deployment **does not** have dual-mode workers — they're standard
disagg-router prefill/decode pods. To run S2 we need to redeploy with that flag
or override the DGD's worker `command:`. See §5.

| Step | Source of truth | Where to look | Pass criterion |
|---|---|---|---|
| Worker reports a role | `GET 127.0.0.1:9090/role` (NEW endpoint to add — see §6) | direct curl | response `{"role":"decode"}` |
| Controller has `ROLE_SWITCH_ENABLED=true` | `GET /api/v1/status` (NEW field — see §6) | curl | `role_switch_enabled=true` |
| Flip request returns `ok` | `POST 127.0.0.1:9090/switch_role` (already implemented) | response body | `status=ok`, `switch_time_ms` populated |
| Worker drained during flip | log line `[DualMode] sleep(level=2)` then `wake_up` | `kubectl logs` | both lines present in order |
| New role persisted | `GET /role` after flip | curl | reports new role |
| `WorkerRoleChanged` event published | `_emit_role_changed` log line | logs | one line per flip |
| **Stub call-out** | NIXL/KV-pool reconfig | logs | warnings present (`stubbed; no Rust reconfig API yet`) — this is *expected*; we only assert the log shows the stub was reached |

Grafana panel for S2: there is no dashboard panel today that shows
`worker_type` flips. We rely on (a) controller logs and (b) the worker
`/role` endpoint. (Adding a `dynamo_worker_current_role{role=}` gauge is a
deferrable improvement.)

### S3 acceptance matrix

S3 needs `--enable-migration` on decode workers and ≥ 2 decode replicas.

| Step | Source of truth | Where to look | Pass criterion |
|---|---|---|---|
| ≥ 2 decode replicas, both serving | `kubectl get dgdsa` + `vllm:num_requests_running` per pod | Disagg dashboard **inflight per worker** | both > 0 with uneven load |
| Migration triggered | controller log `consolidation tick: source=...` | logs | one line per planned pair |
| Source request aborted | `vllm:num_requests_running` on source drops to 0 | dashboard | step-down to 0 |
| Target receives resubmitted prompt | target log: `migrate_in: replay_prompt_len=…` | logs | length = `prompt + previously_generated` |
| **Output correctness** | byte-compare baseline vs migrated when seed fixed + greedy | `sha256sum` of completion text | digests match |
| **No KV transfer occurred** | `kvbm_offload_blocks_d2d`, `kvbm_offload_blocks_d2h`, `kvbm_onboard_blocks_*` | KVBM dashboard | counters do not increase during migration window |
| Frontend migration counter increments | `dynamo_frontend_model_migration_total{migration_type="ongoing_request"}` | Dynamo dashboard **Frontend migrations** | `Δ ≥ migrated_requests` |
| DGDSA shrunk | `kubectl get dgdsa -w` | Operator dashboard | decode replicas decrement |
| Source pod terminated | `kube_pod_status_phase{phase="Succeeded"\|"Failed"}` | Disagg dashboard | source pod gone |

#### About "recording each KV block ID"
Not applicable — recompute-prefill is the chosen fallback, no KV block is moved
between workers. The "correctness" question reduces to:
- Did the destination engine produce the same continuation it would have
  produced if it had served the request from scratch?
- Did the client see no error / disconnect?

This is exactly what items 5 ("output correctness") and 6 ("no KV transfer")
above test. A future S3-v2 with NIXL D2D will need block-id-level tracing
(KVBM emits `kvbm_*` per block move, but per-block IDs aren't currently
exposed as metric labels — they would need a tracing/event log capture).

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

## 5. Pre-flight changes needed for S2/S3

Before S2/S3 can be exercised end-to-end the DGD must be re-applied with
worker flags:

```yaml
VllmDecodeWorker:
  args:
    - --model
    - ${MODEL_NAME}
    - --disaggregation-mode
    - decode
    - --dual-mode                # NEW (for S2)
    - --enable-migration         # NEW (for S3)
  resources: { limits: { gpu: "2" } }   # 2 decode replicas for S3
```

This is a *deploy-time* change. Use `deploy-dynamo.sh --router` after editing
`manifests/dgd-vllm-disagg-router.yaml` (overwrite mode is now in place — the
script will tear down the existing stack first).

---

## 6. Test-script gaps & required fixes

The current `test-scripts/test-s{1,2,3}.sh` reference HTTP endpoints that the
controller does not implement. Concretely:

| Script | Reference | Status | Action |
|---|---|---|---|
| test-s1 | `GET /api/v1/status.role_switch_enabled` | absent | not needed for S1 — remove |
| test-s1 | `dynamo_kvbm_state{}` metric | wrong name; KVBM uses `kvbm_*` and per-tier counters | switch to `dynamo_component_kv_cache_events_applied` (per design-docs/router-design.md) |
| test-s2 | `GET 127.0.0.1:9090/v1/role` | not implemented | add a `/role` GET on worker (1-line) |
| test-s2 | `GET /api/v1/events?type=...` on controller | not implemented | replace with controller-log scraping |
| test-s2 | `POST /api/v1/debug/generate` | not implemented | drop — exercise via real frontend `/v1/completions` |
| test-s2 | default `NAMESPACE=dynamo` | wrong (workers live in `dynamo-system`) | default to `dynamo-system` |
| test-s3 | `POST /api/v1/admin/consolidation/tick` | not implemented | trigger via `signals/sampling_done` + tight loop, or expose admin tick (preferred — controller change) |
| test-s3 | `dynamo-component=decode` label selector | wrong; actual label is `nvidia.com/dynamo-component-type=worker` | update selector |
| test-s3 | `--pin-worker-index` field on `/api/v1/debug/generate` | endpoint absent | use frontend's `--worker-id` extension or pin via separate decode services |

Acceptance criteria for the script-fix follow-up commit:
- All scripts use defaults that match the as-deployed cluster (ns, label selectors, image tag).
- Zero references to non-existent controller endpoints.
- Each script writes a `summary.md` under `/tmp/rls-test/<scenario>-<ts>/` with PASS/FAIL per row of the matrices in §3.

These edits will land alongside the deploy-time DGD changes from §5.

---

## 7. Run order & expected outputs

```bash
# S1 — first, only K8s + DGDSA scaling exercised
bash test-scripts/test-s1.sh
# expect: 5 numbered "blue" sections all green, "S1 PASSED"

# Then redeploy with --dual-mode --enable-migration (§5)
bash deploy/RL-Scaling/deploy-dynamo.sh --router

# S2 — role flip on a single dual-mode decode pod
TARGET_POD=$(kubectl -n dynamo-system get pod -l ...vllmdecodeworker -o jsonpath='{.items[0].metadata.name}')
TARGET_POD=$TARGET_POD NAMESPACE=dynamo-system bash test-scripts/test-s2.sh
# expect: handler.disaggregation_mode flips, /role reports new role, stub log warnings present

# S3 — uneven load + consolidation tick
NAMESPACE=dynamo-system DGD_NAME=vllm-v1-disagg-router bash test-scripts/test-s3.sh
# expect: source decode pod drains + DGDSA shrinks; output sha matches baseline; kvbm_* counters flat
```

After each run, archive the run dir and append a row to a top-level
`tutorial/scaling/test-runs.md` ledger (date, image SHA, scenario, outcome,
summary.md link).
