# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-17T18:58:43
readiness_gate_passed: None

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |
| 2p2d_static | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |
| s2_only | 3/3 | 157.71 | 0.00% | 21.14 | 43.8950 | 0.00% | 6 | 0 | 11.86% |
| s3_only | 3/3 | 81.46 | 0.00% | 16.24 | 79.0577 | 0.00% | 0 | 3 | 13.32% |
| mixed_strategy | 3/3 | 166.85 | 0.00% | 17.85 | 39.3026 | 0.00% | 6 | 3 | 21.69% |

## Goal Analysis

- S2 prefill wall improvement: 0.00%
- S2 overall wall improvement: 0.00%
- S3 overall wall improvement: 0.00%
- S3 tail decode GPU-second savings: 13.32%
- Mixed overall wall improvement: 0.00%
- Mixed tail decode GPU-second savings: 21.69%
- Best wall scenario: s3_only
- Best tokens/GPU-s scenario: s3_only

## Raw Artifact Index

- workload-manifest.jsonl
- readiness_gate/
- baseline_minimal/run-01/
- s2_only/run-01/
- s3_only/run-01/
- mixed_strategy/run-01/
- suite-aggregate.json
- suite-goal-analysis.json
