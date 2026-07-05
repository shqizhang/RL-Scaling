#!/usr/bin/env python3
"""Final thesis E2E suite for RL-Scaling autoscaling validation.

This suite is intentionally strict about experimental fairness:

* every scenario consumes the same deterministic workload manifest;
* warmup/preparation time is recorded separately from request serving time;
* each mechanism is only credited when controller history proves it executed;
* raw requests, responses, pod samples, controller status, and logs are kept.
"""

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


PHASES = ["prefill_burst", "decode_bulk", "decode_tail"]


def status_poller(rows: list[dict[str, Any]], stop: threading.Event, interval: float) -> None:
    while not stop.is_set():
        e2e.status_sample(rows, "poll")
        time.sleep(interval)


def build_final_manifest() -> list[dict[str, Any]]:
    """Build one shared workload for all scenarios.

    The request count and token shapes are deliberately fixed across every
    scenario. Prompt text includes per-scenario nonce at request time through
    the helper marker, but words/max_tokens/concurrency stay identical.
    """
    rows: list[dict[str, Any]] = []
    idx = 1

    # Long prompt, short output: creates prefill pressure.
    for _ in range(48):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "prefill_burst",
                "words": 2200,
                "max_tokens": 96,
                "concurrency": 16,
                "shape": "long_prompt_short_decode",
            }
        )
        idx += 1

    # Medium prompt/output: lets the workload transition into decode-heavy use.
    for _ in range(32):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "decode_bulk",
                "words": 256,
                "max_tokens": 512,
                "concurrency": 8,
                "shape": "balanced_decode",
            }
        )
        idx += 1

    # Short prompt, long output: creates decode tail fragmentation.
    for _ in range(24):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "decode_tail",
                "words": 128,
                "max_tokens": 1024,
                "concurrency": 6,
                "shape": "short_prompt_long_tail_decode",
            }
        )
        idx += 1

    return rows


def scenario_env(name: str) -> dict[str, str]:
    base = {
        "CONTROL_LOOP_INTERVAL": "1",
        "K8S_SCALE_FALLBACK_ENABLED": "true",
        "MAX_GPUS": "4",
        "MAX_CONCURRENT_PER_DECODE": "48",
        "MIN_PREFILL_REPLICAS": "1",
        "MIN_DECODE_REPLICAS": "1",
        "SINGLE_PREFILL_TPS": "60000",
        "TARGET_PREFILL_SECONDS": "5",
        "COOLDOWN_SECONDS": "10",
        "DRAIN_TIMEOUT_SECONDS": "60",
        "CONSOLIDATION_DRAIN_TIMEOUT": "45",
        "CONSOLIDATION_DRAIN_POLL_INTERVAL": "1",
    }
    disabled = {
        "ROLE_SWITCH_ENABLED": "false",
        "CONSOLIDATION_ENABLED": "false",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
        "PRE_WARM_THRESHOLD": "2.0",
    }
    s2 = {
        "ROLE_SWITCH_ENABLED": "true",
        "CONSOLIDATION_ENABLED": "false",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
        "PRE_WARM_THRESHOLD": "2.0",
        "PREFILL_QUEUE_THRESHOLD": "1",
        "DECODE_IDLE_THRESHOLD": "1.0",
        "DECODE_QUEUE_THRESHOLD": "1",
        "PREFILL_IDLE_THRESHOLD": "1.0",
        "MIN_SWITCH_INTERVAL": "30",
    }
    s3 = {
        "ROLE_SWITCH_ENABLED": "false",
        "CONSOLIDATION_ENABLED": "true",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
        "PRE_WARM_THRESHOLD": "2.0",
        "CONSOLIDATION_THRESHOLD": "8",
        "CONSOLIDATION_STABLE_SAMPLES": "2",
        "CONSOLIDATION_MIN_INTERVAL": "5",
        "MIN_BATCH_COMPLETION": "0.60",
        "PER_REQUEST_MIGRATION_OVERHEAD": "0.5",
    }
    mixed = {
        **s2,
        **s3,
        "ROLE_SWITCH_ENABLED": "true",
        "CONSOLIDATION_ENABLED": "true",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
        "PRE_WARM_THRESHOLD": "0.80",
    }
    if name in {"baseline_minimal", "baseline_static", "baseline_overprovisioned"}:
        return {**base, **disabled}
    if name == "s2_only":
        return {**base, **s2}
    if name == "s3_only":
        return {**base, **s3}
    if name == "mixed_strategy":
        return {**base, **mixed}
    raise ValueError(f"unknown scenario: {name}")


def scenario_topology(name: str) -> tuple[int, int]:
    if name == "baseline_minimal":
        return 1, 1
    if name == "baseline_static":
        return 2, 2
    if name == "baseline_overprovisioned":
        return 2, 4
    if name == "s2_only":
        return 1, 3
    if name == "s3_only":
        return 2, 4
    if name == "mixed_strategy":
        return 1, 1
    raise ValueError(f"unknown scenario: {name}")


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


def controller_actions(summary: dict[str, Any]) -> list[str]:
    s2_eval = summary.get("s2_evaluation_summary", {}) or {}
    return [
        f"- S2 history count: {summary.get('s2_history_count', 0)}",
        f"- S2 executed count: {summary.get('s2_executed_count', 0)}",
        f"- S2 evaluation count: {s2_eval.get('count', 0)}",
        f"- S2 max prefill queue: {s2_eval.get('max_prefill_queue_depth', 0)}",
        f"- S2 max prefill worker active: {s2_eval.get('max_prefill_worker_active', 0)}",
        f"- S2 max decode worker active: {s2_eval.get('max_decode_worker_active', 0)}",
        f"- S2 selected actions: {s2_eval.get('selected_actions', [])}",
        f"- S2 top skip reasons: {s2_eval.get('top_skip_reasons', [])}",
        f"- S3 history count: {summary.get('s3_history_count', 0)}",
        f"- S3 executed pairs: {summary.get('s3_executed_pairs', 0)}",
        f"- S3 migrated requests: {summary.get('s3_migrated_requests', 0)}",
        f"- S3 drained sources: {summary.get('s3_drained_sources', [])}",
        f"- S3 scaled down to: {summary.get('s3_scaled_down_to', [])}",
    ]


def scenario_interpretation(name: str, summary: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    valid = float(summary.get("overall_summary", {}).get("valid_decode_pct", 0.0) or 0.0)
    if valid < 100.0:
        lines.append(
            f"正确性风险：valid decode 为 {valid:.2f}%，该场景不能作为生产可用性能收益，只能作为问题定位数据。"
        )
    if name == "baseline_minimal":
        lines.append("Baseline-Minimal 使用 1P1D 且禁用所有动态策略，用于观察资源受限下的端到端处理时间。")
    elif name == "baseline_static":
        lines.append("Baseline-Static 使用固定 2P2D 且禁用动态策略，用于对比传统静态扩容的性能与 GPU 占用。")
    elif name == "s2_only":
        if summary.get("s2_executed_count", 0):
            lines.append("S2 only 中 controller 自动执行了 PD role switch，可将 prefill/decode 阶段收益归因到 S2。")
        else:
            lines.append("S2 only 没有执行 role switch，不能声称 S2 带来性能收益；应查看 S2 evaluation 的 skip reason。")
    elif name == "s3_only":
        if summary.get("s3_migrated_requests", 0):
            lines.append("S3 only 中发生 Request Consolidation；若 drained_sources 先于 scaled_down_to 出现，则说明 drain gate 生效。")
        else:
            lines.append("S3 only 没有迁移请求，不能声称 consolidation 带来收益；应检查 tail 阶段 active/capacity 窗口。")
    elif name == "mixed_strategy":
        lines.append("Mixed Strategy 同时启用 S1/S2/S3，用于验证 controller 是否能自动串联 warmup、role switch、consolidation 与 scale down。")
    return lines


def write_scenario_report(out_dir: Path, name: str, summary: dict[str, Any]) -> None:
    alloc = summary.get("request_window_pod_allocation", {}) or {}
    full_alloc = summary.get("pod_allocation", {}) or {}
    prep = summary.get("preparation", {}) or {}
    lines = [
        f"# {name} 场景测试报告",
        "",
        f"生成时间：{e2e.ts_iso()}",
        "",
        "## 测试目的",
        "",
        "本场景使用最终论文测试套件生成的同一份 `workload-manifest.jsonl`。所有场景的请求数量、phase 顺序、prompt 规模、max_tokens 和并发度保持一致，避免因 workload 不同造成不公平对比。",
        "",
        "## 指标解释",
        "",
        "- Serving Wall Time：从本场景第一条请求发给 Dynamo frontend 开始，到最后一条请求响应完成为止；这是端到端请求处理效率的主指标。",
        "- Preparation Time：从测试脚本开始配置 topology 或发出 warmup signal，到请求正式开始前的准备时间；它单独报告，不混入 Serving Wall Time。",
        "- req/s：HTTP 200 成功请求数除以 Serving Wall Time，表示用户可见请求吞吐，不是 engine 内部 batch 数。",
        "- p50/p95/p99 latency：单请求端到端 latency 分位数，用于观察常规体验和长尾延迟。",
        "- prompt tok/s：成功请求的 prompt_tokens 除以 Wall Time，主要对应 prefill 处理吞吐。",
        "- completion tok/s：成功请求的 completion_tokens 除以 Wall Time，主要对应用户可见 decode 生成吞吐。",
        "- valid decode：HTTP 200、响应 JSON 可解析、completion_tokens > 0，且 finish_reason 为 stop 或 length 的请求。",
        "- Request-window GPU seconds：请求窗口内 ready worker GPU 数量对时间积分，越低表示完成同样 workload 占用 GPU 时间越少。",
        "- Full-scenario GPU seconds：包含配置、warmup、observe、cooldown 在内的资源占用，用于分析策略动作成本。",
        "- S2 switch_time_ms：已有 Pod 内部 role switch 耗时，不等于新 Pod 启动耗时。",
        "- S3 migrated/drained/scaled_down：分别验证迁移、源 worker drain 和 drain 后缩容的顺序正确性。",
        "",
        "## 准备与拓扑",
        "",
        f"- initial topology: {summary.get('initial_topology')}",
        f"- warmup target: {summary.get('warmup_target')}",
        f"- preparation seconds: {prep.get('preparation_s', 0):.2f}",
        f"- signal-to-ready seconds: {prep.get('signal_to_ready_s', 0):.2f}",
        "",
        "## Phase 结果",
        "",
        *phase_summary_table(summary),
        "",
        "## GPU 资源占用",
        "",
        f"- Request-window GPU seconds: {alloc.get('gpu_allocated_seconds', 0):.2f}",
        f"- Request-window prefill GPU seconds: {alloc.get('prefill_allocated_seconds', 0):.2f}",
        f"- Request-window decode GPU seconds: {alloc.get('decode_allocated_seconds', 0):.2f}",
        f"- Full-scenario GPU seconds: {full_alloc.get('gpu_allocated_seconds', 0):.2f}",
        f"- Avg ready workers in request window: {alloc.get('avg_ready_workers', 0):.2f}",
        f"- Min/Max ready workers in request window: {alloc.get('min_ready_workers', 0)} / {alloc.get('max_ready_workers', 0)}",
        "",
        "## Controller 动作",
        "",
        *controller_actions(summary),
        "",
        "## 场景分析",
        "",
        *[f"- {line}" for line in scenario_interpretation(name, summary)],
        "",
        "## 原始数据",
        "",
        "- `requests.csv`：逐请求 latency、HTTP code、token、finish_reason、content hash 和 valid_decode。",
        "- `responses/`：逐请求原始 HTTP response。",
        "- `pod_samples.csv`：ready prefill/decode pod 采样，用于计算 GPU seconds。",
        "- `controller_status.jsonl`：controller `/api/v1/status` 原始采样，包含 S1/S2/S3 状态与 history。",
        "- `events.csv`：测试脚本记录的 signal、phase 边界、topology 与 observe 事件。",
        "- `logs/`：controller 与 worker 日志，用于追踪 sidecar、KV migration、drain、rollback、500 错误等。",
    ]
    out_dir.joinpath("REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_suite_report(suite_dir: Path, summaries: dict[str, dict[str, Any]]) -> None:
    baseline = summaries.get("baseline_static") or summaries.get("baseline_minimal") or {}
    base_overall = baseline.get("overall_summary", {}) or {}
    base_alloc = baseline.get("request_window_pod_allocation", {}) or {}
    base_wall = float(base_overall.get("wall_s", 0.0) or 0.0)
    base_gpu = float(base_alloc.get("gpu_allocated_seconds", 0.0) or 0.0)

    lines = [
        "# 最终论文实验：RL-Scaling Autoscaling E2E 总报告",
        "",
        f"生成时间：{e2e.ts_iso()}",
        "",
        "## 实验目标",
        "",
        "本实验验证 RL-Scaling 在 Dynamo 推理/rollout 场景下的可行性与效能：通过 S1 warmup/scale、S2 Elastic PD Role Switch、S3 Request Consolidation 与 drain-gated scale down，降低相同 workload 的端到端完成时间与 GPU 占用时间。",
        "",
        "## 公平性设计",
        "",
        "- 所有场景使用同一份 `workload-manifest.jsonl`，请求数量、prompt 规模、max_tokens、phase 顺序和并发度一致。",
        "- Preparation Time 与 Serving Wall Time 分开统计；warmup 不能偷偷计入或移出性能指标。",
        "- 只有 controller history 中实际执行的 S2/S3 动作才被视为对应策略收益来源。",
        "- 每个场景保留 requests、responses、pod samples、controller status、events 和 logs，支持复核。",
        "",
        "## Workload 结构",
        "",
        "- `prefill_burst`：48 个长 prompt 短输出请求，用于制造 prefill 压力。",
        "- `decode_bulk`：32 个中等 prompt 中等输出请求，用于观察 prefill 后的 decode 恢复阶段。",
        "- `decode_tail`：24 个短 prompt 长输出请求，用于制造 decode 长尾和 S3 consolidation 窗口。",
        "",
        "## 总体对比",
        "",
        "| scenario | requests | valid decode % | wall(s) | wall change vs static | req/s | p95(s) | prompt tok/s | completion tok/s | request GPU s | GPU s change vs static | S2 exec | S3 migrated | scaled down |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for name, summary in summaries.items():
        overall = summary.get("overall_summary", {}) or {}
        alloc = summary.get("request_window_pod_allocation", {}) or {}
        wall = float(overall.get("wall_s", 0.0) or 0.0)
        gpu = float(alloc.get("gpu_allocated_seconds", 0.0) or 0.0)
        wall_change = ((base_wall - wall) / base_wall * 100.0) if base_wall > 0 else 0.0
        gpu_change = ((base_gpu - gpu) / base_gpu * 100.0) if base_gpu > 0 else 0.0
        lines.append(
            f"| {name} | {overall.get('requests', 0)} | {overall.get('valid_decode_pct', 0):.2f} | "
            f"{wall:.2f} | {wall_change:.2f}% | {overall.get('req_s', 0):.2f} | "
            f"{overall.get('p95_latency_s', 0):.2f} | {overall.get('prompt_tps', 0):.2f} | "
            f"{overall.get('user_completion_tps', 0):.2f} | {gpu:.2f} | {gpu_change:.2f}% | "
            f"{summary.get('s2_executed_count', 0)} | {summary.get('s3_migrated_requests', 0)} | "
            f"{summary.get('s3_scaled_down_to', [])} |"
        )

    lines.extend(
        [
            "",
            "## 结果解释原则",
            "",
            "- 如果某场景 valid decode 低于 100%，该场景不能被直接解释为生产可用性能提升。",
            "- 如果 S2 executed count 为 0，即使 wall time 变短，也不能归因为 PD Role Switch。",
            "- 如果 S3 migrated requests 为 0 或没有 drained_sources，不能归因为 Request Consolidation 或安全缩容。",
            "- GPU utilization 不单独作为主要收益指标；本实验优先比较 tokens/GPU-second、requests/GPU-second、request-window GPU seconds 与 wall time。",
            "",
            "## 按场景分析",
            "",
        ]
    )
    for name, summary in summaries.items():
        lines.append(f"### {name}")
        lines.extend(f"- {line}" for line in scenario_interpretation(name, summary))
        lines.extend(controller_actions(summary))
        lines.append("")

    lines.extend(
        [
            "## 结论模板",
            "",
            "最终结论必须基于上表实际数据填写：",
            "",
            "- Mixed Strategy 若同时满足 valid decode=100%、wall time 不高于 static baseline、request GPU seconds 更低，并且 controller history 中出现 S1/S2/S3 对应动作，则可证明完整 autoscaling 策略有效。",
            "- S2 only 若出现 executed role switch 且 prefill_burst wall time 或 prompt tok/s 优于 static baseline，可证明 PD Role Switch 对 prefill 瓶颈有效。",
            "- S3 only 若出现 migrated_requests、drained_sources、scaled_down_to，且 GPU seconds 下降、valid decode 保持 100%，可证明 Request Consolidation 对长尾资源释放有效。",
            "- 若某个机制未触发，报告必须诚实说明是可观测性、gating 或 workload 窗口问题，而不能把随机波动写成策略收益。",
        ]
    )
    suite_dir.joinpath("REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_phase(manifest: list[dict[str, Any]], phase: str, out_dir: Path) -> list[dict[str, Any]]:
    return e2e.run_manifest_phase(manifest, phase, out_dir)


def run_scenario(
    suite_dir: Path,
    name: str,
    manifest: list[dict[str, Any]],
    *,
    sample_interval: float,
    observe_after_tail_s: int,
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
    pf_frontend = None
    pf_controller = None

    setup_start = e2e.now_ts()
    signal_ts: float | None = None
    ready_ts: float | None = None
    serving_start_ts: float | None = None

    env = scenario_env(name)
    initial_prefill, initial_decode = scenario_topology(name)

    try:
        sampler_thread.start()
        e2e.configure_controller(env)
        e2e.event(events, "controller_configured", scenario=name, env=env)
        e2e.set_topology(initial_prefill, initial_decode)
        ready_ts = e2e.now_ts()
        e2e.event(events, "initial_topology_ready", prefill=initial_prefill, decode=initial_decode)

        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        e2e.wait_frontend_chat_ready(timeout_s=240)
        e2e.event(events, "frontend_model_ready")
        status_thread.start()
        e2e.status_sample(status_rows, "initial")

        if name == "mixed_strategy":
            # The signal is sent before the request batch. This measures S1
            # warmup separately and then starts request-serving timing.
            signal_ts = e2e.now_ts()
            response = e2e.send_progress(0.85, batch_size=len(manifest), avg_isl=4096, avg_osl=512)
            e2e.event(events, "s1_warmup_signal", response=response)
            e2e.wait_ready_counts(prefill=2, decode=2, timeout_s=600)
            e2e.wait_frontend_chat_ready(timeout_s=240)
            ready_ts = e2e.now_ts()
            e2e.status_sample(status_rows, "after_s1_warmup")
            e2e.event(events, "s1_warmup_ready", prefill=2, decode=2)

        if name in {"s2_only", "mixed_strategy"}:
            response = e2e.send_progress(0.70, batch_size=len(manifest), avg_isl=4096, avg_osl=512)
            e2e.event(events, "s2_prefill_pressure_signal", response=response)
            time.sleep(8)
            e2e.status_sample(status_rows, "after_s2_prefill_pressure_signal")

        for phase in PHASES:
            if phase == "decode_bulk" and name == "mixed_strategy":
                e2e.event(
                    events,
                    "sampling_done_decode_signal",
                    response=e2e.send_done(),
                )
                time.sleep(3)
            if phase == "decode_tail" and name in {"s3_only", "mixed_strategy"}:
                e2e.event(
                    events,
                    "batch_completion_signal_for_s3",
                    response=e2e.send_progress(0.95, batch_size=len(manifest), avg_isl=512, avg_osl=1536),
                )
                time.sleep(3)

            e2e.status_sample(status_rows, f"before_{phase}")
            e2e.event(events, f"{phase}_start")
            if serving_start_ts is None:
                serving_start_ts = e2e.now_ts()
            rows = run_phase(manifest, phase, out_dir)
            requests.extend(rows)
            phase_summaries[phase] = e2e.summarize_all_requests(rows)
            e2e.event(events, f"{phase}_done", **phase_summaries[phase])
            e2e.status_sample(status_rows, f"after_{phase}")

        if observe_after_tail_s > 0:
            time.sleep(observe_after_tail_s)
            e2e.status_sample(status_rows, "after_post_request_observe")

        if name in {"s3_only", "mixed_strategy"}:
            e2e.event(events, "batch_complete", response=e2e.send_batch_complete())
            time.sleep(5)
            e2e.status_sample(status_rows, "after_batch_complete")
    finally:
        if pf_frontend is not None:
            pf_frontend.terminate()
        if pf_controller is not None:
            pf_controller.terminate()
        stop.set()
        sampler_thread.join(timeout=10)
        status_thread.join(timeout=10)
        try:
            e2e.disable_controller_strategies()
            e2e.set_topology(prefill=2, decode=4)
        except Exception as exc:  # noqa: BLE001
            print(f"cleanup failed: {exc}", file=sys.stderr)

    e2e.capture_logs(out_dir, since_iso)
    summary = e2e.finalize_artifacts(
        out_dir,
        events,
        requests,
        status_rows,
        sampler.rows,
        phase_summaries,
        {
            "scenario": name,
            "manifest_request_count": len(manifest),
            "initial_topology": {"prefill": initial_prefill, "decode": initial_decode},
            "warmup_target": {"prefill": 2, "decode": 2} if name == "mixed_strategy" else None,
            "preparation": {
                "setup_start_ts": setup_start,
                "signal_ts": signal_ts,
                "ready_ts": ready_ts,
                "serving_start_ts": serving_start_ts,
                "preparation_s": ((serving_start_ts or e2e.now_ts()) - setup_start),
                "signal_to_ready_s": ((ready_ts - signal_ts) if ready_ts and signal_ts else 0.0),
            },
        },
    )
    write_scenario_report(out_dir, name, summary)
    return summary


def parse_scenarios(raw: str) -> list[str]:
    all_scenarios = ["baseline_minimal", "baseline_static", "baseline_overprovisioned", "s2_only", "s3_only", "mixed_strategy"]
    if raw.strip().lower() in {"all", ""}:
        return all_scenarios
    selected = [item.strip() for item in raw.split(",") if item.strip()]
    unknown = [item for item in selected if item not in all_scenarios]
    if unknown:
        raise ValueError(f"unknown scenarios: {unknown}; valid={all_scenarios}")
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description="Final thesis autoscaling E2E suite.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--scenarios", default="all")
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--observe-after-tail", type=int, default=45)
    args = parser.parse_args()

    suite_dir = (
        Path(args.suite_dir)
        if args.suite_dir
        else Path(__file__).resolve().parent
        / "reports"
        / f"final-thesis-autoscaling-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    )
    suite_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = suite_dir / "workload-manifest.jsonl"
    if manifest_path.exists():
        manifest = e2e.load_manifest(manifest_path)
    else:
        manifest = build_final_manifest()
        e2e.write_manifest(manifest_path, manifest)

    summaries: dict[str, dict[str, Any]] = {}
    for scenario in parse_scenarios(args.scenarios):
        summaries[scenario] = run_scenario(
            suite_dir,
            scenario,
            manifest,
            sample_interval=args.sample_interval,
            observe_after_tail_s=args.observe_after_tail,
        )

    summary_path = suite_dir / "suite-summary.json"
    if summary_path.exists():
        previous = json.loads(summary_path.read_text(encoding="utf-8"))
        previous.update(summaries)
        summaries = previous
    summary_path.write_text(json.dumps(summaries, indent=2, ensure_ascii=False), encoding="utf-8")
    write_suite_report(suite_dir, summaries)
    print(f"REPORT={suite_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
