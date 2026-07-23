#!/usr/bin/env python3
"""Build the ending-report dataset directory from an acceptance suite.

Unlike ``aggregate_final_dataset.py`` (which merges scenarios from several
suites), this takes exactly ONE suite -- the run that is intended to be the
report's evidence -- copies its raw per-run artifacts verbatim, and derives
flat aggregate tables next to them so a reader can check any number in the
report against the raw file it came from.

Design intent: the directory must be self-auditing. It carries provenance
(images, commits, controller env), the inclusion rule, the raw artifacts, the
aggregate tables, and an explicit record of what was EXCLUDED and why.

Usage:
  python build_ending_dataset.py <suite-dir> <out-dir> [--label TEXT]
"""
from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SCENARIOS = ["baseline_1p1d", "static_2p2d", "s2_only", "s3_only", "mixed"]
# Copied per run: the artifacts every reported number can be traced back to.
RAW_FILES = ["summary.json", "requests.csv", "events.json",
             "controller_status.jsonl", "pod_samples.csv", "prom_samples.json"]


def _git(repo: Path, *args: str) -> str:
    try:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                              text=True, timeout=30).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


def load_runs(suite: Path) -> list[tuple[str, str, dict]]:
    out = []
    for scn in SCENARIOS:
        for path in sorted((suite / scn).glob("run-*/summary.json")):
            out.append((scn, path.parent.name, json.loads(path.read_text(encoding="utf-8"))))
    return out


def copy_raw(suite: Path, out: Path, runs) -> int:
    n = 0
    for scn, run, _ in runs:
        src, dst = suite / scn / run, out / "runs" / scn / run
        dst.mkdir(parents=True, exist_ok=True)
        for name in RAW_FILES:
            if (src / name).exists():
                shutil.copy2(src / name, dst / name)
                n += 1
        if (src / "logs").exists():
            shutil.copytree(src / "logs", dst / "logs", dirs_exist_ok=True)
            n += len(list((src / "logs").glob("*")))
    for name in ("workload-manifest.jsonl", "test-design.json", "progress.json"):
        if (suite / name).exists():
            shutil.copy2(suite / name, out / name)
            n += 1
    return n


def write_runs_table(out: Path, runs) -> None:
    cols = ["scenario", "run", "repeat", "position", "valid_decode_pct", "http_5xx_count",
            "timeout_count", "T_batch_s", "business_wall_s", "wall_alignment_ok",
            "s2_switch_total_ms", "s3_migrated_requests", "s3_release_lead_time_s",
            "decode_gpu_s", "prefill_gpu_s", "avg_total_gpus"]
    with (out / "aggregate" / "runs.csv").open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for scn, run, s in runs:
            w.writerow([scn, run] + [s.get(c) for c in cols[2:]])


def write_switches_table(out: Path, suite: Path, runs) -> None:
    sys.path.insert(0, str(Path(__file__).parent))
    try:
        from check_suite_gates import parse_switches  # noqa: PLC0415
    except Exception:  # noqa: BLE001
        return
    with (out / "aggregate" / "switches.csv").open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["scenario", "run", "new_role", "t_from_T0_s", "switch_time_ms",
                    "A_window_end_s", "B_window_start_s", "B_window_end_s", "source"])
        for scn, run, s in runs:
            run_dir = suite / scn / run
            events = json.loads((run_dir / "events.json").read_text(encoding="utf-8"))
            t0 = next((float(e["ts"]) for e in events
                       if e.get("event") == "T0_batch_dispatch"), None)
            if t0 is None:
                continue
            pm = s.get("phase_metrics") or {}
            a, b = pm.get("prefill_burst") or {}, pm.get("decode_dense") or {}
            for x in parse_switches(run_dir):
                w.writerow([scn, run, x["new_role"], round(x["ts"] - t0, 2),
                            round(x["switch_time_ms"], 1),
                            a.get("last_completion_from_T0_s"),
                            b.get("first_dispatch_from_T0_s"),
                            b.get("last_completion_from_T0_s"),
                            x.get("source", "controller_log")])


def write_phase_table(out: Path, runs) -> None:
    keys = ["service_window_s", "first_dispatch_from_T0_s", "last_completion_from_T0_s",
            "requests", "valid", "ttft_ms_p50", "ttft_ms_p95",
            "prefill_wait_time_ms_p50", "decode_gpu_s", "prefill_gpu_s",
            "avg_decode_gpus", "avg_prefill_gpus"]
    with (out / "aggregate" / "phase_metrics.csv").open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["scenario", "run", "phase"] + keys)
        for scn, run, s in runs:
            for phase, m in (s.get("phase_metrics") or {}).items():
                row = []
                for k in keys:
                    v = m.get(k)
                    if v is None:  # tolerate nested {p50,p95} shapes
                        base, _, stat = k.rpartition("_")
                        nested = m.get(base)
                        v = nested.get(stat) if isinstance(nested, dict) else None
                    row.append(v)
                w.writerow([scn, run, phase] + row)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("suite")
    ap.add_argument("out")
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    suite, out = Path(args.suite), Path(args.out)
    if not suite.is_dir():
        print(f"suite not found: {suite}", file=sys.stderr)
        return 2
    (out / "aggregate").mkdir(parents=True, exist_ok=True)

    runs = load_runs(suite)
    if not runs:
        print(f"no completed runs in {suite}", file=sys.stderr)
        return 2

    copied = copy_raw(suite, out, runs)
    write_runs_table(out, runs)
    write_switches_table(out, suite, runs)
    write_phase_table(out, runs)

    root = Path(__file__).resolve().parents[2]
    counts: dict[str, int] = {}
    for scn, _, _ in runs:
        counts[scn] = counts.get(scn, 0) + 1
    provenance = {
        "label": args.label,
        "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source_suite": str(suite).replace("\\", "/"),
        "runs_included": len(runs),
        "runs_per_scenario": counts,
        "complete": all(counts.get(s, 0) >= 3 for s in SCENARIOS),
        "raw_files_copied": copied,
        "rl_scaling_commit": _git(root / "RL-Scaling", "rev-parse", "HEAD"),
        "dynamo_commit": _git(root / "dynamo", "rev-parse", "HEAD"),
        "quality": {
            "all_runs_100pct_valid": all(float(s.get("valid_decode_pct") or 0) == 100.0
                                         for _, _, s in runs),
            "total_http_5xx": sum(int(s.get("http_5xx_count") or 0) for _, _, s in runs),
            "total_timeouts": sum(int(s.get("timeout_count") or 0) for _, _, s in runs),
            "wall_alignment_ok_all": all(bool(s.get("wall_alignment_ok")) for _, _, s in runs),
        },
    }
    (out / "provenance.json").write_text(
        json.dumps(provenance, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(provenance, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
