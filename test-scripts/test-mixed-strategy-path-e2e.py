#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Any

import rls_e2e_common as e2e


def status_poller(rows: list[dict[str, Any]], stop: threading.Event, interval: float) -> None:
    while not stop.is_set():
        e2e.status_sample(rows, "poll")
        time.sleep(interval)


def run_manifest_phase_async(manifest: list[dict[str, Any]], phase: str, out_dir: Path) -> list[dict[str, Any]]:
    items = [row for row in manifest if row["phase"] == phase]
    concurrency = max(1, int(items[0].get("concurrency", 1))) if items else 1
    rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(e2e.submit_manifest_request, item, out_dir) for item in items]
        for future in as_completed(futures):
            rows.append(future.result())
    rows.sort(key=lambda r: int(r["manifest_id"]))
    return rows


def wait_for_history(
    status_rows: list[dict[str, Any]],
    kind: str,
    predicate,
    timeout_s: int,
    poll_s: float = 1.0,
) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        rows = e2e.s2_history(status_rows) if kind == "s2" else e2e.s3_history(status_rows)
        if any(predicate(row) for row in rows):
            return True
        time.sleep(poll_s)
    return False


def build_mixed_manifest() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    idx = 1
    for _ in range(64):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "prefill_pressure",
                "words": 2600,
                "max_tokens": 96,
                "concurrency": 16,
                "shape": "very_long_prompt_short_decode",
            }
        )
        idx += 1
    for _ in range(48):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "decode_recovery",
                "words": 256,
                "max_tokens": 512,
                "concurrency": 12,
                "shape": "decode_recovery",
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
                "shape": "long_tail_decode",
            }
        )
        idx += 1
    return rows


def write_report(out_dir: Path, summary: dict[str, Any], decision_notes: list[str]) -> None:
    lines = [
        "# Mixed Strategy Path E2E 补充测试报告",
        "",
        f"生成时间：{e2e.ts_iso()}",
        "",
        "## 测试目标",
        "",
        "本测试专门修正上一轮 Strategy Mix 的脚本构造问题。上一轮在请求前直接发送 `sampling_progress=0.85`，S1 先把 prefill 扩到 5 个副本，导致 D->P role switch 没有触发窗口。本轮改为 staged path：",
        "",
        "1. 先关闭 S1 pre-warm 触发，只启用 S2/S3 controller。",
        "2. 使用真实 prefill-heavy 请求制造 prefill active/queue 压力，观察 controller 是否先执行 D->P。",
        "3. 若 D->P 后仍需要更多 prefill capacity，再发送 S1 sampling signal，让 controller scale up prefill。",
        "4. 进入 decode 阶段后观察 P->D。",
        "5. 进入 decode tail 后观察 S3 Request Consolidation、drain 和 scale down。",
        "",
        "## 指标口径",
        "",
        "- Wall Time：每个 phase 第一条请求发出到最后一条响应返回的端到端时间。",
        "- req/s：HTTP 200 成功请求数 / Wall Time。",
        "- prompt tok/s：成功请求的 prompt tokens / Wall Time，主要对应 prefill 吞吐。",
        "- completion tok/s：成功请求的 completion tokens / Wall Time，主要对应 decode 吞吐。",
        "- valid decode：HTTP 200、JSON 可解析、completion_tokens > 0、finish_reason 为 stop 或 length。",
        "- S2 switch_time_ms：已有 Pod 内部 role switch 耗时，不包含新 Pod 启动和模型加载。",
        "- S1 warmup：sampling signal 后 Kubernetes scale target 到 ready pod 的过程，和 S2 switch time 分开解释。",
        "- S3 migrated_requests / drained_sources / scaled_down_to：分别验证迁移、源 worker drain 和 drain 后缩容。",
        "",
        "## Phase 结果",
        "",
        "| phase | requests | success % | valid decode % | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for phase, row in summary.get("phase_summaries", {}).items():
        lines.append(
            f"| {phase} | {row.get('requests', 0)} | {row.get('success_pct', 0):.2f} | "
            f"{row.get('valid_decode_pct', 0):.2f} | {row.get('wall_s', 0):.2f} | "
            f"{row.get('req_s', 0):.2f} | {row.get('p95_latency_s', 0):.2f} | "
            f"{row.get('prompt_tps', 0):.2f} | {row.get('user_completion_tps', 0):.2f} |"
        )
    overall = summary.get("overall_summary", {})
    lines.append(
        f"| total | {overall.get('requests', 0)} | {overall.get('success_pct', 0):.2f} | "
        f"{overall.get('valid_decode_pct', 0):.2f} | {overall.get('wall_s', 0):.2f} | "
        f"{overall.get('req_s', 0):.2f} | {overall.get('p95_latency_s', 0):.2f} | "
        f"{overall.get('prompt_tps', 0):.2f} | {overall.get('user_completion_tps', 0):.2f} |"
    )
    alloc = summary.get("request_window_pod_allocation", {})
    full_alloc = summary.get("pod_allocation", {})
    lines.extend(
        [
            "",
            "## Controller 动作汇总",
            "",
            f"- S2 history count: {summary.get('s2_history_count', 0)}",
            f"- S2 executed count: {summary.get('s2_executed_count', 0)}",
            f"- S3 history count: {summary.get('s3_history_count', 0)}",
            f"- S3 executed pairs: {summary.get('s3_executed_pairs', 0)}",
            f"- S3 migrated requests: {summary.get('s3_migrated_requests', 0)}",
            f"- S3 drained sources: {summary.get('s3_drained_sources', [])}",
            f"- S3 scaled down to: {summary.get('s3_scaled_down_to', [])}",
            "",
            "## GPU 资源占用",
            "",
            f"- Request-window GPU allocated seconds: {alloc.get('gpu_allocated_seconds', 0):.2f}",
            f"- Full-scenario GPU allocated seconds: {full_alloc.get('gpu_allocated_seconds', 0):.2f}",
            f"- Avg ready workers during request window: {alloc.get('avg_ready_workers', 0):.2f}",
            f"- Min/Max ready workers during request window: {alloc.get('min_ready_workers', 0)} / {alloc.get('max_ready_workers', 0)}",
            "",
            "## 策略链路分析",
            "",
        ]
    )
    lines.extend(f"- {note}" for note in decision_notes)
    lines.extend(
        [
            "",
            "## Artifacts",
            "",
            "- `workload-manifest.jsonl`：本补充测试使用的 staged mixed workload。",
            "- `events.csv`：记录 controller env 切换、signals、phase 边界和是否观察到 S2/S3。",
            "- `controller_status.jsonl`：controller status 原始采样。",
            "- `pod_samples.csv`：ready pod 数量采样。",
            "- `requests.csv` / `responses/`：逐请求结果和原始响应，用于验证 decode 完整性。",
            "- `logs/`：controller 和 worker 日志，用于追踪 sidecar、migration、drain 和 scale patch。",
        ]
    )
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Targeted Mixed Strategy path E2E.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--observe-after-tail", type=int, default=60)
    args = parser.parse_args()

    root = Path(args.suite_dir) if args.suite_dir else Path(__file__).resolve().parent / "reports" / f"mixed-strategy-path-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir = root / "strategy_mix"
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = build_mixed_manifest()
    e2e.write_manifest(root / "workload-manifest.jsonl", manifest)

    events: list[dict[str, Any]] = []
    requests: list[dict[str, Any]] = []
    status_rows: list[dict[str, Any]] = []
    phase_summaries: dict[str, Any] = {}
    since_iso = e2e.ts_utc_since()
    stop = threading.Event()
    sampler = e2e.PodSampler(out_dir, args.sample_interval, stop)
    sampler_thread = threading.Thread(target=sampler.run, daemon=True)
    status_thread = threading.Thread(target=status_poller, args=(status_rows, stop, args.sample_interval), daemon=True)
    pf_frontend = pf_controller = None
    decision_notes: list[str] = []

    try:
        sampler_thread.start()
        e2e.configure_controller(
            {
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
            }
        )
        e2e.event(events, "controller_configured_stage_1_s2_first")
        e2e.set_topology(prefill=1, decode=4)
        e2e.event(events, "topology_ready_low_prefill", prefill=1, decode=4)
        pf_frontend = e2e.start_frontend_pf()
        pf_controller = e2e.start_controller_pf()
        status_thread.start()
        e2e.status_sample(status_rows, "initial")

        phase = "prefill_pressure"
        e2e.event(events, f"{phase}_start")
        rows = run_manifest_phase_async(manifest, phase, out_dir)
        requests.extend(rows)
        phase_summaries[phase] = e2e.summarize_all_requests(rows)
        e2e.event(events, f"{phase}_done", **phase_summaries[phase])
        s2_d_to_p = wait_for_history(
            status_rows,
            "s2",
            lambda item: item.get("executed") and item.get("from_role") == "decode" and item.get("to_role") == "prefill",
            20,
        )
        e2e.event(events, "observe_s2_d_to_p_done", observed=s2_d_to_p)
        decision_notes.append(
            "D->P role switch observed." if s2_d_to_p else "D->P role switch was not observed; this means prefill pressure still did not enter controller S2 metrics window."
        )

        e2e.event(
            events,
            "s1_scale_up_signal_after_s2_window",
            response=e2e.send_progress(0.85, batch_size=128, avg_isl=4096, avg_osl=512),
        )
        time.sleep(12)
        e2e.status_sample(status_rows, "after_s1_scale_up_window")

        phase = "decode_recovery"
        e2e.event(events, "sampling_done_decode_recovery_signal", response=e2e.send_done())
        e2e.event(events, f"{phase}_start")
        rows = run_manifest_phase_async(manifest, phase, out_dir)
        requests.extend(rows)
        phase_summaries[phase] = e2e.summarize_all_requests(rows)
        e2e.event(events, f"{phase}_done", **phase_summaries[phase])
        s2_p_to_d = wait_for_history(
            status_rows,
            "s2",
            lambda item: item.get("executed") and item.get("from_role") == "prefill" and item.get("to_role") == "decode",
            20,
        )
        e2e.event(events, "observe_s2_p_to_d_done", observed=s2_p_to_d)
        decision_notes.append(
            "P->D role switch observed." if s2_p_to_d else "P->D role switch was not observed; decode pressure did not trigger controller S2 reverse switch."
        )

        e2e.event(events, "sampling_progress_tail_for_s3", response=e2e.send_progress(0.95, batch_size=96, avg_isl=512, avg_osl=2048))
        phase = "decode_tail"
        e2e.event(events, f"{phase}_start")
        rows = run_manifest_phase_async(manifest, phase, out_dir)
        requests.extend(rows)
        phase_summaries[phase] = e2e.summarize_all_requests(rows)
        e2e.event(events, f"{phase}_done", **phase_summaries[phase])
        time.sleep(args.observe_after_tail)
        e2e.status_sample(status_rows, "after_tail_observe")
        s3_migration = any(item.get("migrated_requests", 0) for item in e2e.s3_history(status_rows))
        e2e.event(events, "observe_s3_done", observed=s3_migration)
        decision_notes.append(
            "S3 consolidation observed with migrated requests." if s3_migration else "S3 consolidation was not observed in the mixed path."
        )
        try:
            e2e.event(events, "batch_complete", response=e2e.send_batch_complete())
        except Exception as exc:  # noqa: BLE001
            e2e.event(events, "batch_complete_failed", error=str(exc))
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
        {"scenario": "strategy_mix_targeted", "manifest_request_count": len(manifest)},
    )
    write_report(out_dir, summary, decision_notes)
    (root / "suite-summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"REPORT={out_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
