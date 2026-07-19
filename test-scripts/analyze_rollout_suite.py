#!/usr/bin/env python3
"""Analyse a production-faithful rollout suite from its consolidated data file.

Reads <suite>/consolidated-data.json (all runs + aggregates) and reports the
Tier 1-3 metrics with paired within-round statistics, plus a position diagnostic
(the counterbalanced order should leave no residual position effect).

Usage: python analyze_rollout_suite.py <suite-dir>
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

SCENARIOS = ["baseline_1p1d", "static_2p2d", "s2_only", "s3_only", "mixed"]
CONTROL = "static_2p2d"


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else float("nan")


def sd(xs):
    xs = [x for x in xs if x is not None]
    if len(xs) < 2:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def paired_t(diffs):
    n = len(diffs)
    if n < 2:
        return float("nan")
    m, s = mean(diffs), sd(diffs)
    return m / (s / math.sqrt(n)) if s > 0 else (float("inf") if m else 0.0)


def runs_by(all_runs, scn):
    return sorted([r for r in all_runs if r["scenario"] == scn], key=lambda r: r["repeat"])


def main():
    suite = Path(sys.argv[1])
    data = json.load(open(suite / "consolidated-data.json"))
    runs = data["all_runs"]
    # Backfill avg-GPU metrics for suites recorded before they were added.
    for r in runs:
        tb = r.get("T_batch_s") or 0
        if tb > 0:
            r.setdefault("avg_decode_gpus", r.get("decode_gpu_s", 0) / tb)
            r.setdefault("avg_total_gpus", r.get("total_gpu_s", 0) / tb)
            r.setdefault("avg_prefill_gpus", r.get("prefill_gpu_s", 0) / tb)
    print("=" * 80)
    print(f"SUITE: {data['suite']}   config: {data['config']}   aborted: {data.get('aborted')}")
    print("=" * 80)

    # ---- 1. QUALITY GATE ----
    print("\n[1] QUALITY  (gate: 100% valid / 0 timeouts / 0 5xx)")
    print(f"{'scenario':<15}{'n':>3}{'valid%':>9}{'timeouts':>10}{'5xx':>6}")
    quality_ok = True
    for s in SCENARIOS:
        rs = runs_by(runs, s)
        if not rs:
            print(f"{s:<15}{'--':>3}  MISSING"); quality_ok = False; continue
        v, t, x = mean([r["valid_decode_pct"] for r in rs]), sum(r["timeout_count"] for r in rs), sum(r["http_5xx_count"] for r in rs)
        flag = "" if (v == 100.0 and t == 0 and x == 0) else "  <-- FAIL"
        if flag: quality_ok = False
        print(f"{s:<15}{len(rs):>3}{v:>9.1f}{t:>10}{x:>6}{flag}")

    # ---- 2. POSITION DIAGNOSTIC (counterbalance worked?) ----
    print("\n[2] POSITION DIAGNOSTIC  (counterbalanced order should decorrelate")
    print("    position from scenario; shows mean position each scenario ran at)")
    for s in SCENARIOS:
        rs = runs_by(runs, s)
        pos = [r.get("position_in_round") for r in rs]
        print(f"    {s:<15} positions={pos}  mean={mean([float(p) for p in pos]):.2f}")

    # ---- 3. PRIMARY OUTCOMES (Tier 1) ----
    print("\n[3] PRIMARY OUTCOMES (mean +- sd)")
    cols = [("T_batch_s", "T_batch"), ("decode_gpu_s", "decode_gpuS"),
            ("total_gpu_s", "total_gpuS"), ("avg_decode_gpus", "avgDecGPU"),
            ("avg_total_gpus", "avgTotGPU"), ("decode_kv_occupancy_mean", "U_GPU%")]
    hdr = f"{'scenario':<15}" + "".join(f"{lbl:>16}" for _, lbl in cols)
    print(hdr)
    for s in SCENARIOS:
        rs = runs_by(runs, s)
        if not rs:
            continue
        line = f"{s:<15}"
        for key, _ in cols:
            xs = [r.get(key) for r in rs]
            line += f"{mean(xs):>9.1f}+-{sd(xs):<5.1f}"
        print(line)

    # ---- 4. PAIRED vs CONTROL (within round) ----
    print("\n[4] PAIRED vs static_2p2d (strategy - control, per round)")
    pairs = [("static_2p2d", "baseline_1p1d", "topology (2P2D vs 1P1D)"),
             ("s2_only", CONTROL, "S2 effect"),
             ("s3_only", CONTROL, "S3 effect"),
             ("mixed", CONTROL, "S2+S3 combined")]
    for metric in ["T_batch_s", "decode_gpu_s", "total_gpu_s", "avg_decode_gpus", "decode_kv_occupancy_mean"]:
        print(f"\n  -- {metric}")
        for strat, ctrl, label in pairs:
            A, B = runs_by(runs, strat), runs_by(runs, ctrl)
            n = min(len(A), len(B))
            if n < 2:
                continue
            d = [A[i].get(metric, 0) - B[i].get(metric, 0) for i in range(n)]
            base = mean([B[i].get(metric, 0) for i in range(n)])
            pct = mean(d) / base * 100 if base else float("nan")
            t = paired_t(d)
            sig = "significant" if abs(t) > 4.30 else "n.s."  # t_crit df=2, .05, two-tail
            print(f"    {label:<28} d={mean(d):+9.2f} ({pct:+6.1f}%) t={t:+6.2f} {sig}")

    # ---- 5. MECHANISM EVIDENCE ----
    print("\n[5] MECHANISM EVIDENCE (order-independent)")
    print(f"{'scenario':<15}{'S2 switch':>11}{'S2 ms':>9}{'S3 migr':>9}{'S3 drain':>10}{'min_dec':>9}")
    for s in SCENARIOS:
        rs = runs_by(runs, s)
        if not rs:
            continue
        s2 = sum(r["s2_executed_count"] for r in rs)
        s2ms = mean([r["s2_switch_total_ms"] for r in rs if r["s2_executed_count"]])
        s3m = sum(r["s3_migrated_requests"] for r in rs)
        s3d = sum(r["s3_drained_source_count"] for r in rs)
        mind = min(r["min_spec_decode_replicas"] for r in rs)
        print(f"{s:<15}{s2:>11}{(f'{s2ms:.0f}' if s2 else '-'):>9}{s3m:>9}{s3d:>10}{mind:>9}")

    print("\n" + "=" * 80)
    print(f"GATE: quality_ok={quality_ok}")
    print("=" * 80)


if __name__ == "__main__":
    main()
