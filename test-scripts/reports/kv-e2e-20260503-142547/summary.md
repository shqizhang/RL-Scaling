KV E2E Test Summary
===================

Run dir: /home/shengqizhang/IP/RL-Scaling/test-scripts/reports/kv-e2e-20260503-142547
Date: 2026-05-03 14:26:11 UTC

Cluster:
  namespace: dynamo-system
  model: Qwen/Qwen3-0.6B
  SRC worker: vllm-v1-disagg-router-vllmdecodeworker-d1af44b0-7975f6c5f4fcxd5
  DST worker: vllm-v1-disagg-router-vllmdecodeworker-d1af44b0-7975f6c5f42h77g

S3 Migration Proof:
  generated_tokens captured:   434 (real model tokens)
  prompt_tokens captured:      0
  expected replay_tokens:      434
  actual replay_tokens:        434  (F: exact match)
  path:                        recompute
  DST prompt_tokens delta:     500  (G: >= replay_tokens)
  DST local_compute delta:     436  (full recompute)
  SRC num_requests_running:    0   (H: 0)
  SRC kv_cache_usage after:    0%  (freed)
  Token IDs valid:             yes (I)
  Determinism (A==B):          yes (J)

S2 Role Switch KV Proof:
  KV before switch:  0%   (A)
  switch_role status: ok    (C)
  new_role:          prefill   (C)
  switch_time_ms:    72
  KV after switch:   0%  (B: reset_prefix_cache confirmed)
  restore status:    ok (D)

frontend migration counter: 0 → 0

RESULT: PASS (all 0 KV consistency assertions satisfied)
