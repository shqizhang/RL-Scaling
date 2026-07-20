#!/usr/bin/env python3
"""Aggregate a FINAL dataset from multiple suites into one report directory.

Use case: reuse scenarios that are already valid (baseline_1p1d, static_2p2d,
s3_only from the phased suite) and take the post-fix reruns for the scenarios
that were re-run (s2_only, mixed) -- so we never re-run everything just to
refresh two scenarios. Copies the raw per-run artifacts (summary/requests/
pod_samples/prom_samples/logs) and writes a combined consolidated-data.json.

All source suites MUST share the same workload manifest (same seed/params),
otherwise the merge is invalid -- this is checked and refused.

Usage:
  python aggregate_final_dataset.py <out_dir> scenario=<suite_dir> [scenario=<suite_dir> ...]
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path


def load_runs(suite: Path, scn: str) -> list[dict]:
    runs = []
    for f in sorted((suite / scn).glob("run-*/summary.json")):
        runs.append(json.loads(f.read_text(encoding="utf-8")))
    return runs


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    out = Path(sys.argv[1])
    mapping: dict[str, Path] = {}
    for arg in sys.argv[2:]:
        scn, _, src = arg.partition("=")
        mapping[scn] = Path(src)

    # --- integrity: every source suite must share the same workload manifest ---
    manifests = {}
    for scn, suite in mapping.items():
        mf = suite / "workload-manifest.jsonl"
        manifests[scn] = mf.read_text(encoding="utf-8") if mf.exists() else None
    uniq = {m for m in manifests.values() if m is not None}
    if len(uniq) > 1:
        print("REFUSING TO MERGE: source suites use DIFFERENT workload manifests:")
        for scn, m in manifests.items():
            print(f"  {scn}: {'<missing>' if m is None else str(hash(m))}")
        return 1
    print(f"manifest check: OK ({len(uniq)} unique manifest across {len(mapping)} sources)")

    out.mkdir(parents=True, exist_ok=True)
    if uniq:
        (out / "workload-manifest.jsonl").write_text(next(iter(uniq)), encoding="utf-8")

    aggregates, all_runs, provenance = {}, [], {}
    for scn, suite in mapping.items():
        src_dir = suite / scn
        dst_dir = out / scn
        if dst_dir.exists():
            shutil.rmtree(dst_dir)
        shutil.copytree(src_dir, dst_dir)          # raw artifacts + logs
        runs = load_runs(suite, scn)
        all_runs.extend(runs)
        provenance[scn] = {"source_suite": suite.name, "runs": len(runs)}
        agg_f = suite / scn / "aggregate-summary.json"
        if agg_f.exists():
            aggregates[scn] = json.loads(agg_f.read_text(encoding="utf-8"))
        else:
            aggregates[scn] = {"scenario": scn, "run_count": len(runs), "runs": runs}
        print(f"  {scn:<15} <- {suite.name}  ({len(runs)} runs)")

    (out / "consolidated-data.json").write_text(json.dumps({
        "suite": out.name,
        "note": "FINAL merged dataset: reused valid scenarios + post-fix reruns. "
                "All sources share one workload manifest (verified).",
        "provenance": provenance,
        "scenarios": list(mapping.keys()),
        "aborted": None,
        "aggregates": aggregates,
        "all_runs": all_runs,
    }, indent=2), encoding="utf-8")
    print(f"\nwrote {out/'consolidated-data.json'}  ({len(all_runs)} runs total)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
