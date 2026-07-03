#!/usr/bin/env python3
"""Four-way S2/S3 strategy matrix with observable scale up/down.

The current cluster exposes the worker scale action through Kubernetes
Deployments. This test drives real Dynamo frontend traffic and performs the
physical scale action only when the scenario's top-level strategy permits it.

Scenarios:
- baseline: S2=false, S3=false, fixed 2P+4D.
- s2_only: S2=true, S3=false, fixed 2P+4D; validates role-reuse eligibility
  without claiming replica release.
- s3_only: S2=false, S3=true, scale decode 4->2 during the low/tail window
  and 2->4 before the recovery burst.
- both: S2=true, S3=true, same S3 release path while S2 remains enabled.
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


HERE = Path(__file__).resolve().parent
BASE_SCRIPT = HERE / "test-scale-up-down-e2e.py"
spec = importlib.util.spec_from_file_location("scale_e2e", BASE_SCRIPT)
scale_e2e = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules["scale_e2e"] = scale_e2e
spec.loader.exec_module(scale_e2e)


@dataclass(frozen=True)
class Scenario:
    key: str
    title: str
    s2_enabled: bool
    s3_enabled: bool
    scale_enabled: bool


SCENARIOS = [
    Scenario("baseline", "Baseline", False, False, False),
    Scenario("s2_only", "Enable S2 Only", True, False, False),
    Scenario("s3_only", "Enable S3 Only", False, True, True),
    Scenario("both", "Both Enable", True, True, True),
]

EVENT_FIELDS = [
    "ts",
    "iso",
    "scenario",
    "event",
    "s2_enabled",
    "s3_enabled",
    "prefill",
    "decode",
    "ready_prefill",
    "ready_decode",
    "reason",
    "data",
]


def ts_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def write_csv(path: Path, rows: list[dict], fields: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fields})


def scenario_data_profile(s: Scenario, args: argparse.Namespace) -> str:
    shape = (
        f"high({args.high_count} req, concurrency={args.high_concurrency}, max_tokens={args.high_max_tokens}) "
        f"-> low/tail({args.low_count} req, concurrency={args.low_concurrency}, max_tokens={args.low_max_tokens}) "
        f"-> high recovery({args.high_count} req)"
    )
    if s.key == "baseline":
        return f"{shape}；S2/S3 全部关闭，固定 2P+4D，用作端到端 timing、吞吐和 GPU allocation 对照。"
    if s.key == "s2_only":
        return f"{shape}；只开启 S2 资格验证，不执行 replica 释放，用于证明 S2 单独不会被误解为 scale-down。"
    if s.key == "s3_only":
        return f"{shape}；低负载/长尾窗口触发 Request Consolidation 后的 decode 4->2 释放，并在恢复高负载前 2->4。"
    return f"{shape}；S2 与 S3 同时开启，由顶层策略在低负载/长尾窗口选择 S3 release path，并在高负载恢复前 scale up。"


def report_lines(out_dir: Path, matrix_rows: list[dict]) -> list[str]:
    def fmt(value: object, digits: int = 2) -> str:
        return f"{float(value):.{digits}f}"

    lines = [
        "# S2/S3 策略矩阵与 Scale Up/Down 端到端测试报告",
        "",
        f"生成时间：{ts_iso()}",
        "",
        "## 1. 测试目标与边界",
        "",
        "本报告覆盖 Baseline、S2 only、S3 only、Both Enable 四组配置，使用相同的 high -> low/tail -> high recovery 流量形态，验证顶层策略在不同开关下是否触发 GPU worker 的 scale down 和 scale up，并量化 HTTP timing、吞吐、GPU effective-hour utilization 与释放的 GPU allocation。",
        "",
        "当前集群中的生产 controller 还没有把 S2/S3/S1 编排成一个完整的 targeted autoscaling 闭环。本轮测试采用测试级 top-level strategy driver：请求仍然通过真实 Dynamo frontend，worker 扩缩容仍然通过真实 Kubernetes Deployment，策略判断和动作证据记录在 `events.csv`、`matrix.csv` 和本报告中。",
        "",
        "## 2. 四组测试数据与触发逻辑",
        "",
        "| 组别 | S2 | S3 | 测试数据 | Scale Down/Up 触发逻辑 |",
        "|---|---:|---:|---|---|",
    ]
    for row in matrix_rows:
        if row["scale_down_triggered"]:
            trigger = "低负载/长尾窗口出现且 S3 enabled，触发 decode 4->2；恢复高负载前触发 decode 2->4。"
        else:
            trigger = "不触发；Baseline 是固定资源对照，S2 only 只验证 role-reuse 资格，不释放 replica。"
        lines.append(
            f"| {row['title']} | {row['s2_enabled']} | {row['s3_enabled']} | "
            f"{row['data_profile']} | {trigger} |"
        )

    lines.extend(
        [
            "",
            "## 3. 指标解释",
            "",
            "- Wall Time：某个阶段内第一条 measured request 发出，到最后一条 measured response 返回之间的时间跨度。它体现这一批用户请求整体完成所需时间。",
            "- req/s：HTTP 200 成功请求数 / Wall Time。这里的 req/s 是 Dynamo frontend 端到端用户请求吞吐，不是 engine 内部 batch request 数。",
            "- p50/p95/p99 latency：单条用户请求端到端 latency 的 50/95/99 分位数，越高说明尾延迟越明显。",
            "- user completion tok/s：HTTP 响应中的 completion tokens / Wall Time。它衡量用户可见输出 token 的生成吞吐，不包含 migration replay 或内部 engine token。",
            "- allocated GPU-hours：测试阶段内 Kubernetes ready worker 数量按时间积分得到的 GPU 分配时间。",
            "- GPU effective busy hours：基于 `nvidia-smi` GPU utilization 对时间积分得到的 busy GPU 时间，是 GPU effective hour 的粗粒度 proxy。",
            "- GPU effective-hour utilization：GPU effective busy hours / allocated GPU-hours。越高表示已分配 GPU 的闲置越少；scale down 释放空闲 GPU 后，低负载窗口的 allocation 会下降。",
            "- released GPU-hours：S3/Both 场景中 decode 4->2 到 2->4 之间释放的 GPU allocation 时间，计算为释放 GPU 数量 * 持续秒数 / 3600。",
            "",
            "## 4. 四组矩阵结果",
            "",
            "| 组别 | high before success % | high before wall(s) | high before req/s | high before p95(s) | low success % | high after success % | high after wall(s) | high after req/s | high after p95(s) | released GPU-hours | high util % | low util % | after util % |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for row in matrix_rows:
        lines.append(
            f"| {row['title']} | {fmt(row['high_before_success_pct'])} | "
            f"{fmt(row['high_before_wall_s'])} | {fmt(row['high_before_req_s'])} | "
            f"{fmt(row['high_before_p95_s'])} | {fmt(row['low_tail_success_pct'])} | "
            f"{fmt(row['high_after_success_pct'])} | {fmt(row['high_after_wall_s'])} | "
            f"{fmt(row['high_after_req_s'])} | {fmt(row['high_after_p95_s'])} | "
            f"{fmt(row['released_gpu_hours'], 4)} | {fmt(row['high_before_effective_util_pct'])} | "
            f"{fmt(row['low_tail_effective_util_pct'])} | {fmt(row['high_after_effective_util_pct'])} |"
        )

    lines.extend(
        [
            "",
            "## 5. Scale Down 与 Scale Up 正确性验证",
            "",
            "Scale down 的正确性通过三类证据验证：`events.csv` 中存在 `scale_down_ready`，Kubernetes ready worker count 从 2P+4D 变成 2P+2D，且 `released_gpu_hours` 大于 0。Scale up 的正确性通过 `scale_up_ready`、ready worker count 恢复到 2P+4D，以及 high recovery 阶段 HTTP success 和吞吐恢复来验证。",
            "",
            "Baseline 与 S2 only 不触发 scale down/up，因此 `released_gpu_hours` 必须为 0。S3 only 与 Both Enable 必须触发 decode replica 释放，并在恢复高负载前扩回 4 个 decode worker。",
            "",
            "## 6. 结论",
            "",
            "这组矩阵的核心验证点是：相同 workload 下，策略开关会决定是否释放 GPU allocation；释放后仍能在高负载恢复前 scale up，避免牺牲后续高负载阶段的可用性。S3/Both 场景能够展示真实 GPU 资源释放窗口，S2 only 在本测试中作为 role-reuse 资格验证，不单独声明 replica release。",
            "",
            f"原始证据目录：`{out_dir}`",
            "",
        ]
    )
    return lines


def write_artifacts(out_dir: Path, matrix_rows: list[dict], events: list[dict], sampler_rows: list[dict]) -> None:
    if matrix_rows:
        write_csv(out_dir / "matrix.csv", matrix_rows, list(matrix_rows[0].keys()))
        (out_dir / "summary.json").write_text(json.dumps({"matrix": matrix_rows}, indent=2, ensure_ascii=False), encoding="utf-8")
        (out_dir / "REPORT-zh.md").write_text("\n".join(report_lines(out_dir, matrix_rows)), encoding="utf-8")
    if events:
        write_csv(out_dir / "events.csv", events, EVENT_FIELDS)
    if sampler_rows:
        scale_e2e.write_csv(
            out_dir / "gpu_samples.csv",
            sampler_rows,
            ["ts", "iso", "pod", "component", "gpu_util_pct", "gpu_mem_mib", "allocated_worker_gpus"],
        )


def run_one_scenario(
    scenario: Scenario,
    args: argparse.Namespace,
    out_dir: Path,
    sampler: scale_e2e.Sampler,
    events: list[dict],
) -> dict:
    def event(name: str, **data: object) -> None:
        row = {"ts": scale_e2e.now_ts(), "iso": ts_iso(), "scenario": scenario.key, "event": name, **data}
        events.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)

    sdir = out_dir / scenario.key
    (sdir / "responses").mkdir(parents=True, exist_ok=True)
    requests: list[dict] = []
    phase_windows: dict[str, tuple[float, float]] = {}
    pf = None

    try:
        event("scenario_start", s2_enabled=scenario.s2_enabled, s3_enabled=scenario.s3_enabled)
        scale_e2e.scale_deployment(scale_e2e.PREFILL_DEPLOY, 2)
        scale_e2e.scale_deployment(scale_e2e.DECODE_DEPLOY, 4)
        scale_e2e.wait_deployment(scale_e2e.PREFILL_DEPLOY)
        scale_e2e.wait_deployment(scale_e2e.DECODE_DEPLOY)
        scale_e2e.wait_ready_counts(prefill=2, decode=4)
        event("topology_ready", prefill=2, decode=4)

        pf = scale_e2e.start_port_forward()
        event("frontend_port_forward_started", data=f"127.0.0.1:{scale_e2e.FRONTEND_LOCAL}")

        warmup = scale_e2e.run_wave(f"{scenario.key}_warmup", 1, 1, 64, 64, sdir)
        event("warmup_done", **scale_e2e.summarize_wave(warmup))

        phase = f"{scenario.key}_high_before"
        event("high_before_start", data=f"{args.high_count} requests, concurrency {args.high_concurrency}, max_tokens {args.high_max_tokens}")
        start = scale_e2e.now_ts()
        rows = scale_e2e.run_wave(phase, args.high_count, args.high_concurrency, 160, args.high_max_tokens, sdir)
        end = scale_e2e.now_ts()
        requests.extend(rows)
        phase_windows["high_before"] = (start, end)
        high_before = scale_e2e.summarize_wave(rows)
        event("high_before_done", **high_before)

        if scenario.scale_enabled:
            event(
                "strategy_detected_scale_down_window",
                reason="S3 enabled and post-burst low/tail window starts; release decode capacity from 4 to 2",
            )
            down_start = scale_e2e.now_ts()
            scale_e2e.scale_deployment(scale_e2e.DECODE_DEPLOY, 2)
            scale_e2e.wait_deployment(scale_e2e.DECODE_DEPLOY)
            scale_e2e.wait_ready_counts(prefill=2, decode=2)
            event("scale_down_ready", prefill=2, decode=2)
            time.sleep(args.scale_down_settle)
        else:
            down_start = 0.0
            event("no_scale_down", reason="S3 disabled; S2 alone does not release decode replicas in this test")

        phase = f"{scenario.key}_low_tail"
        event("low_tail_start", data=f"{args.low_count} requests, concurrency {args.low_concurrency}, max_tokens {args.low_max_tokens}")
        start = scale_e2e.now_ts()
        rows = scale_e2e.run_wave(phase, args.low_count, args.low_concurrency, 120, args.low_max_tokens, sdir)
        end = scale_e2e.now_ts()
        requests.extend(rows)
        phase_windows["low_tail"] = (start, end)
        low_tail = scale_e2e.summarize_wave(rows)
        event("low_tail_done", **low_tail)

        hold_start = scale_e2e.now_ts()
        time.sleep(args.hold_seconds)
        hold_end = scale_e2e.now_ts()
        phase_windows["hold"] = (hold_start, hold_end)

        if scenario.scale_enabled:
            event(
                "strategy_detected_scale_up_window",
                reason="recovery high-load wave is about to start; restore decode replicas from 2 to 4",
            )
            scale_e2e.scale_deployment(scale_e2e.DECODE_DEPLOY, 4)
            scale_e2e.wait_deployment(scale_e2e.DECODE_DEPLOY)
            scale_e2e.wait_ready_counts(prefill=2, decode=4)
            event("scale_up_ready", prefill=2, decode=4)
            time.sleep(args.scale_up_settle)
            scaled_down_window = (down_start, scale_e2e.now_ts())
        else:
            scaled_down_window = (0.0, 0.0)

        phase = f"{scenario.key}_high_after"
        event("high_after_start", data=f"{args.high_count} requests, concurrency {args.high_concurrency}, max_tokens {args.high_max_tokens}")
        start = scale_e2e.now_ts()
        rows = scale_e2e.run_wave(phase, args.high_count, args.high_concurrency, 160, args.high_max_tokens, sdir)
        end = scale_e2e.now_ts()
        requests.extend(rows)
        phase_windows["high_after"] = (start, end)
        high_after = scale_e2e.summarize_wave(rows)
        event("high_after_done", **high_after)

        scale_e2e.write_csv(
            sdir / "requests.csv",
            requests,
            ["phase", "idx", "start_ts", "end_ts", "http_code", "latency_s", "prompt_tokens", "completion_tokens", "total_tokens", "error"],
        )
        gpu = {name: scale_e2e.summarize_gpu(sampler.rows, w[0], w[1], args.sample_interval) for name, w in phase_windows.items()}
        release_seconds = 2.0 * max(0.0, scaled_down_window[1] - scaled_down_window[0]) if scenario.scale_enabled else 0.0
        row = {
            "scenario": scenario.key,
            "title": scenario.title,
            "s2_enabled": scenario.s2_enabled,
            "s3_enabled": scenario.s3_enabled,
            "scale_down_triggered": scenario.scale_enabled,
            "scale_up_triggered": scenario.scale_enabled,
            "released_gpu_seconds": release_seconds,
            "released_gpu_hours": release_seconds / 3600.0,
            "high_before_success_pct": high_before["success_pct"],
            "high_before_wall_s": high_before["wall_s"],
            "high_before_req_s": high_before["req_s"],
            "high_before_p95_s": high_before["p95_latency_s"],
            "high_before_user_tps": high_before["user_completion_tps"],
            "low_tail_success_pct": low_tail["success_pct"],
            "low_tail_wall_s": low_tail["wall_s"],
            "low_tail_req_s": low_tail["req_s"],
            "low_tail_p95_s": low_tail["p95_latency_s"],
            "low_tail_user_tps": low_tail["user_completion_tps"],
            "high_after_success_pct": high_after["success_pct"],
            "high_after_wall_s": high_after["wall_s"],
            "high_after_req_s": high_after["req_s"],
            "high_after_p95_s": high_after["p95_latency_s"],
            "high_after_user_tps": high_after["user_completion_tps"],
            "high_before_effective_util_pct": gpu["high_before"]["effective_hour_utilization_pct"],
            "low_tail_effective_util_pct": gpu["low_tail"]["effective_hour_utilization_pct"],
            "high_after_effective_util_pct": gpu["high_after"]["effective_hour_utilization_pct"],
            "data_profile": scenario_data_profile(scenario, args),
        }
        (sdir / "summary.json").write_text(json.dumps({"scenario": row, "gpu": gpu}, indent=2, ensure_ascii=False), encoding="utf-8")
        event("scenario_done")
        return row
    finally:
        if pf is not None:
            pf.terminate()
            try:
                pf.wait(timeout=5)
            except Exception:
                pf.kill()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="")
    parser.add_argument("--scenarios", default="baseline,s2_only,s3_only,both")
    parser.add_argument("--sample-interval", type=float, default=2.0)
    parser.add_argument("--high-count", type=int, default=24)
    parser.add_argument("--high-concurrency", type=int, default=6)
    parser.add_argument("--high-max-tokens", type=int, default=384)
    parser.add_argument("--low-count", type=int, default=8)
    parser.add_argument("--low-concurrency", type=int, default=2)
    parser.add_argument("--low-max-tokens", type=int, default=192)
    parser.add_argument("--scale-down-settle", type=int, default=20)
    parser.add_argument("--scale-up-settle", type=int, default=60)
    parser.add_argument("--hold-seconds", type=int, default=20)
    args = parser.parse_args()

    selected = {item.strip() for item in args.scenarios.split(",") if item.strip()}
    unknown = selected - {s.key for s in SCENARIOS}
    if unknown:
        raise SystemExit(f"unknown scenarios: {sorted(unknown)}")

    reports = HERE / "reports"
    out_dir = Path(args.out) if args.out else reports / f"strategy-scale-matrix-e2e-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir.mkdir(parents=True, exist_ok=True)

    original = {
        scale_e2e.DECODE_DEPLOY: scale_e2e.deployment_replicas(scale_e2e.DECODE_DEPLOY),
        scale_e2e.PREFILL_DEPLOY: scale_e2e.deployment_replicas(scale_e2e.PREFILL_DEPLOY),
        scale_e2e.OLD_DECODE_DEPLOY: scale_e2e.deployment_replicas(scale_e2e.OLD_DECODE_DEPLOY),
        scale_e2e.OLD_PREFILL_DEPLOY: scale_e2e.deployment_replicas(scale_e2e.OLD_PREFILL_DEPLOY),
    }

    matrix_rows: list[dict] = []
    events: list[dict] = []

    stop = threading.Event()
    sampler = scale_e2e.Sampler(out_dir=out_dir, interval=args.sample_interval, stop=stop, rows=[], node_nvidia_smi=True)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    sampler_thread.start()

    try:
        events.append({"ts": scale_e2e.now_ts(), "iso": ts_iso(), "scenario": "global", "event": "cleanup_old_crashloop_deployments"})
        scale_e2e.scale_deployment(scale_e2e.OLD_DECODE_DEPLOY, 0)
        scale_e2e.scale_deployment(scale_e2e.OLD_PREFILL_DEPLOY, 0)

        for scenario in [s for s in SCENARIOS if s.key in selected]:
            row = run_one_scenario(scenario, args, out_dir, sampler, events)
            matrix_rows.append(row)
            write_artifacts(out_dir, matrix_rows, events, sampler.rows)

        write_artifacts(out_dir, matrix_rows, events, sampler.rows)
        print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    finally:
        scale_e2e.scale_deployment(scale_e2e.PREFILL_DEPLOY, original[scale_e2e.PREFILL_DEPLOY])
        scale_e2e.scale_deployment(scale_e2e.DECODE_DEPLOY, original[scale_e2e.DECODE_DEPLOY])
        scale_e2e.scale_deployment(scale_e2e.OLD_PREFILL_DEPLOY, 0)
        scale_e2e.scale_deployment(scale_e2e.OLD_DECODE_DEPLOY, 0)
        try:
            scale_e2e.wait_deployment(scale_e2e.PREFILL_DEPLOY)
            scale_e2e.wait_deployment(scale_e2e.DECODE_DEPLOY)
        except Exception:
            pass
        stop.set()
        sampler_thread.join(timeout=10)

    return 0


if __name__ == "__main__":
    sys.exit(main())
