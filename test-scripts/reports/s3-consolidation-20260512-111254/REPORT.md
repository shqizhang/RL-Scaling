# S3 Decoder consolidation — E2E test report (20260512-111254)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
Target pod: `vllm-v1-disagg-router-vllmdecodeworker-55c5d8a8-b7f5d959c-f7lg5`
Peer pod  : `vllm-v1-disagg-router-vllmdecodeworker-55c5d8a8-b7f5d959c-z224b`

Driver: 24 long chats (`max_tokens=3500`) submitted
through the frontend; KV-router distributes them across the two decoders.
After 8 s the test loops up to 6 times calling
`POST /migrate_out` on TARGET (`request_id="*"` -> most-progressed
in-flight request) and `POST /migrate_in` on PEER.

## Migration results

| outcome              | count          |
|----------------------|----------------|
| migrate_in **ok**    | 3      |
| — via connector path | 0|
| migrate_in declined  | 0|
| errors               | 0     |

* >=1 successful migration: **true**
* No `status=error` responses: **true**

## GPU release / dst takeover

|                                            | before mig (T1) | after mig (T2) | drained (T3) |
|--------------------------------------------|----------------:|---------------:|-------------:|
| TARGET `vllm:num_requests_running`       | 9.0   | 0.0  | -            |
| PEER   `vllm:num_requests_running`       | 6.0  | 0.0 | -            |
| TARGET `vllm:generation_tokens_total`    | 18711   | -              | 20294 |
| PEER   `vllm:generation_tokens_total`    | 19375  | -              | 21517 |

* TARGET running-requests count decreased after migration: **true**
* PEER produced additional tokens after T1 (delta=2142): **true**
  (TARGET delta over the same window = 1583)

## Cost-benefit gate (Phase-2 policy)

Synthetic `migrate_in` with `prompt_tokens`=9000 (over the
`max_replay_tokens=8192` policy ceiling) was sent to PEER:

response `status` = **declined**
* Cost-benefit gate rejects oversize migrations: **true**

```json
{"status": "declined", "reason": "replay_total=9050 exceeds max_replay_tokens=8192 (recompute prefill too expensive)", "request_id": "synthetic-overbudget"}
```

## Per-iteration migration log (CSV head)

```csv
iter,phase,status,path,replay_tokens,reason,request_id
1,migrate_out,ok,-,-,-,7476e5b7-c8bc-4713-be9b-eb98ac1d56c8
1,migrate_in,ok,recompute,1633,-,7476e5b7-c8bc-4713-be9b-eb98ac1d56c8
2,migrate_out,ok,-,-,-,b10795eb-e854-447e-abb1-bb1c5596a59d
2,migrate_in,ok,recompute,1833,-,b10795eb-e854-447e-abb1-bb1c5596a59d
3,migrate_out,ok,-,-,-,0795ed5d-8a0b-4af9-8d53-172856056041
3,migrate_in,ok,recompute,2120,-,0795ed5d-8a0b-4af9-8d53-172856056041
```

## Overall
**true**
