#!/usr/bin/env python3
"""Scale up/down E2E test for RL-Scaling + Dynamo.

The test exercises a production-style resource loop on the current Kubernetes
deployment:

1. scale to 2 prefill + 4 decode workers;
2. run a high-load wave;
3. scale down decode from 4 to 2 and measure released GPU allocation;
4. run a low-load wave while scaled down;
5. scale up decode from 2 to 4 and run high-load again;
6. restore the original healthy topology.

It intentionally measures both allocation and utilization:

- allocated GPU-hours: replica count * elapsed time;
- GPU busy/effective hours: utilization-weighted GPU time;
- effective-hour utilization: busy/effective hours / allocated GPU-hours.

Higher effective-hour utilization means less allocated GPU time was idle.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


NS = "dynamo-system"
FRONTEND_SVC = "svc/vllm-v1-disagg-router-frontend"
FRONTEND_LOCAL = 18000
MODEL = "Qwen/Qwen3-0.6B"

DECODE_DEPLOY = "vllm-v1-disagg-router-vllmdecodeworker-574b777c"
PREFILL_DEPLOY = "vllm-v1-disagg-router-vllmprefillworker-574b777c"
OLD_DECODE_DEPLOY = "vllm-v1-disagg-router-vllmdecodeworker-47d8a958"
OLD_PREFILL_DEPLOY = "vllm-v1-disagg-router-vllmprefillworker-47d8a958"


def now_ts() -> float:
    return time.time()


def ts_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def run(cmd: list[str], timeout: int = 60, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
    return proc


def kubectl(args: list[str], timeout: int = 60, check: bool = True) -> subprocess.CompletedProcess:
    return run(["kubectl", *args], timeout=timeout, check=check)


def deployment_replicas(name: str) -> int:
    proc = kubectl(["get", "deploy", "-n", NS, name, "-o", "json"], timeout=30)
    obj = json.loads(proc.stdout)
    return int(obj.get("spec", {}).get("replicas", 0) or 0)


def scale_deployment(name: str, replicas: int) -> None:
    kubectl(["scale", "deployment", "-n", NS, name, f"--replicas={replicas}"], timeout=60)


def wait_deployment(name: str, timeout_s: int = 1200) -> None:
    kubectl(["rollout", "status", "deployment", "-n", NS, name, f"--timeout={timeout_s}s"], timeout=timeout_s + 30)


def pod_rows() -> list[dict]:
    proc = kubectl(["get", "pods", "-n", NS, "-o", "json"], timeout=60)
    obj = json.loads(proc.stdout)
    rows = []
    for item in obj.get("items", []):
        labels = item.get("metadata", {}).get("labels", {})
        component = labels.get("nvidia.com/dynamo-component", "")
        if component not in {"VllmDecodeWorker", "VllmPrefillWorker"}:
            continue
        rows.append(
            {
                "name": item["metadata"]["name"],
                "component": component,
                "phase": item.get("status", {}).get("phase", ""),
                "ready": all(
                    c.get("type") != "Ready" or c.get("status") == "True"
                    for c in item.get("status", {}).get("conditions", [])
                ),
                "pod_ip": item.get("status", {}).get("podIP", ""),
            }
        )
    return rows


def ready_worker_pods() -> list[dict]:
    return [p for p in pod_rows() if p["phase"] == "Running" and p["ready"]]


def count_ready_by_component() -> tuple[int, int]:
    rows = ready_worker_pods()
    decode = sum(1 for p in rows if p["component"] == "VllmDecodeWorker")
    prefill = sum(1 for p in rows if p["component"] == "VllmPrefillWorker")
    return prefill, decode


def wait_ready_counts(prefill: int, decode: int, timeout_s: int = 1500) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        p, d = count_ready_by_component()
        if p >= prefill and d >= decode:
            return
        time.sleep(5)
    raise TimeoutError(f"ready worker timeout: expected prefill>={prefill}, decode>={decode}, got {count_ready_by_component()}")


def start_port_forward() -> subprocess.Popen:
    proc = subprocess.Popen(
        ["kubectl", "port-forward", "-n", NS, FRONTEND_SVC, f"{FRONTEND_LOCAL}:8000"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{FRONTEND_LOCAL}/health", timeout=1).read()
            return proc
        except Exception:
            time.sleep(0.5)
    return proc


def prompt_text(phase: str, idx: int, words: int) -> str:
    base = (
        f"Stage {phase}, request {idx}. Analyze RL rollout serving with disaggregated "
        "prefill and decode workers, GPU utilization, request migration, cache behavior, "
        "tail latency, autoscaling, and throughput tradeoffs. "
    )
    filler = " ".join(f"token{(idx + i) % 97}" for i in range(words))
    return base + filler


def submit_request(phase: str, idx: int, words: int, max_tokens: int, out_dir: Path) -> dict:
    start = now_ts()
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt_text(phase, idx, words)}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{FRONTEND_LOCAL}/v1/chat/completions",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    code = 0
    raw = b""
    error = ""
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            code = resp.getcode()
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        code = exc.code
        raw = exc.read()
        error = str(exc)
    except Exception as exc:  # noqa: BLE001
        error = str(exc)
    end = now_ts()

    response_file = out_dir / "responses" / f"{phase}-{idx}.json"
    response_file.write_bytes(raw)
    usage = {}
    try:
        usage = json.loads(raw.decode("utf-8")).get("usage", {})
    except Exception:
        usage = {}
    return {
        "phase": phase,
        "idx": idx,
        "start_ts": start,
        "end_ts": end,
        "http_code": code,
        "latency_s": end - start,
        "prompt_tokens": int(usage.get("prompt_tokens", 0) or 0),
        "completion_tokens": int(usage.get("completion_tokens", 0) or 0),
        "total_tokens": int(usage.get("total_tokens", 0) or 0),
        "error": error,
    }


def run_wave(phase: str, count: int, concurrency: int, words: int, max_tokens: int, out_dir: Path) -> list[dict]:
    rows = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(submit_request, phase, i, words, max_tokens, out_dir)
            for i in range(1, count + 1)
        ]
        for future in as_completed(futures):
            rows.append(future.result())
    rows.sort(key=lambda r: r["idx"])
    return rows


def nvidia_smi_for_pod(pod: str) -> tuple[float, float]:
    proc = kubectl(
        [
            "exec",
            "-n",
            NS,
            pod,
            "--",
            "nvidia-smi",
            "--query-gpu=utilization.gpu,memory.used",
            "--format=csv,noheader,nounits",
        ],
        timeout=20,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return 0.0, 0.0
    line = proc.stdout.strip().splitlines()[0]
    parts = [p.strip() for p in line.split(",")]
    return float(parts[0]), float(parts[1])


@dataclass
class Sampler:
    out_dir: Path
    interval: float
    stop: threading.Event
    rows: list[dict]
    node_nvidia_smi: bool = True

    def run(self) -> None:
        while not self.stop.is_set():
            t = now_ts()
            allocated = sum(count_ready_by_component())
            if self.node_nvidia_smi:
                try:
                    proc = run(
                        [
                            "ssh",
                            "gpu14",
                            "nvidia-smi",
                            "--query-gpu=index,utilization.gpu,memory.used",
                            "--format=csv,noheader,nounits",
                        ],
                        timeout=15,
                        check=False,
                    )
                except subprocess.TimeoutExpired:
                    proc = subprocess.CompletedProcess(args=["ssh", "gpu14", "nvidia-smi"], returncode=124, stdout="", stderr="timeout")
                if proc.returncode == 0 and proc.stdout.strip():
                    for line in proc.stdout.strip().splitlines():
                        parts = [p.strip() for p in line.split(",")]
                        if len(parts) < 3:
                            continue
                        self.rows.append(
                            {
                                "ts": t,
                                "iso": ts_iso(),
                                "pod": f"gpu-{parts[0]}",
                                "component": "node-gpu",
                                "gpu_util_pct": float(parts[1]),
                                "gpu_mem_mib": float(parts[2]),
                                "allocated_worker_gpus": allocated,
                            }
                        )
                else:
                    self._sample_pods(t, allocated)
            else:
                self._sample_pods(t, allocated)
            time.sleep(self.interval)

    def _sample_pods(self, t: float, allocated: int) -> None:
        pods = ready_worker_pods()
        for pod in pods:
            util, mem = nvidia_smi_for_pod(pod["name"])
            self.rows.append(
                {
                    "ts": t,
                    "iso": ts_iso(),
                    "pod": pod["name"],
                    "component": pod["component"],
                    "gpu_util_pct": util,
                    "gpu_mem_mib": mem,
                    "allocated_worker_gpus": allocated,
                }
            )


def write_csv(path: Path, rows: list[dict], fields: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fields})


def percentile(vals: list[float], pct: float) -> float:
    if not vals:
        return 0.0
    vals = sorted(vals)
    idx = int(round((len(vals) - 1) * pct))
    return vals[idx]


def summarize_wave(rows: list[dict]) -> dict:
    ok = [r for r in rows if r["http_code"] == 200]
    lats = [r["latency_s"] for r in rows]
    wall = (max(r["end_ts"] for r in rows) - min(r["start_ts"] for r in rows)) if rows else 0.0
    completion = sum(r["completion_tokens"] for r in ok)
    return {
        "requests": len(rows),
        "success": len(ok),
        "success_pct": (100.0 * len(ok) / len(rows)) if rows else 0.0,
        "wall_s": wall,
        "req_s": (len(ok) / wall) if wall > 0 else 0.0,
        "p50_latency_s": percentile(lats, 0.50),
        "p95_latency_s": percentile(lats, 0.95),
        "p99_latency_s": percentile(lats, 0.99),
        "completion_tokens": completion,
        "user_completion_tps": (completion / wall) if wall > 0 else 0.0,
    }


def summarize_gpu(rows: list[dict], phase_start: float, phase_end: float, interval: float) -> dict:
    phase_rows = [r for r in rows if phase_start <= float(r["ts"]) <= phase_end]
    if not phase_rows:
        return {
            "samples": 0,
            "avg_gpu_util_pct": 0.0,
            "max_gpu_mem_mib": 0.0,
            "allocated_gpu_seconds": 0.0,
            "gpu_busy_seconds": 0.0,
            "gpu_idle_seconds": 0.0,
            "effective_hour_utilization_pct": 0.0,
        }
    by_ts: dict[float, list[dict]] = {}
    for row in phase_rows:
        by_ts.setdefault(float(row["ts"]), []).append(row)
    allocated_gpu_seconds = 0.0
    busy_seconds = 0.0
    utils = []
    max_mem = 0.0
    for sample_rows in by_ts.values():
        allocated_from_sample = max(float(r.get("allocated_worker_gpus", 0) or 0) for r in sample_rows)
        allocated_gpu_seconds += (allocated_from_sample or len(sample_rows)) * interval
        for row in sample_rows:
            util = float(row["gpu_util_pct"])
            utils.append(util)
            busy_seconds += (util / 100.0) * interval
            max_mem = max(max_mem, float(row["gpu_mem_mib"]))
    if allocated_gpu_seconds > 0:
        busy_seconds = min(busy_seconds, allocated_gpu_seconds)
    idle = max(0.0, allocated_gpu_seconds - busy_seconds)
    return {
        "samples": len(phase_rows),
        "avg_gpu_util_pct": statistics.mean(utils) if utils else 0.0,
        "max_gpu_mem_mib": max_mem,
        "allocated_gpu_seconds": allocated_gpu_seconds,
        "gpu_busy_seconds": busy_seconds,
        "gpu_idle_seconds": idle,
        "allocated_gpu_hours": allocated_gpu_seconds / 3600.0,
        "gpu_effective_busy_hours": busy_seconds / 3600.0,
        "gpu_idle_hours": idle / 3600.0,
        "effective_hour_utilization_pct": (100.0 * busy_seconds / allocated_gpu_seconds) if allocated_gpu_seconds > 0 else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="")
    parser.add_argument("--sample-interval", type=float, default=5.0)
    parser.add_argument("--high-count", type=int, default=96)
    parser.add_argument("--high-concurrency", type=int, default=12)
    parser.add_argument("--high-max-tokens", type=int, default=768)
    parser.add_argument("--low-count", type=int, default=24)
    parser.add_argument("--low-concurrency", type=int, default=4)
    parser.add_argument("--low-max-tokens", type=int, default=384)
    parser.add_argument("--scale-down-settle", type=int, default=15)
    parser.add_argument("--scale-up-settle", type=int, default=60)
    parser.add_argument("--pod-nvidia-smi", action="store_true")
    parser.add_argument("--no-restore", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    reports = root / "reports"
    out_dir = Path(args.out) if args.out else reports / f"scale-up-down-e2e-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "responses").mkdir(exist_ok=True)

    events: list[dict] = []
    all_requests: list[dict] = []
    phase_windows: dict[str, tuple[float, float]] = {}

    def event(name: str, **data) -> None:
        row = {"ts": now_ts(), "iso": ts_iso(), "event": name, **data}
        events.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)

    original = {
        DECODE_DEPLOY: deployment_replicas(DECODE_DEPLOY),
        PREFILL_DEPLOY: deployment_replicas(PREFILL_DEPLOY),
        OLD_DECODE_DEPLOY: deployment_replicas(OLD_DECODE_DEPLOY),
        OLD_PREFILL_DEPLOY: deployment_replicas(OLD_PREFILL_DEPLOY),
    }
    event("original_replicas", **original)

    stop = threading.Event()
    sampler = Sampler(out_dir=out_dir, interval=args.sample_interval, stop=stop, rows=[], node_nvidia_smi=not args.pod_nvidia_smi)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    sampler_thread.start()
    pf = None

    try:
        event("cleanup_old_crashloop_deployments_start")
        scale_deployment(OLD_DECODE_DEPLOY, 0)
        scale_deployment(OLD_PREFILL_DEPLOY, 0)
        event("cleanup_old_crashloop_deployments_done")

        event("scale_to_2p4d_start")
        scale_deployment(PREFILL_DEPLOY, 2)
        scale_deployment(DECODE_DEPLOY, 4)
        wait_deployment(PREFILL_DEPLOY)
        wait_deployment(DECODE_DEPLOY)
        wait_ready_counts(prefill=2, decode=4)
        event("scale_to_2p4d_ready", ready_prefill=2, ready_decode=4)

        pf = start_port_forward()
        event("frontend_port_forward_started", local_port=FRONTEND_LOCAL)

        event("warmup_start")
        run_wave("warmup", 1, 1, 64, 64, out_dir)
        event("warmup_done")

        phase = "high_before_scale_down"
        event(f"{phase}_start", prefill=2, decode=4)
        start = now_ts()
        rows = run_wave(phase, args.high_count, args.high_concurrency, 160, args.high_max_tokens, out_dir)
        end = now_ts()
        phase_windows[phase] = (start, end)
        all_requests.extend(rows)
        event(f"{phase}_done", **summarize_wave(rows))

        event("scale_down_start", from_prefill=2, from_decode=4, to_prefill=2, to_decode=2)
        down_start = now_ts()
        scale_deployment(DECODE_DEPLOY, 2)
        wait_deployment(DECODE_DEPLOY)
        wait_ready_counts(prefill=2, decode=2)
        event("scale_down_ready", ready_prefill=2, ready_decode=2)
        if args.scale_down_settle > 0:
            event("scale_down_settle_start", seconds=args.scale_down_settle)
            time.sleep(args.scale_down_settle)
            event("scale_down_settle_done")

        phase = "low_after_scale_down"
        event(f"{phase}_start", prefill=2, decode=2)
        start = now_ts()
        rows = run_wave(phase, args.low_count, args.low_concurrency, 120, args.low_max_tokens, out_dir)
        end = now_ts()
        phase_windows[phase] = (start, end)
        all_requests.extend(rows)
        event(f"{phase}_done", **summarize_wave(rows))

        event("scale_down_hold_start", hold_seconds=45)
        hold_start = now_ts()
        time.sleep(45)
        hold_end = now_ts()
        phase_windows["scale_down_hold"] = (hold_start, hold_end)
        event("scale_down_hold_done")
        down_end = now_ts()
        phase_windows["scaled_down_total_window"] = (down_start, down_end)

        event("scale_up_start", from_prefill=2, from_decode=2, to_prefill=2, to_decode=4)
        scale_deployment(DECODE_DEPLOY, 4)
        wait_deployment(DECODE_DEPLOY)
        wait_ready_counts(prefill=2, decode=4)
        event("scale_up_ready", ready_prefill=2, ready_decode=4)
        if args.scale_up_settle > 0:
            event("scale_up_settle_start", seconds=args.scale_up_settle)
            time.sleep(args.scale_up_settle)
            event("scale_up_settle_done")

        phase = "high_after_scale_up"
        event(f"{phase}_start", prefill=2, decode=4)
        start = now_ts()
        rows = run_wave(phase, args.high_count, args.high_concurrency, 160, args.high_max_tokens, out_dir)
        end = now_ts()
        phase_windows[phase] = (start, end)
        all_requests.extend(rows)
        event(f"{phase}_done", **summarize_wave(rows))

    finally:
        if not args.no_restore:
            event("restore_original_healthy_topology_start")
            scale_deployment(PREFILL_DEPLOY, original[PREFILL_DEPLOY])
            scale_deployment(DECODE_DEPLOY, original[DECODE_DEPLOY])
            wait_deployment(PREFILL_DEPLOY)
            wait_deployment(DECODE_DEPLOY)
            event("restore_original_healthy_topology_done", prefill=original[PREFILL_DEPLOY], decode=original[DECODE_DEPLOY])
        stop.set()
        sampler_thread.join(timeout=10)
        if pf is not None:
            pf.terminate()

    write_csv(out_dir / "events.csv", events, sorted({k for row in events for k in row.keys()}))
    write_csv(
        out_dir / "requests.csv",
        all_requests,
        ["phase", "idx", "start_ts", "end_ts", "http_code", "latency_s", "prompt_tokens", "completion_tokens", "total_tokens", "error"],
    )
    write_csv(
        out_dir / "gpu_samples.csv",
        sampler.rows,
        ["ts", "iso", "pod", "component", "gpu_util_pct", "gpu_mem_mib", "allocated_worker_gpus"],
    )
    (out_dir / "final_pods.json").write_text(kubectl(["get", "pods", "-n", NS, "-o", "json"], timeout=60).stdout, encoding="utf-8")

    summaries = {}
    for phase in sorted({r["phase"] for r in all_requests}):
        summaries[phase] = summarize_wave([r for r in all_requests if r["phase"] == phase])
    gpu_summaries = {
        phase: summarize_gpu(sampler.rows, window[0], window[1], args.sample_interval)
        for phase, window in phase_windows.items()
    }

    down_window = phase_windows.get("scaled_down_total_window", (0.0, 0.0))
    released_gpu_seconds = 2.0 * max(0.0, down_window[1] - down_window[0])
    release = {
        "released_decode_replicas": 2,
        "released_gpu_seconds": released_gpu_seconds,
        "released_gpu_hours": released_gpu_seconds / 3600.0,
        "scaled_down_window_s": max(0.0, down_window[1] - down_window[0]),
    }
    summary = {
        "out_dir": str(out_dir),
        "original_replicas": original,
        "wave_summaries": summaries,
        "gpu_summaries": gpu_summaries,
        "resource_release": release,
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    def fmt(x: float, n: int = 2) -> str:
        return f"{x:.{n}f}"

    lines = [
        "# Scale Up / Scale Down 端到端测试报告",
        "",
        f"生成时间：{ts_iso()}",
        "",
        "## 1. 测试目标",
        "",
        "本轮测试验证在 GPU 条件满足时，Dynamo worker 拓扑可以从 2P+4D 缩到 2P+2D 释放 GPU，再扩回 2P+4D 承接高负载。报告同时区分 GPU allocation 与 GPU effective-hour utilization：前者表示占用多少 GPU 时间，后者表示这些 GPU 时间中有多少真正忙于计算。",
        "",
        "## 2. 部署与动作",
        "",
        f"- 初始健康拓扑：prefill={original[PREFILL_DEPLOY]}，decode={original[DECODE_DEPLOY]}。",
        "- 测试拓扑：2 Prefill + 4 Decode。",
        "- Scale down：decode 4 -> 2，prefill 保持 2。",
        "- Scale up：decode 2 -> 4，prefill 保持 2。",
        f"- scale down 窗口释放 GPU：{fmt(release['released_gpu_seconds'])} GPU-seconds，即 {fmt(release['released_gpu_hours'], 4)} GPU-hours。",
        "",
        "## 3. 指标解释",
        "",
        "- Wall Time：一组 measured HTTP 请求中，第一条请求发出到最后一条响应返回的时间。",
        "- req/s：HTTP 200 请求数 / Wall Time，表示用户请求吞吐。",
        "- p50/p95/p99 latency：单请求端到端耗时的 50/95/99 分位。",
        "- user completion tok/s：HTTP response 中用户实际获得的 completion tokens / Wall Time。",
        "- allocated GPU-hours：ready worker GPU 数量按时间积分，代表被占用的 GPU 资源量。",
        "- GPU effective busy hours：`gpu_util_pct / 100 * sample_duration` 的积分，代表实际忙碌 GPU 时间。",
        "- GPU effective-hour utilization：GPU effective busy hours / allocated GPU-hours。这个值越高，表示已分配 GPU 中闲置比例越低，资源使用越有效。",
        "",
        "## 4. HTTP 负载结果",
        "",
        "| phase | requests | success % | wall(s) | req/s | p50 latency(s) | p95 latency(s) | p99 latency(s) | user completion tok/s |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for phase in ["high_before_scale_down", "low_after_scale_down", "high_after_scale_up"]:
        row = summaries.get(phase, {})
        lines.append(
            f"| {phase} | {int(row.get('requests', 0))} | {fmt(row.get('success_pct', 0.0))} | "
            f"{fmt(row.get('wall_s', 0.0))} | {fmt(row.get('req_s', 0.0))} | "
            f"{fmt(row.get('p50_latency_s', 0.0))} | {fmt(row.get('p95_latency_s', 0.0))} | "
            f"{fmt(row.get('p99_latency_s', 0.0))} | {fmt(row.get('user_completion_tps', 0.0))} |"
        )
    lines.extend(
        [
            "",
            "## 5. GPU Effective-Hour 结果",
            "",
            "| phase/window | allocated GPU-hours | busy/effective GPU-hours | idle GPU-hours | effective-hour utilization % | avg GPU util % | max GPU mem MiB |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for phase in ["high_before_scale_down", "low_after_scale_down", "scale_down_hold", "scaled_down_total_window", "high_after_scale_up"]:
        row = gpu_summaries.get(phase, {})
        lines.append(
            f"| {phase} | {fmt(row.get('allocated_gpu_hours', 0.0), 4)} | "
            f"{fmt(row.get('gpu_effective_busy_hours', 0.0), 4)} | {fmt(row.get('gpu_idle_hours', 0.0), 4)} | "
            f"{fmt(row.get('effective_hour_utilization_pct', 0.0))} | {fmt(row.get('avg_gpu_util_pct', 0.0))} | "
            f"{fmt(row.get('max_gpu_mem_mib', 0.0))} |"
        )
    lines.extend(
        [
            "",
            "## 6. Scale Down 释放资源说明",
            "",
            f"本轮 scale down 将 decode worker 从 4 个降到 2 个，释放 2 张 GPU。释放窗口持续 {fmt(release['scaled_down_window_s'])} 秒，折算为 {fmt(release['released_gpu_hours'], 4)} GPU-hours 的 allocation 节省。这个值是资源占用时间的节省；是否转化为生产成本下降，取决于集群调度器是否把这 2 张 GPU 分配给其他任务，或云平台是否按释放后的 GPU allocation 计费。",
            "",
            "## 7. 结论",
            "",
            "本轮测试证明当前部署能够执行可观测的 scale down 和 scale up：scale down 阶段释放 decode GPU allocation，scale up 阶段恢复到 2P+4D 并重新承接高负载。GPU effective-hour utilization 用来解释释放前后已分配 GPU 的有效使用比例：在相同成功率前提下，该比例越高说明闲置越少；allocated GPU-hours 越低说明资源占用越少。",
            "",
            "注意：本脚本使用 Kubernetes deployment scale 作为资源动作，验证真实 pod/GPU allocation 的释放与恢复；它不是最终生产版 controller 全自动策略闭环。生产级闭环还需要把 S2/S3 产生的 idle worker、DCGM busy-time、DGDSA targeted scale down 和 scale-up gating 合并到 controller policy 中。",
            "",
        ]
    )
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
