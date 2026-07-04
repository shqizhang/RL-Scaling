#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import urllib.request
from datetime import datetime
from pathlib import Path

import rls_e2e_common as e2e


def switch_role(worker_url: str, target_role: str) -> dict:
    req = urllib.request.Request(
        f"{worker_url.rstrip('/')}/switch_role",
        data=json.dumps({"target_role": target_role}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="PD Role Switch only E2E.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--sample-interval", type=float, default=2.0)
    parser.add_argument("--count", type=int, default=36)
    parser.add_argument("--concurrency", type=int, default=12)
    parser.add_argument("--prompt-words", type=int, default=1600)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--use-controller-auto", action="store_true")
    args = parser.parse_args()

    root = Path(args.suite_dir) if args.suite_dir else Path(__file__).resolve().parent / "reports" / f"strategy-suite-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir = root / "s2_only"
    out_dir.mkdir(parents=True, exist_ok=True)
    events, requests, status_rows = [], [], []
    since_iso = e2e.ts_utc_since()
    stop = threading.Event()
    sampler = e2e.PodSampler(out_dir, args.sample_interval, stop)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    pf_frontend = pf_controller = None
    phase_summary = {}
    switched_url = ""
    try:
        e2e.configure_controller(
            {
                "ROLE_SWITCH_ENABLED": "true",
                "CONSOLIDATION_ENABLED": "false",
                "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
                "PREFILL_QUEUE_THRESHOLD": "0" if args.use_controller_auto else "999",
                "DECODE_IDLE_THRESHOLD": "1.0",
                "DECODE_QUEUE_THRESHOLD": "999",
                "PREFILL_IDLE_THRESHOLD": "1.0",
                "MIN_SWITCH_INTERVAL": "5",
                "MIN_DECODE_REPLICAS": "1",
                "MIN_PREFILL_REPLICAS": "1",
                "CONTROL_LOOP_INTERVAL": "1",
            }
        )
        e2e.event(events, "controller_configured_s2_only", controller_auto=args.use_controller_auto)
        e2e.set_topology(prefill=1, decode=3)
        e2e.event(events, "topology_1p3d_ready")
        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        e2e.status_sample(status_rows, "initial")

        if not args.use_controller_auto:
            decode_pods = [p for p in e2e.ready_worker_pods() if p["component"] == "VllmDecodeWorker"]
            target = decode_pods[-1]
            switched_url = f"http://{target['pod_ip']}:9091"
            e2e.event(events, "manual_switch_decode_to_prefill_start", pod=target["name"], worker_url=switched_url)
            e2e.event(events, "manual_switch_decode_to_prefill_done", result=switch_role(switched_url, "prefill"))
        else:
            e2e.event(events, "controller_auto_s2_window_start", note="PREFILL_QUEUE_THRESHOLD=0 creates an observable controller trigger window")
            deadline = time.time() + 60
            while time.time() < deadline:
                e2e.status_sample(status_rows, "observe_s2")
                if any(item.get("executed") for item in e2e.s2_history(status_rows)):
                    break
                time.sleep(2)

        phase = "s2_prefill_heavy_wave"
        rows = e2e.run_wave(phase, args.count, args.concurrency, args.prompt_words, args.max_tokens, out_dir)
        requests.extend(rows)
        phase_summary[phase] = e2e.summarize_wave(rows)
        e2e.event(events, f"{phase}_done", **phase_summary[phase])
        e2e.status_sample(status_rows, "after_wave")
    finally:
        if switched_url:
            try:
                e2e.event(events, "cleanup_switch_back_decode", result=switch_role(switched_url, "decode"))
            except Exception as exc:
                e2e.event(events, "cleanup_switch_back_decode_failed", error=str(exc))
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
        {"scenario": "s2_only", "role_switch_enabled": True, "consolidation_enabled": False, "manual_switched_worker_url": switched_url},
    )
    e2e.write_scenario_report(
        out_dir,
        "PD Role Switch Only：仅启用 S2",
        summary,
        [
            "默认模式下脚本手动调用目标 decode worker sidecar 的 /switch_role，将其切为 prefill，以验证 worker 端 PD role switch 机制和切换后的端到端 decode 完整性。",
            "可选 --use-controller-auto 会把 PREFILL_QUEUE_THRESHOLD 设置为 0，用于测试 controller S2 自动触发链路；该模式应在报告中与真实压力触发分开解释。",
            "该场景不启用 Request Consolidation，不应出现 S3 migration 或 scale down。",
        ],
    )
    print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
