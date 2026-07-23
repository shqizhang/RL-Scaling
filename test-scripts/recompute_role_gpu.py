#!/usr/bin/env python3
"""Recompute role-aware GPU-seconds per phase, offline, from a suite's raw samples.

The in-harness ``effective_role_gpu_seconds`` keys its sample groups by the exact
float timestamp of each pod row. Every pod in one sampling round carries its own
microsecond-resolution timestamp, so each group ends up holding a single pod: the
integral then evaluates to (window length x 1) regardless of the real occupancy.
This script re-derives the quantity from the same ``pod_samples.csv`` by grouping
rows into sampling rounds, and classifies each pod by its runtime role rather
than by the Deployment it belongs to.

Role resolution, in order:
  1. ``current_role_label`` when the sidecar has published one (an S2-switched
     pod carries the role it switched to);
  2. otherwise the pod's component, which is its role by construction for any
     worker that has not switched.

Readiness is parsed as a boolean; the CSV writes it as the string "False", which
is truthy in Python and previously admitted not-ready pods into the integral.

Usage:
  python recompute_role_gpu.py <suite-dir> [--round-ms 200]
"""
from __future__ import annotations

import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

SCENARIOS = ["baseline_1p1d", "static_2p2d", "s2_only", "s3_only", "mixed"]
PHASES = ["prefill_burst", "decode_dense", "decode_tail"]


def _truthy(value: str) -> bool:
    return str(value).strip().lower() in {"true", "1", "yes"}


def role_of(row: dict) -> str:
    label = (row.get("current_role_label") or "").strip()
    if label in {"prefill", "decode"}:
        return label
    return "prefill" if row.get("component") == "VllmPrefillWorker" else "decode"


def occupancy_series(pod_rows: list[dict], round_s: float) -> list[tuple[float, int, int]]:
    """Return [(ts, prefill_ready, decode_ready)] with one entry per sampling round."""
    rounds: dict[int, dict[str, dict]] = defaultdict(dict)
    for row in pod_rows:
        try:
            ts = float(row["ts"])
        except (KeyError, TypeError, ValueError):
            continue
        rounds[int(ts / round_s)][row.get("name", "")] = row
    series = []
    for bucket in sorted(rounds):
        by_pod = rounds[bucket]
        ts = min(float(r["ts"]) for r in by_pod.values())
        prefill = decode = 0
        for row in by_pod.values():
            if not _truthy(row.get("ready", "")):
                continue
            if role_of(row) == "prefill":
                prefill += 1
            else:
                decode += 1
        series.append((ts, prefill, decode))
    return series


def integrate(series: list[tuple[float, int, int]], start: float, end: float) -> dict:
    """Integrate ready-GPU counts over [start, end], holding each sample forward."""
    if not series or end <= start:
        return {"prefill_gpu_s": 0.0, "decode_gpu_s": 0.0, "samples": 0}
    prefill_s = decode_s = 0.0
    used = 0
    for idx, (ts, prefill, decode) in enumerate(series):
        seg_start = max(ts, start)
        seg_end = series[idx + 1][0] if idx + 1 < len(series) else end
        seg_end = min(seg_end, end)
        if seg_end <= seg_start:
            continue
        span = seg_end - seg_start
        prefill_s += prefill * span
        decode_s += decode * span
        used += 1
    return {"prefill_gpu_s": prefill_s, "decode_gpu_s": decode_s, "samples": used}


def run_rows(run_dir: Path) -> tuple[dict, list[dict], float]:
    summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
    with (run_dir / "pod_samples.csv").open(encoding="utf-8") as fh:
        pods = list(csv.DictReader(fh))
    events = json.loads((run_dir / "events.json").read_text(encoding="utf-8"))
    t0 = next(float(e["ts"]) for e in events if e.get("event") == "T0_batch_dispatch")
    return summary, pods, t0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("suite")
    ap.add_argument("--round-ms", type=float, default=200.0)
    args = ap.parse_args()
    suite = Path(args.suite)

    out: dict[str, dict] = {}
    for scenario in SCENARIOS:
        per_phase: dict[str, dict[str, list[float]]] = {
            ph: {"prefill_gpu_s": [], "decode_gpu_s": [], "window_s": []} for ph in PHASES
        }
        whole = {"prefill_gpu_s": [], "decode_gpu_s": []}
        for run_dir in sorted((suite / scenario).glob("run-*")):
            if not (run_dir / "pod_samples.csv").exists():
                continue
            summary, pods, t0 = run_rows(run_dir)
            series = occupancy_series(pods, args.round_ms / 1000.0)
            t_end = t0 + float(summary["T_batch_s"])
            agg = integrate(series, t0, t_end)
            whole["prefill_gpu_s"].append(agg["prefill_gpu_s"])
            whole["decode_gpu_s"].append(agg["decode_gpu_s"])
            for phase, metrics in (summary.get("phase_metrics") or {}).items():
                if phase not in per_phase:
                    continue
                lo = t0 + float(metrics.get("first_dispatch_from_T0_s", 0.0))
                hi = t0 + float(metrics.get("last_completion_from_T0_s", 0.0))
                phase_agg = integrate(series, lo, hi)
                per_phase[phase]["prefill_gpu_s"].append(phase_agg["prefill_gpu_s"])
                per_phase[phase]["decode_gpu_s"].append(phase_agg["decode_gpu_s"])
                per_phase[phase]["window_s"].append(hi - lo)
        if not whole["prefill_gpu_s"]:
            continue
        out[scenario] = {
            "runs": len(whole["prefill_gpu_s"]),
            "whole": {k: statistics.mean(v) for k, v in whole.items()},
            "phases": {
                ph: {k: statistics.mean(v) for k, v in cols.items() if v}
                for ph, cols in per_phase.items() if cols["window_s"]
            },
        }

    print(json.dumps(out, indent=1))
    print("\n=== role-aware GPU-seconds (means over runs) ===")
    header = f"{'scenario':15s} {'phase':14s} {'window_s':>9s} {'prefill_gpu_s':>14s} {'decode_gpu_s':>13s}"
    print(header)
    for scenario, data in out.items():
        for phase, cols in data["phases"].items():
            print(f"{scenario:15s} {phase:14s} {cols['window_s']:9.1f} "
                  f"{cols['prefill_gpu_s']:14.1f} {cols['decode_gpu_s']:13.1f}")
        w = data["whole"]
        print(f"{scenario:15s} {'WHOLE RUN':14s} {'':>9s} "
              f"{w['prefill_gpu_s']:14.1f} {w['decode_gpu_s']:13.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
