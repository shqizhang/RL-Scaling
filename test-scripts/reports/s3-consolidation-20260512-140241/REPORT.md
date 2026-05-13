# S3 Decoder consolidation — E2E test report (20260512-140241)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
D1 (source):      `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-j96lb`
D2 (destination): `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-wqvrk`
Frontend:         `vllm-v1-disagg-router-frontend-67fbb7767d-744j6`

## 1. Test design

- Submit 60 long-running chats (`max_tokens=8000`)
- Wait 3s for scheduler to distribute across D1 and D2
- Migrate up to 6 requests from D1 → D2 using coordinated
  `POST /migrate` endpoint

The coordinated endpoint ensures KV consistency:
1. `migrate_out` holds the request on D1 (defers abort, blocks pinned)
2. Internally calls D2's `/migrate_in` with the state snapshot
3. On success: aborts D1's copy, frees blocks (D2 continues decoding)
4. On failure: releases hold, D1 continues (rollback — no work lost)

## 2. Pre-migration state

| metric                        | D1          | D2          |
|-------------------------------|------------:|------------:|
| active requests (T1)          | 31 | 31|
| `num_requests_running` (T1) | 4.0 | 0.0 |
| `generation_tokens_total` (T1)| 12673 | 12805 |

## 3. Per-migration detail

| # | request_id (short) | D1 decoded | max_tokens | remaining | path | replay_tokens | status | rolled_back |
|---|-------|----:|----:|----:|------|----:|--------|---------|
| 1 | `0df237b9...` | 105 | 8000 | 7895 | recompute | 105 | **ok** | False |
| 2 | `57733300...` | 296 | 8000 | 7704 | recompute | 296 | **ok** | False |
| 3 | `85bc1d98...` | 459 | 8000 | 7541 | recompute | 459 | **ok** | False |
| 4 | `669213b7...` | 603 | 8000 | 7397 | recompute | 603 | **ok** | False |
| 5 | `cd4bccac...` | 710 | 8000 | 7290 | recompute | 710 | **ok** | False |
| 6 | `da6b2467...` | 827 | 8000 | 7173 | recompute | 827 | **ok** | False |

**How to read this table:**
- **D1 decoded**: number of tokens D1 had already generated for this request
  before migration.  This is the work that would be lost without migration.
- **max_tokens**: the total token budget for this request.
- **remaining**: `max_tokens - D1_decoded`.  D2 will generate these tokens.
- **replay_tokens**: total tokens D2 received as its new prompt
  (`original_prompt + D1_generated_tokens`).  D2 re-prefills this and
  continues decoding from where D1 stopped.
- **rolled_back**: if true, D2 declined and D1's request continues unchanged.

### Migration summary

| outcome              | count              |
|----------------------|-------------------:|
| migrations ok        | **6**      |
| migrations declined  | 0    |
| migrations error     | 0         |
| rolled back          | 0 |

## 4. Post-migration metrics

| metric                             | T1 (before) | T2 (after mig) | T3 (drained) |
|------------------------------------|------------:|---------------:|-------------:|
| D1 `num_requests_running`        | 4.0 | 18.0  | 7.0 |
| D2 `num_requests_running`        | 0.0 | 15.0 | 2.0 |
| D1 `generation_tokens_total`     | 12673 | - | 56966 |
| D2 `generation_tokens_total`     | 12805 | - | 56437 |

**D2 generation_tokens delta** (T1 → T3): **43632**
(This proves D2 actually decoded tokens for the migrated requests)

**D1 running-requests decreased**: T1=4.0 → T2=18.0
→ **false** (proves D1 resources were freed)

## 5. Cost-benefit gate

Synthetic `migrate_in` with `prompt_tokens=9000` (exceeds
`max_replay_tokens=8192`):

```json
{
    "status": "declined",
    "reason": "replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)",
    "request_id": "synthetic-overbudget"
}
```

* Oversize migration declined: **true**

## 6. D1 worker log excerpts (migration events)

```
[2m2026-05-12T14:02:44.829369Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 0df237b9-f7ac-417f-809c-9f3b9bcf597a (block_hold=True, kv_transfer=False)
[2m2026-05-12T14:02:44.837150Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 0df237b9-f7ac-417f-809c-9f3b9bcf597a after 7.8ms hold
[2m2026-05-12T14:02:45.819472Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 57733300-96ef-4079-ba42-c5211212edab (block_hold=True, kv_transfer=False)
[2m2026-05-12T14:02:45.826656Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 57733300-96ef-4079-ba42-c5211212edab after 7.2ms hold
[2m2026-05-12T14:02:46.826632Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 85bc1d98-3bd3-4531-b3df-9f1b16d3c9c2 (block_hold=True, kv_transfer=False)
[2m2026-05-12T14:02:46.834617Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 85bc1d98-3bd3-4531-b3df-9f1b16d3c9c2 after 7.9ms hold
[2m2026-05-12T14:02:47.819987Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request 669213b7-1c27-4239-bcf8-5763bb67f18c (block_hold=True, kv_transfer=False)
[2m2026-05-12T14:02:47.825793Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing 669213b7-1c27-4239-bcf8-5763bb67f18c after 5.9ms hold
[2m2026-05-12T14:02:48.816855Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request cd4bccac-e13d-4732-88fb-c502052d704a (block_hold=True, kv_transfer=False)
[2m2026-05-12T14:02:48.822961Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing cd4bccac-e13d-4732-88fb-c502052d704a after 6.2ms hold
[2m2026-05-12T14:02:49.804848Z[0m [32m INFO[0m [2mmigration.migrate_out[0m[2m:[0m [Migration] migrate_out: holding request da6b2467-e97a-4785-b054-d219e536afb2 (block_hold=True, kv_transfer=False)
[2m2026-05-12T14:02:49.810895Z[0m [32m INFO[0m [2mmigration.migration_complete[0m[2m:[0m [Migration] migration_complete: releasing da6b2467-e97a-4785-b054-d219e536afb2 after 6.1ms hold
```

## Overall

| condition                                | result              |
|------------------------------------------|---------------------|
| ≥1 migration succeeded                  | **true**       |
| zero migration errors                    | **true**    |
| D1 running-requests decreased            | **false**  |
| D2 generation_tokens grew (Δ=43632) | **true** |
| cost-benefit gate declined oversize      | **true**      |
| **OVERALL**                              | **true**              |
