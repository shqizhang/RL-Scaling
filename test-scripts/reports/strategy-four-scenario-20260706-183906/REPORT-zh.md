# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-06T19:16:33
readiness_gate_passed: True

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1/1 | 88.51 | 0.00% | 49.57 | 99.4822 | 0.00% | 0 | 0 | 43.85% |
| s2_only | 0/1 | 212.54 | -140.12% | 52.83 | 20.1098 | -79.79% | 2 | 0 | -97.22% |
| s3_only | 0/1 | 185.13 | -109.15% | 30.55 | 22.9388 | -76.94% | 0 | 0 | 3.96% |
| mixed_strategy | 0/1 | 208.14 | -135.15% | 49.07 | 20.0738 | -79.82% | 2 | 0 | 2.03% |

## Goal Analysis

- S2 prefill wall improvement: -6.59%
- S2 overall wall improvement: -140.12%
- S3 overall wall improvement: -109.15%
- S3 tail decode GPU-second savings: 3.96%
- Mixed overall wall improvement: -135.15%
- Mixed tail decode GPU-second savings: 2.03%
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
