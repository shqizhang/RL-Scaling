#!/usr/bin/env python3
"""Gate checker for the phased_no_gate_v2 five-scenario suite.

Encodes the acceptance gates from
docs/PLAN-metrics-and-s2s3-optimization-20260722-zh.md (Batch D2):

  G1  every run: 100% valid, 0 timeout, 0 HTTP 5xx
  G2  s2/mixed: pre-T0 guard passed (no switch before batch dispatch)
  G3  s2/mixed: D->P lands inside the prefill_burst window,
                P->D inside the decode_dense window
  G4  s2/mixed: every switch_time_ms < SWITCH_BUDGET_MS (default 1500)
  G5  s3_only:  s3_migrated_requests >= 1 (real migration, not idle release)
  G6  all:      every decode_tail request finishes length@max_tokens
                (migration fidelity: ignore_eos survives)
  G7  s3/mixed: s3_release_lead_time_s > 0 (a GPU was released before T_end)
  G8  s2 vs static (same round): prefill_burst ttft_ms p95 improves

Usage:  python check_suite_gates.py <suite-dir> [--switch-budget-ms 1500]
Exit code 0 = all hard gates pass (G8 is reported but soft by default).
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SCENARIOS = ["baseline_1p1d", "static_2p2d", "s2_only", "s3_only", "mixed"]
S2_SCENARIOS = {"s2_only", "mixed"}
S3_SCENARIOS = {"s3_only", "mixed"}
PHASES = ("prefill_burst", "decode_dense", "decode_tail")
_SWITCH_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ .*S2 role switch result: "
    r"executed=True status=ok .*new_role=(\w+) switch_time_ms=([\d.]+)")


def _log_epoch(stamp: str) -> float:
    """Controller logs are UTC (cluster containers run UTC)."""
    return datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").replace(
        tzinfo=timezone.utc).timestamp()


def parse_switches(run_dir: Path) -> list[dict]:
    log = run_dir / "logs" / "controller.log"
    out: list[dict] = []
    if log.exists():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            m = _SWITCH_RE.match(line)
            if m:
                out.append({"ts": _log_epoch(m.group(1)),
                            "new_role": m.group(2),
                            "switch_time_ms": float(m.group(3))})
    if out:
        return out
    # Fallback: the captured controller log is tail-truncated, so a long run
    # can lose its own switch lines and look switch-less to G2/G3/G4. The
    # sampled controller status carries the authoritative switch records; date
    # each one by the first status sample it appeared in (bounded by the ~1s
    # sampling interval, which is far finer than the phase windows G3 checks).
    return switches_from_status(run_dir)


def switches_from_status(run_dir: Path) -> list[dict]:
    status = run_dir / "controller_status.jsonl"
    if not status.exists():
        return []
    out: list[dict] = []
    seen: set[str] = set()
    for line in status.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = float(row.get("ts") or 0.0)
        history = ((row.get("status") or {}).get("strategy") or {}).get("s2_history") or []
        for item in history:
            key = json.dumps(item, sort_keys=True, ensure_ascii=False)
            if key in seen or not item.get("executed"):
                continue
            seen.add(key)
            result = item.get("result") or {}
            out.append({"ts": ts,
                        "new_role": result.get("new_role") or item.get("to_role"),
                        "switch_time_ms": float(result.get("switch_time_ms") or 0.0),
                        "source": "status_sample"})
    return out


class Gates:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, bool, bool, str]] = []

    def check(self, gate: str, where: str, ok: bool, detail: str, hard: bool = True) -> None:
        self.rows.append((gate, where, ok, hard, detail))

    def report(self) -> int:
        width = max((len(r[1]) for r in self.rows), default=10)
        hard_fail = 0
        for gate, where, ok, hard, detail in self.rows:
            flag = "PASS" if ok else ("FAIL" if hard else "warn")
            if not ok and hard:
                hard_fail += 1
            print(f"[{flag:4s}] {gate:3s} {where:<{width}s}  {detail}")
        print(f"\n{'ALL HARD GATES PASS' if hard_fail == 0 else f'{hard_fail} HARD GATE FAILURE(S)'}")
        return 0 if hard_fail == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("suite_dir")
    ap.add_argument("--switch-budget-ms", type=float, default=1500.0)
    ap.add_argument("--soft-g8", action="store_true", default=True)
    args = ap.parse_args()
    suite = Path(args.suite_dir)
    g = Gates()
    ttft_p95: dict[tuple[str, int], float] = {}  # (scenario, repeat) -> A-phase ttft p95

    for scenario in SCENARIOS:
        sdir = suite / scenario
        if not sdir.exists():
            g.check("G0", scenario, False, "scenario directory missing")
            continue
        for run_dir in sorted(sdir.glob("run-*")):
            where = f"{scenario}/{run_dir.name}"
            spath = run_dir / "summary.json"
            if not spath.exists():
                g.check("G0", where, False, "summary.json missing")
                continue
            s = json.loads(spath.read_text(encoding="utf-8"))
            repeat = int(s.get("repeat", 0) or 0)
            events = []
            epath = run_dir / "events.json"
            if epath.exists():
                events = json.loads(epath.read_text(encoding="utf-8"))
            t0 = float(s.get("t0", 0) or 0)

            # G1 quality
            ok = (float(s.get("valid_decode_pct", 0)) == 100.0
                  and int(s.get("timeout_count", 0)) == 0
                  and int(s.get("http_5xx_count", 0)) == 0)
            g.check("G1", where, ok,
                    f"valid={s.get('valid_decode_pct')} timeout={s.get('timeout_count')} "
                    f"5xx={s.get('http_5xx_count')}")

            pm = s.get("phase_metrics", {}) or {}
            a = pm.get("prefill_burst") or {}
            b = pm.get("decode_dense") or {}
            if a.get("ttft_ms"):
                ttft_p95[(scenario, repeat)] = float(a["ttft_ms"].get("p95", 0) or 0)

            # G6 tail fidelity (all scenarios): every decode_tail request must
            # run to its full token budget (finish_reason=length), migrated or not.
            rpath = run_dir / "requests.csv"
            if rpath.exists():
                tail = [r for r in csv.DictReader(open(rpath, encoding="utf-8"))
                        if r.get("phase") == "decode_tail"]
                bad = [r for r in tail
                       if r.get("finish_reason") != "length"
                       or int(float(r.get("completion_tokens", 0) or 0))
                       != int(float(r.get("manifest_max_tokens", 0) or 0))]
                g.check("G6", where, bool(tail) and not bad,
                        f"tail={len(tail)} fidelity_violations="
                        + (";".join(f"id{r.get('manifest_id')}:{r.get('finish_reason')}"
                                    f"@{r.get('completion_tokens')}" for r in bad) or "0"))

            if scenario in S2_SCENARIOS:
                # G2 pre-T0 guard
                guard = any(e.get("event") == "pre_t0_guard_passed" for e in events)
                pre_fired = any(e.get("event") == "pre_t0_switch_detected" for e in events)
                switches = parse_switches(run_dir)
                pre_t0 = [x for x in switches if t0 and x["ts"] < t0]
                g.check("G2", where, guard and not pre_fired and not pre_t0,
                        f"guard_event={guard} pre_t0_switches={len(pre_t0)}")
                # G3 switch placement inside intended phase windows
                d2p = [x for x in switches if x["new_role"] == "prefill" and x["ts"] >= t0]
                p2d = [x for x in switches if x["new_role"] == "decode" and x["ts"] >= t0]
                def _inside(x, phase):
                    lo = t0 + float(phase.get("first_dispatch_from_T0_s", 0) or 0)
                    hi = t0 + float(phase.get("last_completion_from_T0_s", 0) or 0)
                    return lo <= x["ts"] <= hi
                ok3 = bool(d2p) and all(_inside(x, a) for x in d2p) \
                    and all(_inside(x, b) for x in p2d)
                g.check("G3", where, ok3,
                        f"d2p@{[round(x['ts']-t0,1) for x in d2p]}s "
                        f"p2d@{[round(x['ts']-t0,1) for x in p2d]}s "
                        f"(A window 0-{round(float(a.get('last_completion_from_T0_s',0) or 0),1)}s, "
                        f"B {round(float(b.get('first_dispatch_from_T0_s',0) or 0),1)}-"
                        f"{round(float(b.get('last_completion_from_T0_s',0) or 0),1)}s)")
                # G4 switch cost budget
                worst = max((x["switch_time_ms"] for x in switches), default=0.0)
                g.check("G4", where, bool(switches) and worst < args.switch_budget_ms,
                        f"switches={len(switches)} worst={worst:.0f}ms "
                        f"budget={args.switch_budget_ms:.0f}ms")

            if scenario in S3_SCENARIOS:
                migrated = int(s.get("s3_migrated_requests", 0) or 0)
                lead = float(s.get("s3_release_lead_time_s", 0) or 0)
                # G5 hard only for s3_only; mixed may legitimately idle-release.
                g.check("G5", where, migrated >= 1,
                        f"migrated={migrated}", hard=(scenario == "s3_only"))
                g.check("G7", where, lead > 0.0, f"release_lead={lead:.1f}s")

    # G8: same-round TTFT improvement, s2 vs static (soft unless --hard-g8)
    for (scenario, repeat), val in sorted(ttft_p95.items()):
        if scenario != "s2_only":
            continue
        ref = ttft_p95.get(("static_2p2d", repeat))
        if ref:
            g.check("G8", f"s2_only/r{repeat} vs static", val < ref,
                    f"A ttft p95 {val:.0f}ms vs static {ref:.0f}ms", hard=False)

    return g.report()


if __name__ == "__main__":
    sys.exit(main())
