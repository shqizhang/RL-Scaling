# S3 Decoder consolidation — E2E test report (20260510-122258)

DGD: `vllm-v1-disagg-router` | namespace: `dynamo-system` | model: `Qwen/Qwen3-0.6B`
Target pod: `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5wmrpf`
Peer pod  : `vllm-v1-disagg-router-vllmdecodeworker-f5d52951-597f6997d5zh2df`

Driver: 24 long chats (`max_tokens=3500`) submitted
through the frontend; KV-router distributes them across the two decoders.
After 8 s the test loops up to 6 times calling
`POST /migrate_out` on TARGET (`request_id="*"` -> most-progressed
in-flight request) and `POST /migrate_in` on PEER.

## Migration results

| outcome              | count          |
|----------------------|----------------|
| migrate_in **ok**    | 3      |
| migrate_in declined  | 0|
| errors               | 0     |

* >=1 successful migration: **true**
* No `status=error` responses: **true**

## GPU release / dst takeover

|                                            | before mig (T1) | after mig (T2) | drained (T3) |
|--------------------------------------------|----------------:|---------------:|-------------:|
| TARGET `vllm:num_requests_running`       | 5.0   | 0.0  | -            |
| PEER   `vllm:num_requests_running`       | 5.0  | 0.0 | -            |
| TARGET `vllm:generation_tokens_total`    | 41002   | -              | 42079 |
| PEER   `vllm:generation_tokens_total`    | 42775  | -              | 44710 |

* TARGET running-requests count decreased after migration: **true**
* PEER produced additional tokens after T1 (delta=1935): **true**
  (TARGET delta over the same window = 1077)

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
1,migrate_out,ok,-,-,-,22eb4e6b-e896-4cbe-ab7c-961a124eb151
1,migrate_in,ok,recompute,1726,-,22eb4e6b-e896-4cbe-ab7c-961a124eb151
2,migrate_out,ok,-,-,-,325cd6fa-cd8d-4ad9-9a70-a0856e006802
2,migrate_in,ok,recompute,1933,-,325cd6fa-cd8d-4ad9-9a70-a0856e006802
3,migrate_out,ok,-,-,-,73729f36-2cbb-4da2-9547-9f178096d646
3,migrate_in,ok,recompute,2190,-,73729f36-2cbb-4da2-9547-9f178096d646
```

## Overall
**true**
