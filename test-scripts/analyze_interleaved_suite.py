#!/usr/bin/env python3
"""Analyse a round-major (interleaved) strategy suite.

Interleaved execution means round *i* of every scenario ran under the same
cluster conditions, so drift is common-mode within a round. That licenses a
PAIRED analysis (strategy minus its control, per round), which the previous
order-major dataset could not support.

Refuses to report anything until the confound sanity check passes:
`2p2d_static` and `s3_only` are functionally identical during `prefill_burst`
(both 2P2D, no role switch, consolidation inert because its batch_completion
gate cannot be met yet). If their prefill walls disagree, run order is still
contaminating the data and no cross-scenario number is interpretable.

Usage: python analyze_interleaved_suite.py <suite-dir>
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

SCENARIOS = ["baseline_minimal", "2p2d_static", "s2_only", "s3_only", "mixed_strategy"]

# Metrics that are meaningful across scenarios. Deliberately excludes wall_s /
# gpu_s (contaminated by harness-only verification waits in s2/mixed) and
# tail_decode_gpu_s_saved (reports phantom savings when migrated=0).
SERVING = ["serving_wall_s", "prefill_wall_s", "balanced_wall_s", "tail_wall_s",
           "serving_gpu_s", "serving_spec_gpu_s"]


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else float("nan")


def stdev(xs):
    xs = [x for x in xs if x is not None]
    if len(xs) < 2:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def welch_t(a, b):
    """Welch's t. Returns (t, approx_df). No scipy in this env."""
    na, nb = len(a), len(b)
    if na < 2 or nb < 2:
        return float("nan"), float("nan")
    va, vb = stdev(a) ** 2, stdev(b) ** 2
    se2 = va / na + vb / nb
    if se2 <= 0:
        return float("nan"), float("nan")
    t = (mean(a) - mean(b)) / math.sqrt(se2)
    df = se2 ** 2 / ((va / na) ** 2 / (na - 1) + (vb / nb) ** 2 / (nb - 1))
    return t, df


def load(suite: Path):
    runs = {}
    for s in SCENARIOS:
        agg = suite / s / "aggregate-summary.json"
        if agg.exists():
            runs[s] = json.load(open(agg))["runs"]
            continue
        # aggregate not written (suite aborted): fall back to per-run files
        rs = []
        for f in sorted((suite / s).glob("run-*/summary.json")):
            try:
                rs.append(json.load(open(f)))
            except json.JSONDecodeError:
                print(f"  WARN: {f} unreadable (mid-write?) — skipped")
        if rs:
            runs[s] = rs
    return runs


def main():
    suite = Path(sys.argv[1])
    runs = load(suite)
    if not runs:
        sys.exit(f"no data under {suite}")

    print("=" * 78)
    print(f"SUITE: {suite.name}")
    print("=" * 78)

    # ---- 1. QUALITY GATE ------------------------------------------------
    print("\n[1] QUALITY (must be 100% valid / 0 timeouts to interpret anything)")
    print(f"{'scenario':<17}{'n':>3}{'valid%':>9}{'timeouts':>10}{'5xx':>6}")
    quality_ok = True
    for s in SCENARIOS:
        R = runs.get(s, [])
        if not R:
            print(f"{s:<17}{'--':>3}  MISSING")
            quality_ok = False
            continue
        v = mean([r["valid_decode_pct"] for r in R])
        t = sum(r["timeout_count"] for r in R)
        x = sum(r.get("http_5xx_count", 0) for r in R)
        flag = "" if (v == 100.0 and t == 0 and x == 0) else "  <-- PROBLEM"
        if flag:
            quality_ok = False
        print(f"{s:<17}{len(R):>3}{v:>9.1f}{t:>10}{x:>6}{flag}")

    # ---- 2. CONFOUND SANITY CHECK ---------------------------------------
    print("\n[2] CONFOUND CHECK: 2p2d_static vs s3_only during prefill_burst")
    print("    These are FUNCTIONALLY IDENTICAL in this phase. They must agree.")
    a = [r["prefill_wall_s"] for r in runs.get("2p2d_static", [])]
    b = [r["prefill_wall_s"] for r in runs.get("s3_only", [])]
    confound_ok = False
    if len(a) >= 2 and len(b) >= 2:
        t, df = welch_t(a, b)
        gap = abs(mean(a) - mean(b))
        rel = gap / mean(a) * 100 if mean(a) else float("nan")
        print(f"    2p2d_static : {mean(a):6.2f} +- {stdev(a):.2f}  {[round(x,1) for x in a]}")
        print(f"    s3_only     : {mean(b):6.2f} +- {stdev(b):.2f}  {[round(x,1) for x in b]}")
        print(f"    gap = {gap:.2f}s ({rel:.1f}%)   Welch t = {t:.2f}, df ~ {df:.1f}")
        # |t| < 2.5 at these df is comfortably non-significant
        confound_ok = abs(t) < 2.5 and rel < 10.0
        print("    VERDICT: " + ("PASS - order effect controlled" if confound_ok else
              "FAIL - residual order/session effect; cross-scenario numbers NOT interpretable"))

    # ---- 3. SERVING METRICS ---------------------------------------------
    print("\n[3] SERVING METRICS (mean +- sd over rounds)")
    hdr = f"{'scenario':<17}" + "".join(f"{k.replace('serving_','srv_').replace('_wall_s','').replace('_s',''):>16}" for k in SERVING)
    print(hdr)
    for s in SCENARIOS:
        R = runs.get(s, [])
        if not R:
            continue
        line = f"{s:<17}"
        for k in SERVING:
            xs = [r.get(k) for r in R]
            line += f"{mean(xs):>10.1f}+-{stdev(xs):<4.1f}"
        print(line)

    # ---- 4. PAIRED WITHIN-ROUND -----------------------------------------
    print("\n[4] PAIRED WITHIN-ROUND (strategy - control, per round)")
    print("    Interleaving makes round i comparable across scenarios, so pairing")
    print("    cancels drift that the unpaired means still carry.")
    pairs = [
        ("2p2d_static", "baseline_minimal", "topology effect (2P2D vs 1P1D)"),
        ("s2_only", "2p2d_static", "S2 effect (equal-topology control)"),
        ("s3_only", "2p2d_static", "S3 effect (equal-topology control)"),
        ("mixed_strategy", "2p2d_static", "S2+S3 combined"),
    ]
    for metric in ["serving_wall_s", "prefill_wall_s", "tail_wall_s",
                   "observed_tail_spec_decode_gpu_s"]:
        print(f"\n  -- {metric}")
        for strat, ctrl, label in pairs:
            A, B = runs.get(strat, []), runs.get(ctrl, [])
            n = min(len(A), len(B))
            if n < 2:
                continue
            d = [A[i].get(metric, 0) - B[i].get(metric, 0) for i in range(n)]
            md, sd = mean(d), stdev(d)
            base = mean([B[i].get(metric, 0) for i in range(n)])
            pct = md / base * 100 if base else float("nan")
            # paired t
            t = md / (sd / math.sqrt(n)) if sd > 0 else float("inf") if md else 0.0
            sig = "significant" if abs(t) > 4.30 else "n.s."  # t_crit(df=2,0.05,two-tail)
            print(f"    {label:<38} d={md:+7.2f} ({pct:+6.1f}%) sd={sd:5.2f} t={t:+6.2f} {sig}")

    # ---- 5. MECHANISM EVIDENCE ------------------------------------------
    print("\n[5] MECHANISM EVIDENCE (order-independent; the real contribution)")
    print(f"{'scenario':<17}{'S2 switches':>13}{'S2 ms':>9}{'S3 migrated':>13}{'S3 drained':>12}{'decode->':>10}")
    for s in SCENARIOS:
        R = runs.get(s, [])
        if not R:
            continue
        s2 = sum(r.get("s2_executed_count", 0) for r in R)
        s2ms = mean([r.get("s2_switch_total_ms") for r in R if r.get("s2_executed_count")])
        s3m = sum(r.get("s3_migrated_requests", 0) for r in R)
        s3d = sum(r.get("s3_drained_source_count", 0) for r in R)
        dn = [r.get("s3_scaled_down_to") for r in R if r.get("s3_scaled_down_to") is not None]
        s2ms_s = f"{s2ms:.0f}" if s2 else "-"
        print(f"{s:<17}{s2:>13}{s2ms_s:>9}{s3m:>13}{s3d:>12}{str(dn or '-'):>10}")

    print("\n" + "=" * 78)
    print("GATE: quality_ok=%s  confound_ok=%s" % (quality_ok, confound_ok))
    if not (quality_ok and confound_ok):
        print("DO NOT report performance numbers until both gates pass.")
    print("=" * 78)


if __name__ == "__main__":
    main()
