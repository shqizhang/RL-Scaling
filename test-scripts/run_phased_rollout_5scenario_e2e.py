#!/usr/bin/env python3
"""Phased-arrival RL rollout E2E suite.

This is intentionally a NEW harness.  It imports the proven plumbing from
run_rollout_batch_e2e.py but does not modify or replace that continuous-batch
test.  Requests arrive in three predetermined phases; there are no in-window
topology/readiness/mechanism gates.  All mechanism validation is post-hoc.

Design: docs/PLAN-phased-performance-optimization-and-rdma-validation-20260720-zh.md
Report prefix: phased-5scenario-*
"""
from __future__ import annotations

import argparse
import json
import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import rls_strategy_common as e2e
import run_rollout_batch_e2e as base


SCENARIOS = base.SCENARIOS
_base_batch_meta = base.batch_meta
_legacy_scenario_env = base.scenario_env
_base_prewarm = base.prewarm


def target_scenario_env(name: str) -> dict[str, str]:
    env = dict(_legacy_scenario_env(name))
    if name in {"s2_only", "mixed"}:
        # S2 trigger calibration v2 (suite phased-v2-20260722-224207 post-mortem):
        # the calibrated threshold 3 never fired — on this model prefill is
        # near-instant, so a *prefill-side* backlog never materialises from the
        # queue metrics (observed prefill_queue_depth: 0 during the whole A
        # burst, while the decode queue surged to 44+). The only prefill-side
        # signal that exists at the phase boundary is the RL batch hint
        # (ceil(batch_size/64) = ceil(96/64) = 2, applied by
        # apply_signal_hints), so the threshold must equal the hint value.
        # Probe-residue false-fires are prevented by the pre-T0 guard, not by
        # over-raising the threshold. Interval 20s lets the P->D revert respond
        # to genuine decode pressure inside phase B.
        env["PREFILL_QUEUE_THRESHOLD"] = "2"
        env["MIN_SWITCH_INTERVAL"] = "20"
        # Suite 231344 run-01 post-mortem: with A carrying 8-16 output tokens,
        # phase A itself floods the decode queue (sustained 35-44 for ~25s),
        # indistinguishable in magnitude from phase B's genuine decode
        # pressure (46-48) — so the legacy DECODE_QUEUE_THRESHOLD=2 fired the
        # P->D revert at +22s, inside the A window. 8 clears the post-fix A
        # residue (~0-3 once A is a pure prefill probe) while B's sustained
        # 40+ still crosses it immediately.
        env["DECODE_QUEUE_THRESHOLD"] = "8"
        # Same post-mortem: decode_util is >= 0.03 within one controller tick
        # of T0 (A-phase requests carry 8-16 output tokens), so a 0.00/0.02
        # idle threshold closes the D->P window before the T0 phase signal can
        # be observed. 0.05 tolerates the one-tick race while still requiring
        # a near-idle decode pool; in-flight decodes on the switched worker
        # are protected by the worker-side hold-during-switch + drain protocol
        # (zero-loss is the protocol's job, not the trigger's).
        env["DECODE_IDLE_THRESHOLD"] = "0.05"
    return env


def build_phased_manifest(seed: int, size: int, concurrency: int,
                          phase_b_offset_s: float, phase_c_offset_s: float,
                          a_token_choices: list[int] | None = None) -> list[dict[str, Any]]:
    """Build one deterministic manifest shared byte-for-byte by all scenarios.

    The default 96-request mix is 44/49/3.  Phase offsets shape arrival only;
    they are not gates and do not wait for any role or topology condition.
    """
    if size < 24:
        raise ValueError("batch-size must be >= 24 for a meaningful three-phase workload")
    rng = random.Random(seed)
    # Three staggered stragglers are the distribution already proven to produce
    # a migratable 2+1 split in the successful prior S3 suites.
    n_tail = 3
    # Keep phase A below the 48-request HTTP cap so phase B is not delayed by
    # semaphore queueing. For size=96 this produces 44/49/3.
    n_prefill = round(size * 0.46)
    n_decode = size - n_prefill - n_tail
    rows: list[dict[str, Any]] = []

    def add(phase: str, count: int, words_range: tuple[int, int], token_choices: list[int],
            shape: str, offset: float, ignore_eos: bool = False) -> None:
        for _ in range(count):
            rows.append({
                "manifest_id": len(rows) + 1,
                "phase": phase,
                "words": rng.randint(*words_range),
                "max_tokens": rng.choice(token_choices),
                "concurrency": concurrency,
                "timeout_s": 600,
                "shape": shape,
                "ignore_eos": ignore_eos,
                "phase_offset_s": offset,
                "launch_delay_s": 0,
            })

    # Long prompts + short outputs expose the D->P prefill opportunity.
    # Data audit 2026-07-22: with max_tokens 64-128 the A cohort carries real
    # decode demand, so borrowing a decoder (D->P, 3P1D) starves the remaining
    # decoder and the A cohort completes SLOWER despite a -40% prefill TTFT.
    # Suite 231344 post-mortem: even 8/12/16 still floods the decode queue
    # (44 requests x ~12 tokens sustained dq 35-44 for ~25s), so phase A never
    # becomes prefill-bound on this fast-prefill model and the P->D revert
    # fires inside the A window. Default 1 makes A a pure prefill probe
    # (prefill + a single decode step; still a valid completion with
    # finish_reason=length, and nvext TTFT is unaffected); pass
    # --phase-a-max-tokens 64,96,128 to reproduce the legacy shape.
    add("prefill_burst", n_prefill, (1200, 1800),
        list(a_token_choices) if a_token_choices else [8, 12, 16],
        "long_prompt_short_output", 0.0)
    # Medium prompts + long generation expose P->D value.
    add("decode_dense", n_decode, (300, 550), [768, 1024, 1280],
        "medium_prompt_long_output", phase_b_offset_s)
    # A small deterministic ignore-EOS tail creates a consolidatable 2+N split.
    add("decode_tail", n_tail, (300, 500), [5000],
        "ignore_eos_straggler", phase_c_offset_s, True)

    # Shuffle only within each phase.  Phase order/offset remains fixed.
    out: list[dict[str, Any]] = []
    for phase in ("prefill_burst", "decode_dense", "decode_tail"):
        group = [r for r in rows if r["phase"] == phase]
        rng.shuffle(group)
        out.extend(group)
    for idx, row in enumerate(out, 1):
        row["manifest_id"] = idx
        if row["phase"] == "decode_tail":
            # Spread tail requests across router observations without a gate.
            row["launch_delay_s"] = (idx - (n_prefill + n_decode + 1)) * 3.0
    return out


def phased_meta(manifest: list[dict[str, Any]]) -> dict[str, Any]:
    meta: dict[str, Any] = _base_batch_meta(manifest)
    meta["arrival_mode"] = "phased_no_gate"
    meta["phases"] = {}
    for phase in ("prefill_burst", "decode_dense", "decode_tail"):
        rows = [r for r in manifest if r["phase"] == phase]
        meta["phases"][phase] = {
            "requests": len(rows),
            "offset_s": min((float(r["phase_offset_s"]) for r in rows), default=0.0),
            "avg_isl_est": int(sum(int(r["words"]) * 1.3 for r in rows) / max(1, len(rows))),
            "avg_max_tokens": int(sum(int(r["max_tokens"]) for r in rows) / max(1, len(rows))),
        }
    return meta


def enrich_response_metrics(rows: list[dict[str, Any]], out_dir: Path) -> None:
    """Promote nvext timing / worker attribution from saved response JSON into
    the request rows (and therefore requests.csv). The frontend already
    returns prefill_wait_time_ms (router queue wait), prefill_time_ms, ttft_ms
    and per-phase worker ids -- the queue-time evidence the report needs."""
    for row in rows:
        response_path = Path(out_dir) / "responses" / (
            f"{row['phase']}-{int(row['manifest_id'])}.json")
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
                "prefill_worker_id": workers.get("prefill_worker_id"),
                "decode_worker_id": workers.get("decode_worker_id"),
            })
        except Exception as exc:  # noqa: BLE001
            row["nvext_parse_error"] = str(exc)


def _numbers(rows: list[dict[str, Any]], key: str) -> list[float]:
    out: list[float] = []
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


def effective_role_gpu_seconds(pod_rows: list[dict[str, Any]],
                               start_ts: float, end_ts: float) -> dict[str, Any]:
    """Integrate GPU counts by RUNTIME role, not Deployment component.

    The Deployment-based sampler counts an S2-switched decode pod as decode
    forever, so s2 scenarios previously reported 2P/2D throughout even while
    running 3P/1D. Uses the nvidia.com/dynamo-current-role pod label captured
    in pod_samples.csv (current_role_label)."""
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
            label = str(row.get("current_role_label") or "")
            if row.get("component") == "VllmPrefillWorker":
                p += 1
            elif label == "prefill":
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


def prewarm_scenario_env(name: str) -> dict[str, str]:
    """Use the target topology thresholds but disable S2/S3 during prewarm.

    This prevents stale queue samples/readiness probes from changing worker
    roles before T0.  The target strategy is enabled only after 2P2D is ready.
    """
    env = dict(target_scenario_env(name))
    env.update({
        "ROLE_SWITCH_ENABLED": "false",
        "CONSOLIDATION_ENABLED": "false",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
    })
    return env


def phased_prewarm(scenario: str, controller_port: int, frontend_port: int,
                    events: list[dict[str, Any]]) -> None:
    # Role switch mutates a live decode worker into a real prefill worker.  A
    # replica-count reset alone does not necessarily recreate that pod, so the
    # next scenario could inherit its role.  Restart both worker Deployments
    # before every scenario to restore image/default-role state.  This remains
    # outside T0 and is recorded explicitly as test isolation, not performance.
    deployments = e2e.deployment_names_by_component()
    worker_deployments = deployments["prefill"] + deployments["decode"]
    for deployment in worker_deployments:
        e2e.kubectl(["rollout", "restart", "-n", e2e.NS,
                     f"deployment/{deployment}"], timeout=60)
    for deployment in worker_deployments:
        e2e.kubectl(["rollout", "status", "-n", e2e.NS,
                     f"deployment/{deployment}", "--timeout=600s"], timeout=630)
    e2e.event(events, "worker_roles_reset", deployments=worker_deployments)
    _base_prewarm(scenario, controller_port, frontend_port, events)
    # Restart the controller with a fresh, empty strategy history only after the
    # physical topology and model endpoints are ready. This is outside T_batch.
    e2e.configure_controller(target_scenario_env(scenario))
    e2e._restart_port_forward(controller_port)
    e2e.wait_http(f"http://127.0.0.1:{controller_port}/healthz", timeout_s=180)
    env = target_scenario_env(scenario)
    e2e.event(events, "strategy_enabled_after_prewarm", scenario=scenario,
              role_switch=env.get("ROLE_SWITCH_ENABLED"),
              consolidation=env.get("CONSOLIDATION_ENABLED"),
              decode_idle_threshold=env.get("DECODE_IDLE_THRESHOLD"),
              prefill_queue_threshold=env.get("PREFILL_QUEUE_THRESHOLD"),
              min_switch_interval=env.get("MIN_SWITCH_INTERVAL"))
    # PRE-T0 GUARD (data audit 2026-07-22): in the 0720 final dataset the D->P
    # fired 8-26s BEFORE T0 on probe residue, so the whole scenario measured a
    # mis-timed topology. Watch the (now armed) controller for a few ticks and
    # fail fast if any switch fires before the batch is dispatched -- roles are
    # reset by the per-scenario rollout restart, so aborting here is cheap,
    # while a poisoned run costs a full scenario.
    if env.get("ROLE_SWITCH_ENABLED", "false") == "true":
        guard_deadline = time.time() + 6.0
        while time.time() < guard_deadline:
            try:
                status = e2e.controller_json(controller_port, "/api/v1/status")
            except Exception:  # noqa: BLE001
                status = {}
            history = ((status or {}).get("strategy") or {}).get("s2_history") or []
            fired = [h for h in history if h.get("executed")]
            if fired:
                e2e.event(events, "pre_t0_switch_detected", history=fired)
                raise RuntimeError(
                    f"S2 switch fired BEFORE T0 (probe residue?): {fired[:1]} -- "
                    "raise PREFILL_QUEUE_THRESHOLD or extend prewarm quiet period")
            time.sleep(1.0)
        e2e.event(events, "pre_t0_guard_passed", watched_s=6.0)


def run_phased_with_progress(frontend_port: int, controller_port: int,
                             manifest: list[dict[str, Any]], out_dir: Path,
                             nonce: str, meta: dict[str, Any],
                             events: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], float, float]:
    """Run predetermined arrivals with no in-line mechanism checks."""
    done = {"n": 0, "ids": set()}
    lock = threading.Lock()
    stop_prog = threading.Event()

    def _remaining_shape(done_ids: set) -> tuple[int, int]:
        """avg_isl/avg_osl over the NOT-yet-completed manifest rows.

        Suite 231344 post-mortem: signalling the static whole-batch avg_isl
        (1195 >= 1024) kept the controller's prefill-pressure hint alive for
        the entire batch — every momentary decode idle re-fired D->P, giving
        a 5-switch oscillation at the MIN_SWITCH_INTERVAL cadence. The RL
        loop's honest signal is the *remaining* work: once the A prompts are
        sampled the remainder is decode-shaped (avg_isl ~573 < 1024) and the
        prefill hint dies on its own, phase-scoping the trigger without any
        controller change.
        """
        remaining = [r for r in manifest if r["manifest_id"] not in done_ids]
        if not remaining:
            return int(meta["avg_isl"]), int(meta["avg_osl"])
        r_isl = int(sum(int(r["words"]) * 1.3 for r in remaining) / len(remaining))
        r_osl = int(sum(int(r["max_tokens"]) for r in remaining) / len(remaining))
        return r_isl, r_osl

    def progress_loop() -> None:
        while not stop_prog.is_set():
            with lock:
                completed = done["n"]
                frac = completed / max(1, len(manifest))
                done_ids = set(done["ids"])
            # Progress updates (frac > 0) are sent only after real
            # completions; the phase-boundary signal itself is emitted once,
            # synchronously, at T0 below — see the comment there.
            if completed == 0:
                stop_prog.wait(0.25)
                continue
            r_isl, r_osl = _remaining_shape(done_ids)
            try:
                e2e.send_progress(controller_port, round(frac, 3), len(manifest),
                                  r_isl, r_osl)
            except Exception:
                pass
            stop_prog.wait(1.0)

    # business_wall starts at the same boundary as T_batch.
    t0 = e2e.now_ts()
    business_clock_start = time.perf_counter()
    e2e.event(events, "T0_batch_dispatch", batch=meta, arrival_mode="phased_no_gate",
              t0_phase_signal=True)
    # RL phase-boundary signal, emitted AT T0 (not before — the pre-T0 guard
    # still fails the run on any earlier switch). In the RL loop the training
    # job knows the rollout batch shape when it dispatches it; announcing it
    # at dispatch is the workload's own signal, and it is the only moment the
    # "prefill burst incoming + decode still idle" condition is physically
    # observable on this model (suite 224207 post-mortem: waiting for the
    # first completion delayed the hint ~12s, by which time decode_util was
    # 0.27+ and D->P was structurally unreachable).
    try:
        e2e.send_progress(controller_port, 0.0, len(manifest),
                          int(meta["avg_isl"]), int(meta["avg_osl"]))
    except Exception:
        pass
    prog = threading.Thread(target=progress_loop, daemon=True)
    prog.start()
    rows: list[dict[str, Any]] = []
    max_inflight = max(1, int(manifest[0].get("concurrency", 48)))
    inflight = threading.Semaphore(max_inflight)

    def submit_at_offset(item: dict[str, Any]) -> dict[str, Any]:
        target = t0 + float(item.get("phase_offset_s", 0) or 0)
        delay = target - e2e.now_ts()
        if delay > 0:
            time.sleep(delay)
        # Sleeping future threads do not consume an HTTP concurrency slot. This
        # keeps phase offsets accurate while preserving the established tunnel-
        # safe maximum number of in-flight requests.
        with inflight:
            return e2e.submit_manifest_request(frontend_port, item, out_dir, nonce)

    with ThreadPoolExecutor(max_workers=len(manifest)) as pool:
        futures = []
        for phase in ("prefill_burst", "decode_dense", "decode_tail"):
            phase_rows = [r for r in manifest if r["phase"] == phase]
            e2e.event(events, "phase_scheduled", phase=phase,
                      offset_s=phase_rows[0]["phase_offset_s"], requests=len(phase_rows))
            futures.extend(pool.submit(submit_at_offset, item) for item in phase_rows)
        for future in as_completed(futures):
            row = future.result()
            with lock:
                done["n"] += 1
                done["ids"].add(int(row["manifest_id"]))
            rows.append(row)

    t_end = e2e.now_ts()
    business_wall_s = time.perf_counter() - business_clock_start
    stop_prog.set()
    prog.join(timeout=5)
    e2e.send_batch_complete(controller_port)
    e2e.event(events, "T_end_batch_complete", completed=len(rows),
              business_wall_s=business_wall_s, T_batch_s=t_end - t0)
    rows.sort(key=lambda r: int(r["manifest_id"]))
    # Promote frontend nvext timing (queue wait / TTFT / worker attribution)
    # into the rows BEFORE requests.csv is written by run_scenario_once.
    enrich_response_metrics(rows, out_dir)
    return rows, t0, t_end


_base_build_summary = base.build_summary


def build_phased_summary(scenario, repeat, position, rows, t0, t_end, meta,
                         pod_rows, prom_rows, status_rows, events, out_dir) -> dict[str, Any]:
    # The legacy continuous harness keeps controller status only in memory.
    # Persist it in this new harness because phase/action attribution is a core
    # objective of the phased test.
    status_path = Path(out_dir) / "controller_status.jsonl"
    status_path.write_text(
        "\n".join(json.dumps(row, ensure_ascii=False) for row in status_rows) + ("\n" if status_rows else ""),
        encoding="utf-8",
    )
    summary = _base_build_summary(scenario, repeat, position, rows, t0, t_end, meta,
                                  pod_rows, prom_rows, status_rows, events, out_dir)
    end_event = next((x for x in reversed(events) if x.get("event") == "T_end_batch_complete"), {})
    business_wall = float(end_event.get("business_wall_s", summary["T_batch_s"]) or summary["T_batch_s"])
    overhead = business_wall - float(summary["T_batch_s"])
    threshold = max(1.0, float(summary["T_batch_s"]) * 0.02)
    summary.update({
        "harness": "phased_no_gate_v2",
        "business_wall_s": business_wall,
        "business_wall_minus_T_batch_s": overhead,
        "wall_alignment_threshold_s": threshold,
        "wall_alignment_ok": abs(overhead) <= threshold,
        "phase_metrics": {},
        "mechanism_history": {
            "s2": e2e.s2_history(status_rows),
            "s3": e2e.s3_history(status_rows),
        },
    })
    # Controller history stores switch_time_ms under result. Correct the legacy
    # summary extraction and make the exact actions self-contained.
    measured_s2 = e2e.s2_history(status_rows)
    measured_s3 = e2e.s3_history(status_rows)
    summary["s2_executed_count"] = sum(1 for item in measured_s2 if item.get("executed"))
    summary["s2_switch_total_ms"] = sum(
        float((item.get("result") or {}).get("switch_time_ms", item.get("switch_time_ms", 0)) or 0)
        for item in measured_s2 if item.get("executed")
    )
    summary["s3_migrated_requests"] = sum(int(item.get("migrated_requests", 0) or 0) for item in measured_s3)
    drained_sources = {source for item in measured_s3 for source in (item.get("drained_sources") or [])}
    summary["s3_drained_source_count"] = len(drained_sources)
    summary["s3_executed_pairs"] = sum(int(item.get("executed_pairs", 0) or 0) for item in measured_s3)
    # S3's benefit axis is GPU exposure, not wall time. Record when the
    # release (scale-down) landed relative to the batch end: the lead time IS
    # the reclaimed 1-GPU window. Derived from the first controller status
    # sample whose s3_history contains a scale-down (history entries carry no
    # timestamp of their own).
    release_ts = None
    for status_row in status_rows:
        history = ((status_row.get("status") or {}).get("strategy") or {}).get("s3_history") or []
        if any(item.get("scaled_down_to") is not None for item in history):
            release_ts = float(status_row.get("ts", 0) or 0)
            break
    summary["s3_release_lead_time_s"] = (
        max(0.0, t_end - release_ts) if release_ts and release_ts <= t_end else 0.0)
    summary["s3_release_ts"] = release_ts
    # Runtime-role-corrected GPU integration (Deployment-based counts are
    # role-blind: an S2-switched pod kept counting as decode).
    summary["effective_runtime_role_gpu_s"] = effective_role_gpu_seconds(pod_rows, t0, t_end)
    for phase in ("prefill_burst", "decode_dense", "decode_tail"):
        phase_rows = [r for r in rows if r.get("phase") == phase]
        if not phase_rows:
            continue
        p0 = min(float(r.get("start_ts", t0) or t0) for r in phase_rows)
        p1 = max(float(r.get("end_ts", p0) or p0) for r in phase_rows)
        q = e2e.summarize_requests(phase_rows)
        alloc = e2e.summarize_pod_allocation(pod_rows, p0, p1)
        completion = float(q.get("completion_tokens", 0) or 0)
        total_gpu_s = float(alloc.get("spec_gpu_allocated_seconds", 0) or 0)
        from collections import Counter
        summary["phase_metrics"][phase] = {
            "request_count": len(phase_rows),
            "scheduled_offset_s": float(meta["phases"][phase]["offset_s"]),
            "first_dispatch_from_T0_s": p0 - t0,
            "dispatch_lag_s": (p0 - t0) - float(meta["phases"][phase]["offset_s"]),
            "last_completion_from_T0_s": p1 - t0,
            "service_window_s": p1 - p0,
            "valid_decode_pct": float(q.get("valid_decode_pct", 0) or 0),
            "timeout_count": int(q.get("timeout_count", 0) or 0),
            "completion_tokens": completion,
            "p50_latency_s": float(q.get("p50_latency_s", 0) or 0),
            "p95_latency_s": float(q.get("p95_latency_s", 0) or 0),
            "prefill_gpu_s": float(alloc.get("prefill_allocated_seconds", 0) or 0),
            "decode_gpu_s": float(alloc.get("spec_decode_allocated_seconds", 0) or 0),
            "total_gpu_s": total_gpu_s,
            "tokens_per_gpu_s": completion / total_gpu_s if total_gpu_s > 0 else 0.0,
            "min_spec_decode_replicas": int(alloc.get("min_spec_decode_replicas", 0) or 0),
            # Queue-time / first-token evidence (frontend nvext timing):
            # prefill_wait = router queue wait before prefill; ttft = queue +
            # prefill compute. These are the per-phase quantities the S2
            # analysis needs (indicator: "queue timing").
            "prefill_wait_time_ms": _dist(_numbers(phase_rows, "prefill_wait_time_ms")),
            "prefill_time_ms": _dist(_numbers(phase_rows, "prefill_time_ms")),
            "ttft_ms": _dist(_numbers(phase_rows, "ttft_ms")),
            "prefill_worker_distribution": dict(Counter(
                str(r.get("prefill_worker_id")) for r in phase_rows
                if r.get("prefill_worker_id") not in {None, ""})),
            "decode_worker_distribution": dict(Counter(
                str(r.get("decode_worker_id")) for r in phase_rows
                if r.get("decode_worker_id") not in {None, ""})),
            # Runtime-role-corrected per-phase GPU integration.
            "effective_runtime_role_gpu_s": effective_role_gpu_seconds(pod_rows, p0, p1),
        }
    return summary


def main() -> int:
    ap = argparse.ArgumentParser(description="Phased no-gate RL-Scaling five-scenario E2E")
    ap.add_argument("--suite-dir", default="")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--batch-size", type=int, default=96)
    ap.add_argument("--seed", type=int, default=20260720)
    ap.add_argument("--concurrency", type=int, default=48)
    ap.add_argument("--phase-b-offset", type=float, default=45.0)
    ap.add_argument("--phase-c-offset", type=float, default=45.0,
                    help="tail cohort arrives with decode_dense and becomes the long tail")
    ap.add_argument("--phase-a-max-tokens", default="1",
                    help="comma-separated max_tokens choices for the prefill "
                         "burst; default 1 makes phase A a pure prefill probe "
                         "(use 64,96,128 to reproduce the legacy shape)")
    ap.add_argument("--sample-interval", type=float, default=1.0)
    ap.add_argument("--scenarios", default="all")
    ap.add_argument("--continue-after-timeout", action="store_true")
    args = ap.parse_args()
    active = SCENARIOS if args.scenarios.strip().lower() in {"all", ""} else [x.strip() for x in args.scenarios.split(",") if x.strip()]
    unknown = [x for x in active if x not in SCENARIOS]
    if unknown:
        raise ValueError(f"unknown scenarios: {unknown}")

    suite_dir = Path(args.suite_dir) if args.suite_dir else Path(
        f"reports/phased-5scenario-{time.strftime('%Y%m%d-%H%M%S')}")
    suite_dir.mkdir(parents=True, exist_ok=True)
    a_tokens = [int(x) for x in str(args.phase_a_max_tokens).split(",") if x.strip()]
    manifest = build_phased_manifest(args.seed, args.batch_size, args.concurrency,
                                     args.phase_b_offset, args.phase_c_offset,
                                     a_token_choices=a_tokens)
    (suite_dir / "workload-manifest.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in manifest) + "\n", encoding="utf-8")
    e2e.write_json(suite_dir / "test-design.json", {
        "harness": "run_phased_rollout_5scenario_e2e.py",
        "arrival_mode": "phased_no_gate_v2",
        "legacy_script_modified": False,
        "config": vars(args),
        "meta": phased_meta(manifest),
    })

    # Patch only the imported module's in-memory call sites.  No legacy source
    # file is edited; its mature prewarm/sampling/log collection is reused.
    base.run_rollout_with_progress = run_phased_with_progress
    base.build_summary = build_phased_summary
    base.batch_meta = phased_meta
    base.scenario_env = prewarm_scenario_env
    base.prewarm = phased_prewarm

    def progress(**data: Any) -> None:
        e2e.write_json(suite_dir / "progress.json", {"ts": e2e.now_ts(), "iso": e2e.ts_iso(), **data})

    runs_by_scenario: dict[str, list[dict[str, Any]]] = {s: [] for s in SCENARIOS}
    aborted = None
    for repeat in range(1, args.repeats + 1):
        order = [s for s in base.counterbalanced(repeat - 1) if s in active]
        progress(stage="round_start", repeat=repeat, order=order)
        for position, scenario in enumerate(order, 1):
            progress(stage="run_start", repeat=repeat, scenario=scenario, position=position)
            summary = base.run_scenario_once(suite_dir, scenario, repeat, position,
                                             manifest, args.sample_interval)
            runs_by_scenario[scenario].append(summary)
            progress(stage="run_done", repeat=repeat, scenario=scenario,
                     T_batch_s=summary["T_batch_s"], wall_alignment_ok=summary["wall_alignment_ok"])
            if summary["timeout_count"] > 0 and not args.continue_after_timeout:
                aborted = f"timeout in {scenario} r{repeat}: {summary['timeout_count']}"
                break
        if aborted:
            break

    aggregates = {}
    for scenario in SCENARIOS:
        if runs_by_scenario[scenario]:
            agg = base.aggregate_scenario(scenario, runs_by_scenario[scenario])
            aggregates[scenario] = agg
            e2e.write_json(suite_dir / scenario / "aggregate-summary.json", agg)
    e2e.write_json(suite_dir / "consolidated-data.json", {
        "suite": suite_dir.name,
        "harness": "phased_no_gate_v1",
        "config": vars(args),
        "scenarios": SCENARIOS,
        "aborted": aborted,
        "aggregates": aggregates,
        "all_runs": [r for s in SCENARIOS for r in runs_by_scenario[s]],
    })
    progress(stage="suite_done", aborted=aborted)
    print(f"PHASED SUITE {'ABORTED: ' + aborted if aborted else 'DONE'} -> {suite_dir}")
    return 1 if aborted else 0


if __name__ == "__main__":
    raise SystemExit(main())
