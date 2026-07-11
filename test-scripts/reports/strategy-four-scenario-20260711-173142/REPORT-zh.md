# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-11T18:24:56
readiness_gate_passed: True

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1/1 | 403.42 | 0.00% | 321.28 | 20.6720 | 0.00% | 0 | 0 | 17.80% |
| s2_only | 0/1 | 483.15 | -19.76% | 166.69 | 8.6366 | -58.22% | 2 | 0 | -94.24% |
| s3_only | 0/1 | 343.82 | 14.78% | 185.66 | 12.1797 | -41.08% | 0 | 0 | 2.60% |
| mixed_strategy | 0/1 | 488.04 | -20.97% | 172.98 | 8.5248 | -58.76% | 2 | 0 | 1.96% |

## Goal Analysis

- S2 prefill wall improvement: 48.12%
- S2 overall wall improvement: -19.76%
- S3 overall wall improvement: 14.78%
- S3 tail decode GPU-second savings: 2.60%
- Mixed overall wall improvement: -20.97%
- Mixed tail decode GPU-second savings: 1.96%
- Best wall scenario: s3_only
- Best tokens/GPU-s scenario: baseline_minimal

## Raw Artifact Index

- workload-manifest.jsonl
- readiness_gate/
- baseline_minimal/run-01/
- s2_only/run-01/
- s3_only/run-01/
- mixed_strategy/run-01/
- suite-aggregate.json
- suite-goal-analysis.json
