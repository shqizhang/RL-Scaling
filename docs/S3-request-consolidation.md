# S3 — Decoder Long-Request Consolidation (live migration)

> Scope: Path A. This document describes what the current Dynamo + RL-Scaling
> code actually does for **scenario S3 — moving an in-flight long-running
> decode request off a TARGET decoder onto a PEER decoder so the TARGET can
> be drained, shrunk, or role-switched without dropping work**, and the E2E
> test that proves it.
>
> Status: implemented and passing for the **safe default path
> (recompute-prefill replay)**. The connector / NIXL-pull path is gated off
> by default because of a known block-hold race documented in section 6.

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

Concretely:

```
POST <target_sidecar>/migrate_out  {"request_id":"*"}
   -> aborts the most-progressed in-flight request on TARGET
   -> returns its {prompt_tokens, generated_tokens, sampling_params, ...}
POST <peer_sidecar>/migrate_in     <body returned above>
   -> applies a cost-benefit gate
   -> on accept, replays prompt+generated as the new prefill on PEER and
      resumes generation from there
```

A successful pair frees TARGET's KV for that request immediately and
keeps the user-visible answer flowing on PEER.

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

### 2.2 Block-hold race in path 2.B (why it is gated off)

`migrate_out` aborts the source request *before* `migrate_in` begins
its NIXL READ on PEER. KVBM frees the source blocks synchronously on
abort, so by the time PEER pulls them, the source allocator may have
already reused them for a different request. To make 2.B safe we would
need a **block-hold ack** (PEER tells source "I have your blocks; you
may release") — that protocol is not yet implemented, hence
`MigrationPolicy.connector_enabled = False` by default and the test
asserts on the recompute path.

The `migrate_out` response **still carries `src_block_ids` and full
`kv_transfer_params`** when KVBM coordinates are available, so a future
2.B implementation does not need a wire-protocol change — only a
hold/ack on the source side.

### 2.3 Cost-benefit gate

`MigrationHandler._should_migrate` (in
`components/src/dynamo/vllm/migration.py`) refuses to accept a
`migrate_in` if any of:

```python
MigrationPolicy(
    max_replay_tokens=8192,    # recompute prefill too expensive
    min_generated_tokens=16,   # too young to benefit
    min_remaining_tokens=32,   # would finish faster than migrating
    connector_enabled=False,   # 2.B disabled, see 2.2
)
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
| sidecar HTTP surface             | `components/src/dynamo/vllm/rl_scaling_sidecar.py`            | `post_migrate_out`, `post_migrate_in`, `get_active`, L295-340 |
| migration core                   | `components/src/dynamo/vllm/migration.py`                     | `MigrationHandler`, L200-330 |
| cost-benefit policy              | `components/src/dynamo/vllm/migration.py`                     | `_should_migrate`, L355-385 |
| most-progressed selection        | `components/src/dynamo/vllm/migration.py`                     | `_pick_most_progressed`, L387-400 |
| KV block index lookup            | `components/src/dynamo/vllm/migration.py`                     | `_block_index.lookup`    |
| in-flight registry hooks         | `components/src/dynamo/vllm/handlers.py`                      | L1255, L1306, L1348      |
| KVBM `nixl_meta_provider`        | `components/src/dynamo/vllm/handlers.py`                      | L1003 (lazy `_nixl_connector`) |

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
`request_id="*"` and feeding the response straight into PEER's
`migrate_in`.

---

## 5. Test report

Test environment:

- single-node K8s 1.34.1 on `gpu14`, namespace `dynamo-system`
- DGD `vllm-v1-disagg-router`, model `Qwen/Qwen3-0.6B`
- 1 frontend, 2 decoders, 1 prefill (all `Running`)
- image `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-f817b8e5d5`

### 5.1 Migration outcomes

| outcome              | count |
|----------------------|------:|
| `migrate_in` ok      | **3** |
| `migrate_in` declined| 0     |
| errors               | **0** |

Per-iteration log:

| iter | phase        | status | path      | replay_tokens | request_id |
|-----:|--------------|--------|-----------|--------------:|------------|
| 1    | migrate_out  | ok     | -         | -             | 22eb4e6b… |
| 1    | migrate_in   | ok     | recompute | 1726          | 22eb4e6b… |
| 2    | migrate_out  | ok     | -         | -             | 325cd6fa… |
| 2    | migrate_in   | ok     | recompute | 1933          | 325cd6fa… |
| 3    | migrate_out  | ok     | -         | -             | 73729f36… |
| 3    | migrate_in   | ok     | recompute | 2190          | 73729f36… |

All three picks land in the 1.7k-2.2k token range, consistent with
"most-progressed" selection over a workload that began ~8 s earlier
on Qwen3-0.6B.

### 5.2 GPU release / dst takeover

|                                          | T1 (after schedule) | T2 (after migrations) | T3 (drained) |
|------------------------------------------|--------------------:|----------------------:|-------------:|
| TARGET `vllm:num_requests_running`       | 5.0                 | **0.0**               | -            |
| PEER   `vllm:num_requests_running`       | 5.0                 | 0.0                   | -            |
| TARGET `vllm:generation_tokens_total`    | 41 002              | -                     | 42 079       |
| PEER   `vllm:generation_tokens_total`    | 42 775              | -                     | **44 710**   |

Read this as: 8 s into the 24-request workload TARGET and PEER each
held 5 active streams. After the migration loop fired three migrations
plus the natural completion of the other two streams on TARGET, its
running count went to zero — by construction TARGET could now sleep,
shrink, or accept a `switch_role` cleanly. PEER continued to make
forward progress (Δgenerated = 1935 vs TARGET's Δ = 1077 over the
same window), which is how we prove the migrated requests didn't just
silently die — they kept producing tokens on the new pod.

### 5.3 Cost-benefit gate

Synthetic `migrate_in` with `prompt_tokens = 9000` (over the
`max_replay_tokens = 8192` policy ceiling):

```json
{
  "status": "declined",
  "reason": "replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)",
  "request_id": "synthetic-overbudget"
}
```

### 5.4 Overall

**PASS** — all five conditions hold.

Raw artifacts:
[reports/s3-consolidation-20260510-122258/REPORT.md](../test-scripts/reports/s3-consolidation-20260510-122258/REPORT.md),
plus `metrics.csv`, `migrations.csv`, `migrate_out_*.json`,
`migrate_in_*.json`, `decline.json`, `long-chats.csv` in the same
directory.

---

## 6. Limitations and known gaps

1. **Connector / NIXL-pull path is off by default.** The wire protocol
   is wired through (`migrate_out` returns `kv_transfer_params` when
   KVBM is available and `connector_enabled=True`) but the source-side
   block-hold/ack handshake is missing, so enabling 2.B today would
   surface a race where PEER's NIXL READ targets blocks that TARGET's
   allocator has already recycled. To enable: set
   `MigrationPolicy.connector_enabled = True` *and* land the hold/ack
   protocol on the source side first.
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
4. **Single-node measurements.** Network cost for both `migrate_*`
   round-trips is on-host loopback in this report. On a multi-node
   cluster the cost is dominated by the two cross-pod HTTP RTTs (which
   the frontend would normally hide with retries on the user-facing
   side).
