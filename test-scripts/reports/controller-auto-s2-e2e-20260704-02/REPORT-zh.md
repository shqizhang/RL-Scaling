# Controller Auto S2 E2E Report

- image: ghcr.io/shqizhang/rl-scaling-controller:ca629b7
- workload: 48 prefill-heavy requests, concurrency=12, prompt_words=1600, max_tokens=128
- prefill threshold: 1
- success: 100.00%
- wall time: 38.759s
- req/s: 1.238
- p95 latency: 18.883s
- S2 history count: 0
- S2 executed count: 0

Artifacts: requests.csv, controller_status.jsonl, events.csv, gpu_samples.csv, logs/.
