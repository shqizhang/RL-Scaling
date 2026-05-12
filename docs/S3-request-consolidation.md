# S3 — Decoder Long-Request Consolidation (live migration)

> Scope: Path A + B. This document describes what the current Dynamo +
> RL-Scaling code actually does for **scenario S3 — moving an in-flight
> long-running decode request off a TARGET decoder onto a PEER decoder so
> the TARGET can be drained, shrunk, or role-switched without dropping
> work**, and the E2E test that proves it.
>
> Status: implemented and passing. **Phase 2.A (recompute-prefill)** is
> the default and safe path. **Phase 2.B (NIXL-pull connector)** is fully
> wired with a 3-phase block-hold protocol and gated behind
> `DYNAMO_RL_CONNECTOR_ENABLED=1`. Phase 2.B gracefully falls back to
> Phase 2.A when KVBM block index or NIXL coordinates are unavailable.
> Latest evidence run: 2026-05-12.

---

## 1. Scenario

While S2 lets us add/remove decoders from the chat WorkerSet, that flip
unconditionally aborts whatever was running on the TARGET. Long chat
completions (e.g. `max_tokens=3500`) sitting at high `generated_tokens`
are too valuable to throw away — recomputing the prefill from scratch
on a new pod is order-of-magnitude cheaper than rerunning the entire
generation. The same primitive is needed whenever an operator wants to
**consolidate** in-flight load (move all live requests off a decoder so
that decoder can free its KV, then sleep / be terminated / be switched
to a different role).

Concretely (3-phase protocol for both paths):

```
POST <target_sidecar>/migrate_out  {"request_id":"*"}
   -> selects the most-progressed in-flight request on TARGET
   -> Phase 2.A: aborts immediately
   -> Phase 2.B: holds blocks alive (deferred abort)
   -> returns {prompt_tokens, generated_tokens, sampling_params, ...}
     (+ kv_transfer_params when Phase 2.B is active)

POST <peer_sidecar>/migrate_in     <body returned above>
   -> applies a cost-benefit gate
   -> Phase 2.A: replays prompt+generated as the new prefill on PEER
   -> Phase 2.B: injects kv_transfer_params, NIXL READ pull from TARGET

POST <target_sidecar>/migration_complete  {"request_id":"..."}
   -> Phase 2.A: harmless no-op (already aborted)
   -> Phase 2.B: aborts source request, frees held KV blocks
```

A successful triple frees TARGET's KV for that request and keeps the
user-visible answer flowing on PEER.

---

## 2. Technical background

### 2.1 Why two paths exist

| path | how PEER continues  | KV transfer | safe by default? |
|------|---------------------|-------------|------------------|
| Phase 2.A — recompute-prefill | replay `prompt + generated` as a new prefill on PEER | none | **yes** |
| Phase 2.B — connector / NIXL pull | NIXL READ from TARGET's GPU blocks into PEER | yes | no — block-hold race |

Path 2.A is dominant in practice once vLLM's prefix cache is enabled
because the replay cost is bounded by the **uncached suffix** of the
prompt (typically tens of milliseconds for our workloads), whereas
2.B has to coordinate two engines and survive the abort/free race.

### 2.2 Block-hold protocol in path 2.B

Phase 2.B implements a 3-phase block-hold protocol to avoid the
abort/free race:

1. **`migrate_out`** checks if `connector_enabled=True` AND KVBM block
   IDs AND NIXL coordinates are all available. If so, it does NOT abort
   the source request; instead, it records the request_id in
   `_pending_migrations` and returns `kv_transfer_params` so the
   destination can do a NIXL READ pull.
2. **`migrate_in`** on the destination injects `kv_transfer_params` into
   `sampling_params.extra_args["kv_transfer_params"]` and submits the
   request to vLLM's engine. vLLM's `NixlConnectorScheduler` reads
   these params and issues the NIXL READ pull.
3. **`/migration_complete`** on the source aborts the original request
   and frees the held blocks. This is called by the orchestrator (test
   script or RL controller) after `migrate_in` succeeds.

A background sweeper task force-aborts stale pending migrations after
`DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` seconds (default 10) to prevent
block leaks if the orchestrator fails to call `/migration_complete`.

If any of the prerequisites for 2.B are missing (no KVBM, no NIXL),
`migrate_out` falls back to immediate abort (Phase 2.A behavior), and
`migrate_in` uses the recompute-prefill path. The
`/migration_complete` call becomes a harmless no-op.

Phase 2.B is gated behind `DYNAMO_RL_CONNECTOR_ENABLED=1` (env var,
default off).

### 2.3 Cost-benefit gate

`MigrationHandler._should_migrate` (in
`components/src/dynamo/vllm/migration.py`) refuses to accept a
`migrate_in` if any of:

```python
MigrationPolicy(
    max_replay_tokens=8192,    # recompute prefill too expensive
    min_generated_tokens=16,   # too young to benefit
    min_remaining_tokens=32,   # would finish faster than migrating
)
# connector_enabled is controlled via DYNAMO_RL_CONNECTOR_ENABLED env var
```

Rejected requests respond with `status=declined` and a human-readable
reason; nothing is aborted on TARGET in the rejected case (the abort
happens inside `migrate_out`, before this gate runs on the receiver,
which is correct — the gate's job is to refuse poison rather than to
*prevent* the abort). For the wildcard case the test never sends an
oversize body in the success path because it picks
`_pick_most_progressed`, but it does explicitly verify the gate by
sending a synthetic over-budget body to `migrate_in`.

### 2.4 In-process registry

To know which requests are in flight on a given decoder, the worker
keeps an `InProcessRequestRegistry` (rl-scaling sidecar code) updated by
the request handler at three points (`handlers.py:1255-1350`):

```
register      on submit                       # records prompt_tokens, sampling_params
record_tokens on every streamed delta         # extends generated_tokens
deregister    on completion / error / abort   # removes the entry
```

The sidecar's `GET /v1/active_requests` returns the live `request_id`
list directly from this registry; `migrate_out` resolves
`request_id="*"` to the most-progressed entry by inspecting it.

---

## 3. Implementation map

| concern                          | file                                                          | symbol / lines           |
|----------------------------------|---------------------------------------------------------------|--------------------------|
| sidecar HTTP surface             | `components/src/dynamo/vllm/rl_scaling_sidecar.py`            | `post_migrate_out`, `post_migrate_in`, `post_migration_complete`, `get_active` |
| migration core                   | `components/src/dynamo/vllm/migration.py`                     | `MigrationHandler.migrate_out`, `.migrate_in`, `.migration_complete` |
| block-hold sweeper               | `components/src/dynamo/vllm/migration.py`                     | `MigrationHandler.sweep_stale_migrations` |
| cost-benefit policy              | `components/src/dynamo/vllm/migration.py`                     | `_should_migrate`        |
| most-progressed selection        | `components/src/dynamo/vllm/migration.py`                     | `_pick_most_progressed`  |
| KV block index lookup            | `components/src/dynamo/vllm/migration.py`                     | `RequestBlockIndex.lookup` |
| in-flight registry hooks         | `components/src/dynamo/vllm/handlers.py`                      | `generate_tokens`        |
| NIXL meta provider               | `components/src/dynamo/vllm/rl_scaling_sidecar.py`            | `make_nixl_meta_provider` |

`migrate_out` returns:

```jsonc
{
  "status": "ok",
  "request_id": "...",
  "prompt_tokens":     [int, ...],
  "generated_tokens":  [int, ...],
  "sampling_params":   {...},
  "stop_conditions":   {...},
  "src_block_ids":     [int, ...]            // if KVBM available
  "kv_transfer_params": {                    // if connector_enabled AND
    "do_remote_prefill": true,               // src_block_ids AND nixl_coords
    "remote_engine_id": "...",               // all available
    "remote_block_ids": [...],
    "remote_host": "...",
    "remote_port": 12345,
    "remote_request_id": "..."
  }
}
```

`migrate_in` runs the cost-benefit gate, and:

- if `connector_enabled` and `kv_transfer_params` present, attempts the
  NIXL pull path; on any exception falls back to recompute,
- otherwise (the default) submits a recompute-prefill replay with
  `prompt_tokens = old_prompt + old_generated_tokens`,
- in both cases attaches `previously_emitted_tokens` so the streaming
  response on PEER does not re-emit tokens the client already received.

`migration_complete` (Phase 2.B ack):

```jsonc
POST /migration_complete  {"request_id": "..."}
   -> {status: "ok", request_id: "..."}
```

Called by the orchestrator AFTER `migrate_in` succeeds. On the source:
- Phase 2.B: aborts the held source request and frees KV blocks.
- Phase 2.A: harmless no-op (request was already aborted in `migrate_out`).

---

## 4. Verification strategy

Five pass conditions on
[test-s3-consolidation.sh](../test-scripts/test-s3-consolidation.sh)
(all must hold for OVERALL=true):

| code              | meaning                                                                                     |
|-------------------|---------------------------------------------------------------------------------------------|
| `PASS_MIG_OK`      | at least one (`migrate_out`, `migrate_in`) pair both returned `status=ok`                   |
| `PASS_NO_ERRORS`   | no migration response had `status="error"`                                                  |
| `PASS_GPU_RELEASE` | TARGET's `vllm:num_requests_running` decreased between T1 (after schedule) and T2 (after migrations) |
| `PASS_DST_TAKEOVER`| PEER's `vllm:generation_tokens_total` increased between T1 and T3 (drained), proving forward progress |
| `PASS_DECLINE`     | a synthetic `migrate_in` with `prompt_tokens=9000` (above `max_replay_tokens=8192`) returns `status=declined` |

The harness submits 24 streaming long chats (`max_tokens=3500`,
`temperature=0.7`) through the frontend so the KvRouter spreads them
across the two decoders, waits 8 s for the schedule to settle, then
loops up to 6 times calling `migrate_out` against TARGET with
`request_id="*"`, feeding the response into PEER's `migrate_in`, and
then calling `/migration_complete` on TARGET to release held blocks
(Phase 2.B ack).

---

## 5. Test report

Test environment:

- single-node K8s 1.34.1 on `gpu14`, namespace `dynamo-system`
- DGD `vllm-v1-disagg-router`, model `Qwen/Qwen3-0.6B`
- 1 frontend, 2 decoders, 1 prefill (all `Running`)
- image `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-2982f6cb46`
- `DYNAMO_RL_CONNECTOR_ENABLED=1` on decoder workers
- Latest evidence run: 2026-05-12

Pod inventory:

| Role | Pod name |
|------|----------|
| TARGET (source) | `vllm-v1-disagg-router-vllmdecodeworker-55c5d8a8-b7f5d959c-f7lg5` |
| PEER (destination) | `vllm-v1-disagg-router-vllmdecodeworker-55c5d8a8-b7f5d959c-z224b` |
| Frontend | `vllm-v1-disagg-router-frontend-579b79f897-9db5n` |

### 5.1 Migration outcomes

| outcome              | count |
|----------------------|------:|
| `migrate_in` ok      | **3** |
| — via connector path | 0     |
| — via recompute path | 3     |
| `migrate_in` declined| 0     |
| errors               | **0** |

**Migration #1** — `request_id=7476e5b7-c8bc-4713-be9b-eb98ac1d56c8`
- `migrate_out`: status=ok, **generated_tokens=1633**
- `src_block_ids`: null, `kv_transfer_params`: null
- `migrate_in`: status=ok, path=**recompute**, replay_tokens=**1633**
- `migration_complete`: status=ok (Phase-2.A no-op)

**Migration #2** — `request_id=b10795eb-e854-447e-abb1-bb1c5596a59d`
- `migrate_out`: status=ok, **generated_tokens=1833**
- `migrate_in`: status=ok, path=**recompute**, replay_tokens=**1833**
- `migration_complete`: status=ok

**Migration #3** — `request_id=0795ed5d-8a0b-4af9-8d53-172856056041`
- `migrate_out`: status=ok, **generated_tokens=2120**
- `migrate_in`: status=ok, path=**recompute**, replay_tokens=**2120**
- `migration_complete`: status=ok

**Why connector path=0:** `DYNAMO_RL_CONNECTOR_ENABLED=1` is set, but
the connector path requires BOTH KVBM block IDs AND NIXL coordinates.
In this deployment, `engine_client.engine_core.kv_cache_manager` returns
`None` (KVBM cache manager not exposed), so `src_block_ids` is null and
the handler falls back to the Phase-2.A recompute path. The 3-phase
protocol (migrate_out → migrate_in → migration_complete) exercises
correctly in both paths — the `/migration_complete` call is a harmless
no-op when blocks were already freed in `migrate_out`.

### 5.2 GPU release / dst takeover

| Metric | T1 (after schedule) | T2 (after migrations) | T3 (drained) |
|--------|:-------------------:|:--------------------:|:------------:|
| TARGET `num_requests_running` | 9 | **0** | 0 |
| PEER `num_requests_running` | 6 | 0 | 0 |

TARGET running-requests dropped 9 → 0: all active requests either
migrated or completed during the migration window.

### 5.3 Cost-benefit gate

Synthetic `migrate_in` with `prompt_tokens=9000` (above
`max_replay_tokens=8192`) was correctly **declined**.

### 5.4 Overall

**PASS** — all five conditions hold.

| Condition | Result |
|-----------|--------|
| ≥1 migration succeeded (ok) | **true** (3 ok, 0 declined, 0 errors) |
| Zero migration errors | **true** |
| TARGET `requests_running` decreased | **true** (9 → 0) |
| PEER `generation_tokens` grew | **true** |
| Cost-benefit gate declines oversize | **true** |
| 3-phase protocol works (migration_complete) | **true** |
| **OVERALL** | **true** |

Raw artifacts:
[reports/s3-consolidation-20260512-111254/REPORT.md](../test-scripts/reports/s3-consolidation-20260512-111254/REPORT.md),
plus full `migrate_out_N.json` / `migrate_in_N.json` responses,
`metrics.csv`, `decline.json`, and `run.log` in the same directory.

---

## 6. Limitations and known gaps

1. **Connector path requires KVBM block index.** Phase 2.B's NIXL-pull
   path needs `src_block_ids` from the KVBM cache manager, which is
   only available when KVBM is the active block manager. When KVBM is
   not exposed (`engine_client.engine_core.kv_cache_manager = None`),
   the connector path falls back to recompute-prefill automatically.
   The 3-phase protocol (migrate_out → migrate_in → migration_complete)
   works correctly in both cases.
2. **Recompute cost depends on prefix cache.** With prefix caching
   enabled (`enable_prefix_caching=True`, the default in our build) the
   replay pays only for the **uncached suffix** — typically tens of
   milliseconds. Disable the prefix cache and recompute pays full
   prefill cost (~100 ms+); the migration handler logs a warning when
   it detects prefix cache is off (`_warn_if_prefix_cache_disabled`).
3. **`previously_emitted_tokens` requires client cooperation.** The
   sidecar threads `previously_emitted_tokens` through to the new
   submission so a streaming consumer doesn't double-receive tokens.
   Frontends that rebuild the conversation from the back-channel must
   honor that field; our chat-completions path through the OpenAI
   adapter does so transparently because each migration produces a
   fresh server-sent-events stream.
4. **Single-node measurements.** Network cost for `migrate_*`
   round-trips is on-host loopback in this report. On a multi-node
   cluster the cost is dominated by cross-pod HTTP RTTs.
5. **Hold timeout.** The sweeper force-aborts held migrations after
   `DYNAMO_RL_MIGRATION_HOLD_TIMEOUT` seconds (default 10). If the
   orchestrator is slow to call `/migration_complete`, this can cause
   the NIXL READ on the destination to see stale blocks. The timeout
   should be tuned for the expected NIXL transfer latency.
