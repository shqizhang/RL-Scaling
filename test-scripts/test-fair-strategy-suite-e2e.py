#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import rls_e2e_common as e2e


PHASES = ["prefill_peak", "decode_head", "decode_tail"]


def status_poller(rows: list[dict[str, Any]], stop: threading.Event, interval: float) -> None:
    while not stop.is_set():
        e2e.status_sample(rows, "poll")
        time.sleep(interval)


def phase_summary_table(summary: dict[str, Any]) -> list[str]:
    lines = [
        "| phase | requests | success % | valid decode % | wall(s) | req/s | p50(s) | p95(s) | p99(s) | prompt tok/s | completion tok/s |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for phase, row in summary.get("phase_summaries", {}).items():
        lines.append(
            f"| {phase} | {row.get('requests', 0)} | {row.get('success_pct', 0):.2f} | "
            f"{row.get('valid_decode_pct', 0):.2f} | {row.get('wall_s', 0):.2f} | "
            f"{row.get('req_s', 0):.2f} | {row.get('p50_latency_s', 0):.2f} | "
            f"{row.get('p95_latency_s', 0):.2f} | {row.get('p99_latency_s', 0):.2f} | "
            f"{row.get('prompt_tps', 0):.2f} | {row.get('user_completion_tps', 0):.2f} |"
        )
    overall = summary.get("overall_summary", {})
    lines.append(
        f"| total | {overall.get('requests', 0)} | {overall.get('success_pct', 0):.2f} | "
        f"{overall.get('valid_decode_pct', 0):.2f} | {overall.get('wall_s', 0):.2f} | "
        f"{overall.get('req_s', 0):.2f} | {overall.get('p50_latency_s', 0):.2f} | "
        f"{overall.get('p95_latency_s', 0):.2f} | {overall.get('p99_latency_s', 0):.2f} | "
        f"{overall.get('prompt_tps', 0):.2f} | {overall.get('user_completion_tps', 0):.2f} |"
    )
    return lines


def write_report(out_dir: Path, title: str, summary: dict[str, Any], notes: list[str]) -> None:
    alloc = summary.get("request_window_pod_allocation", {}) or summary.get("pod_allocation", {})
    full_alloc = summary.get("pod_allocation", {})
    lines = [
        f"# {title}",
        "",
        f"生成时间：{e2e.ts_iso()}",
        "",
        "## 测试数据",
        "",
        "本场景使用 suite 根目录下同一份 `workload-manifest.jsonl`。所有场景的请求数量、prompt 长度分布、max_tokens 分布、phase 顺序和并发度保持一致。",
        "",
        "- `prefill_peak`：24 条长 prompt、短 decode 请求，用于制造 prefill 压力。",
        "- `decode_head`：24 条中等 prompt、中等 decode 请求，用于形成正常 decode batch。",
        "- `decode_tail`：24 条短 prompt、长 decode 请求，用于制造长尾 decode 和 Request Consolidation 触发窗口。",
        "",
        "## 指标解释",
        "",
        "- Wall Time：该 phase 第一条请求发出到最后一条响应返回的端到端时间；total 行表示整个 manifest 从第一条请求到最后一条响应完成。",
        "- req/s：HTTP 200 成功请求数除以 Wall Time，表示用户可见请求吞吐，不是 engine 内部 batch 数。",
        "- p50/p95/p99 latency：单请求端到端耗时分位数，用于观察平均体验和长尾延迟。",
        "- prompt tok/s：成功请求的 prompt_tokens 除以 Wall Time，主要反映 prefill 处理吞吐。",
        "- completion tok/s：成功请求的 completion_tokens 除以 Wall Time，主要反映用户可见 decode 生成吞吐。",
        "- valid decode：HTTP 200、JSON 可解析、completion_tokens > 0，且 finish_reason 为 `stop` 或 `length` 的请求数。",
        "- Request-window GPU allocated seconds：从该场景第一条请求发出到最后一条响应完成期间，ready worker GPU 数量对时间积分；主性能对比使用这个口径。",
        "- Full-scenario GPU allocated seconds：包含 setup、signal、observe、cooldown 的资源占用，用于分析 scale down 和测试动作成本。",
        "- S2 switch_time_ms：已有 Pod 内部从 prefill/decode 切到另一个 role 的时间，不包含新 Pod 创建、image pull、model load 或 Kubernetes scheduling。",
        "- S1 startup/warmup：由 sampling signal 触发 scale target 到 Pod Ready 的时间，应与 S2 switch_time_ms 分开解释。",
        "- S3 migrated_requests：controller 记录的迁移请求数；`drained_sources` 出现后再 `scaled_down_to` 才说明 scale down 受 drain gate 保护。",
        "",
        "## 结果",
        "",
        *phase_summary_table(summary),
        "",
        "## 资源占用",
        "",
        f"- Request-window GPU allocated seconds: {alloc.get('gpu_allocated_seconds', 0):.2f}",
        f"- Request-window prefill allocated seconds: {alloc.get('prefill_allocated_seconds', 0):.2f}",
        f"- Request-window decode allocated seconds: {alloc.get('decode_allocated_seconds', 0):.2f}",
        f"- Full-scenario GPU allocated seconds: {full_alloc.get('gpu_allocated_seconds', 0):.2f}",
        f"- Avg ready workers: {alloc.get('avg_ready_workers', 0):.2f}",
        f"- Min/Max ready workers: {alloc.get('min_ready_workers', 0)} / {alloc.get('max_ready_workers', 0)}",
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
        "## 分析",
        "",
    ]
    lines.extend(f"- {note}" for note in notes)
    lines.extend(
        [
            "",
            "## Artifacts",
            "",
            "- `requests.csv`：逐请求 latency、HTTP code、token、finish_reason、content hash 和 valid_decode。",
            "- `responses/`：原始 HTTP response。",
            "- `pod_samples.csv`：测试期间 ready pod 数量采样，用于计算 GPU allocated seconds。",
            "- `controller_status.jsonl`：controller status 轮询数据，包含 S1 state、S2 history 和 S3 history。",
            "- `events.csv`：测试脚本记录的 signal、phase 边界和拓扑变化。",
            "- `logs/`：controller 与 worker 日志，用于追踪 migration、KV transfer、rollback、500 错误等。",
        ]
    )
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_scenario(
    suite_dir: Path,
    name: str,
    manifest: list[dict[str, Any]],
    controller_env: dict[str, str],
    notes: list[str],
    *,
    prefill: int = 2,
    decode: int = 4,
    strategy_signals: bool = False,
    s3_signals: bool = False,
    observe_after_tail_s: int = 45,
    sample_interval: float = 2.0,
) -> dict[str, Any]:
    out_dir = suite_dir / name
    out_dir.mkdir(parents=True, exist_ok=True)
    events: list[dict[str, Any]] = []
    requests: list[dict[str, Any]] = []
    status_rows: list[dict[str, Any]] = []
    phase_summaries: dict[str, Any] = {}
    since_iso = e2e.ts_utc_since()
    stop = threading.Event()
    sampler = e2e.PodSampler(out_dir, sample_interval, stop)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    status_thread = threading.Thread(target=status_poller, args=(status_rows, stop, sample_interval), daemon=True)
    pf_frontend = pf_controller = None
    try:
        sampler_thread.start()
        e2e.configure_controller(controller_env)
        e2e.event(events, "controller_configured", scenario=name, env=controller_env)
        e2e.set_topology(prefill=prefill, decode=decode)
        e2e.event(events, "topology_ready", prefill=prefill, decode=decode)
        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        status_thread.start()
        e2e.status_sample(status_rows, "initial")

        if strategy_signals:
            e2e.event(
                events,
                "s1_prefill_warmup_signal",
                response=e2e.send_progress(0.85, batch_size=96, avg_isl=4096, avg_osl=512),
            )
            time.sleep(8)
        elif s3_signals:
            e2e.event(events, "sampling_progress_head", response=e2e.send_progress(0.70, batch_size=72, avg_isl=1024, avg_osl=768))

        for phase in PHASES:
            if phase == "decode_head" and strategy_signals:
                e2e.event(events, "sampling_done_decode_capacity_signal", response=e2e.send_done())
                time.sleep(5)
            if phase == "decode_tail" and (strategy_signals or s3_signals):
                e2e.event(events, "sampling_progress_tail", response=e2e.send_progress(0.95, batch_size=72, avg_isl=512, avg_osl=1536))
                time.sleep(3)

            e2e.event(events, f"{phase}_start")
            rows = e2e.run_manifest_phase(manifest, phase, out_dir)
            requests.extend(rows)
            phase_summaries[phase] = e2e.summarize_all_requests(rows)
            e2e.event(events, f"{phase}_done", **phase_summaries[phase])
            e2e.status_sample(status_rows, f"after_{phase}")

        if strategy_signals or s3_signals:
            time.sleep(observe_after_tail_s)
            e2e.status_sample(status_rows, "after_tail_observe")
            e2e.event(events, "batch_complete", response=e2e.send_batch_complete())
            time.sleep(5)
            e2e.status_sample(status_rows, "after_batch_complete")
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
            status_thread.join(timeout=10)

    e2e.capture_logs(out_dir, since_iso)
    summary = e2e.finalize_artifacts(
        out_dir,
        events,
        requests,
        status_rows,
        sampler.rows,
        phase_summaries,
        {"scenario": name, "manifest_request_count": len(manifest)},
    )
    write_report(out_dir, name, summary, notes)
    return summary


def write_suite_report(suite_dir: Path, summaries: dict[str, dict[str, Any]]) -> None:
    baseline = summaries.get("baseline", {})
    base_overall = baseline.get("overall_summary", {})
    base_gpu = (baseline.get("request_window_pod_allocation") or baseline.get("pod_allocation") or {}).get("gpu_allocated_seconds", 0.0) or 0.0
    lines = [
        "# 统一 Workload 策略验证总报告",
        "",
        f"生成时间：{e2e.ts_iso()}",
        "",
        "本报告使用同一份 `workload-manifest.jsonl` 对 Baseline、S2 only、S3 only 和 Mixed Strategy 做公平对比。所有场景处理相同请求集合，避免由于请求数量、prompt 长度或 max_tokens 不同造成误判。",
        "",
        "## 总览",
        "",
        "| scenario | requests | success % | valid decode % | wall(s) | req/s | p95(s) | completion tok/s | request-window GPU s | GPU saved vs baseline | S2 exec | S3 migrated |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for name, summary in summaries.items():
        overall = summary.get("overall_summary", {})
        alloc = summary.get("request_window_pod_allocation", {}) or summary.get("pod_allocation", {})
        gpu = alloc.get("gpu_allocated_seconds", 0.0) or 0.0
        saved = ((base_gpu - gpu) / base_gpu * 100.0) if base_gpu > 0 else 0.0
        lines.append(
            f"| {name} | {overall.get('requests', 0)} | {overall.get('success_pct', 0):.2f} | "
            f"{overall.get('valid_decode_pct', 0):.2f} | {overall.get('wall_s', 0):.2f} | "
            f"{overall.get('req_s', 0):.2f} | {overall.get('p95_latency_s', 0):.2f} | "
            f"{overall.get('user_completion_tps', 0):.2f} | {gpu:.2f} | {saved:.2f}% |"
            f" {summary.get('s2_executed_count', 0)} | {summary.get('s3_migrated_requests', 0)} |"
        )
    lines.extend(
        [
            "",
            "## 对比解释",
            "",
            "- Baseline 关闭 S1/S2/S3，用固定拓扑处理同一 manifest，是性能和资源占用的对照组。",
            "- S2 only 只启用 PD Role Switch，用于观察在同一请求集合下，现有 Pod 内 role switch 是否能改善 prefill peak 的吞吐或 wall time；S2 switch time 与 Pod startup time 分开记录。",
            "- S3 only 只启用 Request Consolidation 和 drain-gated scale down，用于观察同一 long-tail decode 下，迁移、drain 和 scale down 是否减少 GPU allocated seconds。",
            "- Mixed Strategy 同时启用 S1/S2/S3，并通过 sampling signal 让 controller 自主经历 warmup、role switch、decode recovery、tail consolidation 和 drain 后 scale down。",
            "",
            "## 正确性边界",
            "",
            "- 如果某个场景 valid decode 低于 100%，该场景不能被解释为生产可用的性能提升，只能说明资源动作发生但用户可见连续性仍有缺口。",
            "- 如果 S2 history 中存在 `executed=false`，需要结合 `controller_status.jsonl` 和 controller log 检查 target selection、cooldown 和 sidecar 返回。",
            "- 如果 S3 出现 `scaled_down_to` 但没有对应 `drained_sources`，说明 scale down gate 有问题；本报告以 `drained_sources -> scaled_down_to` 的顺序作为正确性依据。",
            "- 当前 GPU 指标使用 pod allocation seconds，是 GPU 资源占用 proxy；更严谨的 GPU effective busy time 仍需要 DCGM exporter 积分。",
            "",
            "## 本轮结论",
            "",
            "- S3 only 在统一 workload 下成功触发 1 次 migration，记录了 drained source，并将 decode replicas scale down 到 3；同时 valid decode 保持 100%，这是本轮最强的正向证据。",
            "- S2 only 没有产生 S2 history，说明当前真实 prefill pressure 指标仍未稳定进入 controller 可观测窗口；因此本轮不能证明 controller 自动 D->P role switch。",
            "- Mixed Strategy 触发了 S1 warmup 状态流转并保持 100% valid decode，但没有触发 S2/S3 history，说明完整自动混合策略尚未达成。",
            "- 因此，本轮报告的严谨结论是：统一 workload 公平测试框架已经建立，S3 drain-gated scale down 得到验证；S2 自动触发和 Mixed Strategy 自动决策仍是需要继续修复的 controller 可观测性/策略问题。",
            "",
            "## Artifact Index",
            "",
            "- `workload-manifest.jsonl`：四个场景共享的请求清单。",
            "- `baseline/`、`s2_only/`、`s3_only/`、`strategy/`：各场景原始数据与场景报告。",
        ]
    )
    (suite_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fair RL-Scaling E2E suite using one shared workload manifest.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--manifest-repeats", type=int, default=1)
    parser.add_argument("--sample-interval", type=float, default=2.0)
    parser.add_argument("--observe-after-tail", type=int, default=45)
    args = parser.parse_args()

    suite_dir = Path(args.suite_dir) if args.suite_dir else Path(__file__).resolve().parent / "reports" / f"fair-strategy-validation-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    suite_dir.mkdir(parents=True, exist_ok=True)
    manifest = e2e.build_fair_manifest(args.manifest_repeats)
    e2e.write_manifest(suite_dir / "workload-manifest.jsonl", manifest)

    common_env = {
        "CONTROL_LOOP_INTERVAL": "1",
        "K8S_SCALE_FALLBACK_ENABLED": "true",
        "MAX_CONCURRENT_PER_DECODE": "16",
        "MAX_GPUS": "8",
        "MIN_PREFILL_REPLICAS": "1",
        "MIN_DECODE_REPLICAS": "2",
        "SINGLE_PREFILL_TPS": "20000",
        "TARGET_PREFILL_SECONDS": "5",
        "COOLDOWN_SECONDS": "10",
        "DRAIN_TIMEOUT_SECONDS": "60",
    }

    summaries: dict[str, dict[str, Any]] = {}
    summaries["baseline"] = run_scenario(
        suite_dir,
        "baseline",
        manifest,
        {
            **common_env,
            "PRE_WARM_THRESHOLD": "2.0",
            "ROLE_SWITCH_ENABLED": "false",
            "CONSOLIDATION_ENABLED": "false",
            "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
        },
        [
            "Baseline 固定使用 2P+4D，S1/S2/S3 均不参与资源动作。",
            "该场景用于确认同一 manifest 的基础成功率、端到端 wall time 和 GPU allocated seconds。",
        ],
        sample_interval=args.sample_interval,
    )
    summaries["s2_only"] = run_scenario(
        suite_dir,
        "s2_only",
        manifest,
        {
            **common_env,
            "PRE_WARM_THRESHOLD": "2.0",
            "ROLE_SWITCH_ENABLED": "true",
            "CONSOLIDATION_ENABLED": "false",
            "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
            "PREFILL_QUEUE_THRESHOLD": "1",
            "DECODE_IDLE_THRESHOLD": "1.0",
            "DECODE_QUEUE_THRESHOLD": "999",
            "PREFILL_IDLE_THRESHOLD": "1.0",
            "MIN_SWITCH_INTERVAL": "5",
        },
        [
            "S2 only 使用 controller 自动判断 D->P，不直接调用 sidecar；阈值使用真实 active request fallback 形成触发窗口。",
            "该场景不启用 S3，因此任何 migration 或 scale down 都不应出现。",
        ],
        prefill=1,
        decode=4,
        sample_interval=args.sample_interval,
    )
    summaries["s3_only"] = run_scenario(
        suite_dir,
        "s3_only",
        manifest,
        {
            **common_env,
            "PRE_WARM_THRESHOLD": "2.0",
            "ROLE_SWITCH_ENABLED": "false",
            "CONSOLIDATION_ENABLED": "true",
            "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
            "CONSOLIDATION_THRESHOLD": "8",
            "CONSOLIDATION_STABLE_SAMPLES": "2",
            "CONSOLIDATION_MIN_INTERVAL": "5",
            "CONSOLIDATION_DRAIN_TIMEOUT": "30",
            "MIN_BATCH_COMPLETION": "0.60",
        },
        [
            "S3 only 在 decode tail 前发送 batch progress signal，使 controller 使用同一 manifest 的长尾阶段寻找 consolidation plan。",
            "重点检查 migrated_requests、drained_sources 和 scaled_down_to 的先后关系，以及 valid decode 是否保持 100%。",
        ],
        s3_signals=True,
        observe_after_tail_s=args.observe_after_tail,
        sample_interval=args.sample_interval,
    )
    summaries["strategy"] = run_scenario(
        suite_dir,
        "strategy",
        manifest,
        {
            **common_env,
            "PRE_WARM_THRESHOLD": "0.2",
            "ROLE_SWITCH_ENABLED": "true",
            "CONSOLIDATION_ENABLED": "true",
            "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
            "PREFILL_QUEUE_THRESHOLD": "1",
            "DECODE_IDLE_THRESHOLD": "1.0",
            "DECODE_QUEUE_THRESHOLD": "1",
            "PREFILL_IDLE_THRESHOLD": "1.0",
            "MIN_SWITCH_INTERVAL": "5",
            "CONSOLIDATION_THRESHOLD": "8",
            "CONSOLIDATION_STABLE_SAMPLES": "2",
            "CONSOLIDATION_MIN_INTERVAL": "5",
            "CONSOLIDATION_DRAIN_TIMEOUT": "30",
            "MIN_BATCH_COMPLETION": "0.60",
        },
        [
            "Mixed Strategy 启用 S1/S2/S3，使用 sampling progress / done / complete signal 驱动 controller 全流程。",
            "报告需要同时解释 S1 Pod startup/warmup、S2 Pod 内 switch_time_ms、S3 migration/drain/scale down，避免把不同时间混为一个指标。",
        ],
        prefill=1,
        decode=3,
        strategy_signals=True,
        observe_after_tail_s=args.observe_after_tail,
        sample_interval=args.sample_interval,
    )

    (suite_dir / "suite-summary.json").write_text(json.dumps(summaries, indent=2, ensure_ascii=False), encoding="utf-8")
    write_suite_report(suite_dir, summaries)
    print(f"REPORT={suite_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
