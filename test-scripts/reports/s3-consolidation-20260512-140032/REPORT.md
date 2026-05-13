# S3 Decoder consolidation — E2E test report (20260512-140032)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
D1 (source):      `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-j96lb`
D2 (destination): `vllm-v1-disagg-router-vllmdecodeworker-574b777c-59bbdf767-wqvrk`
Frontend:         `vllm-v1-disagg-router-frontend-67fbb7767d-744j6`

## 1. Test design

- Submit 24 long-running chats (`max_tokens=3500`)
- Wait 8s for scheduler to distribute across D1 and D2
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
| active requests (T1)          | 0 | 0|
| `num_requests_running` (T1) | 0.0 | 0.0 |
| `generation_tokens_total` (T1)| 12532 | 12805 |

## 3. Per-migration detail



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
| migrations ok        | **0**      |
| migrations declined  | 0    |
| migrations error     | 0         |
| rolled back          | 0 |

## 4. Post-migration metrics

| metric                             | T1 (before) | T2 (after mig) | T3 (drained) |
|------------------------------------|------------:|---------------:|-------------:|
| D1 `num_requests_running`        | 0.0 | 0.0  | 0.0 |
| D2 `num_requests_running`        | 0.0 | 0.0 | 0.0 |
| D1 `generation_tokens_total`     | 12532 | - | 12532 |
| D2 `generation_tokens_total`     | 12805 | - | 12805 |

**D2 generation_tokens delta** (T1 → T3): **0**
(This proves D2 actually decoded tokens for the migrated requests)

**D1 running-requests decreased**: T1=0.0 → T2=0.0
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
(no matching lines)
```

## Overall

| condition                                | result              |
|------------------------------------------|---------------------|
| ≥1 migration succeeded                  | **false**       |
| zero migration errors                    | **true**    |
| D1 running-requests decreased            | **false**  |
| D2 generation_tokens grew (Δ=0) | **false** |
| cost-benefit gate declined oversize      | **true**      |
| **OVERALL**                              | **false**              |
