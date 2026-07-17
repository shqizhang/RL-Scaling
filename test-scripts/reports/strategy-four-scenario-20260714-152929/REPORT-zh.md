# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-14T16:02:52
readiness_gate_passed: True

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1/1 | 97.36 | 0.00% | 34.43 | 144.0695 | 0.00% | 0 | 0 | 8.04% |
| s2_only | 0/1 | 170.84 | -75.48% | 22.08 | 39.4546 | -72.61% | 2 | 0 | -87.81% |
| s3_only | 1/1 | 70.43 | 27.66% | 20.45 | 84.8452 | -41.11% | 0 | 1 | 15.19% |
| mixed_strategy | 1/1 | 172.59 | -77.28% | 16.72 | 37.1880 | -74.19% | 2 | 1 | 21.74% |

## Goal Analysis

- S2 prefill wall improvement: 35.86%
- S2 overall wall improvement: -75.48%
- S3 overall wall improvement: 27.66%
- S3 tail decode GPU-second savings: 15.19%
- Mixed overall wall improvement: -77.28%
- Mixed tail decode GPU-second savings: 21.74%
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
