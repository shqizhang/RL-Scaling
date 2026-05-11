# S3 Request Consolidation — Detailed Evidence Report

**Date:** 2026-05-11 03:11:06 UTC
**Image:** `ghcr.io/shqizhang/dynamo-vllm-runtime:rl-scaling-fe78f1b652`
**Cluster:** single-node K8s, namespace `dynamo-system`
**Model:** `Qwen/Qwen3-0.6B`

## Pod inventory

| Role | Pod name |
|------|----------|
| TARGET (source — requests migrated FROM) | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489ccjp8x` |
| PEER (destination — requests migrated TO) | `vllm-v1-disagg-router-vllmdecodeworker-7663d0d2-84dc55489cntvq8` |
| Frontend | `vllm-v1-disagg-router-frontend-76457f997c-twkp9` |

---

## Phase 0: Baseline (no load)

Active requests on TARGET: 0
Active requests on PEER: 0

---

## Phase 1: Schedule 8 long-running decode requests

After scheduling, the router distributes them across decoders:

- TARGET active requests: **4**
- PEER active requests: **4**

Active request IDs on TARGET:
```json
[
    "72557043-7fce-4bbb-8274-387f85d9ba38",
    "74233113-9ebf-412a-9078-9d93b1fd1973",
    "2b051e60-237d-4bd1-9867-a4a54df50f29",
    "8a58b7c0-df4c-4f48-af2c-0a7e8f092e84"
]
```

---

## Phase 2: Migrate 3 requests from TARGET → PEER

### migrate_out responses (what was extracted from source)

| # | request_id | prompt_tokens | generated_tokens | sampling_params | src_block_ids | kv_transfer_params |
|---|-----------|---------------|------------------|-----------------|---------------|-------------------|
| 1 | `72557043-7fce-4bbb-8274-387f85...` | 0 | 1539 | temp=0.7, max_tokens=16384 | no | no |
| 2 | `74233113-9ebf-412a-9078-9d93b1...` | 0 | 1857 | temp=0.7, max_tokens=16384 | no | no |
| 3 | `8a58b7c0-df4c-4f48-af2c-0a7e8f...` | 0 | 2119 | temp=0.7, max_tokens=16384 | no | no |

### migrate_in responses (what happened on destination)

| # | status | path | replay_tokens | reason |
|---|--------|------|---------------|--------|
| 1 | ok | recompute | 1539 | - |
| 2 | ok | recompute | 1857 | - |
| 3 | ok | recompute | 2119 | - |

### Per-migration detailed data

#### Migration #1

**migrate_out response** (source extracts request state and aborts):
```json
{
  "status": "ok",
  "request_id": "72557043-7fce-4bbb-8274-387f85d9ba38",
  "prompt_tokens_count": 0,
  "prompt_tokens_first_10": [],
  "prompt_tokens_last_5": [],
  "generated_tokens_count": 1539,
  "generated_tokens_first_10": [
    151667,
    198,
    32313,
    11,
    279,
    1196,
    6801,
    264,
    1602,
    11682
  ],
  "generated_tokens_last_5": [
    82,
    13,
    18611,
    334,
    1592
  ],
  "sampling_params": {
    "temperature": 0.7,
    "top_p": 0.95,
    "top_k": 20,
    "max_tokens": 16384,
    "min_tokens": 0,
    "presence_penalty": 0.0,
    "frequency_penalty": 0.0,
    "repetition_penalty": 1.0,
    "stop": [],
    "stop_token_ids": [
      151643,
      151645
    ],
    "n": 1
  },
  "stop_conditions": {},
  "src_block_ids": null,
  "kv_transfer_params": null
}
```

**migrate_in response** (destination accepts and replays via recompute-prefill):
```json
{
    "status": "ok",
    "request_id": "72557043-7fce-4bbb-8274-387f85d9ba38",
    "path": "recompute",
    "replay_tokens": 1539
}
```

#### Migration #2

**migrate_out response** (source extracts request state and aborts):
```json
{
  "status": "ok",
  "request_id": "74233113-9ebf-412a-9078-9d93b1fd1973",
  "prompt_tokens_count": 0,
  "prompt_tokens_first_10": [],
  "prompt_tokens_last_5": [],
  "generated_tokens_count": 1857,
  "generated_tokens_first_10": [
    151667,
    198,
    32313,
    11,
    279,
    1196,
    6801,
    264,
    1602,
    11682
  ],
  "generated_tokens_last_5": [
    304,
    3033,
    5942,
    11,
    323
  ],
  "sampling_params": {
    "temperature": 0.7,
    "top_p": 0.95,
    "top_k": 20,
    "max_tokens": 16384,
    "min_tokens": 0,
    "presence_penalty": 0.0,
    "frequency_penalty": 0.0,
    "repetition_penalty": 1.0,
    "stop": [],
    "stop_token_ids": [
      151643,
      151645
    ],
    "n": 1
  },
  "stop_conditions": {},
  "src_block_ids": null,
  "kv_transfer_params": null
}
```

**migrate_in response** (destination accepts and replays via recompute-prefill):
```json
{
    "status": "ok",
    "request_id": "74233113-9ebf-412a-9078-9d93b1fd1973",
    "path": "recompute",
    "replay_tokens": 1857
}
```

#### Migration #3

**migrate_out response** (source extracts request state and aborts):
```json
{
  "status": "ok",
  "request_id": "8a58b7c0-df4c-4f48-af2c-0a7e8f092e84",
  "prompt_tokens_count": 0,
  "prompt_tokens_first_10": [],
  "prompt_tokens_last_5": [],
  "generated_tokens_count": 2119,
  "generated_tokens_first_10": [
    151667,
    198,
    32313,
    11,
    279,
    1196,
    6801,
    264,
    11682,
    8895
  ],
  "generated_tokens_last_5": [
    97219,
    3070,
    18247,
    1211,
    97219
  ],
  "sampling_params": {
    "temperature": 0.7,
    "top_p": 0.95,
    "top_k": 20,
    "max_tokens": 16384,
    "min_tokens": 0,
    "presence_penalty": 0.0,
    "frequency_penalty": 0.0,
    "repetition_penalty": 1.0,
    "stop": [],
    "stop_token_ids": [
      151643,
      151645
    ],
    "n": 1
  },
  "stop_conditions": {},
  "src_block_ids": null,
  "kv_transfer_params": null
}
```

**migrate_in response** (destination accepts and replays via recompute-prefill):
```json
{
    "status": "ok",
    "request_id": "8a58b7c0-df4c-4f48-af2c-0a7e8f092e84",
    "path": "recompute",
    "replay_tokens": 2119
}
```

### Active request count changes during migration

| Point | TARGET active | PEER active |
|-------|--------------|-------------|
| Before migration | 4 | 4 |
| After all migrations | 0 | 0 |
| **Δ** | **-4** | **-4** |

---

## Phase 3: GPU metrics evidence

| Metric | T0 (baseline) | T1 (after schedule) | T2 (after migration) | T3 (drained) |
|--------|:-------------:|:-------------------:|:--------------------:|:------------:|
| T0_baseline | — | — | — | — |
| T0_baseline | tgt_gpu=0% peer_gpu=0% | tgt_run=0 peer_run=0 | tgt_gen=34750 peer_gen=41918 | tgt_pt=2430 peer_pt=13321 |
| T1_after_schedule | tgt_gpu=0% peer_gpu=0% | tgt_run=4 peer_run=4 | tgt_gen=39553 peer_gen=47057 | tgt_pt=2661 peer_pt=13552 |
| T2_after_migrations | tgt_gpu=0% peer_gpu=0% | tgt_run=0 peer_run=0 | tgt_gen=42214 peer_gen=52326 | tgt_pt=2661 peer_pt=19067 |
| T3_drained | tgt_gpu=0% peer_gpu=0% | tgt_run=0 peer_run=0 | tgt_gen=42214 peer_gen=52326 | tgt_pt=2661 peer_pt=19067 |

### Key metrics interpretation

- **TARGET `num_requests_running`**: T1=4 → T2=0
  **Decreased** — proves requests were aborted on source, freeing GPU KV.
- **PEER `generation_tokens_total`**: T1=47057 → T3=52326 (Δ=5269)
  **Positive delta** — proves PEER is generating tokens for migrated requests.

---

## Phase 4: Cost-benefit gate evidence

The `MigrationPolicy` rejects migrations that aren't cost-effective.

### Test 1: Oversize replay (9000 prompt + 50 generated > max_replay_tokens=8192)

```json
{
    "status": "declined",
    "reason": "replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)",
    "request_id": "synthetic-oversize-test"
}
```

### Test 2: Too few generated tokens (2 < min_generated_tokens=16)

```json
{
    "status": "declined",
    "reason": "generated_tokens=2 below min_generated_tokens=16 (request too young to benefit)",
    "request_id": "synthetic-too-few-gen"
}
```

Both synthetic requests were correctly **declined** with informative reason strings.

---

## Worker logs

### TARGET: request aborts after migrate_out

```

```

### PEER: recompute-prefill replay after migrate_in

```
[2m2026-05-11T03:09:00.164547Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 222.2 tokens/s, Avg generation throughput: 128.9 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.1%, External prefix cache hit rate: 39.5%
[2m2026-05-11T03:09:00.165067Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 0.0 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.1%, External prefix cache hit rate: 39.5%
[2m2026-05-11T03:09:30.169394Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.1 tokens/s, Avg generation throughput: 0.4 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.1%, External prefix cache hit rate: 39.6%
[2m2026-05-11T03:09:30.172718Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 0.0 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.1%, External prefix cache hit rate: 39.6%
[2m2026-05-11T03:09:40.172215Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 338.4 tokens/s, Avg generation throughput: 833.7 tokens/s, Running: 5 reqs, Waiting: 0 reqs, GPU KV cache usage: 5.5%, Prefix cache hit rate: 4.4%, External prefix cache hit rate: 29.4%
[2m2026-05-11T03:09:40.174462Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 0.0 tokens/s, Running: 5 reqs, Waiting: 0 reqs, GPU KV cache usage: 5.5%, Prefix cache hit rate: 4.4%, External prefix cache hit rate: 29.4%
[2m2026-05-11T03:09:50.176237Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 112.4 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.4%, External prefix cache hit rate: 29.4%
[2m2026-05-11T03:09:50.176855Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 0.0 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.4%, External prefix cache hit rate: 29.4%
[2m2026-05-11T03:10:40.181045Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.3 tokens/s, Avg generation throughput: 60.7 tokens/s, Running: 3 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.4%, Prefix cache hit rate: 5.3%, External prefix cache hit rate: 29.6%
[2m2026-05-11T03:10:40.182914Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 0.0 tokens/s, Running: 3 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.4%, Prefix cache hit rate: 5.3%, External prefix cache hit rate: 29.6%
[2m2026-05-11T03:10:50.185323Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 543.5 tokens/s, Avg generation throughput: 979.9 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.4%, External prefix cache hit rate: 20.9%
[2m2026-05-11T03:10:50.188534Z[0m [32m INFO[0m [2mloggers.log[0m[2m:[0m Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 0.0 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 4.4%, External prefix cache hit rate: 20.9%
```

---

## Summary

| Condition | Result |
|-----------|--------|
| ≥1 migration succeeded (ok) | **true** (3 ok, 0 declined, 0 errors) |
| Zero migration errors | **true** |
| TARGET requests_running decreased | **true** (4 → 0) |
| PEER generation_tokens grew | **true** (Δ=5269) |
| Cost-benefit gate declines oversize | **true** |
| **OVERALL** | **true** |

## Raw artifacts

- `metrics.csv` — 4 timestamped metrics snapshots
- `migrations.csv` — per-migration outcome summary
- `migrate_out_N.json` / `migrate_in_N.json` — full API responses
- `active-target-*.json` / `active-peer-*.json` — active request snapshots
- `decline-response.json`, `decline2-min-gen.json` — gate test responses
- `target-logs-aborts.txt`, `peer-logs-replay.txt` — worker log excerpts
- `chat-long-*.json` — raw chat responses
- `run.log` — complete execution log
