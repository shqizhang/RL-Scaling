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
    parser = argparse.ArgumentParser(description="Controller mixed strategy E2E.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--sample-interval", type=float, default=2.0)
    parser.add_argument("--prefill-count", type=int, default=48)
    parser.add_argument("--prefill-concurrency", type=int, default=12)
    parser.add_argument("--tail-count", type=int, default=24)
    parser.add_argument("--tail-concurrency", type=int, default=4)
    parser.add_argument("--observe-seconds", type=int, default=60)
    args = parser.parse_args()

    root = Path(args.suite_dir) if args.suite_dir else Path(__file__).resolve().parent / "reports" / f"strategy-suite-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir = root / "strategy"
    out_dir.mkdir(parents=True, exist_ok=True)
    events, requests, status_rows = [], [], []
    since_iso = e2e.ts_utc_since()
    stop = threading.Event()
    sampler = e2e.PodSampler(out_dir, args.sample_interval, stop)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    sampler_thread.start()
    pf_frontend = pf_controller = None
    phase_summary = {}
    try:
        e2e.configure_controller(
            {
                "ROLE_SWITCH_ENABLED": "true",
                "CONSOLIDATION_ENABLED": "false",
                "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
                "PREFILL_QUEUE_THRESHOLD": "0",
                "DECODE_IDLE_THRESHOLD": "1.0",
                "DECODE_QUEUE_THRESHOLD": "999",
                "PREFILL_IDLE_THRESHOLD": "1.0",
                "MIN_SWITCH_INTERVAL": "5",
                "MIN_DECODE_REPLICAS": "2",
                "MIN_PREFILL_REPLICAS": "2",
                "CONSOLIDATION_THRESHOLD": "8",
                "CONSOLIDATION_STABLE_SAMPLES": "2",
                "CONSOLIDATION_MIN_INTERVAL": "5",
                "MIN_BATCH_COMPLETION": "0.60",
                "CONTROL_LOOP_INTERVAL": "1",
                "MAX_CONCURRENT_PER_DECODE": "16",
                "K8S_SCALE_FALLBACK_ENABLED": "true",
            }
        )
        e2e.event(events, "controller_configured_d_to_p", note="PREFILL_QUEUE_THRESHOLD=0 is used to force an observable controller D->P decision window")
        e2e.set_topology(prefill=2, decode=4)
        e2e.event(events, "healthy_topology_ready", prefill=2, decode=4)
        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        e2e.status_sample(status_rows, "initial")

        e2e.event(events, "sampling_progress_prefill_pressure", response=e2e.send_progress(0.30, batch_size=96, avg_isl=8192, avg_osl=256))
        deadline = time.time() + args.observe_seconds
        while time.time() < deadline:
            e2e.status_sample(status_rows, "observe_s2_d_to_p")
            if any(item.get("executed") and item.get("from_role") == "decode" and item.get("to_role") == "prefill" for item in e2e.s2_history(status_rows)):
                break
            time.sleep(2)

        phase = "strategy_prefill_peak"
        rows = e2e.run_wave(phase, args.prefill_count, args.prefill_concurrency, 1800, 128, out_dir)
        requests.extend(rows)
        phase_summary[phase] = e2e.summarize_wave(rows)
        e2e.event(events, f"{phase}_done", **phase_summary[phase])
        e2e.status_sample(status_rows, "after_prefill_peak")

        e2e.event(events, "scale_up_prefill_if_needed_start", note="script records actual pod counts and enforces 3 prefill deployment replicas for the next phase")
        p, d = e2e.count_ready_by_component()
        if p < 3:
            e2e.scale_deployment(e2e.PREFILL_DEPLOY, 3)
            e2e.wait_deployment(e2e.PREFILL_DEPLOY)
            e2e.wait_ready_counts(prefill=3, decode=max(2, d))
        e2e.event(events, "scale_up_prefill_window_ready", ready_prefill=e2e.count_ready_by_component()[0], ready_decode=e2e.count_ready_by_component()[1])

        e2e.configure_controller(
            {
                "ROLE_SWITCH_ENABLED": "true",
                "CONSOLIDATION_ENABLED": "false",
                "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
                "PREFILL_QUEUE_THRESHOLD": "999",
                "DECODE_QUEUE_THRESHOLD": "0",
                "PREFILL_IDLE_THRESHOLD": "1.0",
                "MIN_PREFILL_REPLICAS": "2",
                "MIN_DECODE_REPLICAS": "2",
                "MIN_SWITCH_INTERVAL": "5",
                "CONTROL_LOOP_INTERVAL": "1",
            }
        )
        e2e.event(events, "controller_configured_p_to_d")
        if pf_controller:
            pf_controller.terminate()
        pf_controller = e2e.start_controller_pf()
        deadline = time.time() + args.observe_seconds
        while time.time() < deadline:
            e2e.status_sample(status_rows, "observe_s2_p_to_d")
            if any(item.get("executed") and item.get("from_role") == "prefill" and item.get("to_role") == "decode" for item in e2e.s2_history(status_rows)):
                break
            time.sleep(2)

        e2e.event(events, "sampling_done_decoder_recovery", response=e2e.send_done())
        e2e.scale_deployment(e2e.DECODE_DEPLOY, 4)
        e2e.wait_deployment(e2e.DECODE_DEPLOY)
        e2e.wait_ready_counts(prefill=3, decode=4)
        e2e.event(events, "decoder_capacity_ready", prefill=3, decode=4)

        e2e.configure_controller(
            {
                "ROLE_SWITCH_ENABLED": "false",
                "CONSOLIDATION_ENABLED": "true",
                "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
                "CONSOLIDATION_THRESHOLD": "8",
                "CONSOLIDATION_STABLE_SAMPLES": "1",
                "CONSOLIDATION_MIN_INTERVAL": "5",
                "MIN_BATCH_COMPLETION": "0.60",
                "MIN_DECODE_REPLICAS": "2",
                "MAX_CONCURRENT_PER_DECODE": "16",
                "CONTROL_LOOP_INTERVAL": "1",
                "K8S_SCALE_FALLBACK_ENABLED": "true",
            }
        )
        e2e.event(events, "controller_configured_s3_tail")
        if pf_controller:
            pf_controller.terminate()
        pf_controller = e2e.start_controller_pf()
        e2e.event(events, "sampling_progress_tail", response=e2e.send_progress(0.95, batch_size=64, avg_isl=1024, avg_osl=1024))
        phase = "strategy_decode_tail"
        rows = e2e.run_wave(phase, args.tail_count, args.tail_concurrency, 128, 768, out_dir)
        requests.extend(rows)
        phase_summary[phase] = e2e.summarize_wave(rows)
        e2e.event(events, f"{phase}_done", **phase_summary[phase])
        time.sleep(args.observe_seconds)
        e2e.status_sample(status_rows, "after_decode_tail")
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
        {"scenario": "strategy", "role_switch_enabled": True, "consolidation_enabled": True},
    )
    e2e.write_scenario_report(
        out_dir,
        "Controller Mixed Strategy：S2 + S3 自动/半自动闭环",
        summary,
        [
            "该脚本从低 P/D available 拓扑启动，先构造 prefill pressure，让 controller 有机会触发 D->P role switch。",
            "随后记录 prefill scale-up 窗口、decoder 恢复、长尾 decode 和 Request Consolidation scale down。",
            "当前为了形成 controller 可观测触发窗口，PREFILL_QUEUE_THRESHOLD=0。报告需要把这一点解释为测试窗口构造，不等同于生产阈值。",
            "S3 scale down 的正确性以 drained_sources 和 scaled_down_to 的先后关系为准；如果 source 未 drain，应只出现 scale_down_blocked_reason，不应缩容。",
        ],
    )
    print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
