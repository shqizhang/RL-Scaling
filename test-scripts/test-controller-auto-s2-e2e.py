#!/usr/bin/env python3
"""Controller-driven S2 role-switch E2E.

The test configures the controller for S2 only, creates a prefill-heavy
frontend wave, and records whether the controller itself emits and executes an
S2 role-switch decision. It does not call worker sidecar action endpoints.
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path


HERE = Path(__file__).resolve().parent
BASE_SCRIPT = HERE / "test-scale-up-down-e2e.py"
spec = importlib.util.spec_from_file_location("scale_e2e", BASE_SCRIPT)
scale_e2e = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules["scale_e2e"] = scale_e2e
spec.loader.exec_module(scale_e2e)

CONTROLLER_NS = "dynamo"
CONTROLLER_DEPLOY = "rl-scaling-controller"
CONTROLLER_LOCAL = 18082


def ts_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def ts_utc_since() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def run(cmd: list[str], timeout: int = 60, check: bool = True) -> subprocess.CompletedProcess:
    return scale_e2e.run(cmd, timeout=timeout, check=check)


def kubectl(args: list[str], timeout: int = 60, check: bool = True) -> subprocess.CompletedProcess:
    return run(["kubectl", *args], timeout=timeout, check=check)


def kubectl_text(args: list[str], timeout: int = 60) -> str:
    try:
        proc = subprocess.run(
            ["kubectl", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except Exception as exc:
        return f"<kubectl capture failed: {exc}>"
    return proc.stdout.decode("utf-8", "replace") + proc.stderr.decode("utf-8", "replace")


def write_csv(path: Path, rows: list[dict], fields: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fields})


def set_controller_env(prefill_threshold: int) -> None:
    env = {
        "ROLE_SWITCH_ENABLED": "true",
        "CONSOLIDATION_ENABLED": "false",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
        "K8S_SCALE_FALLBACK_ENABLED": "true",
        "CONTROL_LOOP_INTERVAL": "1",
        "PREFILL_QUEUE_THRESHOLD": str(prefill_threshold),
        "DECODE_QUEUE_THRESHOLD": "999",
        "DECODE_IDLE_THRESHOLD": "1.0",
        "PREFILL_IDLE_THRESHOLD": "1.0",
        "MIN_SWITCH_INTERVAL": "5",
        "MAX_CONCURRENT_PER_DECODE": "16",
        "MIN_PREFILL_REPLICAS": "2",
        "MIN_DECODE_REPLICAS": "2",
    }
    args = ["set", "env", "-n", CONTROLLER_NS, f"deploy/{CONTROLLER_DEPLOY}"]
    args.extend(f"{k}={v}" for k, v in env.items())
    kubectl(args, timeout=120)
    kubectl(["rollout", "status", "-n", CONTROLLER_NS, f"deploy/{CONTROLLER_DEPLOY}", "--timeout=300s"], timeout=330)


def reset_controller() -> None:
    kubectl(
        [
            "set",
            "env",
            "-n",
            CONTROLLER_NS,
            f"deploy/{CONTROLLER_DEPLOY}",
            "ROLE_SWITCH_ENABLED=false",
            "CONSOLIDATION_ENABLED=false",
            "CONSOLIDATION_SCALE_DOWN_ENABLED=false",
        ],
        timeout=120,
    )
    kubectl(["rollout", "status", "-n", CONTROLLER_NS, f"deploy/{CONTROLLER_DEPLOY}", "--timeout=300s"], timeout=330)


def start_controller_pf() -> subprocess.Popen:
    proc = subprocess.Popen(
        ["kubectl", "-n", CONTROLLER_NS, "port-forward", f"svc/{CONTROLLER_DEPLOY}", f"{CONTROLLER_LOCAL}:8080"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{CONTROLLER_LOCAL}/healthz", timeout=1).read()
            return proc
        except Exception:
            time.sleep(0.5)
    return proc


def controller_status() -> dict:
    with urllib.request.urlopen(f"http://127.0.0.1:{CONTROLLER_LOCAL}/api/v1/status", timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def event(rows: list[dict], name: str, **data) -> None:
    row = {"ts": scale_e2e.now_ts(), "iso": ts_iso(), "event": name, **data}
    rows.append(row)
    print(json.dumps(row, ensure_ascii=False), flush=True)


def capture_logs(out_dir: Path, since_iso: str) -> None:
    log_dir = out_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    controller = kubectl_text(
        ["logs", "-n", CONTROLLER_NS, "-l", "app=rl-scaling-controller", f"--since-time={since_iso}", "--tail=1600"],
        timeout=60,
    )
    (log_dir / "controller.log").write_text(controller, encoding="utf-8")
    workers = kubectl(["get", "pods", "-n", scale_e2e.NS, "-o", "json"], timeout=60)
    for item in json.loads(workers.stdout).get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        if labels.get("nvidia.com/dynamo-component") not in {"VllmDecodeWorker", "VllmPrefillWorker"}:
            continue
        name = item.get("metadata", {}).get("name", "")
        proc = kubectl_text(["logs", "-n", scale_e2e.NS, name, f"--since-time={since_iso}", "--tail=800"], timeout=60)
        (log_dir / f"{name}.log").write_text(proc, encoding="utf-8")


def s2_summary(status_rows: list[dict]) -> dict:
    history = []
    for row in status_rows:
        strategy = (row.get("status") or {}).get("strategy") or {}
        history.extend(strategy.get("s2_history") or [])
    return {
        "s2_history_count": len(history),
        "s2_executed_count": sum(1 for item in history if item.get("executed")),
        "s2_history": history,
    }


def restore_switched_workers(status_rows: list[dict], events: list[dict]) -> None:
    restored: set[str] = set()
    for item in s2_summary(status_rows)["s2_history"]:
        worker_url = item.get("worker_url")
        if not item.get("executed") or item.get("from_role") != "decode" or item.get("to_role") != "prefill" or not worker_url:
            continue
        if worker_url in restored:
            continue
        payload = json.dumps({"target_role": "decode"}).encode("utf-8")
        req = urllib.request.Request(
            f"{worker_url.rstrip('/')}/switch_role",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8", "replace")
            event(events, "cleanup_switch_role_decode", worker_url=worker_url, http_code=resp.status, response=body)
            restored.add(worker_url)
        except (urllib.error.URLError, TimeoutError, Exception) as exc:  # noqa: BLE001
            event(events, "cleanup_switch_role_decode_failed", worker_url=worker_url, error=str(exc))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="")
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--request-count", type=int, default=48)
    parser.add_argument("--concurrency", type=int, default=12)
    parser.add_argument("--prompt-words", type=int, default=1600)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--prefill-threshold", type=int, default=1)
    parser.add_argument("--observe-seconds", type=int, default=60)
    args = parser.parse_args()

    out_dir = Path(args.out) if args.out else HERE / "reports" / f"controller-auto-s2-e2e-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "responses").mkdir(parents=True, exist_ok=True)
    events: list[dict] = []
    status_rows: list[dict] = []
    since_iso = ts_utc_since()
    stop = threading.Event()
    sampler = scale_e2e.Sampler(out_dir=out_dir, interval=args.sample_interval, stop=stop, rows=[], node_nvidia_smi=True)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    sampler_thread.start()
    pf_frontend = None
    pf_controller = None
    original = {
        scale_e2e.PREFILL_DEPLOY: scale_e2e.deployment_replicas(scale_e2e.PREFILL_DEPLOY),
        scale_e2e.DECODE_DEPLOY: scale_e2e.deployment_replicas(scale_e2e.DECODE_DEPLOY),
    }
    try:
        set_controller_env(args.prefill_threshold)
        event(events, "controller_configured", prefill_threshold=args.prefill_threshold)
        scale_e2e.scale_deployment(scale_e2e.OLD_DECODE_DEPLOY, 0)
        scale_e2e.scale_deployment(scale_e2e.OLD_PREFILL_DEPLOY, 0)
        scale_e2e.scale_deployment(scale_e2e.PREFILL_DEPLOY, 2)
        scale_e2e.scale_deployment(scale_e2e.DECODE_DEPLOY, 4)
        scale_e2e.wait_deployment(scale_e2e.PREFILL_DEPLOY, timeout_s=900)
        scale_e2e.wait_deployment(scale_e2e.DECODE_DEPLOY, timeout_s=900)
        scale_e2e.wait_ready_counts(prefill=2, decode=4, timeout_s=900)
        event(events, "topology_ready_2p4d")

        pf_frontend = scale_e2e.start_port_forward()
        pf_controller = start_controller_pf()
        status_rows.append({"ts": scale_e2e.now_ts(), "iso": ts_iso(), "event": "initial", "status": controller_status()})

        start = scale_e2e.now_ts()
        rows = scale_e2e.run_wave("auto_s2_prefill_heavy", args.request_count, args.concurrency, args.prompt_words, args.max_tokens, out_dir)
        end = scale_e2e.now_ts()
        event(events, "prefill_heavy_done", **scale_e2e.summarize_wave(rows))
        for _ in range(max(1, args.observe_seconds // 3)):
            status_rows.append({"ts": scale_e2e.now_ts(), "iso": ts_iso(), "event": "observe", "status": controller_status()})
            if s2_summary(status_rows)["s2_executed_count"] > 0:
                break
            time.sleep(3)

        wave = scale_e2e.summarize_wave(rows)
        gpu = scale_e2e.summarize_gpu(sampler.rows, start, end, args.sample_interval)
        summary = {"wave": wave, "gpu": gpu, "controller": s2_summary(status_rows)}
        (out_dir / "requests.csv").write_text("", encoding="utf-8")
        scale_e2e.write_csv(
            out_dir / "requests.csv",
            rows,
            ["phase", "idx", "start_ts", "end_ts", "http_code", "latency_s", "prompt_tokens", "completion_tokens", "total_tokens", "error"],
        )
        (out_dir / "controller_status.jsonl").write_text(
            "\n".join(json.dumps(row, ensure_ascii=False) for row in status_rows) + "\n",
            encoding="utf-8",
        )
        write_csv(out_dir / "events.csv", events, sorted({k for row in events for k in row}))
        scale_e2e.write_csv(out_dir / "gpu_samples.csv", sampler.rows, ["ts", "iso", "pod", "component", "gpu_util_pct", "gpu_mem_mib", "allocated_worker_gpus"])
        (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
        capture_logs(out_dir, since_iso)
        (out_dir / "REPORT-zh.md").write_text(
            "\n".join(
                [
                    "# Controller Auto S2 E2E Report",
                    "",
                    f"- image: ghcr.io/shqizhang/rl-scaling-controller:ca629b7",
                    f"- workload: {args.request_count} prefill-heavy requests, concurrency={args.concurrency}, prompt_words={args.prompt_words}, max_tokens={args.max_tokens}",
                    f"- prefill threshold: {args.prefill_threshold}",
                    f"- success: {wave['success_pct']:.2f}%",
                    f"- wall time: {wave['wall_s']:.3f}s",
                    f"- req/s: {wave['req_s']:.3f}",
                    f"- p95 latency: {wave['p95_latency_s']:.3f}s",
                    f"- S2 history count: {summary['controller']['s2_history_count']}",
                    f"- S2 executed count: {summary['controller']['s2_executed_count']}",
                    "",
                    "Artifacts: requests.csv, controller_status.jsonl, events.csv, gpu_samples.csv, logs/.",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    finally:
        try:
            restore_switched_workers(status_rows, events)
            if events:
                write_csv(out_dir / "events.csv", events, sorted({k for row in events for k in row}))
        except Exception as exc:  # noqa: BLE001
            print(f"cleanup role restore failed: {exc}", file=sys.stderr)
        if pf_frontend:
            pf_frontend.terminate()
        if pf_controller:
            pf_controller.terminate()
        try:
            reset_controller()
            scale_e2e.scale_deployment(scale_e2e.PREFILL_DEPLOY, original[scale_e2e.PREFILL_DEPLOY])
            scale_e2e.scale_deployment(scale_e2e.DECODE_DEPLOY, original[scale_e2e.DECODE_DEPLOY])
            scale_e2e.scale_deployment(scale_e2e.OLD_PREFILL_DEPLOY, 0)
            scale_e2e.scale_deployment(scale_e2e.OLD_DECODE_DEPLOY, 0)
        finally:
            stop.set()
            sampler_thread.join(timeout=10)
    return 0


if __name__ == "__main__":
    sys.exit(main())
