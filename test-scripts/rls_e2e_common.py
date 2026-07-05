#!/usr/bin/env python3
"""Shared helpers for RL-Scaling Dynamo E2E strategy tests."""

from __future__ import annotations

import csv
import hashlib
import json
import subprocess
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

NS = "dynamo-system"
CONTROLLER_NS = "dynamo"
CONTROLLER_DEPLOY = "rl-scaling-controller"
FRONTEND_SVC = "svc/vllm-v1-disagg-router-frontend"
FRONTEND_LOCAL = 18000
CONTROLLER_LOCAL = 18082
MODEL = "Qwen/Qwen3-0.6B"

DECODE_DEPLOY = "vllm-v1-disagg-router-vllmdecodeworker-574b777c"
PREFILL_DEPLOY = "vllm-v1-disagg-router-vllmprefillworker-574b777c"
OLD_DECODE_DEPLOY = "vllm-v1-disagg-router-vllmdecodeworker-47d8a958"
OLD_PREFILL_DEPLOY = "vllm-v1-disagg-router-vllmprefillworker-47d8a958"


def now_ts() -> float:
    return time.time()


def ts_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def ts_utc_since() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def run(cmd: list[str], timeout: int = 60, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        encoding="utf-8",
        errors="replace",
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
    return proc


def kubectl(args: list[str], timeout: int = 60, check: bool = True) -> subprocess.CompletedProcess:
    return run(["kubectl", *args], timeout=timeout, check=check)


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str] | None = None) -> None:
    fields = fields or sorted({k for row in rows for k in row})
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fields})


def deployment_replicas(name: str) -> int:
    proc = kubectl(["get", "deploy", "-n", NS, name, "-o", "json"], timeout=30)
    return int(json.loads(proc.stdout).get("spec", {}).get("replicas", 0) or 0)


def scale_deployment(name: str, replicas: int) -> None:
    kubectl(["scale", "deployment", "-n", NS, name, f"--replicas={replicas}"], timeout=90)


def wait_deployment(name: str, timeout_s: int = 900) -> None:
    kubectl(["rollout", "status", "deployment", "-n", NS, name, f"--timeout={timeout_s}s"], timeout=timeout_s + 30)


def pod_rows() -> list[dict[str, Any]]:
    proc = kubectl(["get", "pods", "-n", NS, "-o", "json"], timeout=60)
    obj = json.loads(proc.stdout)
    rows: list[dict[str, Any]] = []
    for item in obj.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        component = labels.get("nvidia.com/dynamo-component", "")
        if component not in {"VllmDecodeWorker", "VllmPrefillWorker"}:
            continue
        conditions = item.get("status", {}).get("conditions", []) or []
        rows.append(
            {
                "ts": now_ts(),
                "iso": ts_iso(),
                "name": item["metadata"]["name"],
                "component": component,
                "current_role_label": labels.get("nvidia.com/dynamo-current-role", ""),
                "phase": item.get("status", {}).get("phase", ""),
                "ready": all(c.get("type") != "Ready" or c.get("status") == "True" for c in conditions),
                "pod_ip": item.get("status", {}).get("podIP", ""),
            }
        )
    return rows


def ready_worker_pods() -> list[dict[str, Any]]:
    return [p for p in pod_rows() if p["phase"] == "Running" and p["ready"]]


def count_ready_by_component() -> tuple[int, int]:
    rows = ready_worker_pods()
    prefill = sum(1 for p in rows if p["component"] == "VllmPrefillWorker")
    decode = sum(1 for p in rows if p["component"] == "VllmDecodeWorker")
    return prefill, decode


def wait_ready_counts(prefill: int, decode: int, timeout_s: int = 900) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        p, d = count_ready_by_component()
        if p >= prefill and d >= decode:
            return
        time.sleep(5)
    raise TimeoutError(f"ready worker timeout: expected prefill>={prefill}, decode>={decode}, got {count_ready_by_component()}")


def configure_controller(env: dict[str, str]) -> None:
    args = ["set", "env", "-n", CONTROLLER_NS, f"deploy/{CONTROLLER_DEPLOY}"]
    args.extend(f"{k}={v}" for k, v in env.items())
    kubectl(args, timeout=180)
    kubectl(["rollout", "status", "-n", CONTROLLER_NS, f"deploy/{CONTROLLER_DEPLOY}", "--timeout=300s"], timeout=330)


def disable_controller_strategies() -> None:
    configure_controller(
        {
            "ROLE_SWITCH_ENABLED": "false",
            "CONSOLIDATION_ENABLED": "false",
            "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
        }
    )


def set_topology(prefill: int, decode: int) -> None:
    scale_deployment(OLD_PREFILL_DEPLOY, 0)
    scale_deployment(OLD_DECODE_DEPLOY, 0)
    scale_deployment(PREFILL_DEPLOY, prefill)
    scale_deployment(DECODE_DEPLOY, decode)
    wait_deployment(PREFILL_DEPLOY)
    wait_deployment(DECODE_DEPLOY)
    wait_ready_counts(prefill=prefill, decode=decode)


def start_port_forward(service: str, local_port: int, remote_port: int, namespace: str) -> subprocess.Popen:
    proc = subprocess.Popen(
        ["kubectl", "port-forward", "-n", namespace, service, f"{local_port}:{remote_port}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return proc


def wait_http(url: str, timeout_s: int = 60) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=15).read()
            return
        except Exception:
            time.sleep(0.5)
    raise TimeoutError(f"HTTP endpoint not ready: {url}")


def start_frontend_pf() -> subprocess.Popen:
    proc = start_port_forward(FRONTEND_SVC, FRONTEND_LOCAL, 8000, NS)
    try:
        wait_http(f"http://127.0.0.1:{FRONTEND_LOCAL}/health")
    except Exception:
        proc.terminate()
        raise
    return proc


def wait_frontend_chat_ready(timeout_s: int = 180) -> None:
    deadline = time.time() + timeout_s
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": "RL_SCALING_READINESS ping"}],
        "max_tokens": 1,
        "temperature": 0,
        "stream": False,
    }
    while time.time() < deadline:
        req = urllib.request.Request(
            f"http://127.0.0.1:{FRONTEND_LOCAL}/v1/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                if resp.getcode() == 200:
                    return
        except Exception:
            time.sleep(2)
            continue
        time.sleep(2)
    raise TimeoutError("Dynamo frontend chat completion endpoint did not become model-ready")


def start_controller_pf() -> subprocess.Popen:
    proc = start_port_forward(f"svc/{CONTROLLER_DEPLOY}", CONTROLLER_LOCAL, 8080, CONTROLLER_NS)
    try:
        wait_http(f"http://127.0.0.1:{CONTROLLER_LOCAL}/healthz")
    except Exception:
        proc.terminate()
        raise
    return proc


def controller_json(path: str, method: str = "GET", body: dict[str, Any] | None = None) -> dict[str, Any]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"http://127.0.0.1:{CONTROLLER_LOCAL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def send_progress(progress: float, batch_size: int = 64, avg_isl: int = 4096, avg_osl: int = 768) -> dict[str, Any]:
    return controller_json(
        "/api/v1/signals/sampling_progress",
        "POST",
        {"progress": progress, "batch_meta": {"batch_size": batch_size, "avg_isl": avg_isl, "avg_osl": avg_osl, "total_tokens": batch_size * (avg_isl + avg_osl)}},
    )


def send_done() -> dict[str, Any]:
    return controller_json("/api/v1/signals/sampling_done", "POST", {"batch_meta": {"batch_size": 64, "avg_isl": 4096, "avg_osl": 768, "total_tokens": 300000}})


def send_batch_complete() -> dict[str, Any]:
    return controller_json("/api/v1/signals/batch_complete", "POST", {})


def prompt_text(phase: str, idx: int, words: int) -> str:
    marker = f"RL_SCALING_E2E phase={phase} request={idx}"
    base = (
        f"{marker}. Return a concise technical answer and include the marker at the end. "
        "Discuss prefill, decode, KV cache, GPU scheduling, request consolidation, and role switch. "
    )
    filler = " ".join(f"token{(idx + i) % 101}" for i in range(words))
    return base + filler


def build_fair_manifest(total_repeats: int = 1) -> list[dict[str, Any]]:
    """Build one deterministic workload manifest shared by all fair scenarios.

    The manifest intentionally mixes prefill-heavy, balanced decode, and long
    tail decode requests. Every scenario consumes the same list in the same
    order so timing and GPU allocation comparisons are not distorted by
    request-count or prompt-shape differences.
    """
    rows: list[dict[str, Any]] = []
    idx = 1
    for repeat in range(total_repeats):
        for i in range(24):
            rows.append(
                {
                    "manifest_id": idx,
                    "phase": "prefill_peak",
                    "words": 1200,
                    "max_tokens": 128,
                    "concurrency": 8,
                    "repeat": repeat,
                    "shape": "long_prompt_short_decode",
                }
            )
            idx += 1
        for i in range(24):
            rows.append(
                {
                    "manifest_id": idx,
                    "phase": "decode_head",
                    "words": 256,
                    "max_tokens": 384,
                    "concurrency": 8,
                    "repeat": repeat,
                    "shape": "balanced_decode",
                }
            )
            idx += 1
        for i in range(24):
            rows.append(
                {
                    "manifest_id": idx,
                    "phase": "decode_tail",
                    "words": 128,
                    "max_tokens": 1536,
                    "concurrency": 6,
                    "repeat": repeat,
                    "shape": "short_prompt_long_tail_decode",
                }
            )
            idx += 1
    return rows


def write_manifest(path: Path, manifest: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in manifest) + "\n", encoding="utf-8")


def load_manifest(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def parse_response(raw: bytes) -> dict[str, Any]:
    try:
        obj = json.loads(raw.decode("utf-8"))
    except Exception:
        return {"parse_ok": False}
    choice = (obj.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    content = msg.get("content") or ""
    usage = obj.get("usage") or {}
    return {
        "parse_ok": True,
        "finish_reason": choice.get("finish_reason", ""),
        "content_chars": len(content),
        "content_sha256": hashlib.sha256(content.encode("utf-8", "replace")).hexdigest() if content else "",
        "prompt_tokens": int(usage.get("prompt_tokens", 0) or 0),
        "completion_tokens": int(usage.get("completion_tokens", 0) or 0),
        "total_tokens": int(usage.get("total_tokens", 0) or 0),
    }


def submit_request(phase: str, idx: int, words: int, max_tokens: int, out_dir: Path) -> dict[str, Any]:
    start = now_ts()
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt_text(phase, idx, words)}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }
    req = urllib.request.Request(
        f"http://127.0.0.1:{FRONTEND_LOCAL}/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    code = 0
    raw = b""
    error = ""
    try:
        with urllib.request.urlopen(req, timeout=240) as resp:
            code = resp.getcode()
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        code = exc.code
        raw = exc.read()
        error = f"HTTP Error {exc.code}: {exc.reason}"
    except Exception as exc:
        error = str(exc)
    end = now_ts()
    response_file = out_dir / "responses" / f"{phase}-{idx}.json"
    response_file.parent.mkdir(parents=True, exist_ok=True)
    response_file.write_bytes(raw)
    parsed = parse_response(raw)
    valid_decode = code == 200 and parsed.get("parse_ok") and int(parsed.get("completion_tokens", 0) or 0) > 0 and parsed.get("finish_reason") in {"stop", "length"}
    return {
        "phase": phase,
        "idx": idx,
        "start_ts": start,
        "end_ts": end,
        "http_code": code,
        "latency_s": end - start,
        "valid_decode": bool(valid_decode),
        "error": error,
        **parsed,
    }


def submit_manifest_request(item: dict[str, Any], out_dir: Path) -> dict[str, Any]:
    phase = str(item["phase"])
    idx = int(item["manifest_id"])
    row = submit_request(phase, idx, int(item["words"]), int(item["max_tokens"]), out_dir)
    row.update(
        {
            "manifest_id": idx,
            "shape": item.get("shape", ""),
            "manifest_words": item.get("words", ""),
            "manifest_max_tokens": item.get("max_tokens", ""),
        }
    )
    return row


def run_wave(phase: str, count: int, concurrency: int, words: int, max_tokens: int, out_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(submit_request, phase, i, words, max_tokens, out_dir) for i in range(1, count + 1)]
        for future in as_completed(futures):
            rows.append(future.result())
    rows.sort(key=lambda r: int(r["idx"]))
    return rows


def run_manifest_phase(manifest: list[dict[str, Any]], phase: str, out_dir: Path) -> list[dict[str, Any]]:
    items = [row for row in manifest if row["phase"] == phase]
    if not items:
        return []
    concurrency = max(1, int(items[0].get("concurrency", 1)))
    rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(submit_manifest_request, item, out_dir) for item in items]
        for future in as_completed(futures):
            rows.append(future.result())
    rows.sort(key=lambda r: int(r["manifest_id"]))
    return rows


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    idx = min(len(values) - 1, max(0, int(round((len(values) - 1) * q))))
    return values[idx]


def summarize_wave(rows: list[dict[str, Any]]) -> dict[str, Any]:
    ok = [r for r in rows if int(r.get("http_code", 0)) == 200]
    valid = [r for r in rows if r.get("valid_decode")]
    lats = [float(r["latency_s"]) for r in rows]
    wall = (max(float(r["end_ts"]) for r in rows) - min(float(r["start_ts"]) for r in rows)) if rows else 0.0
    completion = sum(int(r.get("completion_tokens", 0) or 0) for r in ok)
    return {
        "requests": len(rows),
        "success": len(ok),
        "success_pct": (100.0 * len(ok) / len(rows)) if rows else 0.0,
        "valid_decode": len(valid),
        "valid_decode_pct": (100.0 * len(valid) / len(rows)) if rows else 0.0,
        "wall_s": wall,
        "req_s": (len(ok) / wall) if wall > 0 else 0.0,
        "p50_latency_s": percentile(lats, 0.50),
        "p95_latency_s": percentile(lats, 0.95),
        "p99_latency_s": percentile(lats, 0.99),
        "completion_tokens": completion,
        "user_completion_tps": (completion / wall) if wall > 0 else 0.0,
    }


def summarize_all_requests(rows: list[dict[str, Any]]) -> dict[str, Any]:
    summary = summarize_wave(rows)
    summary["prompt_tokens"] = sum(int(r.get("prompt_tokens", 0) or 0) for r in rows if int(r.get("http_code", 0)) == 200)
    summary["total_tokens"] = sum(int(r.get("total_tokens", 0) or 0) for r in rows if int(r.get("http_code", 0)) == 200)
    wall = float(summary.get("wall_s", 0.0) or 0.0)
    summary["prompt_tps"] = (summary["prompt_tokens"] / wall) if wall > 0 else 0.0
    summary["total_tps"] = (summary["total_tokens"] / wall) if wall > 0 else 0.0
    return summary


def summarize_pod_allocation(rows: list[dict[str, Any]], start_ts: float | None = None, end_ts: float | None = None) -> dict[str, Any]:
    by_key: dict[str, dict[str, Any]] = {}
    for row in rows:
        try:
            ts = float(row.get("ts", 0.0))
        except Exception:
            continue
        if start_ts is not None and ts < start_ts:
            continue
        if end_ts is not None and ts > end_ts:
            continue
        if row.get("name") == "sampler_error":
            continue
        key = str(row.get("iso") or round(ts))
        bucket = by_key.setdefault(key, {"ts": ts, "prefill": 0, "decode": 0, "total": 0})
        bucket["ts"] = min(float(bucket["ts"]), ts)
        if row.get("ready_prefill_count") not in (None, "") and row.get("ready_decode_count") not in (None, ""):
            prefill = int(float(row.get("ready_prefill_count") or 0))
            decode = int(float(row.get("ready_decode_count") or 0))
            bucket["prefill"] = max(int(bucket["prefill"]), prefill)
            bucket["decode"] = max(int(bucket["decode"]), decode)
            bucket["total"] = max(int(bucket["total"]), prefill + decode)
            continue
        if row.get("phase") == "Running" and str(row.get("ready")) in {"True", "true", "1"}:
            if row.get("component") == "VllmPrefillWorker":
                bucket["prefill"] += 1
            elif row.get("component") == "VllmDecodeWorker":
                bucket["decode"] += 1
            bucket["total"] = int(bucket["prefill"]) + int(bucket["decode"])
    points = sorted((float(v["ts"]), v) for v in by_key.values())
    if len(points) < 2:
        return {
            "sample_count": len(points),
            "gpu_allocated_seconds": 0.0,
            "prefill_allocated_seconds": 0.0,
            "decode_allocated_seconds": 0.0,
            "avg_ready_workers": 0.0,
            "min_ready_workers": 0,
            "max_ready_workers": 0,
        }
    gpu_s = prefill_s = decode_s = 0.0
    totals: list[int] = []
    for (ts, value), (next_ts, _) in zip(points, points[1:]):
        dt = max(0.0, next_ts - ts)
        gpu_s += value["total"] * dt
        prefill_s += value["prefill"] * dt
        decode_s += value["decode"] * dt
        totals.append(value["total"])
    return {
        "sample_count": len(points),
        "gpu_allocated_seconds": gpu_s,
        "prefill_allocated_seconds": prefill_s,
        "decode_allocated_seconds": decode_s,
        "avg_ready_workers": (sum(totals) / len(totals)) if totals else 0.0,
        "min_ready_workers": min(totals) if totals else 0,
        "max_ready_workers": max(totals) if totals else 0,
    }


class PodSampler:
    def __init__(self, out_dir: Path, interval: float, stop: threading.Event):
        self.out_dir = out_dir
        self.interval = interval
        self.stop = stop
        self.rows: list[dict[str, Any]] = []

    def run(self) -> None:
        while not self.stop.is_set():
            try:
                p, d = count_ready_by_component()
                for row in pod_rows():
                    row["ready_prefill_count"] = p
                    row["ready_decode_count"] = d
                    row["allocated_worker_gpus"] = p + d
                    self.rows.append(row)
            except Exception as exc:  # noqa: BLE001
                self.rows.append(
                    {
                        "ts": now_ts(),
                        "iso": ts_iso(),
                        "name": "sampler_error",
                        "component": "sampler",
                        "phase": "error",
                        "ready": False,
                        "error": str(exc),
                    }
                )
            time.sleep(self.interval)


def event(events: list[dict[str, Any]], name: str, **data: Any) -> None:
    row = {"ts": now_ts(), "iso": ts_iso(), "event": name, **data}
    events.append(row)
    print(json.dumps(row, ensure_ascii=False), flush=True)


def status_sample(status_rows: list[dict[str, Any]], label: str) -> None:
    try:
        body = controller_json("/api/v1/status")
    except Exception as exc:
        body = {"error": str(exc)}
    status_rows.append({"ts": now_ts(), "iso": ts_iso(), "event": label, "status": body})


def s2_history(status_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in status_rows:
        for item in ((row.get("status") or {}).get("strategy") or {}).get("s2_history") or []:
            key = json.dumps(item, sort_keys=True, ensure_ascii=False)
            if key not in seen:
                seen.add(key)
                rows.append(item)
    return rows


def s3_history(status_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in status_rows:
        for item in ((row.get("status") or {}).get("strategy") or {}).get("s3_history") or []:
            key = json.dumps(item, sort_keys=True, ensure_ascii=False)
            if key not in seen:
                seen.add(key)
                rows.append(item)
    return rows


def s2_evaluations(status_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in status_rows:
        for item in ((row.get("status") or {}).get("strategy") or {}).get("s2_evaluations") or []:
            key = json.dumps(item, sort_keys=True, ensure_ascii=False)
            if key not in seen:
                seen.add(key)
                rows.append(item)
    return rows


def summarize_s2_evaluations(status_rows: list[dict[str, Any]]) -> dict[str, Any]:
    rows = s2_evaluations(status_rows)
    if not rows:
        return {
            "count": 0,
            "max_prefill_queue_depth": 0,
            "max_decode_queue_depth": 0,
            "max_prefill_worker_active": 0,
            "max_decode_worker_active": 0,
            "selected_actions": [],
            "top_skip_reasons": [],
        }
    skip_counts: dict[str, int] = {}
    for row in rows:
        reason = str(row.get("skip_reason") or "")
        if reason:
            skip_counts[reason] = skip_counts.get(reason, 0) + 1
    return {
        "count": len(rows),
        "max_prefill_queue_depth": max(int(row.get("prefill_queue_depth", 0) or 0) for row in rows),
        "max_decode_queue_depth": max(int(row.get("decode_queue_depth", 0) or 0) for row in rows),
        "max_prefill_worker_active": max(int(row.get("prefill_worker_active", 0) or 0) for row in rows),
        "max_decode_worker_active": max(int(row.get("decode_worker_active", 0) or 0) for row in rows),
        "selected_actions": [row.get("selected_action") for row in rows if row.get("selected_action")],
        "top_skip_reasons": sorted(skip_counts.items(), key=lambda item: item[1], reverse=True)[:5],
    }


def capture_logs(out_dir: Path, since_iso: str) -> None:
    log_dir = out_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    controller = kubectl(
        ["logs", "-n", CONTROLLER_NS, "-l", "app=rl-scaling-controller", f"--since-time={since_iso}", "--tail=2200"],
        timeout=90,
        check=False,
    )
    (log_dir / "controller.log").write_text(controller.stdout + controller.stderr, encoding="utf-8")
    for pod in pod_rows():
        name = pod["name"]
        proc = kubectl(["logs", "-n", NS, name, f"--since-time={since_iso}", "--tail=1200"], timeout=90, check=False)
        (log_dir / f"{name}.log").write_text(proc.stdout + proc.stderr, encoding="utf-8")


def finalize_artifacts(
    out_dir: Path,
    events: list[dict[str, Any]],
    requests: list[dict[str, Any]],
    status_rows: list[dict[str, Any]],
    pod_samples: list[dict[str, Any]],
    phase_summaries: dict[str, Any],
    extra_summary: dict[str, Any],
) -> dict[str, Any]:
    write_csv(out_dir / "events.csv", events)
    write_csv(
        out_dir / "requests.csv",
        requests,
        [
            "phase",
            "manifest_id",
            "shape",
            "idx",
            "start_ts",
            "end_ts",
            "http_code",
            "latency_s",
            "valid_decode",
            "finish_reason",
            "prompt_tokens",
            "completion_tokens",
            "total_tokens",
            "content_chars",
            "content_sha256",
            "error",
        ],
    )
    write_csv(out_dir / "pod_samples.csv", pod_samples)
    (out_dir / "controller_status.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in status_rows) + ("\n" if status_rows else ""), encoding="utf-8")
    (out_dir / "final_pods.json").write_text(kubectl(["get", "pods", "-n", NS, "-o", "json"], timeout=60).stdout, encoding="utf-8")
    summary = {
        "generated_at": ts_iso(),
        "phase_summaries": phase_summaries,
        "overall_summary": summarize_all_requests(requests),
        "pod_allocation": summarize_pod_allocation(pod_samples),
        "request_window_pod_allocation": summarize_pod_allocation(
            pod_samples,
            min((float(r["start_ts"]) for r in requests), default=None),
            max((float(r["end_ts"]) for r in requests), default=None),
        ),
        "s2_history_count": len(s2_history(status_rows)),
        "s2_executed_count": sum(1 for item in s2_history(status_rows) if item.get("executed")),
        "s2_evaluation_summary": summarize_s2_evaluations(status_rows),
        "s3_history_count": len(s3_history(status_rows)),
        "s3_executed_pairs": sum(int(item.get("executed_pairs", 0) or 0) for item in s3_history(status_rows)),
        "s3_migrated_requests": sum(int(item.get("migrated_requests", 0) or 0) for item in s3_history(status_rows)),
        "s3_scaled_down_to": [item.get("scaled_down_to") for item in s3_history(status_rows) if item.get("scaled_down_to") is not None],
        "s3_drained_sources": [src for item in s3_history(status_rows) for src in (item.get("drained_sources") or [])],
        **extra_summary,
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    return summary


def write_scenario_report(out_dir: Path, title: str, summary: dict[str, Any], notes: list[str]) -> None:
    lines = [
        f"# {title}",
        "",
        f"生成时间：{ts_iso()}",
        "",
        "## 指标解释",
        "",
        "- Wall Time：该 phase 第一条请求发出到最后一条响应返回的端到端时间。",
        "- req/s：HTTP 200 成功请求数 / Wall Time，表示用户请求吞吐。",
        "- p95 latency：该 phase 单请求端到端 latency 的 95 分位。",
        "- user completion tok/s：成功响应中的 completion tokens / Wall Time，表示用户可见生成吞吐。",
        "- valid decode：HTTP 200、响应 JSON 可解析、completion_tokens > 0 且 finish_reason 为 stop 或 length 的请求数。",
        "- pod count：`pod_samples.csv` 中采样的 ready prefill/decode worker 数量，用于还原每个阶段实际运行的 pod 数。",
        "- S3 migrated requests：controller status 中 S3 history 记录的 migrated_requests，用于确认哪些 source/target worker 执行了 request/KV 接管。",
        "",
        "## Phase 结果",
        "",
        "| phase | requests | success % | valid decode % | wall(s) | req/s | p95(s) | user tok/s |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for phase, row in summary.get("phase_summaries", {}).items():
        lines.append(
            f"| {phase} | {row.get('requests', 0)} | {row.get('success_pct', 0):.2f} | {row.get('valid_decode_pct', 0):.2f} | "
            f"{row.get('wall_s', 0):.2f} | {row.get('req_s', 0):.2f} | {row.get('p95_latency_s', 0):.2f} | {row.get('user_completion_tps', 0):.2f} |"
        )
    lines.extend(
        [
            "",
            "## Controller / Worker 动作",
            "",
            f"- S2 history count: {summary.get('s2_history_count', 0)}",
            f"- S2 executed count: {summary.get('s2_executed_count', 0)}",
            f"- S3 history count: {summary.get('s3_history_count', 0)}",
            f"- S3 executed pairs: {summary.get('s3_executed_pairs', 0)}",
            f"- S3 migrated requests: {summary.get('s3_migrated_requests', 0)}",
            f"- S3 drained sources: {summary.get('s3_drained_sources', [])}",
            f"- S3 scaled down to: {summary.get('s3_scaled_down_to', [])}",
            "",
            "## 解释与结论",
            "",
        ]
    )
    lines.extend([f"- {note}" for note in notes])
    lines.extend(
        [
            "",
            "## Artifact Index",
            "",
            "- `requests.csv`：每条请求的 HTTP code、latency、token、finish_reason、content hash 和 valid_decode 判断。",
            "- `responses/`：每条原始 HTTP response。",
            "- `pod_samples.csv`：测试过程中实际 ready pod 数采样。",
            "- `controller_status.jsonl`：controller `/api/v1/status` 原始采样，包含 S2/S3 history。",
            "- `logs/`：controller 和 worker 日志，可继续排查 KV migration、rollback、500 等问题。",
        ]
    )
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
