#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import rls_e2e_common as e2e


def main() -> int:
    parser = argparse.ArgumentParser(description="Request Consolidation only E2E.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--sample-interval", type=float, default=2.0)
    parser.add_argument("--head-count", type=int, default=24)
    parser.add_argument("--head-concurrency", type=int, default=6)
    parser.add_argument("--tail-count", type=int, default=24)
    parser.add_argument("--tail-concurrency", type=int, default=4)
    parser.add_argument("--tail-observe-seconds", type=int, default=45)
    args = parser.parse_args()

    root = Path(args.suite_dir) if args.suite_dir else Path(__file__).resolve().parent / "reports" / f"strategy-suite-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir = root / "s3_only"
    out_dir.mkdir(parents=True, exist_ok=True)
    events, requests, status_rows = [], [], []
    since_iso = e2e.ts_utc_since()
    stop = threading.Event()
    sampler = e2e.PodSampler(out_dir, args.sample_interval, stop)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    pf_frontend = pf_controller = None
    phase_summary = {}
    try:
        e2e.configure_controller(
            {
                "ROLE_SWITCH_ENABLED": "false",
                "CONSOLIDATION_ENABLED": "true",
                "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
                "CONSOLIDATION_THRESHOLD": "8",
                "CONSOLIDATION_STABLE_SAMPLES": "2",
                "CONSOLIDATION_MIN_INTERVAL": "5",
                "MIN_BATCH_COMPLETION": "0.60",
                "CONTROL_LOOP_INTERVAL": "1",
                "MIN_DECODE_REPLICAS": "2",
                "MAX_CONCURRENT_PER_DECODE": "16",
                "K8S_SCALE_FALLBACK_ENABLED": "true",
            }
        )
        e2e.event(events, "controller_configured_s3_only")
        e2e.set_topology(prefill=2, decode=4)
        e2e.event(events, "topology_2p4d_ready")
        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        e2e.status_sample(status_rows, "initial")
        e2e.event(events, "sampling_progress_70", response=e2e.send_progress(0.70))

        phase = "s3_head_wave"
        rows = e2e.run_wave(phase, args.head_count, args.head_concurrency, 192, 384, out_dir)
        requests.extend(rows)
        phase_summary[phase] = e2e.summarize_wave(rows)
        e2e.event(events, f"{phase}_done", **phase_summary[phase])
        e2e.status_sample(status_rows, "after_head")

        e2e.event(events, "sampling_progress_95", response=e2e.send_progress(0.95))
        phase = "s3_tail_wave"
        rows = e2e.run_wave(phase, args.tail_count, args.tail_concurrency, 128, 768, out_dir)
        requests.extend(rows)
        phase_summary[phase] = e2e.summarize_wave(rows)
        e2e.event(events, f"{phase}_done", **phase_summary[phase])
        time.sleep(args.tail_observe_seconds)
        e2e.status_sample(status_rows, "after_tail_observe")
        e2e.event(events, "batch_complete", response=e2e.send_batch_complete())
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
        {"scenario": "s3_only", "role_switch_enabled": False, "consolidation_enabled": True},
    )
    e2e.write_scenario_report(
        out_dir,
        "Request Consolidation Only：仅启用 S3",
        summary,
        [
            "该场景通过 sampling progress 和 tail decode wave 构造 Request Consolidation 触发窗口。",
            "重点检查 S3 history 中的 plans、migrated_requests、drained_sources 和 scaled_down_to，以确认迁移后先 drain 再 scale down。",
            "如果 requests.csv 中出现 HTTP 500 或 valid_decode 下降，说明当前 S3 对用户可见 stream continuity 仍存在正确性风险。",
        ],
    )
    print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
