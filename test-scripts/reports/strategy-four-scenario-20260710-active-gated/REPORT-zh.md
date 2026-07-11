# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-10T11:43:51
readiness_gate_passed: True

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1/1 | 89.37 | 0.00% | 49.08 | 102.6405 | 0.00% | 0 | 0 | 43.41% |
| s2_only | 0/1 | 210.74 | -135.81% | 48.43 | 20.2692 | -80.25% | 2 | 0 | -94.74% |
| s3_only | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |
| mixed_strategy | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |

## Goal Analysis

- S2 prefill wall improvement: 1.32%
- S2 overall wall improvement: -135.81%
- S3 overall wall improvement: 0.00%
- S3 tail decode GPU-second savings: 0.00%
- Mixed overall wall improvement: 0.00%
- Mixed tail decode GPU-second savings: 0.00%
- Best wall scenario: baseline_minimal
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
