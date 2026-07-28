# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-18T10:39:49
readiness_gate_passed: True

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 3/3 | 105.94 | 0.00% | 35.16 | 141.1188 | 0.00% | 0 | 0 | 0.00% |
| 2p2d_static | 3/3 | 80.51 | 24.00% | 21.65 | 92.8503 | -34.20% | 0 | 0 | 0.00% |
| s2_only | 3/3 | 157.33 | -48.51% | 16.59 | 47.9646 | -66.01% | 6 | 0 | 0.00% |
| s3_only | 3/3 | 75.23 | 28.99% | 15.19 | 91.2175 | -35.36% | 0 | 3 | 10.69% |
| mixed_strategy | 3/3 | 174.20 | -64.44% | 17.40 | 35.5081 | -74.84% | 6 | 3 | 13.94% |

## Goal Analysis

- S2 prefill wall improvement: 52.80%
- S2 overall wall improvement: -48.51%
- S3 overall wall improvement: 28.99%
- S3 tail decode GPU-second savings: 10.69%
- Mixed overall wall improvement: -64.44%
- Mixed tail decode GPU-second savings: 13.94%
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
