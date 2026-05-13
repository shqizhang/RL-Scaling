# S3 Decoder Consolidation — E2E Test Report (20260513-082114)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
D1 (source):      `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-j96lb`
D2 (destination): `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-wqvrk`
Frontend:         `vllm-v1-disagg-router-frontend-87b9678b7-fzplg`

---

## 1. Test Design

**Goal**: prove that in-flight decode requests migrate from D1→D2 via the
coordinated `POST /migrate` endpoint, preserving KV consistency.

**Method**:
1. Submit 80 long-running streaming chats (`max_tokens=8000`).
2. Wait 5s for the router to distribute requests across D1 and D2.
3. Before each migration: record D1/D2 active request ID lists.
4. Migrate up to 6 requests from D1→D2 via coordinated endpoint.
5. After each migration: verify request_id left D1 and appeared on D2.
6. Wait for drain; verify D2 generation tokens grew.

**Coordinated endpoint protocol** (`POST /migrate`):
1. D1 `migrate_out`: snapshot state, **hold blocks** (defer abort)
2. Internally call D2 `/migrate_in` with full state snapshot
3. On success: D1 abort + free blocks; D2 continues decoding
4. On failure: D1 release hold (rollback); request continues on D1

---

## 2. Pre-Migration State (T1)

| metric                        | D1 (source)    | D2 (destination) |
|-------------------------------|---------------:|-----------------:|
| active request IDs            | 40   | 40    |
| `num_requests_running`        | 40.0   | 40.0    |
| `generation_tokens_total`     | 218833   | 241620    |

<details><summary>D1 active request IDs at T1 (click to expand)</summary>

```
009c210b-c13e-4c3e-82c3-5bc85ce619dc
0283e94f-9a55-4769-990b-1dcaa697ba81
0b07dd58-b756-490f-ba43-16b44bf559bf
0d92fdbd-2f5f-4aaf-9123-4cd9bddcada1
16dbfe31-199a-4e99-ad2c-476e5df71967
188ceda5-362c-4366-9e49-ac3e1d8caeaf
1a87d3d0-3fbe-478b-8d84-8f715d7f4cdd
1a9c3afa-ed9f-4ed1-bc3e-078bdf8d7748
1b1485ec-5da4-4669-9210-83ca3e351dde
1d6d09aa-1bf6-42e4-bdf6-9c9c087e421e
2358dc1b-f6fd-4cce-bf08-3ebd9d350ee6
27e4a95d-6866-4270-bab1-2fe80676a1fe
43354e28-d8f0-4f0a-a0dd-e3758d56f76a
4cc0b7e3-4b75-442f-a7f5-ad50ca672924
4fe65d97-ada6-4510-bdc5-0bcb6b3fa8a7
5340393b-e4ab-4e12-be95-e6acdfc4d563
59a8f0b7-fef7-44aa-b773-ee7cacf51314
6a612a33-1737-4f47-855c-e77523c33e7d
6d70dbc9-d970-47ed-9506-c090f8c8fb66
71bc7d9b-1bed-481e-af15-d58a2260516b
789b6ad0-b9bc-4766-a526-9072a395c7d9
7ad99d57-5ad7-4337-8085-e02fe10daa10
856f7bd0-cf3c-4ea4-92cf-5ba45c1c6ec4
861df185-b99b-4a57-ad97-70352520f676
8676a784-55ef-4430-a2c7-718bd6451f6a
8819d97c-eed3-45c5-b7da-6dc698d8ea28
8aafd42d-6d32-496e-b038-dd0776858954
8adfc945-a167-4b96-999a-2544daeba27f
8ba5da96-53ba-4fe2-a0d9-9d42465b1bbc
ac1d13f7-9538-4cc7-99d5-3bb867b1fd33
af010cc1-ef51-4d06-8bf7-54a299bea1c4
b4c515d1-17a6-483a-a854-bb0fa1a28376
b97f669a-7723-455f-8f4d-d7ac074905cb
b99336f0-bc90-470b-bb6e-637a3125ce1a
c1132656-7bb9-4f9b-bc27-245ac103a342
ca964924-b5e9-4054-8ea3-e843ddc3d9bb
cabba041-2a2e-4101-ab2f-c53273f51871
e6975ffa-4f60-4eae-830e-6fb7f48c28cd
e8dc9533-4426-48f4-9d02-214d36ce943d
f16d79c7-24a0-450e-96d4-3990553aefe7
```

</details>

<details><summary>D2 active request IDs at T1 (click to expand)</summary>

```
013241be-9feb-4a62-bb5c-c79b0c6c25b0
042ca997-e8b3-453c-9e33-a49c573d5ab3
066d53db-a286-4f5f-ac72-29204aefe5f9
158f0bac-da68-42d8-a922-5e8cf3907d2d
1e39d714-3709-4952-94fd-fc9599913295
22e39c94-d696-4cc3-b0de-ed93f4a8a372
24733b2b-3e6a-4a46-9e41-4aa5def67c4a
31387d2f-820b-4c50-991a-3958d8748099
315d12b4-450d-4cee-909c-c5393cf81b48
445f08dc-6e61-448e-9319-055c6fc1216f
5be7ca58-58e9-47dd-9e22-844bca9383ee
6034de4b-9b6c-4ec9-a7a0-e01ede7ce99f
6451e556-a163-4ff9-9690-2dd07e743536
649171d3-9b93-4d0e-93a1-242626e2d5b3
6898eba3-c849-4fc3-bce3-af86e0993785
6cebdd12-b18f-45f6-8e77-0b7e1bd104fd
6da83e1a-6276-4ad6-acd3-ac3399458602
6e991ce3-f180-424f-b61c-4e8b29e8cd3c
6fb52e27-c987-43c8-b5a0-d9d43d0c27fd
72838a8b-5db4-4bd0-a3a0-9042ed97951c
77d2fb60-dcfd-4fc0-bbf6-8683c02adf6d
78480a4e-cf41-4fd6-a18a-c41c8e2480b8
8054a7a2-17b0-4f34-aa63-77102e36cd59
830213ac-b349-4e7b-8dee-9ce00f052459
872f7d93-386d-4aba-8b03-f7e73505a5c1
8f542e69-e5db-40a7-87a1-ef19daf8a04d
90d0ca20-a50a-4b97-8d1c-fb3acb73e887
a2485a36-bbcc-4fbf-a136-c0a15b0496c8
a987a2a0-f7b4-410e-b6c2-1354c5ce6337
ae93eb7b-a958-495f-8a3a-4a83ce7662bc
b331b72d-58c2-474b-86fa-bf35e4d4c8c2
b8724b21-3114-4f0f-8099-03cc6073c3c1
bc321eb8-dd15-4ce0-98bf-f627ac40fc3b
beff9a8c-8490-495f-a992-70c5fa1ac0ac
c9bae174-d00b-4e0f-9487-da8c31f1d7a0
d2e79d5b-018e-4497-9f65-1a0b7c60cf46
d3ebbac4-2780-4b31-945a-970c79815f21
de1959e4-4088-4bd1-aba2-f559b3859ae3
e1826843-a674-403d-acea-1d01ca745c5d
e889a0dc-6fde-4694-8ebd-59c4e85c2bfd
```

</details>

---

## 3. Per-Migration Detail (with before/after tracking)

| # | request_id | D1 decoded | max_tok | remaining | path | replay | D1 pre→post | D2 pre→post | left D1 | on D2 | status |
|---|------------|----:|----:|----:|------|----:|------------|------------|---------|-------|--------|
| 1 | `2358dc1b-f6f..` | 1060 | 8000 | 6940 | recompute | 1060 | 40→39 | 40→40 | true | false | **ok** |
| 2 | `b4c515d1-17a..` | 1174 | 8000 | 6826 | recompute | 1174 | 39→38 | 39→39 | true | false | **ok** |
| 3 | `af010cc1-ef5..` | 1284 | 8000 | 6716 | recompute | 1284 | 38→37 | 39→39 | true | false | **ok** |
| 4 | `0b07dd58-b75..` | 1388 | 8000 | 6612 | recompute | 1388 | 36→35 | 38→38 | true | false | **ok** |
| 5 | `cabba041-2a2..` | 1489 | 8000 | 6511 | recompute | 1489 | 35→34 | 38→37 | true | false | **ok** |
| 6 | `6a612a33-173..` | 1536 | 8000 | 6464 | recompute | 1536 | 33→32 | 35→35 | true | false | **ok** |

### How to read this table

- **D1 decoded**: tokens D1 had already generated before migration
- **remaining**: `max_tokens - D1_decoded` — what D2 will continue generating
- **replay**: total tokens D2 received (`original_prompt + D1_generated`)
- **D1 pre→post**: D1 active request count before → after migration
- **D2 pre→post**: D2 active request count before → after migration
- **left D1**: request_id disappeared from D1 active list (D1 released it)
- **on D2**: request_id appeared on D2 active list (D2 accepted it)

### Migration summary

| outcome                          | count               |
|----------------------------------|--------------------:|
| migrations ok                    | **6**        |
| migrations declined              | 0           |
| migrations error                 | 0           |
| rolled back                      | 0            |
| request IDs moved correctly      | 0             |
| request IDs NOT moved correctly  | 6           |

---

## 4. KV Migration Consistency Proof

For each successful migration, the following chain proves KV consistency:

```
D1 (source worker)                              D2 (destination worker)
┌─────────────────────────────────┐             ┌─────────────────────────────────┐
│ request R is actively decoding  │             │ request R is NOT here           │
│ D1 has generated N tokens       │             │                                 │
│ active_ids contains R           │             │ active_ids does NOT contain R   │
└──────────┬──────────────────────┘             └─────────────────────────────────┘
           │
           │  POST /migrate {request_id: R, target_url: D2}
           ▼
┌──────────────────────────────────┐
│ migrate_out:                     │
│  • snapshot prompt + N gen tokens│
│  • hold blocks (defer abort)     │
│  • return state to orchestrator  │
└──────────┬───────────────────────┘
           │
           │  POST D2/migrate_in {prompt + N tokens}
           ▼
           │             ┌─────────────────────────────────────┐
           │             │ migrate_in:                          │
           │             │  • cost-benefit check (replay < 8192)│
           │             │  • submit(prompt + N, skip_emit=N)  │
           │             │  • path=recompute, replay=prompt+N  │
           │             └──────────┬──────────────────────────┘
           │                        │
           │  migration_complete    │  D2 starts decoding from token N+1
           ▼                        ▼
┌──────────────────────────────────┐ ┌─────────────────────────────────┐
│ D1: abort R, free blocks         │ │ D2: R in active_ids             │
│ active_ids does NOT contain R    │ │ D2 continues from token N+1    │
│ resources freed                  │ │ generation_tokens_total grows   │
└──────────────────────────────────┘ └─────────────────────────────────┘
```

**Per-migration token evidence:**

- **Migration #1** (`2358dc1b-f6f..`): D1 decoded **1060** tokens out of 8000.
  D2 received replay_tokens=1060 (original prompt + 1060 generated tokens).
  D2 will generate ~6940 more tokens to complete the request.
  Verified: left_D1=true, on_D2=false

- **Migration #2** (`b4c515d1-17a..`): D1 decoded **1174** tokens out of 8000.
  D2 received replay_tokens=1174 (original prompt + 1174 generated tokens).
  D2 will generate ~6826 more tokens to complete the request.
  Verified: left_D1=true, on_D2=false

- **Migration #3** (`af010cc1-ef5..`): D1 decoded **1284** tokens out of 8000.
  D2 received replay_tokens=1284 (original prompt + 1284 generated tokens).
  D2 will generate ~6716 more tokens to complete the request.
  Verified: left_D1=true, on_D2=false

- **Migration #4** (`0b07dd58-b75..`): D1 decoded **1388** tokens out of 8000.
  D2 received replay_tokens=1388 (original prompt + 1388 generated tokens).
  D2 will generate ~6612 more tokens to complete the request.
  Verified: left_D1=true, on_D2=false

- **Migration #5** (`cabba041-2a2..`): D1 decoded **1489** tokens out of 8000.
  D2 received replay_tokens=1489 (original prompt + 1489 generated tokens).
  D2 will generate ~6511 more tokens to complete the request.
  Verified: left_D1=true, on_D2=false

- **Migration #6** (`6a612a33-173..`): D1 decoded **1536** tokens out of 8000.
  D2 received replay_tokens=1536 (original prompt + 1536 generated tokens).
  D2 will generate ~6464 more tokens to complete the request.
  Verified: left_D1=true, on_D2=false

---

## 5. Post-Migration State

| metric                             | T1 (before)     | T2 (after mig)  | T3 (drained) |
|------------------------------------|----------------:|----------------:|-------------:|
| D1 active requests                 | 40    | 29    | -            |
| D2 active requests                 | 40   | 30   | -            |
| D1 `num_requests_running`          | 40.0    | 30.0    | 0.0 |
| D2 `num_requests_running`          | 40.0   | 35.0   | 0.0|
| D1 `generation_tokens_total`       | 218833    | -               | 258054 |
| D2 `generation_tokens_total`       | 241620   | -               | 282783|

**D1 active requests decreased**: T1=40 → T2=29
→ **true** (D1 released migrated requests)

**D2 generation_tokens delta** (T1→T3): **41163**
(D2 generated tokens for all requests including migrated ones)

**Estimated remaining tokens across 6 migrated requests**: ~40069

---

## 6. Cost-Benefit Gate (Decline Test)

Synthetic `migrate_in` with `prompt_tokens=9000` (exceeds `max_replay_tokens=8192`):

```json
{
  "status": "declined",
  "reason": "replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)",
  "request_id": "synthetic-overbudget"
}
```

* Oversize migration declined: **true**

---

## 7. Worker Log Evidence

### D1 (source) — migration events
```
1.3ms hold
[2m2026-05-13T08:21:25.980444Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request b4c515d1-17a6-483a-a854-bb0fa1a28376 (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:21:25.986038Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing b4c515d1-17a6-483a-a854-bb0fa1a28376 after 5.6ms hold
[2m2026-05-13T08:21:27.139578Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request af010cc1-ef51-4d06-8bf7-54a299bea1c4 (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:21:27.148274Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing af010cc1-ef51-4d06-8bf7-54a299bea1c4 after 9.2ms hold
[2m2026-05-13T08:21:28.282713Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 0b07dd58-b756-490f-ba43-16b44bf559bf (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:21:28.289846Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 0b07dd58-b756-490f-ba43-16b44bf559bf after 7.2ms hold
[2m2026-05-13T08:21:29.431073Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request cabba041-2a2e-4101-ab2f-c53273f51871 (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:21:29.440782Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing cabba041-2a2e-4101-ab2f-c53273f51871 after 9.9ms hold
[2m2026-05-13T08:21:30.590318Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 6a612a33-1737-4f47-855c-e77523c33e7d (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:21:30.597493Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 6a612a33-1737-4f47-855c-e77523c33e7d after 7.2ms hold
```

### D2 (destination) — migration events
```
ore_DP0 pid=714) INFO 05-12 13:54:55 [nixl_connector.py:1323] Registering KV_Caches. use_mla: False, kv_buffer_device: cuda, use_host_buffer: False
(EngineCore_DP0 pid=714) INFO 05-12 13:55:02 [factory.py:64] Creating v1 connector with name: NixlConnector and engine_id: c6fcac18-e997-4a0e-8549-bd2b0d9fa6ee
(EngineCore_DP0 pid=714) INFO 05-12 13:55:02 [nixl_connector.py:535] Initializing NIXL Scheduler c6fcac18-e997-4a0e-8549-bd2b0d9fa6ee
[2m2026-05-12T13:55:02.738239Z[0m [33mWARNING[0m [2mnixl_connector[0m[2m:[0m NIXL was already imported, we can't reset UCX_RCACHE_MAX_UNRELEASED. Please set it to '1024' manually.
[2m2026-05-12T13:55:02.738404Z[0m [32m INFO[0m [2mnixl_connector[0m[2m:[0m NIXL is available
(EngineCore_DP0 pid=714) INFO 05-12 13:59:46 [nixl_connector.py:1104] NIXL compatibility check passed (hash: dbb2848cbaefc84f6db09834b6d47a09b8266fec2abb3dbbba3c3f553be60df9)
(EngineCore_DP0 pid=714) INFO 05-12 13:59:55 [nixl_connector.py:1104] NIXL compatibility check passed (hash: dbb2848cbaefc84f6db09834b6d47a09b8266fec2abb3dbbba3c3f553be60df9)
[2m2026-05-12T14:00:46.210363Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-12T14:02:53.032211Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-13T08:20:16.866712Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-13T08:21:34.016631Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
```

---

## Overall

| condition                                          | result               |
|----------------------------------------------------|----------------------|
| ≥1 migration succeeded                            | **true**          |
| zero migration errors                              | **true**          |
| every migrated request left D1 and arrived on D2   | **false**           |
| D1 active requests decreased (T1→T2)              | **true**          |
| D2 generation_tokens grew (Δ=41163)     | **true**          |
| cost-benefit gate declined oversize                | **true**          |
| **OVERALL**                                        | **false**          |

