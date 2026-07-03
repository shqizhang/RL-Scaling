#!/usr/bin/env python3
"""Controller-driven autoscaling E2E for S2/S3/S1.

This test differs from the mechanism matrix: it never calls worker sidecar
action endpoints and never performs strategy scale actions directly. It only
configures the controller, sends the same RL-like signal stream and frontend
traffic to both scenarios, then observes controller status/logs and Kubernetes
replica changes.
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
import urllib.request
from dataclasses import dataclass
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
CONTROLLER_LOCAL = 18081


@dataclass(frozen=True)
class Scenario:
    key: str
    title: str
    role_switch: bool
    consolidation: bool


SCENARIOS = [
    Scenario("baseline", "Baseline: S2/S3 Disabled", False, False),
    Scenario("auto_strategy", "Controller Auto Strategy: S2/S3 Enabled", True, True),
]


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


def controller_env(scenario: Scenario) -> dict[str, str]:
    return {
        "ROLE_SWITCH_ENABLED": str(scenario.role_switch).lower(),
        "CONSOLIDATION_ENABLED": str(scenario.consolidation).lower(),
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
        "K8S_SCALE_FALLBACK_ENABLED": "true",
        "CONTROL_LOOP_INTERVAL": "2",
        "MIN_BATCH_COMPLETION": "0.95",
        "CONSOLIDATION_THRESHOLD": "8",
        "CONSOLIDATION_STABLE_SAMPLES": "1",
        "CONSOLIDATION_MIN_INTERVAL": "5",
        "MAX_CONCURRENT_PER_DECODE": "16",
        "PREFILL_QUEUE_THRESHOLD": "999",
        "DECODE_QUEUE_THRESHOLD": "999",
        "DECODE_IDLE_THRESHOLD": "1.0",
        "PREFILL_IDLE_THRESHOLD": "1.0",
        "MIN_SWITCH_INTERVAL": "10",
        "MIN_PREFILL_REPLICAS": "2",
        "MIN_DECODE_REPLICAS": "2",
    }


def set_controller_env(env: dict[str, str]) -> None:
    args = ["set", "env", "-n", CONTROLLER_NS, f"deploy/{CONTROLLER_DEPLOY}"]
    args.extend(f"{k}={v}" for k, v in env.items())
    kubectl(args, timeout=120)
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


def controller_json(path: str, *, method: str = "GET", body: dict | None = None) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"http://127.0.0.1:{CONTROLLER_LOCAL}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def send_progress(progress: float = 0.9) -> dict:
    return controller_json(
        "/api/v1/signals/sampling_progress",
        method="POST",
        body={"progress": progress, "batch_meta": {"batch_size": 64, "avg_isl": 4096, "avg_osl": 768, "total_tokens": 300000}},
    )


def send_done() -> dict:
    return controller_json(
        "/api/v1/signals/sampling_done",
        method="POST",
        body={"batch_meta": {"batch_size": 64, "avg_isl": 4096, "avg_osl": 768, "total_tokens": 300000}},
    )


def send_batch_complete() -> dict:
    return controller_json("/api/v1/signals/batch_complete", method="POST", body={})


def deploy_replicas(name: str) -> int:
    return scale_e2e.deployment_replicas(name)


def ready_counts() -> tuple[int, int]:
    return scale_e2e.count_ready_by_component()


def sample_cluster(scenario: str, event: str) -> dict:
    p_ready, d_ready = ready_counts()
    return {
        "ts": scale_e2e.now_ts(),
        "iso": ts_iso(),
        "scenario": scenario,
        "event": event,
        "prefill_replicas": deploy_replicas(scale_e2e.PREFILL_DEPLOY),
        "decode_replicas": deploy_replicas(scale_e2e.DECODE_DEPLOY),
        "ready_prefill": p_ready,
        "ready_decode": d_ready,
    }


def wait_decode_replicas(target: int, timeout_s: int = 360) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if deploy_replicas(scale_e2e.DECODE_DEPLOY) == target:
            scale_e2e.wait_deployment(scale_e2e.DECODE_DEPLOY, timeout_s=600)
            return True
        time.sleep(3)
    return False


def capture_logs(out_dir: Path, scenario: str, since_iso: str) -> None:
    log_dir = out_dir / scenario / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    controller = kubectl_text(
        ["logs", "-n", CONTROLLER_NS, "-l", "app=rl-scaling-controller", f"--since-time={since_iso}", "--tail=1200"],
        timeout=60,
    )
    (log_dir / "controller.log").write_text(controller, encoding="utf-8")
    workers = kubectl(["get", "pods", "-n", scale_e2e.NS, "-o", "json"], timeout=60)
    for item in json.loads(workers.stdout).get("items", []):
        name = item.get("metadata", {}).get("name", "")
        labels = item.get("metadata", {}).get("labels", {})
        if labels.get("nvidia.com/dynamo-component") not in {"VllmDecodeWorker", "VllmPrefillWorker"}:
            continue
        proc = kubectl_text(["logs", "-n", scale_e2e.NS, name, f"--since-time={since_iso}", "--tail=800"], timeout=60)
        (log_dir / f"{name}.log").write_text(proc, encoding="utf-8")


def summarize_status(status_rows: list[dict]) -> dict:
    s2 = []
    s3 = []
    states = []
    for row in status_rows:
        body = row.get("status") or {}
        states.append(body.get("state"))
        strategy = body.get("strategy") or {}
        s2.extend(strategy.get("s2_history") or [])
        s3.extend(strategy.get("s3_history") or [])
    return {
        "controller_states": [s for s in states if s],
        "s2_history_count": len(s2),
        "s2_executed_count": sum(1 for item in s2 if item.get("executed")),
        "s3_history_count": len(s3),
        "s3_executed_pairs": sum(int(item.get("executed_pairs") or 0) for item in s3),
        "s3_migrated_requests": sum(int(item.get("migrated_requests") or 0) for item in s3),
        "s3_scaled_down_to": [item.get("scaled_down_to") for item in s3 if item.get("scaled_down_to") is not None],
    }


def run_scenario(s: Scenario, args: argparse.Namespace, out_dir: Path, sampler: scale_e2e.Sampler, events: list[dict]) -> dict:
    sdir = out_dir / s.key
    (sdir / "responses").mkdir(parents=True, exist_ok=True)
    status_rows: list[dict] = []
    requests: list[dict] = []
    phase_windows: dict[str, tuple[float, float]] = {}
    pf_frontend = None
    pf_controller = None
    since_iso = ts_utc_since()

    def event(name: str, **data) -> None:
        row = {"ts": scale_e2e.now_ts(), "iso": ts_iso(), "scenario": s.key, "event": name, **data}
        events.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)

    def status(name: str) -> None:
        try:
            body = controller_json("/api/v1/status")
        except Exception as exc:
            body = {"error": str(exc)}
        row = {"ts": scale_e2e.now_ts(), "iso": ts_iso(), "event": name, "status": body}
        status_rows.append(row)
        (sdir / "controller_status.jsonl").open("a", encoding="utf-8").write(json.dumps(row, ensure_ascii=False) + "\n")

    try:
        set_controller_env(controller_env(s))
        event("controller_configured", role_switch=s.role_switch, consolidation=s.consolidation)
        scale_e2e.scale_deployment(scale_e2e.OLD_DECODE_DEPLOY, 0)
        scale_e2e.scale_deployment(scale_e2e.OLD_PREFILL_DEPLOY, 0)
        scale_e2e.scale_deployment(scale_e2e.PREFILL_DEPLOY, 2)
        scale_e2e.scale_deployment(scale_e2e.DECODE_DEPLOY, 4)
        scale_e2e.wait_deployment(scale_e2e.PREFILL_DEPLOY, timeout_s=900)
        scale_e2e.wait_deployment(scale_e2e.DECODE_DEPLOY, timeout_s=900)
        scale_e2e.wait_ready_counts(prefill=2, decode=4)
        events.append(sample_cluster(s.key, "topology_ready_2p4d"))

        pf_frontend = scale_e2e.start_port_forward()
        pf_controller = start_controller_pf()
        status("initial")

        event("controller_sampling_progress", response=send_progress(0.9))
        status("after_sampling_progress")
        time.sleep(6)

        phase = "high_before"
        start = scale_e2e.now_ts()
        rows = scale_e2e.run_wave(f"{s.key}_{phase}", args.high_count, args.high_concurrency, 160, args.high_max_tokens, sdir)
        end = scale_e2e.now_ts()
        requests.extend(rows)
        phase_windows[phase] = (start, end)
        event(f"{phase}_done", **scale_e2e.summarize_wave(rows))
        status(f"after_{phase}")

        event("controller_tail_progress", response=send_progress(0.95))
        phase = "low_tail"
        start = scale_e2e.now_ts()
        rows = scale_e2e.run_wave(f"{s.key}_{phase}", args.low_count, args.low_concurrency, 120, args.low_max_tokens, sdir)
        end = scale_e2e.now_ts()
        requests.extend(rows)
        phase_windows[phase] = (start, end)
        event(f"{phase}_done", **scale_e2e.summarize_wave(rows))
        time.sleep(args.tail_observe_seconds)
        status(f"after_{phase}")
        events.append(sample_cluster(s.key, "after_low_tail"))

        down_observed = deploy_replicas(scale_e2e.DECODE_DEPLOY) < 4
        event("auto_scale_down_observed", observed=down_observed, decode_replicas=deploy_replicas(scale_e2e.DECODE_DEPLOY))

        try:
            event("controller_batch_complete", response=send_batch_complete())
        except Exception as exc:
            event("controller_batch_complete_error", error=str(exc))
        time.sleep(2)
        event("controller_sampling_done_recovery", response=send_done())
        up_observed = wait_decode_replicas(4, timeout_s=args.scale_up_wait_seconds)
        if up_observed:
            scale_e2e.wait_ready_counts(prefill=2, decode=4, timeout_s=900)
            event("recovery_ready_settle_start", seconds=args.recovery_settle_seconds)
            time.sleep(args.recovery_settle_seconds)
        events.append(sample_cluster(s.key, "after_recovery_signal"))
        status("after_recovery_signal")
        event("auto_scale_up_observed", observed=up_observed, decode_replicas=deploy_replicas(scale_e2e.DECODE_DEPLOY))

        phase = "high_after"
        start = scale_e2e.now_ts()
        rows = scale_e2e.run_wave(f"{s.key}_{phase}", args.high_count, args.high_concurrency, 160, args.high_max_tokens, sdir)
        end = scale_e2e.now_ts()
        requests.extend(rows)
        phase_windows[phase] = (start, end)
        event(f"{phase}_done", **scale_e2e.summarize_wave(rows))
        status(f"after_{phase}")

        scale_e2e.write_csv(
            sdir / "requests.csv",
            requests,
            ["phase", "idx", "start_ts", "end_ts", "http_code", "latency_s", "prompt_tokens", "completion_tokens", "total_tokens", "error"],
        )
        capture_logs(out_dir, s.key, since_iso)
        wave = {name: scale_e2e.summarize_wave([r for r in requests if r["phase"].endswith(name)]) for name in phase_windows}
        gpu = {name: scale_e2e.summarize_gpu(sampler.rows, w[0], w[1], args.sample_interval) for name, w in phase_windows.items()}
        controller_summary = summarize_status(status_rows)
        row = {
            "scenario": s.key,
            "title": s.title,
            "role_switch_enabled": s.role_switch,
            "consolidation_enabled": s.consolidation,
            "scale_down_observed": down_observed,
            "scale_up_observed": up_observed,
            "s2_executed_count": controller_summary["s2_executed_count"],
            "s3_executed_pairs": controller_summary["s3_executed_pairs"],
            "s3_migrated_requests": controller_summary["s3_migrated_requests"],
            "s3_scaled_down_to": ";".join(map(str, controller_summary["s3_scaled_down_to"])),
            "high_before_success_pct": wave["high_before"]["success_pct"],
            "high_before_wall_s": wave["high_before"]["wall_s"],
            "high_before_req_s": wave["high_before"]["req_s"],
            "high_before_p95_s": wave["high_before"]["p95_latency_s"],
            "high_before_user_tps": wave["high_before"]["user_completion_tps"],
            "low_tail_success_pct": wave["low_tail"]["success_pct"],
            "low_tail_wall_s": wave["low_tail"]["wall_s"],
            "low_tail_req_s": wave["low_tail"]["req_s"],
            "low_tail_p95_s": wave["low_tail"]["p95_latency_s"],
            "low_tail_user_tps": wave["low_tail"]["user_completion_tps"],
            "high_after_success_pct": wave["high_after"]["success_pct"],
            "high_after_wall_s": wave["high_after"]["wall_s"],
            "high_after_req_s": wave["high_after"]["req_s"],
            "high_after_p95_s": wave["high_after"]["p95_latency_s"],
            "high_after_user_tps": wave["high_after"]["user_completion_tps"],
            "low_tail_gpu_effective_hours": gpu["low_tail"].get("gpu_effective_busy_hours", 0.0),
            "low_tail_gpu_idle_hours": gpu["low_tail"].get("gpu_idle_hours", 0.0),
            "low_tail_effective_util_pct": gpu["low_tail"].get("effective_hour_utilization_pct", 0.0),
        }
        (sdir / "summary.json").write_text(json.dumps({"scenario": row, "controller": controller_summary, "gpu": gpu}, indent=2, ensure_ascii=False), encoding="utf-8")
        return row
    finally:
        if pf_frontend:
            pf_frontend.terminate()
        if pf_controller:
            pf_controller.terminate()


def generate_report(out_dir: Path, rows: list[dict]) -> None:
    def fmt(value, digits=2):
        try:
            return f"{float(value):.{digits}f}"
        except Exception:
            return str(value)

    baseline = next((r for r in rows if r["scenario"] == "baseline"), None)
    auto = next((r for r in rows if r["scenario"] == "auto_strategy"), None)
    lines = [
        "# Controller 自动策略闭环 E2E 测试报告",
        "",
        f"生成时间：{ts_iso()}",
        "",
        "## 1. 测试目标",
        "",
        "本轮测试验证标准 CI 镜像部署后的 controller 是否能在相同 signal 与 frontend workload 下自主决策。测试脚本只负责配置开关、发送相同 RL-like signals、发送真实 Dynamo frontend 请求和采集数据；不调用 worker sidecar action endpoint，也不直接执行策略 scale down/up。",
        "",
        "Baseline 关闭 S2/S3；Auto Strategy 同时开启 S2/S3，并启用当前测试集群需要的 K8s Deployment scale fallback。两组均从 2P+4D 开始，使用相同 high -> low/tail -> recovery high 流量与相同 controller signal。",
        "",
        "## 2. 数据来源与统一口径",
        "",
        "- HTTP timing：`requests.csv`，来自 Dynamo frontend `/v1/chat/completions` 的端到端请求。",
        "- Controller 自动决策：`controller_status.jsonl` 与 `logs/controller.log`，包括 `s2_history`、`s3_history`、state machine state 和 controller log line。",
        "- Scale 结果：Kubernetes Deployment replicas / ready worker count，由脚本在关键节点采样，记录到 `events.csv`。",
        "- GPU effective hour：同一采样器、同一 `nvidia-smi` 来源，按相同 sample interval 计算。",
        "",
        "## 3. 触发机制与结果",
        "",
        "| 场景 | S2 | S3 | 自动 S3 pairs | migrated requests | scale down observed | scale up observed |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['title']} | {row['role_switch_enabled']} | {row['consolidation_enabled']} | "
            f"{row['s3_executed_pairs']} | {row['s3_migrated_requests']} | {row['scale_down_observed']} | {row['scale_up_observed']} |"
        )
    lines.extend([
        "",
        "## 4. 统一指标对比",
        "",
        "| 场景 | high before success % | high before wall(s) | high before req/s | low success % | low wall(s) | low req/s | high after success % | high after wall(s) | high after req/s | low GPU effective h | low GPU idle h | low GPU util % |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for row in rows:
        lines.append(
            f"| {row['title']} | {fmt(row['high_before_success_pct'])} | {fmt(row['high_before_wall_s'])} | "
            f"{fmt(row['high_before_req_s'])} | {fmt(row['low_tail_success_pct'])} | {fmt(row['low_tail_wall_s'])} | "
            f"{fmt(row['low_tail_req_s'])} | {fmt(row['high_after_success_pct'])} | {fmt(row['high_after_wall_s'])} | "
            f"{fmt(row['high_after_req_s'])} | {fmt(row['low_tail_gpu_effective_hours'], 5)} | "
            f"{fmt(row['low_tail_gpu_idle_hours'], 5)} | {fmt(row['low_tail_effective_util_pct'])} |"
        )
    if baseline and auto:
        def pct_change(key: str, higher_better: bool = True) -> str:
            b = float(baseline.get(key) or 0.0)
            a = float(auto.get(key) or 0.0)
            if b == 0:
                return "n/a"
            value = ((a - b) / b * 100.0) if higher_better else ((b - a) / b * 100.0)
            return f"{value:.2f}%"

        lines.extend([
            "",
            "## 5. 因果分析",
            "",
            f"- 自动策略只在 Auto Strategy 场景打开，因此若 `s3_executed_pairs > 0` 且 `scale_down_observed=True`，因果链为：controller 接收 progress signal -> batch completion gate 满足 -> metrics collector 发现 decode tail source/target -> S3 controller 记录 decision/history -> controller patch Deployment scale -> ready decode replicas 降低。",
            f"- low/tail 阶段 GPU idle/effective hour 用同一采样器和同一窗口计算。Baseline low GPU idle hours 为 {fmt(baseline['low_tail_gpu_idle_hours'], 5)}，Auto Strategy 为 {fmt(auto['low_tail_gpu_idle_hours'], 5)}；差异必须结合是否发生 scale down 解读。",
            f"- high recovery 阶段用于验证 scale up 后服务可恢复。Auto Strategy high-after success 为 {fmt(auto['high_after_success_pct'])}%，req/s 相对 Baseline 变化 {pct_change('high_after_req_s')}。",
            f"- low/tail req/s 相对 Baseline 变化 {pct_change('low_tail_req_s')}，p95 latency 变化 {pct_change('low_tail_p95_s', higher_better=False)}。这些指标与 GPU 释放一起判断策略是否在不破坏请求成功率的前提下降低空闲 allocation。",
            "",
        ])
    lines.extend([
        "## 6. Artifact Index",
        "",
        "| 文件 | 含义 |",
        "|---|---|",
        "| `events.csv` | controller signal、K8s replicas、scale observed 事件时间线 |",
        "| `gpu_samples.csv` | 原始 GPU utilization/memory samples |",
        "| `<scenario>/requests.csv` | 每条 HTTP 请求 timing、token usage、错误 |",
        "| `<scenario>/controller_status.jsonl` | controller `/api/v1/status` 原始采样 |",
        "| `<scenario>/logs/controller.log` | controller 自动决策日志 |",
        "| `<scenario>/summary.json` | 单场景机器可读汇总 |",
    ])
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def generate_report(out_dir: Path, rows: list[dict]) -> None:
    def fmt(value, digits=2):
        try:
            return f"{float(value):.{digits}f}"
        except Exception:
            return str(value)

    def pct_change(baseline: dict, auto: dict, key: str, higher_better: bool = True) -> str:
        b = float(baseline.get(key) or 0.0)
        a = float(auto.get(key) or 0.0)
        if b == 0:
            return "n/a"
        value = ((a - b) / b * 100.0) if higher_better else ((b - a) / b * 100.0)
        return f"{value:.2f}%"

    baseline = next((r for r in rows if r["scenario"] == "baseline"), None)
    auto = next((r for r in rows if r["scenario"] == "auto_strategy"), None)
    lines = [
        "# Controller 自动策略闭环 E2E 测试报告",
        "",
        f"生成时间：{ts_iso()}",
        "",
        "## 1. 测试目标",
        "",
        "本轮测试验证标准 CI 镜像部署后的 controller 是否能够在相同 signal 与 frontend workload 下自主决策。测试脚本只负责配置开关、发送相同 RL-like signals、发送真实 Dynamo frontend 请求并采集数据；脚本不调用 worker sidecar action endpoint，也不直接执行策略 scale down/up。",
        "",
        "Baseline 关闭 S2/S3；Auto Strategy 同时开启 S2/S3，并启用当前测试集群需要的 K8s Deployment scale fallback。两组均从 2P+4D 开始，使用相同的 high -> low/tail -> recovery high 流量与相同 controller signal。",
        "",
        "## 2. 数据来源与统一口径",
        "",
        "- HTTP timing：`<scenario>/requests.csv`，来自 Dynamo frontend `/v1/chat/completions` 的端到端请求。",
        "- Controller 自动决策：`<scenario>/controller_status.jsonl` 与 `<scenario>/logs/controller.log`，包括 state machine state、`s2_history`、`s3_history` 和 controller log line。",
        "- Scale 结果：Kubernetes Deployment replicas / ready worker count，由脚本在关键节点采样并记录到 `events.csv`。",
        "- GPU effective hour：同一个 `nvidia-smi` 采样器、同一个 sample interval 计算，保证 Baseline 与 Auto Strategy 的比较口径一致。",
        "",
        "## 3. 指标解释",
        "",
        "- Wall Time：某个 phase 内第一条请求开始发送到最后一条请求结束之间的端到端时间，包含排队、prefill、decode、网络与客户端等待。越短表示这一阶段整体完成得越快。",
        "- req/s：成功 HTTP 请求数除以该 phase 的 Wall Time，表示 Dynamo frontend 对用户请求的端到端完成吞吐，不是 engine 内部 token batch 速率。",
        "- p95 latency：该 phase 内所有请求 latency 的 95 分位，表示 95% 请求能在该时间内完成，用于观察尾延迟。",
        "- user completion Token/s：成功请求产生的用户可见 completion tokens 除以 Wall Time，表示端到端用户可见生成吞吐。",
        "- GPU effective busy hours：按 GPU util% 对每次采样积分得到的有效忙碌 GPU 时间，单位为小时；它越高表示分配出去的 GPU 中实际被计算利用的时间越多。",
        "- GPU idle hours：allocated GPU hours - effective busy hours，表示已分配但未被有效利用的 GPU 时间；在可缩容阶段越低越好。",
        "- effective hour utilization：effective busy hours / allocated GPU hours。它衡量已分配 GPU 的有效使用比例；当 scale down 释放闲置 GPU 后，即使总 busy time 下降，该比例也更能反映闲置减少。",
        "",
        "## 4. 触发机制与结果",
        "",
        "| 场景 | S2 enabled | S3 enabled | 自动 S2 executed | 自动 S3 pairs | migrated requests | scale down observed | scale up observed | scaled down to |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for row in rows:
        lines.append(
            f"| {row['title']} | {row['role_switch_enabled']} | {row['consolidation_enabled']} | "
            f"{row['s2_executed_count']} | {row['s3_executed_pairs']} | {row['s3_migrated_requests']} | "
            f"{row['scale_down_observed']} | {row['scale_up_observed']} | {row['s3_scaled_down_to']} |"
        )

    lines.extend([
        "",
        "## 5. 统一指标对比",
        "",
        "| 场景 | high-before success % | high-before wall(s) | high-before req/s | high-before Token/s | low-tail success % | low-tail wall(s) | low-tail req/s | low-tail p95(s) | high-after success % | high-after wall(s) | high-after req/s | low GPU effective h | low GPU idle h | low GPU util % |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for row in rows:
        lines.append(
            f"| {row['title']} | {fmt(row['high_before_success_pct'])} | {fmt(row['high_before_wall_s'])} | "
            f"{fmt(row['high_before_req_s'])} | {fmt(row['high_before_user_tps'])} | "
            f"{fmt(row['low_tail_success_pct'])} | {fmt(row['low_tail_wall_s'])} | {fmt(row['low_tail_req_s'])} | "
            f"{fmt(row['low_tail_p95_s'])} | {fmt(row['high_after_success_pct'])} | {fmt(row['high_after_wall_s'])} | "
            f"{fmt(row['high_after_req_s'])} | {fmt(row['low_tail_gpu_effective_hours'], 5)} | "
            f"{fmt(row['low_tail_gpu_idle_hours'], 5)} | {fmt(row['low_tail_effective_util_pct'])} |"
        )

    if baseline and auto:
        lines.extend([
            "",
            "## 6. 因果链路与对比分析",
            "",
            "- Baseline 与 Auto Strategy 使用同一拓扑起点、同一 workload、同一 signal 序列和同一 GPU 采样器，因此差异主要来自 S2/S3 controller 开关是否允许策略闭环执行。",
            "- 如果 Auto Strategy 中 `s3_executed_pairs > 0` 且 `scale_down_observed=True`，则因果链路为：controller 接收 progress signal -> batch completion gate 满足 -> metrics collector 发现 decode tail source/target -> S3 controller 记录 decision/history -> controller patch Deployment scale -> ready decode replicas 降低。",
            f"- low-tail 阶段 req/s 相对 Baseline 变化 {pct_change(baseline, auto, 'low_tail_req_s')}；p95 latency 改善 {pct_change(baseline, auto, 'low_tail_p95_s', higher_better=False)}。这两个指标说明用户侧吞吐与尾延迟是否在缩容窗口内保持稳定。",
            f"- low-tail GPU idle hours：Baseline {fmt(baseline['low_tail_gpu_idle_hours'], 5)}，Auto Strategy {fmt(auto['low_tail_gpu_idle_hours'], 5)}；GPU effective hour utilization：Baseline {fmt(baseline['low_tail_effective_util_pct'])}%，Auto Strategy {fmt(auto['low_tail_effective_util_pct'])}%。这组数据用于判断资源释放后，已分配 GPU 的闲置比例是否下降。",
            f"- recovery high 阶段用于验证 scale up 后服务恢复。Auto Strategy high-after success 为 {fmt(auto['high_after_success_pct'])}%，req/s 相对 Baseline 变化 {pct_change(baseline, auto, 'high_after_req_s')}。",
            "- 如果 GPU effective busy hours 下降但 idle hours 同时下降，需要结合 replicas 变化解释：这通常表示 controller 释放了部分长期空闲 GPU，系统总 GPU allocation 变小；真正应该关注的是剩余 GPU 的 effective hour utilization 是否提高，以及 high-after 是否能够恢复吞吐。",
        ])

    lines.extend([
        "",
        "## 7. Artifact Index",
        "",
        "| 文件 | 含义 |",
        "|---|---|",
        "| `matrix.csv` | 每个场景的汇总指标与策略执行结果 |",
        "| `events.csv` | controller signal、K8s replicas、scale observed 事件时间线 |",
        "| `gpu_samples.csv` | 原始 GPU utilization/memory samples |",
        "| `<scenario>/requests.csv` | 每条 HTTP 请求 timing、token usage、错误信息 |",
        "| `<scenario>/controller_status.jsonl` | controller `/api/v1/status` 原始采样 |",
        "| `<scenario>/logs/controller.log` | controller 自动决策日志 |",
        "| `<scenario>/summary.json` | 单场景机器可读汇总 |",
    ])
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample-interval", type=float, default=2.0)
    parser.add_argument("--high-count", type=int, default=36)
    parser.add_argument("--high-concurrency", type=int, default=6)
    parser.add_argument("--high-max-tokens", type=int, default=768)
    parser.add_argument("--low-count", type=int, default=16)
    parser.add_argument("--low-concurrency", type=int, default=4)
    parser.add_argument("--low-max-tokens", type=int, default=768)
    parser.add_argument("--tail-observe-seconds", type=int, default=20)
    parser.add_argument("--scale-up-wait-seconds", type=int, default=360)
    parser.add_argument("--recovery-settle-seconds", type=int, default=90)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    out_dir = Path(args.out) if args.out else HERE / "reports" / f"controller-auto-strategy-e2e-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir.mkdir(parents=True, exist_ok=True)
    events: list[dict] = []
    rows: list[dict] = []
    stop = threading.Event()
    sampler = scale_e2e.Sampler(out_dir=out_dir, interval=args.sample_interval, stop=stop, rows=[], node_nvidia_smi=True)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    sampler_thread.start()
    original = {
        scale_e2e.PREFILL_DEPLOY: deploy_replicas(scale_e2e.PREFILL_DEPLOY),
        scale_e2e.DECODE_DEPLOY: deploy_replicas(scale_e2e.DECODE_DEPLOY),
    }
    try:
        for scenario in SCENARIOS:
            row = run_scenario(scenario, args, out_dir, sampler, events)
            rows.append(row)
            write_csv(out_dir / "matrix.csv", rows, list(rows[0].keys()))
            write_csv(out_dir / "events.csv", events, sorted({k for event in events for k in event.keys()}))
            scale_e2e.write_csv(out_dir / "gpu_samples.csv", sampler.rows, ["ts", "iso", "pod", "component", "gpu_util_pct", "gpu_mem_mib", "allocated_worker_gpus"])
            generate_report(out_dir, rows)
        print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    finally:
        try:
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
