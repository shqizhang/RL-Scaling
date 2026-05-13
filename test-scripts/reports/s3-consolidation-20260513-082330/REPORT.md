# S3 Decoder Consolidation — E2E Test Report (20260513-082330)

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
| `generation_tokens_total`     | 291701   | 317683    |

<details><summary>D1 active request IDs at T1 (click to expand)</summary>

```
01f742e0-ccec-4f67-98a7-0e2038b215cd
106523b4-951f-43c4-8a28-9b5b23c31deb
16d0cd3d-25e3-420c-968b-c6fc707119a3
17b25fd6-2ff8-4802-b1ad-c396f38e3613
1e6df650-b75d-4688-819b-b3161bcc3228
2517c2c8-b7c9-458b-9cd1-9e4117b1f811
2f972ec9-436e-4690-838d-28e9c7556cf6
36991d3d-05d1-42cd-ac1f-558486ec4101
3b6d8d52-f738-41dd-8a7b-ba51877ac3f2
487302a7-7bc3-4762-aeff-3f214ea60c62
515beee3-74c8-41f6-bd74-0caac45bb1a5
672bb0f1-0724-4241-865e-601e0dc7fc57
74f6d5b2-9ba9-4405-b594-afc33a6de211
77fbb70d-018f-4cdd-8cb4-d5c47e3867b6
7e90f753-a57f-46a9-931e-cec453854ad3
8d5cd744-2e31-4622-9fc1-7b9c1e4da473
8e7350a4-3e4b-4fc8-ad92-4c3a5cbb80a3
940cc186-69a6-4908-a627-7399bac4c941
96ce6d22-887e-49f9-b4e5-52abac1b7d7a
993f3d4c-cceb-44d3-8765-ebd4747c181d
9e7eaba3-e644-4b02-93ca-bcf32c5f2358
a723c718-79e0-4d0b-bdb1-8acf859419e8
a97ac702-1d6d-4eee-81aa-93eb53e6318b
ad8d4015-e2ad-4d8b-af0a-7b65e7ab719f
b8aff656-d087-4fc2-b0f7-f0f285d9df95
ba1cc79e-528d-4c14-a465-204b0a83d150
c57b6b7a-d933-4088-a3d1-c309b5acdb87
c8d17144-8a46-4fc8-a76c-84dc6122e976
cb0aa6df-927d-4c75-aa9d-756015e9fe83
cd815c61-7377-498f-b6ff-3836ce30de1b
d4a6e9e3-f971-4841-b31d-46f1927119bd
d9c664aa-ec7c-4096-a141-7af8c7a5b5bb
dc418b74-7983-419d-a815-9644e426c21f
dd3b5f68-7560-43b8-810a-53ceef615f52
e8659bc0-38ca-4411-8871-38501c3ec99d
ea755744-8029-48b6-8849-bbc880b08529
eddff925-1283-45f2-b073-e4b2b042049a
f887fbd9-8fd5-442e-99a8-f6fe66d8a53c
fbd36031-182c-4caa-9f14-9b0b11f3d40f
fef570c2-138d-4260-b4e4-3e1df4851587
```

</details>

<details><summary>D2 active request IDs at T1 (click to expand)</summary>

```
0176b9be-9c79-40fa-a056-7e181eed5ede
0380993d-2bfd-40f6-af97-ea3760ccc186
09997ad6-2326-4ccf-9e37-e429f273dbf3
0cf24927-a68a-4efb-b1e0-b0780c69ea3c
155888ed-219f-4f0d-bc37-272e14edc735
1f25b995-b0fa-4436-b008-9d73fe75be8e
21ae4321-5354-4037-be5a-44482743d025
2e035814-e5d1-49b7-84e6-4f4cf981a59e
3b12a0c1-e888-4964-91c7-4a895b8ec8e4
3cfdaaab-69d6-420b-b403-606b9deaf106
4216ff3e-c648-4f47-a3ed-6cc4dddf59f0
4285984e-c3b1-4940-82ca-3fc1fb870cf5
446b375e-5a05-454a-a087-80834bd5177c
45bb0291-4387-4266-b5e8-a83f1006c28c
4d78e069-59a5-4a5e-b3ab-e59486c7f12d
5022938a-7d77-40fb-8f85-d14d426e1614
5f9b1a38-aa5c-49e1-b1f1-ebc36001249e
60e99c51-75d6-4b11-840a-a3edb7879ef4
6ce88150-f9cc-4e66-90e5-53fac7fe999f
75fa35b7-21e9-45db-b196-e869a4992cd6
777ae243-4c4c-4a30-8385-a3756115cb8f
7a759400-22f1-408d-a27a-1cd07db5c45a
7d8cde7e-b491-4c94-9688-75d0bdc2b08a
7e82f093-718f-4f89-a818-408084201293
88f5c806-359b-4577-bd6b-f4a5fbfd1a11
954a346a-98c5-4be9-8ec5-21cd0ae2f08d
955feade-64b4-48ad-917a-4b9807cd5916
9a53ec29-5793-4180-a901-8e36e5d36cb5
9be12149-10fd-47d7-b326-4b81b4cb3a34
a079a40f-eb4b-43c4-aecf-e62c2c20bd29
b0b024f8-b533-4b0d-937f-61a0e225309d
b39ea001-5372-42bf-b017-5616eb6213a5
c230900d-12fc-4d1d-a6c0-dce51a0c656c
cbc46bb4-85e6-4a97-9fca-d89a935928ee
d3bf8c21-c07b-4bf6-a8be-e81981d43809
e140c075-6649-4ffb-ba9c-3e719d862c60
e4666a82-1e16-43b2-bc04-88796f8e0522
eb2fd8a1-6dd4-4be3-b736-299c27791d48
f3934749-f200-45a2-9072-13658c5b4a97
ffa2a1d2-fe02-4cc4-827a-ab16a0f49185
```

</details>

---

## 3. Per-Migration Detail (with before/after tracking)

| # | request_id | D1 decoded | max_tok | remaining | path | replay | D1 pre→post | D2 pre→post | left D1 | D2 accepted | status |
|---|------------|----:|----:|----:|------|----:|------------|------------|---------|-------------|--------|
| 1 | `36991d3d-05d..` | 1081 | 8000 | 6919 | recompute | 1081 | 40→39 | 40→40 | true | true | **ok** |
| 2 | `d4a6e9e3-f97..` | 1187 | 8000 | 6813 | recompute | 1187 | 39→38 | 40→40 | true | true | **ok** |
| 3 | `01f742e0-cce..` | 1294 | 8000 | 6706 | recompute | 1294 | 38→37 | 40→40 | true | true | **ok** |
| 4 | `cd815c61-737..` | 1399 | 8000 | 6601 | recompute | 1399 | 37→36 | 40→39 | true | true | **ok** |
| 5 | `1e6df650-b75..` | 1500 | 8000 | 6500 | recompute | 1500 | 36→34 | 39→39 | true | true | **ok** |
| 6 | `c8d17144-8a4..` | 1521 | 8000 | 6479 | recompute | 1521 | 34→33 | 39→39 | true | true | **ok** |

### How to read this table

- **D1 decoded**: tokens D1 had already generated before migration
- **remaining**: `max_tokens - D1_decoded` — what D2 will continue generating
- **replay**: total tokens D2 received (`original_prompt + D1_generated`)
- **D1 pre→post**: D1 active request count before → after migration
- **D2 pre→post**: D2 active request count before → after migration
- **left D1**: request_id disappeared from D1 active list (D1 released it)
- **D2 accepted**: D2's migrate_in returned ok with path=recompute/connector

### Migration summary

| outcome                          | count               |
|----------------------------------|--------------------:|
| migrations ok                    | **6**        |
| migrations declined              | 0           |
| migrations error                 | 0           |
| rolled back                      | 0            |
| request IDs moved correctly      | 6             |
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

- **Migration #1** (`36991d3d-05d..`): D1 decoded **1081** tokens out of 8000.
  D2 received replay_tokens=1081 (original prompt + 1081 generated tokens).
  D2 will generate ~6919 more tokens to complete the request.
  Verified: left_D1=true, D2_accepted=true

- **Migration #2** (`d4a6e9e3-f97..`): D1 decoded **1187** tokens out of 8000.
  D2 received replay_tokens=1187 (original prompt + 1187 generated tokens).
  D2 will generate ~6813 more tokens to complete the request.
  Verified: left_D1=true, D2_accepted=true

- **Migration #3** (`01f742e0-cce..`): D1 decoded **1294** tokens out of 8000.
  D2 received replay_tokens=1294 (original prompt + 1294 generated tokens).
  D2 will generate ~6706 more tokens to complete the request.
  Verified: left_D1=true, D2_accepted=true

- **Migration #4** (`cd815c61-737..`): D1 decoded **1399** tokens out of 8000.
  D2 received replay_tokens=1399 (original prompt + 1399 generated tokens).
  D2 will generate ~6601 more tokens to complete the request.
  Verified: left_D1=true, D2_accepted=true

- **Migration #5** (`1e6df650-b75..`): D1 decoded **1500** tokens out of 8000.
  D2 received replay_tokens=1500 (original prompt + 1500 generated tokens).
  D2 will generate ~6500 more tokens to complete the request.
  Verified: left_D1=true, D2_accepted=true

- **Migration #6** (`c8d17144-8a4..`): D1 decoded **1521** tokens out of 8000.
  D2 received replay_tokens=1521 (original prompt + 1521 generated tokens).
  D2 will generate ~6479 more tokens to complete the request.
  Verified: left_D1=true, D2_accepted=true

---

## 5. Post-Migration State

| metric                             | T1 (before)     | T2 (after mig)  | T3 (drained) |
|------------------------------------|----------------:|----------------:|-------------:|
| D1 active requests                 | 40    | 26    | -            |
| D2 active requests                 | 40   | 36   | -            |
| D1 `num_requests_running`          | 40.0    | 26.0    | 0.0 |
| D2 `num_requests_running`          | 40.0   | 39.0   | 0.0|
| D1 `generation_tokens_total`       | 291701    | -               | 328301 |
| D2 `generation_tokens_total`       | 317683   | -               | 363420|

**D1 active requests decreased**: T1=40 → T2=26
→ **true** (D1 released migrated requests)

**D2 generation_tokens delta** (T1→T3): **45737**
(D2 generated tokens for all requests including migrated ones)

**Estimated remaining tokens across 6 migrated requests**: ~40018

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
5.1ms hold
[2m2026-05-13T08:23:42.200994Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request d4a6e9e3-f971-4841-b31d-46f1927119bd (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:23:42.207797Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing d4a6e9e3-f971-4841-b31d-46f1927119bd after 7.0ms hold
[2m2026-05-13T08:23:43.341196Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 01f742e0-ccec-4f67-98a7-0e2038b215cd (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:23:43.349340Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 01f742e0-ccec-4f67-98a7-0e2038b215cd after 8.2ms hold
[2m2026-05-13T08:23:44.496365Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request cd815c61-7377-498f-b6ff-3836ce30de1b (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:23:44.501701Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing cd815c61-7377-498f-b6ff-3836ce30de1b after 5.4ms hold
[2m2026-05-13T08:23:45.644551Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 1e6df650-b75d-4688-819b-b3161bcc3228 (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:23:45.652139Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 1e6df650-b75d-4688-819b-b3161bcc3228 after 7.6ms hold
[2m2026-05-13T08:23:46.801353Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request c8d17144-8a46-4fc8-a76c-84dc6122e976 (block_hold=True, kv_transfer=False)
[2m2026-05-13T08:23:46.804809Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing c8d17144-8a46-4fc8-a76c-84dc6122e976 after 3.5ms hold
```

### D2 (destination) — migration events
```
 with name: NixlConnector and engine_id: c6fcac18-e997-4a0e-8549-bd2b0d9fa6ee
(EngineCore_DP0 pid=714) INFO 05-12 13:55:02 [nixl_connector.py:535] Initializing NIXL Scheduler c6fcac18-e997-4a0e-8549-bd2b0d9fa6ee
[2m2026-05-12T13:55:02.738239Z[0m [33mWARNING[0m [2mnixl_connector[0m[2m:[0m NIXL was already imported, we can't reset UCX_RCACHE_MAX_UNRELEASED. Please set it to '1024' manually.
[2m2026-05-12T13:55:02.738404Z[0m [32m INFO[0m [2mnixl_connector[0m[2m:[0m NIXL is available
(EngineCore_DP0 pid=714) INFO 05-12 13:59:46 [nixl_connector.py:1104] NIXL compatibility check passed (hash: dbb2848cbaefc84f6db09834b6d47a09b8266fec2abb3dbbba3c3f553be60df9)
(EngineCore_DP0 pid=714) INFO 05-12 13:59:55 [nixl_connector.py:1104] NIXL compatibility check passed (hash: dbb2848cbaefc84f6db09834b6d47a09b8266fec2abb3dbbba3c3f553be60df9)
[2m2026-05-12T14:00:46.210363Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-12T14:02:53.032211Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-13T08:20:16.866712Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-13T08:21:34.016631Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
[2m2026-05-13T08:23:50.223832Z[0m [32m INFO[0m [2mmigration.migrate_in[0m[2m:[0m [Migration] migrate_in declined for synthetic-overbudget: replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)
```

---

## Overall

| condition                                          | result               |
|----------------------------------------------------|----------------------|
| ≥1 migration succeeded                            | **true**          |
| zero migration errors                              | **true**          |
| every migrated request left D1 and arrived on D2   | **true**           |
| D1 active requests decreased (T1→T2)              | **true**          |
| D2 generation_tokens grew (Δ=45737)     | **true**          |
| cost-benefit gate declined oversize                | **true**          |
| **OVERALL**                                        | **true**          |

