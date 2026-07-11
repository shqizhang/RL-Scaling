# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-11T21:09:01
readiness_gate_passed: True

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1/1 | 342.71 | 0.00% | 296.93 | 24.5375 | 0.00% | 0 | 0 | 20.17% |
| s2_only | 0/1 | 467.67 | -36.46% | 146.77 | 8.8540 | -63.92% | 2 | 0 | -99.03% |
| s3_only | 0/1 | 346.29 | -1.05% | 155.78 | 12.2252 | -50.18% | 0 | 0 | 5.25% |
| mixed_strategy | 0/1 | 496.20 | -44.79% | 178.90 | 8.4085 | -65.73% | 2 | 0 | 2.14% |

## Goal Analysis

- S2 prefill wall improvement: 50.57%
- S2 overall wall improvement: -36.46%
- S3 overall wall improvement: -1.05%
- S3 tail decode GPU-second savings: 5.25%
- Mixed overall wall improvement: -44.79%
- Mixed tail decode GPU-second savings: 2.14%
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
