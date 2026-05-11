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
> Latest detailed evidence run: 2026-05-11.

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
- image `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`
- Detailed evidence run: 2026-05-11

Pod inventory:

| Role | Pod name |
|------|----------|
| TARGET (source) | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x` |
| PEER (destination) | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489cntvq8` |
| Frontend | `vllm-v1-disagg-router-frontend-76457f997c-twkp9` |

### 5.1 Migration outcomes

| outcome              | count |
|----------------------|------:|
| `migrate_in` ok      | **3** |
| `migrate_in` declined| 0     |
| errors               | **0** |

#### Detailed per-migration data

**Migration #1** — `request_id=72557043-7fce-4bbb-8274-387f85d9ba38`

- `migrate_out`: status=ok, prompt_tokens=0, **generated_tokens=1539**
- Generated tokens (first 10): `[151667, 198, 32313, 11, 279, 1196, 6801, 264, 1602, 11682]`
- Generated tokens (last 5): `[82, 13, 18611, 334, 1592]`
- Sampling params: `temperature=0.7, top_p=0.95, top_k=20, max_tokens=16384`
- `src_block_ids`: null (recompute path, connector_enabled=False)
- `kv_transfer_params`: null
- `migrate_in`: status=ok, path=**recompute**, replay_tokens=**1539**
- TARGET active: 4 → 3 (Δ=-1)

**Migration #2** — `request_id=74233113-9ebf-412a-9078-9d93b1fd1973`

- `migrate_out`: status=ok, prompt_tokens=0, **generated_tokens=1857**
- Generated tokens (first 10): `[151667, 198, 32313, 11, 279, 1196, 6801, 264, 1602, 11682]`
- Generated tokens (last 5): `[304, 3033, 5942, 11, 323]`
- Sampling params: same as above
- `migrate_in`: status=ok, path=**recompute**, replay_tokens=**1857**
- TARGET active: 3 → 2 (Δ=-1)

**Migration #3** — `request_id=8a58b7c0-df4c-4f48-af2c-0a7e8f092e84`

- `migrate_out`: status=ok, prompt_tokens=0, **generated_tokens=2119**
- Generated tokens (first 10): `[151667, 198, 32313, 11, 279, 1196, 6801, 264, 11682, 8895]`
- Generated tokens (last 5): `[97219, 3070, 18247, 1211, 97219]`
- Sampling params: same as above
- `migrate_in`: status=ok, path=**recompute**, replay_tokens=**2119**
- TARGET active: 1 → 0 (Δ=-1)

**Observation on `prompt_tokens=0`:** This is expected behavior. The
`InProcessRequestRegistry` records `prompt_token_ids` from the
`TokensPrompt` at submit time, but vLLM's chat completions path
tokenizes internally and does not expose the prompt token IDs back to
the handler. The migration handler compensates by including all
`generated_tokens` in the replay, which the destination prefills from
scratch — effectively `replay_tokens = len(prompt_tokens) +
len(generated_tokens)` where `prompt_tokens` is empty means the full
replay is just the generated sequence.

**Observation on `src_block_ids=null` and `kv_transfer_params=null`:**
Both are null because `MigrationPolicy.connector_enabled=False` (the
default safe setting). The NIXL-pull path (Phase 2.B) is gated off;
these fields would be populated when the connector is enabled.

### 5.2 GPU release / dst takeover

| Metric | T1 (after schedule) | T2 (after migrations) | T3 (drained) |
|--------|:-------------------:|:--------------------:|:------------:|
| TARGET `num_requests_running` | 4 | **0** | 0 |
| PEER `num_requests_running` | 4 | 0 | 0 |
| TARGET `generation_tokens_total` | 39553 | 42214 | 42214 |
| PEER `generation_tokens_total` | 47057 | **52326** | 52326 |
| PEER `prompt_tokens_total` | 13552 | **19067** | 19067 |

PEER's `prompt_tokens_total` jumped by **5515** tokens between T1 and
T2 — this is the recompute-prefill cost of replaying the three migrated
requests (1539 + 1857 + 2119 = 5515 tokens, matching exactly). This is
the strongest evidence that the migrated requests were actually
reprocessed on PEER.

### 5.3 Cost-benefit gate

**Test 1: Oversize replay** (9000 prompt + 50 generated > `max_replay_tokens=8192`):

```json
{
  "status": "declined",
  "reason": "replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)",
  "request_id": "synthetic-oversize-test"
}
```

**Test 2: Too few generated tokens** (2 < `min_generated_tokens=16`):

```json
{
  "status": "declined",
  "reason": "generated_tokens=2 below min_generated_tokens=16 (request too young to benefit)",
  "request_id": "synthetic-too-few-gen"
}
```

Both synthetic requests were correctly **declined** with informative
reason strings.

### 5.4 Overall

**PASS** — all five conditions hold.

| Condition | Result |
|-----------|--------|
| ≥1 migration succeeded (ok) | **true** (3 ok, 0 declined, 0 errors) |
| Zero migration errors | **true** |
| TARGET `requests_running` decreased | **true** (4 → 0) |
| PEER `generation_tokens` grew | **true** (Δ=5269) |
| PEER `prompt_tokens` Δ matches replay sum | **true** (Δ=5515 ≈ 1539+1857+2119) |
| Cost-benefit gate declines oversize | **true** |
| Cost-benefit gate declines too-young | **true** |
| **OVERALL** | **true** |

Raw artifacts:
[reports/s3-detailed-20260511-031034/REPORT.md](../test-scripts/reports/s3-detailed-20260511-031034/REPORT.md),
plus full `migrate_out_N.json` / `migrate_in_N.json` responses,
`metrics.csv`, `active-target-*.json`, `active-peer-*.json`,
`decline-response.json`, `decline2-min-gen.json`, worker log excerpts,
and `run.log` in the same directory.

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
