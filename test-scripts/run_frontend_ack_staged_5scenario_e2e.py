#!/usr/bin/env python3
"""Frontend-ACK staged five-scenario E2E suite.

This is a new harness; no previous test script is modified.  It reuses the
proven deployment, sampling, request and log-capture plumbing, but creates a
causal S2 experiment:

  T0 -> D->P (included) -> prefill burst -> P->D (included)
     -> decode dense + tail -> T_end

The switch response is the barrier: it includes old-role Frontend ACK, local
drain, final drain and target-role Frontend readiness.  Therefore every phase
request is admitted only after the role required by that phase is routable.
"""
from __future__ import annotations

import argparse
import json
import random
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import rls_strategy_common as e2e
import run_phased_rollout_5scenario_e2e as phased
import run_rollout_batch_e2e as base


SCENARIOS = list(base.SCENARIOS)
S2_SCENARIOS = {"s2_only", "mixed"}
_original_target_env = phased.target_scenario_env


def target_scenario_env(name: str) -> dict[str, str]:
    """Keep S3 automatic; S2 is deliberately driven by phase boundaries."""
    env = dict(_original_target_env(name))
    if name in S2_SCENARIOS:
        env["ROLE_SWITCH_ENABLED"] = "false"
        env["MIN_SWITCH_INTERVAL"] = "0"
    return env


def prewarm_scenario_env(name: str) -> dict[str, str]:
    env = dict(target_scenario_env(name))
    env.update({
        "ROLE_SWITCH_ENABLED": "false",
        "CONSOLIDATION_ENABLED": "false",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
    })
    return env


def build_manifest(seed: int, size: int, concurrency: int) -> list[dict[str, Any]]:
    rows = phased.build_phased_manifest(
        seed,
        size,
        concurrency,
        phase_b_offset_s=0.0,
        phase_c_offset_s=0.0,
    )
    # Phase ordering is enforced by this harness, not request-side sleeps.
    for row in rows:
        row["phase_offset_s"] = 0.0
    return rows


def _choose_dual_mode_pod() -> str:
    pods = sorted(
        p["name"]
        for p in e2e.ready_worker_pods()
        if p.get("component") == "VllmDecodeWorker"
    )
    if not pods:
        raise RuntimeError("no ready VllmDecodeWorker pod for staged S2")
    return pods[0]


def _switch(
    port: int,
    pod: str,
    from_role: str,
    to_role: str,
    events: list[dict[str, Any]],
) -> dict[str, Any]:
    started_ts = e2e.now_ts()
    started_clock = time.perf_counter()
    pre_role = e2e.local_json_retry(port, "/v1/role", timeout_s=15)
    response = e2e.local_post_json(
        port,
        "/switch_role",
        {"target_role": to_role},
        timeout=180,
    )
    post_role = e2e.local_json_retry(port, "/v1/role", timeout_s=15)
    ended_ts = e2e.now_ts()
    action = {
        "pod": pod,
        "from_role": from_role,
        "to_role": to_role,
        "start_ts": started_ts,
        "end_ts": ended_ts,
        "client_wall_ms": (time.perf_counter() - started_clock) * 1000.0,
        "pre_role": pre_role,
        "post_role": post_role,
        "response": response,
        "executed": (
            response.get("status") == "ok"
            and response.get("new_role") == to_role
            and post_role.get("current_role") == to_role
            and (response.get("frontend_ack") or {}).get("acknowledged") is True
            and (response.get("frontend_target_ready") or {}).get("acknowledged") is True
        ),
    }
    e2e.event(events, "s2_switch_action", **action)
    if not action["executed"]:
        raise RuntimeError(f"staged S2 switch failed: {action}")
    return action


def _enrich_response_metrics(rows: list[dict[str, Any]], out_dir: Path) -> None:
    """Promote nvext timing/worker attribution into requests.csv."""
    for row in rows:
        response_path = out_dir / "responses" / (
            f"{row['phase']}-{int(row['manifest_id'])}.json"
        )
        try:
            raw = response_path.read_bytes()
            obj = json.loads(raw)
            nvext = obj.get("nvext") or {}
            timing = nvext.get("timing") or {}
            workers = nvext.get("worker_id") or {}
            row.update({
                "prefill_wait_time_ms": timing.get("prefill_wait_time_ms"),
                "prefill_time_ms": timing.get("prefill_time_ms"),
                "ttft_ms": timing.get("ttft_ms"),
                "server_total_time_ms": timing.get("total_time_ms"),
                "kv_hit_rate": timing.get("kv_hit_rate"),
                "request_received_ms": timing.get("request_received_ms"),
                "prefill_worker_id": workers.get("prefill_worker_id"),
                "prefill_dp_rank": workers.get("prefill_dp_rank"),
                "decode_worker_id": workers.get("decode_worker_id"),
                "decode_dp_rank": workers.get("decode_dp_rank"),
                "response_bytes": len(raw),
            })
        except Exception as exc:  # noqa: BLE001
            row["nvext_parse_error"] = str(exc)


def _run_group(
    frontend_port: int,
    items: list[dict[str, Any]],
    out_dir: Path,
    nonce: str,
    done: dict[str, int],
    lock: threading.Lock,
) -> list[dict[str, Any]]:
    if not items:
        return []
    max_inflight = max(1, int(items[0].get("concurrency", 48)))
    semaphore = threading.Semaphore(max_inflight)

    def submit(item: dict[str, Any]) -> dict[str, Any]:
        with semaphore:
            row = e2e.submit_manifest_request(frontend_port, item, out_dir, nonce)
        with lock:
            done["n"] += 1
        return row

    rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=len(items)) as pool:
        futures = [pool.submit(submit, item) for item in items]
        for future in as_completed(futures):
            rows.append(future.result())
    rows.sort(key=lambda r: int(r["manifest_id"]))
    _enrich_response_metrics(rows, out_dir)
    return rows


def run_staged_with_progress(
    frontend_port: int,
    controller_port: int,
    manifest: list[dict[str, Any]],
    out_dir: Path,
    nonce: str,
    meta: dict[str, Any],
    events: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], float, float]:
    scenario = str(nonce).split("-r", 1)[0]
    done = {"n": 0}
    lock = threading.Lock()
    stop_progress = threading.Event()
    worker_pf = None
    worker_pod = ""

    # Establish the control path before T0 so port-forward setup is not counted
    # as switch cost or batch work.
    if scenario in S2_SCENARIOS:
        worker_pod = _choose_dual_mode_pod()
        worker_pf = e2e.start_port_forward(f"pod/{worker_pod}", 9091, e2e.NS)
        e2e.local_json_retry(worker_pf.local_port, "/healthz", timeout_s=20)

    def progress_loop() -> None:
        while not stop_progress.is_set():
            with lock:
                completed = done["n"]
            if completed:
                try:
                    e2e.send_progress(
                        controller_port,
                        round(completed / max(1, len(manifest)), 3),
                        len(manifest),
                        int(meta["avg_isl"]),
                        int(meta["avg_osl"]),
                    )
                except Exception:
                    pass
            stop_progress.wait(0.5)

    t0 = e2e.now_ts()
    wall_start = time.perf_counter()
    e2e.event(
        events,
        "T0_batch",
        scenario=scenario,
        includes_switch_actions=True,
        protocol="frontend_ack_parallel_drain",
    )
    progress = threading.Thread(target=progress_loop, daemon=True)
    progress.start()
    rows: list[dict[str, Any]] = []
    try:
        if worker_pf is not None:
            _switch(worker_pf.local_port, worker_pod, "decode", "prefill", events)

        phase_a = [r for r in manifest if r["phase"] == "prefill_burst"]
        e2e.event(events, "phase_begin", phase="prefill_burst", requests=len(phase_a))
        rows.extend(
            _run_group(frontend_port, phase_a, out_dir, nonce, done, lock)
        )
        e2e.event(events, "phase_end", phase="prefill_burst", completed=len(phase_a))

        if worker_pf is not None:
            _switch(worker_pf.local_port, worker_pod, "prefill", "decode", events)

        decode_and_tail = [
            r for r in manifest if r["phase"] in {"decode_dense", "decode_tail"}
        ]
        e2e.event(
            events,
            "phase_begin",
            phase="decode_dense+decode_tail",
            requests=len(decode_and_tail),
        )
        rows.extend(
            _run_group(frontend_port, decode_and_tail, out_dir, nonce, done, lock)
        )
        e2e.event(
            events,
            "phase_end",
            phase="decode_dense+decode_tail",
            completed=len(decode_and_tail),
        )
        t_end = e2e.now_ts()
        e2e.send_batch_complete(controller_port)
        e2e.event(
            events,
            "T_end_batch_complete",
            completed=len(rows),
            business_wall_s=time.perf_counter() - wall_start,
            T_batch_s=t_end - t0,
        )
        rows.sort(key=lambda r: int(r["manifest_id"]))
        return rows, t0, t_end
    finally:
        stop_progress.set()
        progress.join(timeout=5)
        if worker_pf is not None:
            worker_pf.stop()


def _numbers(rows: list[dict[str, Any]], key: str) -> list[float]:
    out = []
    for row in rows:
        value = row.get(key)
        if value is not None and value != "":
            try:
                out.append(float(value))
            except (TypeError, ValueError):
                pass
    return out


def _dist(values: list[float]) -> dict[str, float]:
    return {
        "count": len(values),
        "mean": sum(values) / len(values) if values else 0.0,
        "p50": e2e.percentile(values, 0.50),
        "p95": e2e.percentile(values, 0.95),
        "max": max(values) if values else 0.0,
    }


def effective_role_gpu_seconds(
    pod_rows: list[dict[str, Any]], start_ts: float, end_ts: float
) -> dict[str, float]:
    """Integrate runtime role labels, not immutable deployment components."""
    samples: dict[float, dict[str, dict[str, Any]]] = {}
    for row in pod_rows:
        ts = float(row.get("ts", 0) or 0)
        if not (start_ts <= ts <= end_ts) or not row.get("ready"):
            continue
        samples.setdefault(ts, {})[str(row.get("name"))] = row
    points: list[tuple[float, int, int]] = []
    for ts, by_pod in sorted(samples.items()):
        p = d = 0
        for row in by_pod.values():
            if row.get("component") == "VllmPrefillWorker":
                p += 1
            elif row.get("current_role_label") == "prefill":
                p += 1
            else:
                d += 1
        points.append((ts, p, d))
    if not points:
        return {"prefill_gpu_s": 0.0, "decode_gpu_s": 0.0, "sample_count": 0}
    p_s = d_s = 0.0
    for idx, (ts, p, d) in enumerate(points):
        left = start_ts if idx == 0 else ts
        right = end_ts if idx == len(points) - 1 else points[idx + 1][0]
        dt = max(0.0, right - left)
        p_s += p * dt
        d_s += d * dt
    return {"prefill_gpu_s": p_s, "decode_gpu_s": d_s, "sample_count": len(points)}


def build_summary(
    scenario, repeat, position, rows, t0, t_end, meta,
    pod_rows, prom_rows, status_rows, events, out_dir,
) -> dict[str, Any]:
    summary = phased.build_phased_summary(
        scenario, repeat, position, rows, t0, t_end, meta,
        pod_rows, prom_rows, status_rows, events, out_dir,
    )
    actions = [e for e in events if e.get("event") == "s2_switch_action"]
    summary.update({
        "harness": "frontend_ack_staged_v1",
        "T_batch_includes_s2_actions": True,
        "s2_actions": actions,
        "s2_executed_count": sum(1 for a in actions if a.get("executed")),
        "s2_switch_total_ms": sum(
            float((a.get("response") or {}).get("switch_time_ms", 0) or 0)
            for a in actions
        ),
        "s2_client_wall_total_ms": sum(
            float(a.get("client_wall_ms", 0) or 0) for a in actions
        ),
        "effective_runtime_role_gpu_s": effective_role_gpu_seconds(
            pod_rows, t0, t_end
        ),
    })
    summary["mechanism_history"]["s2"] = actions

    for phase, phase_metrics in summary.get("phase_metrics", {}).items():
        phase_rows = [r for r in rows if r.get("phase") == phase]
        phase_metrics.update({
            "prefill_wait_time_ms": _dist(_numbers(phase_rows, "prefill_wait_time_ms")),
            "prefill_time_ms": _dist(_numbers(phase_rows, "prefill_time_ms")),
            "ttft_ms": _dist(_numbers(phase_rows, "ttft_ms")),
            "server_total_time_ms": _dist(_numbers(phase_rows, "server_total_time_ms")),
            "prefill_worker_distribution": dict(Counter(
                str(r.get("prefill_worker_id")) for r in phase_rows
                if r.get("prefill_worker_id") not in {None, ""}
            )),
            "decode_worker_distribution": dict(Counter(
                str(r.get("decode_worker_id")) for r in phase_rows
                if r.get("decode_worker_id") not in {None, ""}
            )),
        })
        starts = _numbers(phase_rows, "start_ts")
        ends = _numbers(phase_rows, "end_ts")
        if starts and ends:
            phase_metrics["effective_runtime_role_gpu_s"] = effective_role_gpu_seconds(
                pod_rows, min(starts), max(ends)
            )
    e2e.write_json(Path(out_dir) / "switch-actions.json", actions)
    return summary


def aggregate_scenario(scenario: str, runs: list[dict[str, Any]]) -> dict[str, Any]:
    agg = base.aggregate_scenario(scenario, runs)
    agg["harness"] = "frontend_ack_staged_v1"
    agg["phase_metrics"] = {}
    for phase in ("prefill_burst", "decode_dense", "decode_tail"):
        phase_runs = [r.get("phase_metrics", {}).get(phase, {}) for r in runs]
        phase_runs = [p for p in phase_runs if p]
        if not phase_runs:
            continue
        keys = (
            "service_window_s", "p50_latency_s", "p95_latency_s",
            "total_gpu_s", "tokens_per_gpu_s",
        )
        item: dict[str, Any] = {"run_count": len(phase_runs)}
        for key in keys:
            vals = [float(p.get(key, 0) or 0) for p in phase_runs]
            item[f"{key}_mean"] = sum(vals) / len(vals)
        for key in ("prefill_wait_time_ms", "prefill_time_ms", "ttft_ms"):
            for stat in ("mean", "p50", "p95"):
                vals = [float((p.get(key) or {}).get(stat, 0) or 0) for p in phase_runs]
                item[f"{key}_{stat}_mean"] = sum(vals) / len(vals)
        agg["phase_metrics"][phase] = item
    return agg


def main() -> int:
    ap = argparse.ArgumentParser(description="Frontend-ACK staged five-scenario E2E")
    ap.add_argument("--suite-dir", default="")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--batch-size", type=int, default=96)
    ap.add_argument("--seed", type=int, default=20260721)
    ap.add_argument("--concurrency", type=int, default=48)
    ap.add_argument("--sample-interval", type=float, default=1.0)
    ap.add_argument("--scenarios", default="all")
    ap.add_argument("--continue-after-timeout", action="store_true")
    args = ap.parse_args()
    active = (
        SCENARIOS
        if args.scenarios.strip().lower() in {"all", ""}
        else [x.strip() for x in args.scenarios.split(",") if x.strip()]
    )
    unknown = [x for x in active if x not in SCENARIOS]
    if unknown:
        raise ValueError(f"unknown scenarios: {unknown}")

    suite_dir = Path(args.suite_dir) if args.suite_dir else Path(
        f"reports/frontend-ack-staged-5scenario-{time.strftime('%Y%m%d-%H%M%S')}"
    )
    suite_dir.mkdir(parents=True, exist_ok=True)
    manifest = build_manifest(args.seed, args.batch_size, args.concurrency)
    (suite_dir / "workload-manifest.jsonl").write_text(
        "\n".join(json.dumps(row, ensure_ascii=False) for row in manifest) + "\n",
        encoding="utf-8",
    )
    e2e.write_json(suite_dir / "test-design.json", {
        "harness": "run_frontend_ack_staged_5scenario_e2e.py",
        "version": "frontend_ack_staged_v1",
        "legacy_scripts_modified": False,
        "T_batch_boundary": "before D->P action (if any) through last response",
        "phase_protocol": ["D->P", "prefill_burst", "P->D", "decode_dense+decode_tail"],
        "s2_required_evidence": [
            "frontend precheck routable=true",
            "old-role frontend ACK routable=false",
            "parallel drain + final drain",
            "target-role frontend ready routable=true",
            "per-action switch/client wall time",
            "per-request nvext timing and worker attribution",
            "T_batch including actions",
        ],
        "config": vars(args),
        "meta": phased.phased_meta(manifest),
    })

    # Patch only imported in-memory call sites. Existing source files stay intact.
    phased.target_scenario_env = target_scenario_env
    base.scenario_env = prewarm_scenario_env
    base.prewarm = phased.phased_prewarm
    base.run_rollout_with_progress = run_staged_with_progress
    base.batch_meta = phased.phased_meta
    base.build_summary = build_summary

    def progress(**data: Any) -> None:
        e2e.write_json(
            suite_dir / "progress.json",
            {"ts": e2e.now_ts(), "iso": e2e.ts_iso(), **data},
        )

    runs_by_scenario: dict[str, list[dict[str, Any]]] = {s: [] for s in SCENARIOS}
    aborted = None
    for repeat in range(1, args.repeats + 1):
        order = [s for s in base.counterbalanced(repeat - 1) if s in active]
        progress(stage="round_start", repeat=repeat, order=order)
        for position, scenario in enumerate(order, 1):
            progress(stage="run_start", repeat=repeat, scenario=scenario, position=position)
            try:
                summary = base.run_scenario_once(
                    suite_dir, scenario, repeat, position,
                    manifest, args.sample_interval,
                )
            except Exception as exc:  # noqa: BLE001
                failure = {
                    "repeat": repeat,
                    "scenario": scenario,
                    "error": str(exc),
                    "ts": e2e.now_ts(),
                }
                e2e.write_json(
                    suite_dir / scenario / f"run-{repeat:02d}" / "RUN-FAILURE.json",
                    failure,
                )
                progress(stage="run_failed", **failure)
                if not args.continue_after_timeout:
                    aborted = f"{scenario} r{repeat}: {exc}"
                    break
                continue
            runs_by_scenario[scenario].append(summary)
            progress(
                stage="run_done",
                repeat=repeat,
                scenario=scenario,
                T_batch_s=summary["T_batch_s"],
                valid_decode_pct=summary["valid_decode_pct"],
                timeout_count=summary["timeout_count"],
            )
        if aborted:
            break

    aggregates = {}
    for scenario in SCENARIOS:
        if runs_by_scenario[scenario]:
            aggregate = aggregate_scenario(scenario, runs_by_scenario[scenario])
            aggregates[scenario] = aggregate
            e2e.write_json(
                suite_dir / scenario / "aggregate-summary.json", aggregate
            )
    e2e.write_json(suite_dir / "consolidated-data.json", {
        "suite": suite_dir.name,
        "harness": "frontend_ack_staged_v1",
        "config": vars(args),
        "scenarios": SCENARIOS,
        "aborted": aborted,
        "aggregates": aggregates,
        "all_runs": [r for s in SCENARIOS for r in runs_by_scenario[s]],
    })
    progress(stage="suite_done", aborted=aborted)
    print(f"STAGED SUITE {'ABORTED: ' + aborted if aborted else 'DONE'} -> {suite_dir}")
    return 1 if aborted else 0


if __name__ == "__main__":
    raise SystemExit(main())
