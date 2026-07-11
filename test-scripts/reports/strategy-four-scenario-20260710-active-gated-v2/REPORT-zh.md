# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-10T12:09:40
readiness_gate_passed: None

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |
| s2_only | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |
| s3_only | 0/1 | 182.90 | 0.00% | 29.73 | 15.6700 | 0.00% | 0 | 1 | 100.00% |
| mixed_strategy | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |

## Goal Analysis

- S2 prefill wall improvement: 0.00%
- S2 overall wall improvement: 0.00%
- S3 overall wall improvement: 0.00%
- S3 tail decode GPU-second savings: 100.00%
- Mixed overall wall improvement: 0.00%
- Mixed tail decode GPU-second savings: 0.00%
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
