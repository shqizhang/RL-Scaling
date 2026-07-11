#!/usr/bin/env python3
"""Minimal S2 E2E: prove P->D recovery can serve decode without timeout."""

from __future__ import annotations

import json
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import rls_strategy_common as e2e


def append_jsonl(path: Path, row: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def build_decode_manifest() -> list[dict[str, Any]]:
    return [
        {
            "manifest_id": i + 1,
            "phase": "decode_probe",
            "words": 96,
            "max_tokens": 48,
            "concurrency": 2,
            "timeout_s": 180,
            "shape": "s2_minimal_long_decode",
        }
        for i in range(6)
    ]


def main() -> int:
    suite_dir = (
        Path(__file__).resolve().parent
        / "reports"
        / f"s2-minimal-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    )
    run_dir = suite_dir / "run-01"
    run_dir.mkdir(parents=True, exist_ok=True)
    events: list[dict[str, Any]] = []
    status_rows: list[dict[str, Any]] = []
    stop = threading.Event()
    sampler = e2e.PodSampler(1.0, stop)
    sampler_thread: threading.Thread | None = None
    status_thread: threading.Thread | None = None
    controller_pf: e2e.PortForward | None = None
    frontend_pf: e2e.PortForward | None = None
    since_iso = e2e.ts_utc_since()
    role_snapshots = run_dir / "worker_role_snapshots.jsonl"
    manifest = build_decode_manifest()

    try:
        e2e.write_json(suite_dir / "manifest.json", manifest)
        e2e.event(events, "setup_start")
        e2e.disable_controller_strategies()
        e2e.set_topology(prefill=2, decode=2)
        sampler_thread = threading.Thread(target=sampler.run, daemon=True)
        sampler_thread.start()
        frontend_pf = e2e.start_port_forward(e2e.FRONTEND_SVC, 8000, e2e.NS)
        time.sleep(2)
        e2e.wait_frontend_chat_ready(frontend_pf.local_port, timeout_s=240)
        reset_actions = e2e.reset_decode_component_roles(snapshot_path=role_snapshots)
        e2e.event(events, "reset_decode_component_roles", actions=reset_actions)
        e2e.wait_runtime_role_counts(prefill=2, decode=2, timeout_s=180, snapshot_path=role_snapshots)
        e2e.event(events, "initial_runtime_role_gate", prefill=2, decode=2)

        env = {
            "CONTROL_LOOP_INTERVAL": "1",
            "K8S_SCALE_FALLBACK_ENABLED": "false",
            "MAX_GPUS": "4",
            "MIN_PREFILL_REPLICAS": "2",
            "MIN_DECODE_REPLICAS": "1",
            "MAX_CONCURRENT_PER_DECODE": "64",
            "PRE_WARM_THRESHOLD": "2.0",
            "ROLE_SWITCH_ENABLED": "true",
            "CONSOLIDATION_ENABLED": "false",
            "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
            "PREFILL_QUEUE_THRESHOLD": "1",
            "DECODE_QUEUE_THRESHOLD": "1",
            "DECODE_IDLE_THRESHOLD": "0.30",
            "PREFILL_IDLE_THRESHOLD": "0.30",
            "MIN_SWITCH_INTERVAL": "30",
            "ROLE_SWITCH_VERIFY_TIMEOUT": "60",
            "ROLE_SWITCH_VERIFY_POLL_INTERVAL": "1",
            "RLS_TEST_RUN_ID": f"s2-minimal-{int(time.time())}",
        }
        e2e.configure_controller(env)
        e2e.event(events, "controller_configured", env=env)
        controller_pf = e2e.start_port_forward(f"svc/{e2e.CONTROLLER_DEPLOY}", 8080, e2e.CONTROLLER_NS)
        time.sleep(2)
        e2e.wait_http(f"http://127.0.0.1:{controller_pf.local_port}/api/v1/status", timeout_s=120)
        status_thread = threading.Thread(
            target=_status_poller,
            args=(controller_pf.local_port, status_rows, stop, 1.0),
            daemon=True,
        )
        status_thread.start()

        response = e2e.send_progress(controller_pf.local_port, 0.30, batch_size=16, avg_isl=4096, avg_osl=64)
        e2e.event(events, "prefill_pressure_signal", response=response)
        d_to_p = e2e.wait_runtime_role_counts(prefill=3, decode=1, timeout_s=240, snapshot_path=role_snapshots)
        e2e.event(events, "runtime_role_gate_after_d_to_p", snapshot=d_to_p)
        e2e.wait_frontend_chat_ready(frontend_pf.local_port, timeout_s=180)

        response = e2e.send_done(controller_pf.local_port, batch_size=16, avg_isl=512, avg_osl=512)
        e2e.event(events, "decode_pressure_signal", response=response)
        p_to_d = e2e.wait_runtime_role_counts(prefill=2, decode=2, timeout_s=240, snapshot_path=role_snapshots)
        e2e.event(events, "runtime_role_gate_after_p_to_d", snapshot=p_to_d)
        e2e.wait_frontend_chat_ready(frontend_pf.local_port, timeout_s=180)
        e2e.wait_frontend_long_decode_ready(frontend_pf.local_port, timeout_s=240, max_tokens=48)
        e2e.event(events, "long_decode_readiness_probe", max_tokens=48)

        e2e.status_sample(controller_pf.local_port, status_rows, "before_decode_probe")
        rows = e2e.run_manifest_phase(frontend_pf.local_port, manifest, "decode_probe", run_dir, "s2-minimal")
        phase_summary = e2e.summarize_requests(rows)
        e2e.event(events, "decode_probe_done", **phase_summary)
        e2e.status_sample(controller_pf.local_port, status_rows, "after_decode_probe")
        summary = {
            "suite_dir": str(suite_dir),
            "passed": (
                int(phase_summary.get("timeout_count", 0) or 0) == 0
                and int(phase_summary.get("http_5xx_count", 0) or 0) == 0
            ),
            "decode_probe": phase_summary,
            "s2_history": e2e.s2_history(status_rows),
            "s2_executed_count": len([x for x in e2e.s2_history(status_rows) if x.get("executed")]),
            "role_snapshots": str(role_snapshots),
            "events": events,
        }
        e2e.write_json(run_dir / "summary.json", summary)
        e2e.finalize_artifacts(run_dir, events, rows, status_rows, sampler.rows, {"decode_probe": phase_summary}, summary)
        _write_report(run_dir, summary)
        return 0 if summary["passed"] else 2
    finally:
        if frontend_pf:
            frontend_pf.stop()
        if controller_pf:
            controller_pf.stop()
        stop.set()
        if status_thread:
            status_thread.join(timeout=10)
        if sampler_thread:
            sampler_thread.join(timeout=10)
        e2e.capture_logs(run_dir, since_iso)


def _status_poller(controller_port: int, rows: list[dict[str, Any]], stop: threading.Event, interval: float) -> None:
    while not stop.is_set():
        e2e.status_sample(controller_port, rows, "poll")
        time.sleep(interval)


def _write_report(run_dir: Path, summary: dict[str, Any]) -> None:
    probe = summary.get("decode_probe", {})
    lines = [
        "# S2 Minimal E2E Report",
        "",
        f"generated_at: {e2e.ts_iso()}",
        f"- passed: {summary.get('passed')}",
        f"- timeout_count: {probe.get('timeout_count', 0)}",
        f"- http_5xx_count: {probe.get('http_5xx_count', 0)}",
        f"- requests: {probe.get('requests', 0)}",
        f"- valid_decode_pct: {probe.get('valid_decode_pct', 0):.2f}",
        f"- wall_s: {probe.get('wall_s', 0):.2f}",
        f"- s2_executed_count: {summary.get('s2_executed_count', 0)}",
        "",
        "## Artifacts",
        "",
        "- summary.json",
        "- requests.csv",
        "- worker_role_snapshots.jsonl",
        "- controller_status.jsonl",
        "- events.csv",
        "- logs/",
    ]
    (run_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
