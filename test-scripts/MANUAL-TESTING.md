# Manual Testing Guideline — RL-Scaling on Dynamo

Last updated: 2026-05-10
Branch: `RL-Scaling`
Audience: engineers verifying S2 (elastic PD role switch) and S3 (long-request consolidation) by hand on a live cluster.

For the architectural background, read first:
- [docs/TECH-REPORT-architecture-and-implementation.md](../docs/TECH-REPORT-architecture-and-implementation.md)
- [docs/S2-elastic-pd-switch.md](../docs/S2-elastic-pd-switch.md)
- [docs/S3-request-consolidation.md](../docs/S3-request-consolidation.md)

The two automated scripts in this folder (`test-s2-elastic.sh`, `test-s3-consolidation.sh`) are the source of truth. This guide explains how to drive the same flows by hand when you need to debug, demo, or extend a scenario.

---

## 0. Prerequisites

| Item | Required value / how to check |
|---|---|
| Cluster | K8s ≥ 1.30 single-node, GPU node ready (`kubectl get node -o wide`) |
| Namespace | `dynamo-system` (override with `NS=...`) |
| DGD | `vllm-v1-disagg-router` (override with `DGD=...`) — `kubectl -n dynamo-system get dynamographdeployments.nvidia.com` |
| Discovery backend | DynamoWorkerMetadata CRDs — `kubectl get crd dynamoworkermetadatas.nvidia.com` |
| Image | `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<git-sha>` deployed on Frontend + decode + prefill pods |
| Model | `Qwen/Qwen3-0.6B` |

Decode pods must run with the dual-mode patches:

- `--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both",...}'` on the engine
- env `DYNAMO_RL_DUAL_MODE=1`
- env `DYNAMO_RL_SIDECAR_PORT=9091`
- env `DYN_SYSTEM_PORT=9090`

Apply or re-apply the dual-mode patch in one shot:

```bash
IMAGE=ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-<sha> \
  ./test-scripts/apply-dual-mode-decode.sh
```

Verify pods are Ready:

```bash
kubectl -n dynamo-system get pod -l nvidia.com/dynamo-graph-deployment-name=vllm-v1-disagg-router -o wide
```

You should see ≥ 2 decode pods (`vllmdecodeworker-...`), ≥ 1 prefill pod (`vllmprefillworker-...`), and 1 frontend (`...frontend-...`).

---

## 1. Common port-forwards

Open three local ports — keep them in separate terminals (`Ctrl-C` to release):

```bash
NS=dynamo-system

# Frontend OpenAI API
FRONTEND=$(kubectl -n $NS get pod -l nvidia.com/dynamo-component-type=frontend -o name | head -1)
kubectl -n $NS port-forward "$FRONTEND" 18000:8000 &

# Pick the two decode pods
mapfile -t DEC < <(kubectl -n $NS get pod -l nvidia.com/dynamo-component-type=worker \
  -o jsonpath='{range .items[?(@.spec.containers[0].args[0]=="vllmdecodeworker")]}{.metadata.name}{"\n"}{end}')
TGT="${DEC[0]}"; PEER="${DEC[1]}"
echo "TARGET=$TGT  PEER=$PEER"

# Sidecar HTTP (role-switch + migrate) on each decode
kubectl -n $NS port-forward "$TGT"  19191:9091 &   # TARGET sidecar
kubectl -n $NS port-forward "$PEER" 19192:9091 &   # PEER   sidecar

# vLLM /metrics on each decode
kubectl -n $NS port-forward "$TGT"  19291:9090 &   # TARGET metrics
kubectl -n $NS port-forward "$PEER" 19292:9090 &   # PEER   metrics
```

Quick smoke:

```bash
curl -s localhost:18000/v1/models | jq .data[].id        # -> "Qwen/Qwen3-0.6B"
curl -s localhost:19191/v1/role                          # -> {"role":"decode"}
curl -s localhost:19291/metrics | grep '^vllm:num_requests_running'
```

---

## 2. Inspect the discovery substrate (DynamoWorkerMetadata CR)

The router does NOT use Service endpoints. It watches CRs:

```bash
# List CRs (one per worker pod)
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com

# What model_cards does the TARGET pod currently advertise?
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '
    .items[] | select(.metadata.ownerReferences[0].name==$p)
    | .spec.data.model_cards[].endpoint_id'
```

A decode-mode pod publishes an entry whose endpoint_id ends in `/backend/generate`. After `switch_role -> prefill`, that entry disappears. This is the single most reliable router-awareness probe.

---

## 3. S2 — Elastic PD role switch (manual walkthrough)

**Goal**: take a decode pod out of the chat WorkerSet (becomes prefill-only), then put it back. Prove the router stops/resumes routing decode traffic to it.

### 3.1 Snapshot before the switch

```bash
# CR state of TARGET (should contain a "/backend/generate" endpoint)
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '.items[] | select(.metadata.ownerReferences[0].name==$p) | .spec.data.model_cards'

# Sidecar role
curl -s localhost:19191/v1/role
```

### 3.2 Trigger the switch (decode -> prefill)

```bash
curl -s -X POST localhost:19191/switch_role \
     -H 'content-type: application/json' \
     -d '{"role":"prefill"}' | jq .
```

The response returns `status:"ok"` and a per-step duration breakdown (`sleep_ms`, `unregister_mdc_ms`, `reconfig_nixl_ms`, `reset_prefix_cache_ms`, `set_disaggregation_mode_ms`, `register_mdc_ms`, `wake_ms`, `emit_role_changed_ms`).

### 3.3 Verify router-awareness directly

```bash
# (a) CR diff: TARGET's "/backend/generate" entry should be gone
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '.items[] | select(.metadata.ownerReferences[0].name==$p) | .spec.data.model_cards[].endpoint_id'

# (b) Chat attribution: 30 probes; TARGET hits should be 0
TGT_BEFORE=$(curl -s localhost:19291/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
PEER_BEFORE=$(curl -s localhost:19292/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
for i in $(seq 1 30); do
  curl -s -X POST localhost:18000/v1/chat/completions \
       -H 'content-type: application/json' \
       -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"say hi"}],"max_tokens":4}' >/dev/null
done
TGT_AFTER=$(curl -s localhost:19291/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
PEER_AFTER=$(curl -s localhost:19292/metrics | awk '/^vllm:request_success_total/{s+=$2} END{print s+0}')
echo "TARGET delta = $((TGT_AFTER-TGT_BEFORE))   PEER delta = $((PEER_AFTER-PEER_BEFORE))"
# Expected: TARGET delta == 0, PEER delta == 30
```

### 3.4 Revert (prefill -> decode)

```bash
curl -s -X POST localhost:19191/switch_role -H 'content-type: application/json' -d '{"role":"decode"}' | jq .

# CR should regain the "/backend/generate" entry
kubectl -n dynamo-system get dynamoworkermetadatas.nvidia.com \
  -o json | jq -r --arg p "$TGT" '.items[] | select(.metadata.ownerReferences[0].name==$p) | .spec.data.model_cards[].endpoint_id'

# Probes should now be split across both decoders again
```

### 3.5 (Optional) Sustained load during the switch

In a 2nd shell, before step 3.2:

```bash
end=$((SECONDS+30))
while (( SECONDS < end )); do
  curl -s -X POST localhost:18000/v1/chat/completions \
       -H 'content-type: application/json' \
       -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' >/dev/null &
  sleep 0.5
done
wait
```

No 5xx should be observed; latency tail may briefly bump while NIXL re-handshakes.

---

## 4. S3 — Long-request consolidation (manual walkthrough)

**Goal**: an in-flight long decode on TARGET is moved to PEER, freeing TARGET's GPU KV while the request keeps making progress.

### 4.1 Schedule a long-request load on TARGET

The router will pick a decoder by KV-affinity; with only 2 decoders and N≥24 streamed requests, both pods get work.

```bash
# Snapshot
curl -s localhost:19291/metrics | grep -E '^vllm:num_requests_running' ; \
curl -s localhost:19292/metrics | grep -E '^vllm:num_requests_running'

# Fire 24 streamed long chats (background)
for i in $(seq 1 24); do
  curl -sN -X POST localhost:18000/v1/chat/completions \
       -H 'content-type: application/json' \
       -d "{\"model\":\"Qwen/Qwen3-0.6B\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"please write a long story #$i\"}],\"max_tokens\":3500}" \
       >/dev/null &
done
sleep 8   # let the scheduler ramp up

# Confirm both decoders are busy
echo "TGT  running=$(curl -s localhost:19291/metrics | awk '/^vllm:num_requests_running/{print $2;exit}')"
echo "PEER running=$(curl -s localhost:19292/metrics | awk '/^vllm:num_requests_running/{print $2;exit}')"
```

### 4.2 Migrate the most-progressed request off TARGET, into PEER

```bash
BODY=$(curl -s -X POST localhost:19191/migrate_out \
       -H 'content-type: application/json' \
       -d '{"request_id":"*"}')
echo "$BODY" | jq '.status, .request_id, .generated_tokens'

curl -s -X POST localhost:19192/migrate_in \
     -H 'content-type: application/json' \
     -d "$BODY" | jq .
```

Expected:
- `migrate_out.status == "ok"` (the wildcard `"*"` resolves to the most-progressed in-flight request)
- `migrate_in.status == "ok"`  (or `"declined"` if the cost-benefit gate rejects — see §4.4)

Loop 5-6 times to drain TARGET further. Between iterations, watch:

```bash
curl -s localhost:19291/metrics | awk '/^vllm:num_requests_running/{print "TGT  running="$2}'
curl -s localhost:19292/metrics | awk '/^vllm:num_requests_running/{print "PEER running="$2}'
```

`TGT.running` should monotonically decrease toward 0; `PEER.generation_tokens_total` should keep climbing.

### 4.3 Wait for the original chat fan-out to finish

```bash
wait   # the 24 background curls
```

Every chat must terminate cleanly (no 5xx, no truncation banner). The migrated requests on PEER continue to stream tokens to the same client connection because the Frontend is unaffected by the underlying engine swap (request_id is preserved).

### 4.4 Decline path (cost-benefit gate)

The gate (in `MigrationPolicy`) rejects when:
- `generated_tokens < 16` (replay too cheap to bother; just retry locally), OR
- `generated_tokens > max_replay_tokens (8192)` (too expensive to recompute), OR
- `remaining < min_remaining_tokens (32)` (request will finish anyway), OR
- both ends would saturate `max_active`.

Force a decline by feeding an obviously-too-long body:

```bash
curl -s -X POST localhost:19192/migrate_in -H 'content-type: application/json' -d '{
  "status":"ok","request_id":"synthetic","prompt_token_ids":[1,2,3],
  "generated_token_ids":[],"generated_tokens":99999,
  "sampling_params":{"max_tokens":1000},"original_max_tokens":1000
}' | jq .
# -> {"status":"declined","reason":"generated_tokens_exceeds_max_replay_tokens"}
```

---

## 5. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `switch_role` returns 5xx with `kv_transfer_config not set` | Decode pod was started without `--kv-transfer-config`. Re-run `apply-dual-mode-decode.sh`. |
| CR still shows `/backend/generate` after `switch_role -> prefill` | Reregistrar didn't run. Check pod logs: `kubectl logs $TGT -c main | grep -iE 'reregistrar\|register_endpoint\|apply_cr'`. |
| Probes after switch still hit TARGET | Frontend cache lag. The `ModelWatcher` re-reads CRs every 1s; wait 2s and re-probe. If still failing, frontend pod was started without `DYN_DISCOVERY_BACKEND=kubernetes`. |
| `migrate_out` returns `"no_eligible_request"` | No request on TARGET satisfies `min_generated_tokens`. Bump `LONG_MAX_TOK` or wait longer before migrating. |
| `migrate_in` always declines | Inspect `reason` field — most often the request is too short (replay cheap) or too long (replay expensive). Tune `MigrationPolicy` in `components/src/dynamo/vllm/migration.py`. |
| Both decoders go to 0 immediately | Qwen3-0.6B is fast; the load drained before you migrated. Use `stream=true` and `max_tokens >= 3500`, or switch to a larger model. |
| `kubectl port-forward` hangs / dies | Restart it. The migration / role-switch state lives on the pod, not on the port-forward. |

Logs that matter:

```bash
# Decode worker — role transitions, NIXL handshakes, migration register/dereg
kubectl -n dynamo-system logs "$TGT"  -c main | grep -iE 'switch_role|reregistr|nixl|migrate|model_card'

# Frontend — router decisions, model-card watcher events
kubectl -n dynamo-system logs "$FRONTEND" -c main | grep -iE 'kv_router|prefill_router|model_watcher|backend/generate'
```

---

## 6. Cleanup

```bash
# Kill any leftover port-forwards
pkill -f 'kubectl.*port-forward' || true

# Restore the deployment to a clean image / replica count if you scaled it
kubectl -n dynamo-system rollout restart deploy
```

Reports from the scripted runs are kept under [test-scripts/reports/](reports/) — never delete those by hand; they are referenced from the scenario docs.
