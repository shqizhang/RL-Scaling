# S3 Decoder Consolidation — E2E Test Report (20260513-081957)

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
| `generation_tokens_total`     | 145150   | 152303    |

<details><summary>D1 active request IDs at T1 (click to expand)</summary>

```
03892bae-30ed-4390-818a-960a4b5b0703
080d8318-12d4-40f9-88c1-b351cdc42131
086d58f2-f1a5-4c47-ab6f-fd64749b9c92
0977ab3c-1c5c-4dfc-878d-a2b8fe79642c
09e6d196-3392-42c7-aec8-4b486be453c6
0afc21d9-a562-4f9a-8cae-b0861b9080e9
0d705cfd-d3a3-4d4c-8a84-7ff3be7ae9d0
1b772f43-b661-40ae-8750-3b5718c91b94
28150229-8286-44e3-a367-c1a8b9ccd494
288ece5d-8279-42bc-8934-44a2a81f0e21
3ad4f971-116d-4129-9b58-e9e97f191682
3b53818d-db31-4caf-9f8b-13b19d99f480
4141a259-0721-49a6-a3cb-ccf681848f74
440f795d-a7c1-408b-b824-9b2ceb24b07e
50ad9903-839c-41ee-8f8e-c56054226a3c
5f793b58-a7a8-47ed-8b83-f1592c2ff8d8
632adbdd-055f-4f54-9c2f-d1f74cc5b5b8
7bef7504-caa7-4528-bf1a-1ab7a4da7711
8383f0e5-578b-41ae-9b6a-0d35e2dbdcc7
84c21078-77b9-491c-8106-2b94bfa59747
86b1ad5d-4bd8-42a8-aa01-1e9704ef2129
8e17d560-6816-4e0d-a8e7-626284767a8b
98598402-5b6d-4391-a695-2a7d4245b165
9eca064c-f4ee-490c-a644-6d74388a607c
9f1713af-5019-4db2-825d-c0ab9b1ec12b
a1bac52e-140d-4e7f-83f5-6fdbc55e9641
a9688525-e9fe-4204-8e5b-ce6c2584e433
b11cedfd-ebc7-4498-9808-956293538242
b2339440-aab8-4494-b847-9477fa8ca63e
b66a2e48-30e3-449b-bb55-2490b671e79a
bc21b389-0d1b-4d09-9f04-07617b0299ff
bd1e5db3-6308-4859-a18b-91bcb5f19a1e
dba92ad2-caec-4b39-ad1d-2d70bcf7c7ce
e7dbd449-7f1f-4208-baa3-12b312094a2b
e9ea0c14-ace7-4a2f-9acc-cd10ee870d51
ecfb5114-eb47-4f24-b1b5-38a06c94fec0
edf3d944-c4c4-45b5-b33a-b066ef9b6861
f10151e9-1279-4681-ad60-555c72fe293c
f1571bbc-adb0-4f55-a202-c9a41bd27f75
f7a5b46e-f6a6-4a69-9c19-090cf0bda9e6
```

</details>

<details><summary>D2 active request IDs at T1 (click to expand)</summary>

```
02c41434-a6d7-4a88-aa98-c97f12334f8b
09c69b89-e781-4152-b36e-f0c14a7cc166
1a408452-adc0-42d0-99bc-789d7fe9897c
3461a988-2332-48eb-a394-88118e3befd9
3509969f-6384-4b07-9888-b4f8cd859fed
379dc165-b1b7-4923-b166-2cc1184f5d93
3d66b417-62e5-40f6-bc53-b71efe1e928e
3f635899-012a-40ec-bf14-382c307ad73b
40a25509-f861-41d6-b3da-0c4d7efd7932
426e8a56-f517-40e9-88be-d838b1a12f26
42a8c2f3-2a6c-4977-8853-7727ece97223
431ae600-7e1a-489c-8ca4-ff4528677633
58347cb9-f3e1-4964-8a84-04281141bb39
659bbbaf-7c8e-45df-84e9-0e196be5f7d3
6660ac87-4f37-400a-b511-fcbcfb163ac1
6b142f77-462b-473b-93e9-77ec799ee5d2
6cd67317-885f-49a2-9df1-2913b3fe010b
7759cea8-5ae2-4d38-a024-b3804f489f48
812d7d7e-3b66-474e-a971-2ab7bc54f450
8bdf9bb0-0b0e-4d0d-9645-8f6c82231c71
91b044c0-bbb9-4818-a1f3-9ff2fcd11608
925c44e6-7016-4a57-9838-f3b2a5bf0b8f
93bdbe08-de3c-4fee-ae48-17fe770d3c48
94626dea-f35e-4ee2-b929-1dc21562b180
982f783c-d112-4ee7-8c88-db627048fe0c
98c5b707-29f4-43a5-b5c5-a063cf0a31af
9e279f46-83be-428b-933e-c4b2a354810a
9f0bc137-b4b2-4c63-8e56-1406ed117fa9
9fdb3b20-ae01-412e-b5be-7d159d461569
a5ee03b0-84cb-4a8e-8d2e-6d4c136a6bf4
a71e748b-c8c6-4ea2-a819-9e765a4721d2
b2d1204a-080b-473a-9c03-5ef750fb7c6e
b9ca66d1-b054-444a-9793-0f74b510264b
cbd151fa-f5db-4168-a473-d49ede5f51e9
d78df449-a95c-425a-b08e-f522984ca05f
df9369e4-524a-477b-8de9-3567cd4efc27
e6d02b14-6c2c-4ea0-a8b7-f57b52c789d5
ea63281d-729f-42bd-acd2-cee073f12e5d
eeba6aaf-9dcc-453e-bcaa-a3110834dbfb
fd29a27c-844b-48d2-be7d-bb73aa40d2e1
```

</details>

---

## 3. Per-Migration Detail (with before/after tracking)

| # | request_id | D1 decoded | max_tok | remaining | path | replay | D1 pre→post | D2 pre→post | left D1 | on D2 | status |
|---|------------|----:|----:|----:|------|----:|------------|------------|---------|-------|--------|
| 1 | `-` | 0 | 0 | 0 | - | - | 40→39 | 40→40 | n/a | n/a | **?** |
| 2 | `-` | 0 | 0 | 0 | - | - | 39→38 | 40→40 | n/a | n/a | **?** |
| 3 | `-` | 0 | 0 | 0 | - | - | 38→37 | 40→40 | n/a | n/a | **?** |
| 4 | `-` | 0 | 0 | 0 | - | - | 37→36 | 40→40 | n/a | n/a | **?** |
| 5 | `-` | 0 | 0 | 0 | - | - | 36→35 | 40→40 | n/a | n/a | **?** |
| 6 | `-` | 0 | 0 | 0 | - | - | 34→33 | 39→39 | n/a | n/a | **?** |

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
| migrations ok                    | **0**        |
| migrations declined              | 0           |
| migrations error                 | 6           |
| rolled back                      | 0            |
| request IDs moved correctly      | 0             |
| request IDs NOT moved correctly  | 0           |

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

---

## 5. Post-Migration State

| metric                             | T1 (before)     | T2 (after mig)  | T3 (drained) |
|------------------------------------|----------------:|----------------:|-------------:|
| D1 active requests                 | 40    | 29    | -            |
| D2 active requests                 | 40   | 33   | -            |
| D1 `num_requests_running`          | 40.0    | 30.0    | 0.0 |
| D2 `num_requests_running`          | 40.0   | 38.0   | 1.0|
| D1 `generation_tokens_total`       | 145150    | -               | 185093 |
| D2 `generation_tokens_total`       | 152303   | -               | 200645|

**D1 active requests decreased**: T1=40 → T2=29
→ **true** (D1 released migrated requests)

**D2 generation_tokens delta** (T1→T3): **48342**
(D2 generated tokens for all requests including migrated ones)

**Estimated remaining tokens across 0 migrated requests**: ~0

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
.6ms hold
[2m2026-05-13T08:20:08.565593Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 1b772f43-b661-40ae-8750-3b5718c91b94 (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:20:08.570871Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 1b772f43-b661-40ae-8750-3b5718c91b94 after 5.5ms hold
[2m2026-05-13T08:20:09.776345Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 03892bae-30ed-4390-818a-960a4b5b0703 (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:20:09.785235Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 03892bae-30ed-4390-818a-960a4b5b0703 after 9.1ms hold
[2m2026-05-13T08:20:10.981640Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request dba92ad2-caec-4b39-ad1d-2d70bcf7c7ce (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:20:10.991917Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing dba92ad2-caec-4b39-ad1d-2d70bcf7c7ce after 10.3ms hold
[2m2026-05-13T08:20:12.197187Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request f10151e9-1279-4681-ad60-555c72fe293c (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:20:12.204490Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing f10151e9-1279-4681-ad60-555c72fe293c after 7.3ms hold
[2m2026-05-13T08:20:13.407135Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request bc21b389-0d1b-4d09-9f04-07617b0299ff (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:20:13.412064Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing bc21b389-0d1b-4d09-9f04-07617b0299ff after 5.1ms hold
```

### D2 (destination) — migration events
```
onnector.py:862] Initializing NIXL worker c6fcac18-e997-4a0e-8549-bd2b0d9fa6ee
(EngineCore_DP0 pid=714) INFO 05-12 13:54:54 [nixl_connector.py:360] NixlConnector setting KV cache layout to HND for better xfer performance.
(EngineCore_DP0 pid=714) INFO 05-12 13:54:55 [nixl_connector.py:1323] Registering KV_Caches. use_mla: False, kv_buffer_device: cuda, use_host_buffer: False
(EngineCore_DP0 pid=714) INFO 05-12 13:55:02 [factory.py:64] Creating v1 connector with name: NixlConnector and engine_id: c6fcac18-e997-4a0e-8549-bd2b0d9fa6ee
(EngineCore_DP0 pid=714) INFO 05-12 13:55:02 [nixl_connector.py:535] Initializing NIXL Scheduler c6fcac18-e997-4a0e-8549-bd2b0d9fa6ee
[2m2026-05-12T13:55:02.738239Z[0m [33mWARNING[0m [2mnixl_connector[0m[2m:[0m NIXL was already imported, we can't reset UCX_RCACHE_MAX_UNRELEASED. Please set it to '1024' manually.
[2m2026-05-12T13:55:02.738404Z[0m [32m INFO[0m [2mnixl_connector[0m[2m:[0m NIXL is available
(EngineCore_DP0 pid=714) INFO 05-12 13:59:46 [nixl_connector.py:1104] NIXL compatibility check passed (hash: dbb2848cbaefc84f6db09834b6d47a09b8266fec2abb3dbbba3c3f553be60df9)
(EngineCore_DP0 pid=714) INFO 05-12 13:59:55 [nixl_connector.py:1104] NIXL compatibility check passed (hash: dbb2848cbaefc84f6db09834b6d47a09b8266fec2abb3dbbba3c3f553be60df9)
[2m2026-05-12T14:00:46.210363Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-12T14:02:53.032211Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-13T08:20:16.866712Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
```

---

## Overall

| condition                                          | result               |
|----------------------------------------------------|----------------------|
| ≥1 migration succeeded                            | **false**          |
| zero migration errors                              | **false**          |
| every migrated request left D1 and arrived on D2   | **false**           |
| D1 active requests decreased (T1→T2)              | **true**          |
| D2 generation_tokens grew (Δ=48342)     | **true**          |
| cost-benefit gate declined oversize                | **true**          |
| **OVERALL**                                        | **false**          |

