# RL-Scaling Four-Scenario Strategy E2E Report

generated_at: 2026-07-17T22:31:00
readiness_gate_passed: None

## Cross-Scenario Comparison

| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline_minimal | 3/3 | 94.65 | 0.00% | 30.93 | 150.6185 | 0.00% | 0 | 0 | 8.07% |
| 2p2d_static | 3/3 | 73.92 | 21.90% | 19.46 | 101.0190 | -32.93% | 0 | 0 | 21.63% |
| s2_only | 2/3 | 170.03 | -79.63% | 20.20 | 40.4305 | -73.16% | 6 | 0 | 9.96% |
| s3_only | 3/3 | 78.71 | 16.84% | 21.42 | 82.6300 | -45.14% | 0 | 3 | 11.41% |
| mixed_strategy | 2/3 | 169.78 | -79.38% | 17.79 | 35.8519 | -76.20% | 6 | 3 | 21.31% |

## Goal Analysis

- S2 prefill wall improvement: 34.69%
- S2 overall wall improvement: -79.63%
- S3 overall wall improvement: 16.84%
- S3 tail decode GPU-second savings: 11.41%
- Mixed overall wall improvement: -79.38%
- Mixed tail decode GPU-second savings: 21.31%
- Best wall scenario: 2p2d_static
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
