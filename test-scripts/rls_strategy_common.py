#!/usr/bin/env python3
"""Shared helpers for the RL-Scaling four-scenario strategy E2E suite."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from statistics import mean, stdev
from typing import Any

NS = os.environ.get("DYNAMO_NAMESPACE", "dynamo-system")
CONTROLLER_NS = os.environ.get("CONTROLLER_NAMESPACE", "dynamo")
CONTROLLER_DEPLOY = os.environ.get("CONTROLLER_DEPLOY", "rl-scaling-controller")
FRONTEND_SVC = os.environ.get("FRONTEND_SVC", "svc/vllm-v1-disagg-router-frontend")
MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")
GRAPH_NAME = os.environ.get("DGD_NAME", "vllm-v1-disagg-router")


def now_ts() -> float:
    return time.time()


def ts_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def ts_utc_since() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


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


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def load_json_lines(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def deployment_names_by_component() -> dict[str, list[str]]:
    proc = kubectl(["get", "deploy", "-n", NS, "-o", "json"], timeout=60)
    obj = json.loads(proc.stdout)
    out: dict[str, list[tuple[int, str, str]]] = {"prefill": [], "decode": []}
    for item in obj.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        component = labels.get("nvidia.com/dynamo-component", "")
        graph = labels.get("nvidia.com/dynamo-graph-deployment-name", "")
        if graph and graph != GRAPH_NAME:
            continue
        name = item.get("metadata", {}).get("name", "")
        created = item.get("metadata", {}).get("creationTimestamp", "")
        replicas = int(item.get("spec", {}).get("replicas", 0) or 0)
        if component == "VllmPrefillWorker":
            out["prefill"].append((replicas, created, name))
        elif component == "VllmDecodeWorker":
            out["decode"].append((replicas, created, name))
    return {role: [name for _, _, name in sorted(items, reverse=True)] for role, items in out.items()}


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
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)
        rows.append(
            {
                "ts": now_ts(),
                "iso": ts_iso(),
                "name": item["metadata"]["name"],
                "component": component,
                "current_role_label": labels.get("nvidia.com/dynamo-current-role", ""),
                "phase": item.get("status", {}).get("phase", ""),
                "ready": ready,
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


def set_topology(prefill: int, decode: int) -> None:
    deployments = deployment_names_by_component()
    if not deployments["prefill"] or not deployments["decode"]:
        raise RuntimeError(f"could not discover worker deployments: {deployments}")
    target_prefill = os.environ.get("PREFILL_DEPLOY") or deployments["prefill"][0]
    target_decode = os.environ.get("DECODE_DEPLOY") or deployments["decode"][0]
    for name in deployments["prefill"]:
        scale_deployment(name, prefill if name == target_prefill else 0)
    for name in deployments["decode"]:
        scale_deployment(name, decode if name == target_decode else 0)
    wait_deployment(target_prefill)
    wait_deployment(target_decode)
    wait_ready_counts(prefill=prefill, decode=decode)


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
            "PRE_WARM_THRESHOLD": "2.0",
        }
    )


@dataclass
class PortForward:
    proc: subprocess.Popen
    local_port: int

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def start_port_forward(service: str, remote_port: int, namespace: str) -> PortForward:
    port = free_port()
    proc = subprocess.Popen(
        ["kubectl", "port-forward", "-n", namespace, service, f"{port}:{remote_port}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return PortForward(proc=proc, local_port=port)


def wait_http(url: str, timeout_s: int = 60) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=15).read()
            return
        except Exception:
            time.sleep(0.5)
    raise TimeoutError(f"HTTP endpoint not ready: {url}")


def controller_json(port: int, path: str, method: str = "GET", body: dict[str, Any] | None = None) -> dict[str, Any]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def local_post_json(port: int, path: str, body: dict[str, Any], timeout: int = 30) -> Any:
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def local_json(port: int, path: str, timeout: int = 10) -> Any:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def local_json_retry(port: int, path: str, timeout_s: int = 10) -> Any:
    deadline = time.time() + timeout_s
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            return local_json(port, path, timeout=3)
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            time.sleep(0.4)
    raise TimeoutError(f"local port-forward endpoint did not become ready: {path}: {last_error}")


def port_forward_stderr(pf: PortForward) -> str:
    try:
        if pf.proc.stderr is None or pf.proc.poll() is None:
            return ""
        return (pf.proc.stderr.read() or "")[:1000]
    except Exception:
        return ""


def collect_decode_active_requests() -> dict[str, Any]:
    """Snapshot decode worker sidecars via short-lived pod port-forwards."""
    snapshot = {"ts": now_ts(), "iso": ts_iso(), "workers": []}
    for pod in ready_worker_pods():
        if pod.get("component") != "VllmDecodeWorker":
            continue
        worker = {
            "pod": pod.get("name", ""),
            "pod_ip": pod.get("pod_ip", ""),
            "current_role_label": pod.get("current_role_label", ""),
            "active_requests": [],
            "active_count": 0,
        }
        pf: PortForward | None = None
        try:
            pf = start_port_forward(f"pod/{pod['name']}", 9091, NS)
            local_json_retry(pf.local_port, "/healthz", timeout_s=10)
            try:
                role_body = local_json_retry(pf.local_port, "/v1/role", timeout_s=10)
                worker["sidecar_role"] = role_body.get("current_role") if isinstance(role_body, dict) else role_body
            except Exception as exc:  # noqa: BLE001
                worker["role_error"] = str(exc)
            active = local_json_retry(pf.local_port, "/v1/active_requests", timeout_s=10)
            worker["active_requests"] = active if isinstance(active, list) else []
            worker["active_count"] = len(worker["active_requests"])
        except Exception as exc:  # noqa: BLE001
            worker["error"] = str(exc)
            if pf is not None:
                worker["port_forward_stderr"] = port_forward_stderr(pf)
        finally:
            if pf is not None:
                pf.stop()
        snapshot["workers"].append(worker)
    snapshot["total_active"] = sum(int(w.get("active_count", 0) or 0) for w in snapshot["workers"])
    snapshot["active_worker_count"] = sum(1 for w in snapshot["workers"] if int(w.get("active_count", 0) or 0) > 0)
    return snapshot


def collect_worker_roles() -> dict[str, Any]:
    """Snapshot runtime roles from every ready worker sidecar."""
    snapshot = {"ts": now_ts(), "iso": ts_iso(), "workers": []}
    for pod in ready_worker_pods():
        worker = {
            "pod": pod.get("name", ""),
            "component": pod.get("component", ""),
            "pod_ip": pod.get("pod_ip", ""),
            "current_role_label": pod.get("current_role_label", ""),
            "sidecar_role": "unknown",
            "healthy": False,
        }
        pf: PortForward | None = None
        try:
            pf = start_port_forward(f"pod/{pod['name']}", 9091, NS)
            local_json_retry(pf.local_port, "/healthz", timeout_s=10)
            role_body = local_json_retry(pf.local_port, "/v1/role", timeout_s=10)
            role = role_body.get("current_role") if isinstance(role_body, dict) else role_body
            worker["sidecar_role"] = role
            worker["healthy"] = role in {"prefill", "decode"}
        except Exception as exc:  # noqa: BLE001
            worker["error"] = str(exc)
            if pf is not None:
                worker["port_forward_stderr"] = port_forward_stderr(pf)
        finally:
            if pf is not None:
                pf.stop()
        snapshot["workers"].append(worker)
    snapshot["role_counts"] = {
        "prefill": sum(1 for w in snapshot["workers"] if w.get("sidecar_role") == "prefill"),
        "decode": sum(1 for w in snapshot["workers"] if w.get("sidecar_role") == "decode"),
        "unknown": sum(1 for w in snapshot["workers"] if w.get("sidecar_role") not in {"prefill", "decode"}),
    }
    return snapshot


def wait_runtime_role_counts(
    *,
    prefill: int,
    decode: int,
    timeout_s: int = 180,
    snapshot_path: Path | None = None,
) -> dict[str, Any]:
    deadline = time.time() + timeout_s
    last_snapshot: dict[str, Any] | None = None
    while time.time() < deadline:
        snapshot = collect_worker_roles()
        last_snapshot = snapshot
        if snapshot_path is not None:
            with snapshot_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(snapshot, ensure_ascii=False) + "\n")
        counts = snapshot.get("role_counts", {})
        if (
            int(counts.get("prefill", 0) or 0) >= prefill
            and int(counts.get("decode", 0) or 0) >= decode
            and int(counts.get("unknown", 0) or 0) == 0
        ):
            return snapshot
        time.sleep(2)
    raise TimeoutError(
        "runtime role timeout: "
        f"expected prefill>={prefill}, decode>={decode}, unknown=0, last={last_snapshot}"
    )


def reset_decode_component_roles(snapshot_path: Path | None = None) -> list[dict[str, Any]]:
    """Return all dual-mode decode-component pods to runtime decode role."""
    actions: list[dict[str, Any]] = []
    snapshot = collect_worker_roles()
    if snapshot_path is not None:
        with snapshot_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"reset_scan": snapshot}, ensure_ascii=False) + "\n")
    by_name = {pod["name"]: pod for pod in ready_worker_pods()}
    for worker in snapshot.get("workers", []):
        if worker.get("component") != "VllmDecodeWorker" or worker.get("sidecar_role") == "decode":
            continue
        pod_name = str(worker.get("pod") or "")
        if pod_name not in by_name:
            continue
        action = {"pod": pod_name, "from_role": worker.get("sidecar_role"), "to_role": "decode"}
        pf: PortForward | None = None
        try:
            pf = start_port_forward(f"pod/{pod_name}", 9091, NS)
            local_json_retry(pf.local_port, "/healthz", timeout_s=10)
            action["response"] = local_post_json(pf.local_port, "/switch_role", {"target_role": "decode"}, timeout=60)
        except Exception as exc:  # noqa: BLE001
            action["error"] = str(exc)
            if pf is not None:
                action["port_forward_stderr"] = port_forward_stderr(pf)
        finally:
            if pf is not None:
                pf.stop()
        actions.append(action)
    if actions:
        wait_runtime_role_counts(prefill=2, decode=2, timeout_s=240, snapshot_path=snapshot_path)
    return actions


def wait_frontend_chat_ready(frontend_port: int, timeout_s: int = 240) -> None:
    deadline = time.time() + timeout_s
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": "RL_SCALING_READINESS ping"}],
        "max_tokens": 1,
        "temperature": 0,
        "stream": False,
    }
    while time.time() < deadline:
        try:
            submit_chat(frontend_port, payload, timeout=30)
            return
        except Exception:
            time.sleep(2)
    raise TimeoutError("Dynamo frontend chat completion endpoint did not become model-ready")


def wait_frontend_long_decode_ready(frontend_port: int, timeout_s: int = 240, max_tokens: int = 48) -> None:
    deadline = time.time() + timeout_s
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": "Count from one to thirty with comma separators."}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }
    last_error = ""
    while time.time() < deadline:
        try:
            submit_chat(frontend_port, payload, timeout=min(120, max(30, int(timeout_s))))
            return
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
            time.sleep(3)
    raise TimeoutError(f"Dynamo frontend long-decode readiness failed: {last_error}")


def submit_chat(frontend_port: int, payload: dict[str, Any], timeout: int = 300) -> bytes:
    req = urllib.request.Request(
        f"http://127.0.0.1:{frontend_port}/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def send_progress(controller_port: int, progress: float, batch_size: int, avg_isl: int, avg_osl: int) -> dict[str, Any]:
    return controller_json(
        controller_port,
        "/api/v1/signals/sampling_progress",
        "POST",
        {
            "progress": progress,
            "batch_meta": {
                "batch_size": batch_size,
                "avg_isl": avg_isl,
                "avg_osl": avg_osl,
                "total_tokens": batch_size * (avg_isl + avg_osl),
            },
        },
    )


def send_done(controller_port: int, batch_size: int, avg_isl: int, avg_osl: int) -> dict[str, Any]:
    return controller_json(
        controller_port,
        "/api/v1/signals/sampling_done",
        "POST",
        {
            "batch_meta": {
                "batch_size": batch_size,
                "avg_isl": avg_isl,
                "avg_osl": avg_osl,
                "total_tokens": batch_size * (avg_isl + avg_osl),
            }
        },
    )


def send_batch_complete(controller_port: int) -> dict[str, Any]:
    return controller_json(controller_port, "/api/v1/signals/batch_complete", "POST", {})


def prompt_text(phase: str, idx: int, words: int, nonce: str, max_tokens: int, shape: str) -> str:
    marker = f"RL_SCALING_STRATEGY_TEST phase={phase} request={idx} nonce={nonce}"
    if phase == "decode_tail":
        instruction = (
            "Return a compact numbered list about GPU autoscaling. "
            "Keep each item short and stop naturally after the list. "
        )
    elif phase == "balanced_decode":
        instruction = (
            f"Write a medium-length technical answer and continue until close to the {max_tokens} token limit. "
        )
    else:
        instruction = (
            f"Return a technical answer and continue until close to the {max_tokens} token limit. "
        )
    base = (
        f"{marker}. shape={shape}. {instruction} Repeat the marker at the end only if there is remaining budget. "
        "Discuss prefill pressure, decode tail, KV cache transfer, GPU scheduling, and autoscaling. "
    )
    filler = " ".join(f"token{(idx + i) % 197}" for i in range(words))
    return base + filler


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


def submit_manifest_request(frontend_port: int, item: dict[str, Any], out_dir: Path, nonce: str) -> dict[str, Any]:
    start = now_ts()
    idx = int(item["manifest_id"])
    phase = str(item["phase"])
    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": prompt_text(
                    phase,
                    idx,
                    int(item["words"]),
                    nonce,
                    int(item["max_tokens"]),
                    str(item.get("shape", "")),
                ),
            }
        ],
        "max_tokens": int(item["max_tokens"]),
        "temperature": 0,
        "stream": False,
    }
    code = 0
    raw = b""
    error = ""
    try:
        raw = submit_chat(frontend_port, payload, timeout=int(item.get("timeout_s", 420)))
        code = 200
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
    valid_decode = (
        code == 200
        and parsed.get("parse_ok")
        and int(parsed.get("completion_tokens", 0) or 0) > 0
        and parsed.get("finish_reason") in {"stop", "length"}
    )
    return {
        "phase": phase,
        "manifest_id": idx,
        "shape": item.get("shape", ""),
        "manifest_words": item.get("words", ""),
        "manifest_max_tokens": item.get("max_tokens", ""),
        "start_ts": start,
        "end_ts": end,
        "http_code": code,
        "latency_s": end - start,
        "valid_decode": bool(valid_decode),
        "error": error,
        **parsed,
    }


def run_manifest_phase(frontend_port: int, manifest: list[dict[str, Any]], phase: str, out_dir: Path, nonce: str) -> list[dict[str, Any]]:
    items = [row for row in manifest if row["phase"] == phase]
    if not items:
        return []
    concurrency = max(1, int(items[0].get("concurrency", 1)))
    rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(submit_manifest_request, frontend_port, item, out_dir, nonce) for item in items]
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


def summarize_requests(rows: list[dict[str, Any]]) -> dict[str, Any]:
    ok = [r for r in rows if int(r.get("http_code", 0)) == 200]
    valid = [r for r in rows if r.get("valid_decode")]
    timeout = [r for r in rows if "timed out" in str(r.get("error", "")).lower() or "timeout" in str(r.get("error", "")).lower()]
    http_5xx = [r for r in rows if int(r.get("http_code", 0) or 0) >= 500]
    lats = [float(r["latency_s"]) for r in rows]
    wall = (max(float(r["end_ts"]) for r in rows) - min(float(r["start_ts"]) for r in rows)) if rows else 0.0
    prompt = sum(int(r.get("prompt_tokens", 0) or 0) for r in ok)
    completion = sum(int(r.get("completion_tokens", 0) or 0) for r in ok)
    total = sum(int(r.get("total_tokens", 0) or 0) for r in ok)
    return {
        "requests": len(rows),
        "success": len(ok),
        "success_pct": (100.0 * len(ok) / len(rows)) if rows else 0.0,
        "valid_decode": len(valid),
        "valid_decode_pct": (100.0 * len(valid) / len(rows)) if rows else 0.0,
        "timeout_count": len(timeout),
        "http_5xx_count": len(http_5xx),
        "wall_s": wall,
        "req_s": (len(ok) / wall) if wall > 0 else 0.0,
        "p50_latency_s": percentile(lats, 0.50),
        "p95_latency_s": percentile(lats, 0.95),
        "p99_latency_s": percentile(lats, 0.99),
        "prompt_tokens": prompt,
        "completion_tokens": completion,
        "total_tokens": total,
        "prompt_tps": (prompt / wall) if wall > 0 else 0.0,
        "completion_tps": (completion / wall) if wall > 0 else 0.0,
        "total_tps": (total / wall) if wall > 0 else 0.0,
    }


def summarize_pod_allocation(rows: list[dict[str, Any]], start_ts: float | None = None, end_ts: float | None = None) -> dict[str, Any]:
    points: list[tuple[float, int, int]] = []
    seen: set[tuple[str, int, int]] = set()
    for row in rows:
        if row.get("name") == "sampler_error":
            continue
        ts = float(row.get("ts", 0.0) or 0.0)
        if start_ts is not None and ts < start_ts:
            continue
        if end_ts is not None and ts > end_ts:
            continue
        p = int(float(row.get("ready_prefill_count") or 0))
        d = int(float(row.get("ready_decode_count") or 0))
        key = (str(row.get("iso")), p, d)
        if key in seen:
            continue
        seen.add(key)
        points.append((ts, p, d))
    points.sort()
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
    for (ts, p, d), (next_ts, _, _) in zip(points, points[1:]):
        dt = max(0.0, next_ts - ts)
        gpu_s += (p + d) * dt
        prefill_s += p * dt
        decode_s += d * dt
        totals.append(p + d)
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
    def __init__(self, interval: float, stop: threading.Event):
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
            except Exception as exc:
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


def status_sample(controller_port: int, status_rows: list[dict[str, Any]], label: str) -> None:
    try:
        body = controller_json(controller_port, "/api/v1/status")
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
            "selected_actions": [],
            "top_skip_reasons": [],
        }
    skips: dict[str, int] = {}
    for row in rows:
        reason = str(row.get("skip_reason") or "")
        if reason:
            skips[reason] = skips.get(reason, 0) + 1
    return {
        "count": len(rows),
        "max_prefill_queue_depth": max(int(row.get("prefill_queue_depth", 0) or 0) for row in rows),
        "max_decode_queue_depth": max(int(row.get("decode_queue_depth", 0) or 0) for row in rows),
        "max_prefill_worker_active": max(int(row.get("prefill_worker_active", 0) or 0) for row in rows),
        "max_decode_worker_active": max(int(row.get("decode_worker_active", 0) or 0) for row in rows),
        "selected_actions": [row.get("selected_action") for row in rows if row.get("selected_action")],
        "top_skip_reasons": sorted(skips.items(), key=lambda item: item[1], reverse=True)[:5],
    }


def capture_logs(out_dir: Path, since_iso: str) -> None:
    log_dir = out_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    errors: list[str] = []
    try:
        controller = kubectl(
            ["logs", "-n", CONTROLLER_NS, "-l", f"app={CONTROLLER_DEPLOY}", f"--since-time={since_iso}", "--tail=2600"],
            timeout=120,
            check=False,
        )
        (log_dir / "controller.log").write_text(controller.stdout + controller.stderr, encoding="utf-8")
    except Exception as exc:
        errors.append(f"controller logs: {exc}")
    try:
        pods = pod_rows()
    except Exception as exc:
        pods = []
        errors.append(f"list pods: {exc}")
    for pod in pods:
        name = pod["name"]
        try:
            proc = kubectl(["logs", "-n", NS, name, f"--since-time={since_iso}", "--tail=1600"], timeout=120, check=False)
            (log_dir / f"{name}.log").write_text(proc.stdout + proc.stderr, encoding="utf-8")
        except Exception as exc:
            errors.append(f"{name} logs: {exc}")
    if errors:
        (log_dir / "capture_error.txt").write_text("\n".join(errors) + "\n", encoding="utf-8")


def find_event_ts(events: list[dict[str, Any]], name: str) -> float | None:
    for row in events:
        if row.get("event") == name:
            return float(row.get("ts", 0.0) or 0.0)
    return None


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
            "manifest_words",
            "manifest_max_tokens",
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
    (out_dir / "controller_status.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in status_rows) + ("\n" if status_rows else ""),
        encoding="utf-8",
    )
    try:
        write_json(out_dir / "final_pods.json", json.loads(kubectl(["get", "pods", "-n", NS, "-o", "json"], timeout=60).stdout))
    except Exception as exc:
        write_json(out_dir / "final_pods_error.json", {"error": str(exc), "ts": now_ts(), "iso": ts_iso()})
    first_request = min((float(r["start_ts"]) for r in requests), default=None)
    last_request = max((float(r["end_ts"]) for r in requests), default=None)
    prep = dict(extra_summary.get("preparation", {}))
    signal = prep.get("T_signal_recv")
    warmup = prep.get("T_warmup_start")
    ready = prep.get("T_ready")
    burst = prep.get("T_burst_arrival") or first_request
    prep["Warmup Trigger Lag"] = (warmup - signal) if signal and warmup else None
    prep["Signal-to-Ready"] = (ready - signal) if signal and ready else None
    prep["Burst Safety Margin"] = (burst - ready) if burst and ready else None
    summary = {
        "generated_at": ts_iso(),
        "phase_summaries": phase_summaries,
        "overall_summary": summarize_requests(requests),
        "pod_allocation": summarize_pod_allocation(pod_samples),
        "request_window_pod_allocation": summarize_pod_allocation(pod_samples, first_request, last_request),
        "preparation": prep,
        "s2_history_count": len(s2_history(status_rows)),
        "s2_executed_count": sum(1 for item in s2_history(status_rows) if item.get("executed")),
        "s2_switch_latencies_ms": [
            item.get("result", {}).get("switch_time_ms")
            for item in s2_history(status_rows)
            if item.get("executed") and isinstance(item.get("result"), dict)
        ],
        "s2_evaluation_summary": summarize_s2_evaluations(status_rows),
        "s3_history_count": len(s3_history(status_rows)),
        "s3_executed_pairs": sum(int(item.get("executed_pairs", 0) or 0) for item in s3_history(status_rows)),
        "s3_migration_attempts": sum(int(item.get("migration_attempts", 0) or 0) for item in s3_history(status_rows)),
        "s3_migrated_requests": sum(int(item.get("migrated_requests", 0) or 0) for item in s3_history(status_rows)),
        "s3_declined_requests": sum(int(item.get("declined_requests", 0) or 0) for item in s3_history(status_rows)),
        "s3_scaled_down_to": [item.get("scaled_down_to") for item in s3_history(status_rows) if item.get("scaled_down_to") is not None],
        "s3_drained_sources": [src for item in s3_history(status_rows) for src in (item.get("drained_sources") or [])],
        **{k: v for k, v in extra_summary.items() if k != "preparation"},
    }
    write_json(out_dir / "summary.json", summary)
    return summary


def metric_stats(values: list[float]) -> dict[str, float]:
    if not values:
        return {"mean": 0.0, "stdev": 0.0, "best": 0.0, "worst": 0.0}
    return {
        "mean": mean(values),
        "stdev": stdev(values) if len(values) > 1 else 0.0,
        "best": min(values),
        "worst": max(values),
    }
