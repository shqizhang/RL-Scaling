# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-10T18:48:38
readiness_gate_passed: True

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 1/1 | 92.14 | 0.00% | 49.35 | 93.8749 | 0.00% | 0 | 0 | 14.38% |
| s2_only | 0/1 | 357.76 | -288.28% | 38.52 | 11.5823 | -87.66% | 2 | 0 | -95.76% |
| s3_only | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |
| mixed_strategy | 0/0 | 0.00 | 0.00% | 0.00 | 0.0000 | 0.00% | 0 | 0 | 0.00% |

## Goal Analysis

- S2 prefill wall improvement: 21.94%
- S2 overall wall improvement: -288.28%
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
