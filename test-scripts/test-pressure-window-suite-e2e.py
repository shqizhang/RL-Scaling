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


PHASES = ["prefill_pressure", "decode_head", "decode_tail"]


def build_pressure_manifest() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    idx = 1
    for _ in range(48):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "prefill_pressure",
                "words": 2200,
                "max_tokens": 64,
                "concurrency": 12,
                "shape": "very_long_prompt_short_decode",
            }
        )
        idx += 1
    for _ in range(24):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "decode_head",
                "words": 256,
                "max_tokens": 256,
                "concurrency": 8,
                "shape": "balanced_decode",
            }
        )
        idx += 1
    for _ in range(24):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "decode_tail",
                "words": 128,
                "max_tokens": 1024,
                "concurrency": 6,
                "shape": "controlled_long_tail_decode",
            }
        )
        idx += 1
    return rows


def status_poller(rows: list[dict[str, Any]], stop: threading.Event, interval: float) -> None:
    while not stop.is_set():
        e2e.status_sample(rows, "poll")
        time.sleep(interval)


def run_scenario(
    root: Path,
    name: str,
    manifest: list[dict[str, Any]],
    env: dict[str, str],
    *,
    prefill: int = 2,
    decode: int = 4,
    s3_signals: bool = False,
    observe_after_tail: int = 45,
    sample_interval: float = 1.0,
) -> dict[str, Any]:
    out_dir = root / name
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
        e2e.configure_controller(env)
        e2e.event(events, "controller_configured", scenario=name, env=env)
        e2e.set_topology(prefill=prefill, decode=decode)
        e2e.event(events, "topology_ready", prefill=prefill, decode=decode)
        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        status_thread.start()
        e2e.status_sample(status_rows, "initial")
        if s3_signals:
            e2e.event(events, "sampling_progress_head", response=e2e.send_progress(0.70, batch_size=168, avg_isl=2048, avg_osl=512))
        for phase in PHASES:
            if s3_signals and phase == "decode_tail":
                e2e.event(events, "sampling_progress_tail", response=e2e.send_progress(0.95, batch_size=168, avg_isl=512, avg_osl=1024))
                time.sleep(3)
            e2e.event(events, f"{phase}_start")
            rows = e2e.run_manifest_phase(manifest, phase, out_dir)
            requests.extend(rows)
            phase_summaries[phase] = e2e.summarize_all_requests(rows)
            e2e.event(events, f"{phase}_done", **phase_summaries[phase])
            e2e.status_sample(status_rows, f"after_{phase}")
        if s3_signals:
            time.sleep(observe_after_tail)
            e2e.status_sample(status_rows, "after_tail_observe")
            try:
                e2e.event(events, "batch_complete", response=e2e.send_batch_complete())
            except Exception as exc:  # noqa: BLE001
                e2e.event(events, "batch_complete_failed", error=str(exc))
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
    write_scenario_report(out_dir, name, summary)
    return summary


def write_scenario_report(out_dir: Path, name: str, summary: dict[str, Any]) -> None:
    overall = summary.get("overall_summary", {})
    alloc = summary.get("request_window_pod_allocation", {})
    s2_eval = summary.get("s2_evaluation_summary", {})
    lines = [
        f"# {name} Pressure Window E2E",
        "",
        f"生成时间：{e2e.ts_iso()}",
        "",
        "## 数据与指标",
        "",
        "本场景使用统一 pressure manifest：96 条超长 prompt prefill-pressure 请求、48 条 decode-head 请求、24 条受控 decode-tail 请求。",
        "",
        "- Wall Time：第一条请求发出到最后一条响应完成的端到端时间。",
        "- req/s：HTTP 200 成功请求数 / Wall Time。",
        "- prompt tok/s：成功请求 prompt_tokens / Wall Time，主要反映 prefill 压力。",
        "- completion tok/s：成功请求 completion_tokens / Wall Time，主要反映 decode 生成吞吐。",
        "- valid decode：HTTP 200、JSON 可解析、completion_tokens > 0、finish_reason 为 stop 或 length。",
        "- request-window GPU seconds：请求窗口内 ready worker GPU 数量对时间积分。",
        "",
        "## 总体结果",
        "",
        f"- requests: {overall.get('requests', 0)}",
        f"- success / valid decode: {overall.get('success_pct', 0):.2f}% / {overall.get('valid_decode_pct', 0):.2f}%",
        f"- wall time: {overall.get('wall_s', 0):.2f}s",
        f"- req/s: {overall.get('req_s', 0):.2f}",
        f"- p95 latency: {overall.get('p95_latency_s', 0):.2f}s",
        f"- prompt tok/s: {overall.get('prompt_tps', 0):.2f}",
        f"- completion tok/s: {overall.get('user_completion_tps', 0):.2f}",
        f"- request-window GPU seconds: {alloc.get('gpu_allocated_seconds', 0):.2f}",
        "",
        "## S2 观测窗口",
        "",
        f"- evaluation count: {s2_eval.get('count', 0)}",
        f"- max prefill_queue_depth: {s2_eval.get('max_prefill_queue_depth', 0)}",
        f"- max decode_queue_depth: {s2_eval.get('max_decode_queue_depth', 0)}",
        f"- max prefill_worker_active: {s2_eval.get('max_prefill_worker_active', 0)}",
        f"- max decode_worker_active: {s2_eval.get('max_decode_worker_active', 0)}",
        f"- selected actions: {s2_eval.get('selected_actions', [])}",
        f"- top skip reasons: {s2_eval.get('top_skip_reasons', [])}",
        "",
        "## S3 动作",
        "",
        f"- S3 migrated requests: {summary.get('s3_migrated_requests', 0)}",
        f"- S3 drained sources: {summary.get('s3_drained_sources', [])}",
        f"- S3 scaled down to: {summary.get('s3_scaled_down_to', [])}",
    ]
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_suite_report(root: Path, summaries: dict[str, dict[str, Any]]) -> None:
    base_gpu = (summaries["baseline"].get("request_window_pod_allocation") or {}).get("gpu_allocated_seconds", 0.0) or 0.0
    lines = [
        "# Pressure Window Baseline / S2 / S3 E2E 总结",
        "",
        f"生成时间：{e2e.ts_iso()}",
        "",
        "## 为什么上一轮 Strategy Mix 没有触发有效窗口",
        "",
        "这次先给 controller 增加了 S2 evaluation 观测字段，记录每次 tick 的 prefill/decode queue、worker active request、utilization、worker count 和 skip reason。这样可以区分两类问题：",
        "",
        "- workload 没有制造出 controller 能看到的压力。",
        "- workload 有压力，但某个 gating 条件不满足。",
        "",
        "## 统一测试数据",
        "",
        "- prefill_pressure：96 条超长 prompt、短 decode 请求，用于最大化 prefill 压力窗口。",
        "- decode_head：48 条中等 decode 请求，用于形成正常 decode batch。",
        "- decode_tail：24 条受控长尾 decode 请求，用于触发 S3 consolidation，同时避免 240s timeout 大面积污染。",
        "",
        "## 对比结果",
        "",
        "| scenario | requests | valid decode % | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s | request GPU s | GPU saved vs baseline | S2 exec | S3 migrated |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for name, summary in summaries.items():
        overall = summary.get("overall_summary", {})
        alloc = summary.get("request_window_pod_allocation", {})
        gpu = alloc.get("gpu_allocated_seconds", 0.0) or 0.0
        saved = ((base_gpu - gpu) / base_gpu * 100.0) if base_gpu > 0 else 0.0
        lines.append(
            f"| {name} | {overall.get('requests', 0)} | {overall.get('valid_decode_pct', 0):.2f} | "
            f"{overall.get('wall_s', 0):.2f} | {overall.get('req_s', 0):.2f} | {overall.get('p95_latency_s', 0):.2f} | "
            f"{overall.get('prompt_tps', 0):.2f} | {overall.get('user_completion_tps', 0):.2f} | "
            f"{gpu:.2f} | {saved:.2f}% | {summary.get('s2_executed_count', 0)} | {summary.get('s3_migrated_requests', 0)} |"
        )
    lines.extend(["", "## S2 触发窗口诊断", ""])
    for name, summary in summaries.items():
        s2_eval = summary.get("s2_evaluation_summary", {})
        lines.extend(
            [
                f"### {name}",
                "",
                f"- evaluation count: {s2_eval.get('count', 0)}",
                f"- max prefill_queue_depth: {s2_eval.get('max_prefill_queue_depth', 0)}",
                f"- max prefill_worker_active: {s2_eval.get('max_prefill_worker_active', 0)}",
                f"- max decode_worker_active: {s2_eval.get('max_decode_worker_active', 0)}",
                f"- selected actions: {s2_eval.get('selected_actions', [])}",
                f"- top skip reasons: {s2_eval.get('top_skip_reasons', [])}",
                "",
            ]
        )
    lines.extend(
        [
            "## 结论口径",
            "",
            "如果 S2 only 仍没有 selected action，但 evaluation 中 max prefill_queue_depth / prefill_worker_active 为 0，则说明 controller 仍看不到 prefill pressure；此时继续调 workload 没有意义，需要修 metrics。",
            "如果 evaluation 能看到 prefill pressure，但 skip reason 指向 decode_utilization、min_decode_replicas 或 target_available，则下一步应调整对应 gating 或 workload。",
            "S3 only 的结论以 migrated_requests、drained_sources、scaled_down_to 和 valid decode 为准。",
        ]
    )
    (root / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Pressure-window E2E for Baseline, S2 only, and S3 only.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--observe-after-tail", type=int, default=45)
    args = parser.parse_args()

    root = Path(args.suite_dir) if args.suite_dir else Path(__file__).resolve().parent / "reports" / f"pressure-window-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    root.mkdir(parents=True, exist_ok=True)
    manifest = build_pressure_manifest()
    e2e.write_manifest(root / "workload-manifest.jsonl", manifest)
    common_env = {
        "CONTROL_LOOP_INTERVAL": "1",
        "K8S_SCALE_FALLBACK_ENABLED": "true",
        "MAX_CONCURRENT_PER_DECODE": "16",
        "MAX_GPUS": "8",
        "MIN_PREFILL_REPLICAS": "1",
        "MIN_DECODE_REPLICAS": "2",
        "PRE_WARM_THRESHOLD": "2.0",
        "SINGLE_PREFILL_TPS": "20000",
        "TARGET_PREFILL_SECONDS": "5",
        "COOLDOWN_SECONDS": "10",
        "DRAIN_TIMEOUT_SECONDS": "60",
    }
    summaries = {
        "baseline": run_scenario(
            root,
            "baseline",
            manifest,
            {**common_env, "ROLE_SWITCH_ENABLED": "false", "CONSOLIDATION_ENABLED": "false", "CONSOLIDATION_SCALE_DOWN_ENABLED": "false"},
            sample_interval=args.sample_interval,
        ),
        "s2_only": run_scenario(
            root,
            "s2_only",
            manifest,
            {
                **common_env,
                "ROLE_SWITCH_ENABLED": "true",
                "CONSOLIDATION_ENABLED": "false",
                "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
                "PREFILL_QUEUE_THRESHOLD": "1",
                "DECODE_IDLE_THRESHOLD": "1.0",
                "DECODE_QUEUE_THRESHOLD": "999",
                "PREFILL_IDLE_THRESHOLD": "1.0",
                "MIN_SWITCH_INTERVAL": "5",
            },
            prefill=1,
            decode=4,
            sample_interval=args.sample_interval,
        ),
        "s3_only": run_scenario(
            root,
            "s3_only",
            manifest,
            {
                **common_env,
                "ROLE_SWITCH_ENABLED": "false",
                "CONSOLIDATION_ENABLED": "true",
                "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
                "CONSOLIDATION_THRESHOLD": "8",
                "CONSOLIDATION_STABLE_SAMPLES": "2",
                "CONSOLIDATION_MIN_INTERVAL": "5",
                "CONSOLIDATION_DRAIN_TIMEOUT": "30",
                "MIN_BATCH_COMPLETION": "0.60",
            },
            s3_signals=True,
            sample_interval=args.sample_interval,
            observe_after_tail=args.observe_after_tail,
        ),
    }
    (root / "suite-summary.json").write_text(json.dumps(summaries, indent=2, ensure_ascii=False), encoding="utf-8")
    write_suite_report(root, summaries)
    print(f"REPORT={root / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
