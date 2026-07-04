#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
import threading
from datetime import datetime
from pathlib import Path

import rls_e2e_common as e2e


def main() -> int:
    parser = argparse.ArgumentParser(description="Baseline E2E with S2/S3 disabled.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--sample-interval", type=float, default=2.0)
    parser.add_argument("--count", type=int, default=32)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--prompt-words", type=int, default=256)
    parser.add_argument("--max-tokens", type=int, default=256)
    args = parser.parse_args()

    root = Path(args.suite_dir) if args.suite_dir else Path(__file__).resolve().parent / "reports" / f"strategy-suite-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir = root / "baseline"
    out_dir.mkdir(parents=True, exist_ok=True)
    events, requests, status_rows = [], [], []
    since_iso = e2e.ts_utc_since()
    stop = threading.Event()
    sampler = e2e.PodSampler(out_dir, args.sample_interval, stop)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    sampler_thread.start()
    pf_frontend = pf_controller = None
    try:
        e2e.event(events, "configure_controller_disabled")
        e2e.disable_controller_strategies()
        e2e.event(events, "topology_2p4d_start")
        e2e.set_topology(prefill=2, decode=4)
        e2e.event(events, "topology_2p4d_ready")
        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        e2e.status_sample(status_rows, "initial")

        phase = "baseline_wave"
        e2e.event(events, f"{phase}_start", count=args.count, concurrency=args.concurrency)
        rows = e2e.run_wave(phase, args.count, args.concurrency, args.prompt_words, args.max_tokens, out_dir)
        requests.extend(rows)
        phase_summary = {phase: e2e.summarize_wave(rows)}
        e2e.event(events, f"{phase}_done", **phase_summary[phase])
        e2e.status_sample(status_rows, "after_wave")
    finally:
        if pf_frontend:
            pf_frontend.terminate()
        if pf_controller:
            pf_controller.terminate()
        try:
            e2e.disable_controller_strategies()
            e2e.set_topology(prefill=2, decode=4)
        finally:
            stop.set()
            sampler_thread.join(timeout=10)
    e2e.capture_logs(out_dir, since_iso)
    summary = e2e.finalize_artifacts(
        out_dir,
        events,
        requests,
        status_rows,
        sampler.rows,
        phase_summary,
        {"scenario": "baseline", "role_switch_enabled": False, "consolidation_enabled": False},
    )
    e2e.write_scenario_report(
        out_dir,
        "Baseline：S2/S3 全部关闭",
        summary,
        [
            "Baseline 固定使用 2P+4D，controller 中 S2/S3 均关闭，用于提供端到端 wall time、吞吐、latency 和 valid decode 的对照。",
            "该场景不应出现 S2/S3 history，也不应出现 migration 或 scale down。",
        ],
    )
    print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
