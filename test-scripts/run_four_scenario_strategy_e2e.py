#!/usr/bin/env python3
"""Run the formal four-scenario RL-Scaling strategy E2E suite.

The suite intentionally separates preparation time from serving wall time.
Dynamic scenarios must be warm and routable before the measured batch starts.
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

import rls_strategy_common as e2e


PHASES = ["prefill_burst", "balanced_decode", "decode_tail"]
SCENARIOS = ["baseline_minimal", "s2_only", "s3_only", "mixed_strategy"]
MIN_VALID_DECODE_PCT = 99.0
MAX_S2_SWITCHES_PER_RUN = 2
S3_TAIL_TRIGGER_MIN_DELAY_S = 4.0
S3_TAIL_TRIGGER_POLL_S = 1.0
# A migratable straggler must have generated enough to be worth moving and have
# enough left to run that the migration overhead pays off (token-progress window
# from test-strategy.md §11.3). Sized for the long tail requests (max_tokens=160).
S3_TRIGGER_MIN_GENERATED_TOKENS = 8
S3_TRIGGER_MIN_REMAINING_TOKENS = 24


def write_progress(suite_dir: Path, **data: Any) -> None:
    e2e.write_json(suite_dir / "progress.json", {"ts": e2e.now_ts(), "iso": e2e.ts_iso(), **data})


def build_manifest() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    idx = 1

    # Prefill-heavy phase: long input, short output. This is where S2 D->P
    # should help by adding prefill capacity without measuring warmup time.
    #
    # Prompt size / output length are sized to this cluster's disagg KV
    # TRANSPORT, which has no RDMA (pods lack /dev/infiniband and per-pod GPU
    # isolation blocks cuda_ipc), so cross-pod KV transfer falls back to
    # TCP-over-overlay at ~32-54 MB/s with ~0.57ms/descriptor. A 3200-word
    # prompt produces a ~1.2GB / ~38k-descriptor transfer that takes 10-58s and
    # backs up on the decode-bound worker, timing out tail requests. 1200 words
    # keeps prefill the bottleneck (so D->P still helps) while keeping each
    # transfer fast enough to avoid the backlog; max_tokens=8 keeps the decode
    # phase from bottlenecking the single decode worker during 3P1D. With RDMA
    # the original 3200/48 workload would also serve; see NIXL/receive analysis.
    for _ in range(64):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "prefill_burst",
                "words": 400,
                "max_tokens": 4,
                "concurrency": 12,
                "timeout_s": 600,
                "shape": "long_prompt_short_decode",
            }
        )
        idx += 1

    # Balanced phase: enough decode pressure to make an optional P->D return
    # useful, but not long enough to let S2 churn repeatedly.
    for _ in range(24):
        rows.append(
            {
                "manifest_id": idx,
                "phase": "balanced_decode",
                "words": 200,
                "max_tokens": 96,
                "concurrency": 8,
                "timeout_s": 600,
                "shape": "medium_prompt_medium_decode",
            }
        )
        idx += 1

    # Tail phase: explicit long-tail mix for S3 consolidation.
    #
    # KEY (2026-07-12): S3 can only migrate a request that is actually IN-FLIGHT
    # when the controller polls /v1/active_requests. This small model hits EOS
    # after ~1-2k tokens and decodes at ~2000 tok/s, so an ordinary
    # max_tokens=48 request finishes in ~0.02s and is NEVER caught — which is why
    # every prior run showed migrated=0 (a workload artefact, not a broken S3
    # mechanism; migrate->drain is validated directly via the sidecar /migrate).
    #
    # So the tail is two parts:
    #   * A short/medium burst (natural EOS) that completes fast and forms the
    #     "batch mostly complete" context the consolidation gate looks for.
    #   * A few genuine long stragglers with ignore_eos=true + high max_tokens.
    #     They keep a real, token-progressing request in-flight for ~20-30s
    #     (under tail contention), long enough for the controller to detect,
    #     migrate, drain the source, and scale a decode replica down (GPU
    #     release). Small prompts (48 words) keep their prefill KV transfer tiny
    #     so they never hit the no-RDMA transport backlog that times out large
    #     prompts. Staggered budgets + emitting them FIRST (so they start while
    #     both decoders are empty) encourage a 2+1 / 1+1 split across the two
    #     decoders, giving the gate a source with exactly one in-flight request
    #     (consolidation_threshold=1).
    tail_concurrency = 8
    # (count, words, max_tokens, shape, ignore_eos) — stragglers first.
    # Sizing (validated 2026-07-12 s3-derisk run): the consolidation trigger
    # fires EARLY — at only ~2200 generated tokens, ~20s into the tail — so the
    # stragglers do not need to be huge to be caught. Sustained aggregate decode
    # here is ~300 tok/s, so max_tokens=8000 still keeps each straggler in-flight
    # ~50-80s (plenty for the 4s delay + controller ticks + drain), while
    # bounding KV: baseline_minimal is 1P1D, so all 3 stragglers share ONE decode
    # GPU the whole run (3x8000=24k tokens fits without the preemption thrash a
    # 30k budget caused — that run's tail hit 219s, within 20s of the 240s
    # timeout). timeout_s=300 leaves generous headroom on the worst case.
    tail_shapes = [
        (3, 48, 8000, "tail_long", True),
        (8, 64, 16, "tail_short", False),
        (6, 64, 32, "tail_medium", False),
    ]
    # Stagger between successive stragglers so the KV router does not route them
    # all to one decoder (a 3+0 split leaves no source with in_flight==1, so
    # consolidation cannot fire). 4s lets each straggler's load register before
    # the next is routed, biasing toward a 2+1 spread across the two decoders.
    straggler_stagger_s = 4
    for count, words, max_tokens, shape, ignore_eos in tail_shapes:
        for i in range(count):
            row = {
                "manifest_id": idx,
                "phase": "decode_tail",
                "words": words,
                "max_tokens": max_tokens,
                "concurrency": tail_concurrency,
                # Stragglers run to max_tokens (~20-30s under contention) and a
                # migrated straggler pays recompute-replay overhead, so give the
                # long shape plenty of client-side headroom; short/medium keep
                # the tight 120s bound.
                "timeout_s": 300 if ignore_eos else 120,
                "shape": shape,
                "ignore_eos": ignore_eos,
                # Only the long stragglers stagger; short/medium fire immediately.
                "launch_delay_s": (i * straggler_stagger_s) if ignore_eos else 0,
            }
            rows.append(row)
            idx += 1
    return rows


def write_manifest(path: Path, manifest: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in manifest) + "\n", encoding="utf-8")


def load_manifest(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]


def scenario_env(name: str) -> dict[str, str]:
    base = {
        "CONTROL_LOOP_INTERVAL": "1",
        "K8S_SCALE_FALLBACK_ENABLED": "true",
        "MAX_GPUS": "4",
        "MIN_PREFILL_REPLICAS": "1",
        "MIN_DECODE_REPLICAS": "1",
        "MAX_CONCURRENT_PER_DECODE": "64",
        "SINGLE_PREFILL_TPS": "50000",
        "TARGET_PREFILL_SECONDS": "5",
        "COOLDOWN_SECONDS": "20",
        "DRAIN_TIMEOUT_SECONDS": "120",
        "CONSOLIDATION_DRAIN_TIMEOUT": "120",
        "CONSOLIDATION_DRAIN_POLL_INTERVAL": "1",
    }
    disabled = {
        "PRE_WARM_THRESHOLD": "2.0",
        "ROLE_SWITCH_ENABLED": "false",
        "CONSOLIDATION_ENABLED": "false",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
    }
    s2 = {
        "PRE_WARM_THRESHOLD": "0.80",
        "ROLE_SWITCH_ENABLED": "true",
        "CONSOLIDATION_ENABLED": "false",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
        "PREFILL_QUEUE_THRESHOLD": "1",
        "DECODE_QUEUE_THRESHOLD": "2",
        "DECODE_IDLE_THRESHOLD": "0.30",
        "PREFILL_IDLE_THRESHOLD": "0.30",
        "MIN_SWITCH_INTERVAL": "60",
        "ROLE_SWITCH_VERIFY_TIMEOUT": "60",
        "ROLE_SWITCH_VERIFY_POLL_INTERVAL": "1",
    }
    s3 = {
        "PRE_WARM_THRESHOLD": "0.80",
        "ROLE_SWITCH_ENABLED": "false",
        "CONSOLIDATION_ENABLED": "true",
        "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
        "CONSOLIDATION_THRESHOLD": "1",
        "CONSOLIDATION_STABLE_SAMPLES": "1",
        "CONSOLIDATION_MIN_INTERVAL": "4",
        "MIN_BATCH_COMPLETION": "0.92",
        "PER_REQUEST_MIGRATION_OVERHEAD": "0.10",
    }
    if name == "baseline_minimal":
        return {**base, **disabled}
    if name == "s2_only":
        return {**base, **s2}
    if name == "s3_only":
        return {**base, **s3}
    if name == "mixed_strategy":
        return {**base, **s2, **s3, "ROLE_SWITCH_ENABLED": "true", "MIN_SWITCH_INTERVAL": "60"}
    raise ValueError(name)


def status_poller(controller_port: int, rows: list[dict[str, Any]], stop: threading.Event, interval: float) -> None:
    while not stop.is_set():
        e2e.status_sample(controller_port, rows, "poll")
        time.sleep(interval)


def send_warmup_and_wait(
    scenario: str,
    controller_port: int,
    frontend_port: int,
    events: list[dict[str, Any]],
    status_rows: list[dict[str, Any]],
) -> dict[str, float]:
    client_signal_send = e2e.now_ts()
    response = e2e.send_progress(controller_port, 0.85, batch_size=128, avg_isl=3072, avg_osl=512)
    signal_recv = e2e.now_ts()
    e2e.event(events, "T_signal_recv", scenario=scenario, response=response, client_signal_send=client_signal_send)
    e2e.event(events, "T_warmup_start", scenario=scenario)
    # Give the controller a chance to pre-warm to 2P2D autonomously (on_sampling_
    # progress only scales up from IDLE, and that scale-up is occasionally not
    # applied); if it has not reached 2P2D within the grace window, force the
    # topology via the deployment scaler. Pre-warm-scaling reliability is not
    # what S2/S3 measures — the scenarios only need to START at 2P2D — so this
    # guarantees the starting topology instead of hanging the whole suite.
    grace_deadline = time.time() + 90
    forced = False
    while True:
        try:
            p, d = e2e.count_ready_by_component()
        except Exception:
            p, d = 0, 0
        if p >= 2 and d >= 2:
            break
        if time.time() >= grace_deadline:
            e2e.event(events, "warmup_forcing_topology", got={"prefill": p, "decode": d},
                      note="controller did not pre-warm to 2P2D; forcing via deployment scaler")
            e2e.set_topology(2, 2)
            forced = True
            break
        time.sleep(3)
    if forced:
        # Re-assert the warm-up signal so controller state matches the topology.
        e2e.send_progress(controller_port, 0.85, batch_size=128, avg_isl=3072, avg_osl=512)
    e2e.wait_ready_counts(prefill=2, decode=2, timeout_s=300)
    time.sleep(30)
    for _ in range(3):
        e2e.wait_frontend_chat_ready(frontend_port, timeout_s=240)
        time.sleep(2)
    ready = e2e.now_ts()
    e2e.status_sample(controller_port, status_rows, "after_warmup_ready")
    e2e.event(events, "T_ready", scenario=scenario, prefill=2, decode=2)
    return {"T_signal_recv": signal_recv, "T_warmup_start": signal_recv, "T_ready": ready}


def append_jsonl(path: Path, row: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def _has_migratable_straggler(snapshot: dict[str, Any]) -> dict[str, Any] | None:
    """Return the best token-progress-qualified in-flight request, if any.

    A request qualifies when it has generated enough tokens to be worth moving
    and has enough tokens left to run that the migration overhead pays off.
    """
    best: dict[str, Any] | None = None
    for worker in snapshot.get("workers", []) or []:
        for req in worker.get("active_requests", []) or []:
            if not isinstance(req, dict):
                continue
            gen = int(req.get("generated_tokens", 0) or 0)
            rem = req.get("remaining_tokens")
            rem = int(rem) if isinstance(rem, (int, float)) else None
            if gen >= S3_TRIGGER_MIN_GENERATED_TOKENS and (
                rem is None or rem >= S3_TRIGGER_MIN_REMAINING_TOKENS
            ):
                cand = {"worker": worker.get("pod"), "generated_tokens": gen, "remaining_tokens": rem}
                if best is None or (rem or 0) > (best.get("remaining_tokens") or 0):
                    best = cand
    return best


def tail_signal_on_active_window(
    controller_port: int,
    out_dir: Path,
    events: list[dict[str, Any]],
    stop: threading.Event,
    phase_count: int,
) -> None:
    started = e2e.now_ts()
    snapshot_path = out_dir / "active_requests_snapshots.jsonl"
    e2e.event(
        events,
        "tail_active_window_poll_start",
        min_delay_s=S3_TAIL_TRIGGER_MIN_DELAY_S,
        min_generated_tokens=S3_TRIGGER_MIN_GENERATED_TOKENS,
        min_remaining_tokens=S3_TRIGGER_MIN_REMAINING_TOKENS,
        note="continuously poll /v1/active_requests for the whole tail phase; "
        "signal consolidation when a token-progress-qualified straggler exists",
    )
    signalled = False
    last_signal_ts = 0.0
    last_snapshot: dict[str, Any] | None = None
    # Poll for the entire decode_tail phase (driven by ``stop``), not a fixed
    # window — the qualifying straggler often appears only as the tail drains.
    while not stop.is_set():
        try:
            snapshot = e2e.collect_decode_active_requests()
            snapshot["elapsed_s"] = e2e.now_ts() - started
            append_jsonl(snapshot_path, snapshot)
            last_snapshot = snapshot
            elapsed = float(snapshot["elapsed_s"])
            straggler = _has_migratable_straggler(snapshot)
            now = e2e.now_ts()
            # Re-send the 0.92 completion signal while a qualifying straggler
            # exists so the controller's batch_completion stays above the gate
            # across the ticks where the source decoder drains to <=threshold.
            if elapsed >= S3_TAIL_TRIGGER_MIN_DELAY_S and straggler and (now - last_signal_ts) >= 3.0:
                response = e2e.send_progress(controller_port, 0.92, batch_size=phase_count, avg_isl=128, avg_osl=320)
                last_signal_ts = now
                e2e.event(
                    events,
                    "tail_consolidation_signal",
                    response=response,
                    trigger="token_progress_straggler",
                    straggler=straggler,
                    total_active=int(snapshot.get("total_active", 0) or 0),
                    active_worker_count=int(snapshot.get("active_worker_count", 0) or 0),
                    snapshot_file=str(snapshot_path),
                )
                signalled = True
        except Exception as exc:  # noqa: BLE001
            append_jsonl(snapshot_path, {"ts": e2e.now_ts(), "iso": e2e.ts_iso(), "error": str(exc)})
            e2e.event(events, "tail_active_window_poll_error", error=str(exc))
        time.sleep(S3_TAIL_TRIGGER_POLL_S)
    if not signalled:
        e2e.event(
            events,
            "tail_consolidation_signal_skipped",
            reason="no_token_progress_straggler",
            last_snapshot=last_snapshot,
            snapshot_file=str(snapshot_path),
        )


def _soft_role_gate(
    events: list[dict[str, Any]],
    label: str,
    *,
    prefill: int,
    decode: int,
    timeout_s: int,
    snapshot_path: Path,
) -> dict[str, Any]:
    """Wait for a runtime role topology, but NEVER raise.

    The S2 role switches are driven by the controller's real queue/util
    metrics, so the exact moment a switch lands is inherently timing-dependent
    (and a switch can be briefly blocked by MIN_SWITCH_INTERVAL). A hard wait
    here previously turned that timing into an unhandled TimeoutError that
    aborted the entire suite. Instead, record whether the target topology was
    reached and let the phase proceed; the phase's own decode load then drives
    any pending switch reactively, and the continuous role snapshots capture it.
    """
    try:
        return e2e.wait_runtime_role_counts(
            prefill=prefill, decode=decode, timeout_s=timeout_s, snapshot_path=snapshot_path,
        )
    except TimeoutError as exc:
        snapshot = e2e.collect_worker_roles()
        e2e.event(
            events,
            f"{label}_timeout_nonfatal",
            expected={"prefill": prefill, "decode": decode},
            got=snapshot.get("role_counts", {}),
            note="proceeding without hard topology gate; switch may occur reactively under load",
            error=str(exc)[:200],
        )
        return snapshot


def run_phase(
    scenario: str,
    phase: str,
    controller_port: int,
    frontend_port: int,
    manifest: list[dict[str, Any]],
    out_dir: Path,
    nonce: str,
    events: list[dict[str, Any]],
    status_rows: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    phase_items = [row for row in manifest if row["phase"] == phase]
    role_snapshot_path = out_dir / "worker_role_snapshots.jsonl"
    if phase == "prefill_burst" and scenario in {"s2_only", "mixed_strategy"}:
        response = e2e.send_progress(controller_port, 0.30, batch_size=len(phase_items), avg_isl=4096, avg_osl=64)
        e2e.event(events, "prefill_pressure_signal", response=response)
        role_snapshot = _soft_role_gate(
            events, "runtime_role_gate_after_d_to_p", prefill=3, decode=1,
            timeout_s=180, snapshot_path=role_snapshot_path,
        )
        e2e.event(events, "runtime_role_gate_after_d_to_p", snapshot=role_snapshot)
    if phase == "balanced_decode" and scenario in {"s2_only", "mixed_strategy"}:
        response = e2e.send_done(controller_port, batch_size=len(phase_items), avg_isl=512, avg_osl=512)
        e2e.event(events, "decode_pressure_signal", response=response)
        # NON-FATAL gate: the S2 P->D switch-back is driven by REAL decode-queue
        # pressure, but that pressure only exists once the decode load (this
        # balanced_decode phase, then the tail) is actually sent — and
        # MIN_SWITCH_INTERVAL can block a switch until the prefill burst's decode
        # pressure has drained. So do not hard-block here (a premature wait that
        # once crashed the whole suite); proceed, let the balanced_decode load
        # drive the reactive P->D, and re-observe roles afterwards.
        # Short pre-observation only: no decode load exists yet, so the switch
        # cannot have fired. The real P->D is driven below, after this phase's
        # load runs (see the post-phase soft gate).
        role_snapshot = _soft_role_gate(
            events, "runtime_role_gate_before_p_to_d", prefill=2, decode=2,
            timeout_s=10, snapshot_path=role_snapshot_path,
        )
        e2e.event(events, "runtime_role_gate_before_p_to_d", snapshot=role_snapshot)
        for _ in range(2):
            e2e.wait_frontend_chat_ready(frontend_port, timeout_s=180)
            time.sleep(1)
        e2e.wait_frontend_long_decode_ready(frontend_port, timeout_s=240, max_tokens=48)
        e2e.event(events, "decode_readiness_after_switch", long_decode_probe_max_tokens=48)
    tail_thread: threading.Thread | None = None
    tail_stop = threading.Event()
    if phase == "decode_tail" and scenario in {"s3_only", "mixed_strategy"}:
        tail_thread = threading.Thread(
            target=tail_signal_on_active_window,
            args=(controller_port, out_dir, events, tail_stop, len(phase_items)),
            daemon=True,
        )
        tail_thread.start()

    e2e.status_sample(controller_port, status_rows, f"before_{phase}")
    e2e.event(events, f"{phase}_start")
    rows = e2e.run_manifest_phase(frontend_port, manifest, phase, out_dir, nonce)
    e2e.event(events, f"{phase}_done", **e2e.summarize_requests(rows))
    e2e.status_sample(controller_port, status_rows, f"after_{phase}")
    # After balanced_decode's real decode load, give the controller a window to
    # land the reactive P->D switch-back (restoring 2P2D) so the decode_tail —
    # and, for mixed, S3 consolidation which needs >1 decode worker — runs on the
    # intended topology. Non-fatal: if it does not switch, the tail still runs.
    if phase == "balanced_decode" and scenario in {"s2_only", "mixed_strategy"}:
        # The reliable P->D trigger is the decode_tail stragglers (sustained
        # decode_queue>=2 with idle prefill), so this is a short best-effort
        # observation only; the switch typically lands during decode_tail.
        role_snapshot = _soft_role_gate(
            events, "runtime_role_gate_after_p_to_d", prefill=2, decode=2,
            timeout_s=30, snapshot_path=role_snapshot_path,
        )
        e2e.event(events, "runtime_role_gate_after_p_to_d", snapshot=role_snapshot)
    if tail_thread:
        tail_stop.set()
        tail_thread.join(timeout=20)
    return rows


def phase_allocation(pod_samples: list[dict[str, Any]], rows: list[dict[str, Any]]) -> dict[str, Any]:
    start = min((float(row["start_ts"]) for row in rows), default=None)
    end = max((float(row["end_ts"]) for row in rows), default=None)
    return e2e.summarize_pod_allocation(pod_samples, start, end)


def s2_directions(summary: dict[str, Any]) -> list[str]:
    directions: list[str] = []
    for item in summary.get("_s2_history", []) or []:
        if not item.get("executed"):
            continue
        src = item.get("from_role") or item.get("source_role") or item.get("old_role") or ""
        dst = item.get("to_role") or item.get("target_role") or item.get("new_role") or ""
        if src or dst:
            directions.append(f"{src}->{dst}")
        else:
            action = item.get("action") or item.get("selected_action") or item.get("decision") or "executed"
            directions.append(str(action))
    return directions


def add_quality_and_effect(summary: dict[str, Any]) -> None:
    overall = summary.get("overall_summary", {})
    scenario = summary.get("scenario")
    timeout_count = int(overall.get("timeout_count", 0) or 0)
    http_5xx_count = int(overall.get("http_5xx_count", 0) or 0)
    valid_pct = float(overall.get("valid_decode_pct", 0.0) or 0.0)
    s2_count = int(summary.get("s2_executed_count", 0) or 0)
    s3_migrated = int(summary.get("s3_migrated_requests", 0) or 0)
    s3_drained = len(summary.get("s3_drained_sources", []) or [])
    phase_alloc = summary.get("phase_allocations", {})
    tail_phase = summary.get("phase_summaries", {}).get("decode_tail", {})
    tail_alloc = phase_alloc.get("decode_tail", {})
    tail_wall = float(tail_phase.get("wall_s", 0.0) or 0.0)
    observed_tail_decode_gpu_s = float(tail_alloc.get("decode_allocated_seconds", 0.0) or 0.0)
    counterfactual_tail_decode_gpu_s = tail_wall * 2.0 if scenario in {"s3_only", "mixed_strategy"} else tail_wall
    tail_saving = counterfactual_tail_decode_gpu_s - observed_tail_decode_gpu_s
    summary["tail_gpu_efficiency"] = {
        "tail_wall_s": tail_wall,
        "observed_tail_decode_gpu_s": observed_tail_decode_gpu_s,
        "counterfactual_2d_decode_gpu_s": counterfactual_tail_decode_gpu_s,
        "tail_decode_gpu_s_saved": tail_saving,
        "tail_decode_gpu_s_savings_pct": (tail_saving / counterfactual_tail_decode_gpu_s * 100.0)
        if counterfactual_tail_decode_gpu_s > 0
        else 0.0,
    }
    summary["s2_directions"] = s2_directions(summary)
    summary["quality_gate"] = {
        "passed": valid_pct >= MIN_VALID_DECODE_PCT and timeout_count == 0 and http_5xx_count == 0,
        "min_valid_decode_pct": MIN_VALID_DECODE_PCT,
        "valid_decode_pct": valid_pct,
        "timeout_count": timeout_count,
        "http_5xx_count": http_5xx_count,
    }
    summary["scenario_gate"] = {
        "passed": True,
        "reasons": [],
    }
    if scenario == "baseline_minimal":
        if s2_count != 0 or s3_migrated != 0:
            summary["scenario_gate"]["passed"] = False
            summary["scenario_gate"]["reasons"].append("baseline must not execute S2 or S3")
    if scenario in {"s2_only", "mixed_strategy"}:
        if s2_count <= 0:
            summary["scenario_gate"]["passed"] = False
            summary["scenario_gate"]["reasons"].append("S2 action evidence missing")
        if s2_count > MAX_S2_SWITCHES_PER_RUN:
            summary["scenario_gate"]["passed"] = False
            summary["scenario_gate"]["reasons"].append("S2 switched too frequently")
    if scenario == "s2_only" and s3_migrated != 0:
        summary["scenario_gate"]["passed"] = False
        summary["scenario_gate"]["reasons"].append("S3 must stay disabled in s2_only")
    if scenario in {"s3_only", "mixed_strategy"}:
        if s3_migrated <= 0 and s3_drained <= 0:
            summary["scenario_gate"]["passed"] = False
            summary["scenario_gate"]["reasons"].append("S3 migration/drain evidence missing")
    if scenario == "s3_only" and s2_count != 0:
        summary["scenario_gate"]["passed"] = False
        summary["scenario_gate"]["reasons"].append("S2 must stay disabled in s3_only")
    summary["performance_valid"] = bool(summary["quality_gate"]["passed"] and summary["scenario_gate"]["passed"])


def run_readiness_gate(suite_dir: Path, sample_interval: float) -> dict[str, Any]:
    out_dir = suite_dir / "readiness_gate"
    out_dir.mkdir(parents=True, exist_ok=True)
    events: list[dict[str, Any]] = []
    status_rows: list[dict[str, Any]] = []
    requests: list[dict[str, Any]] = []
    stop = threading.Event()
    sampler = e2e.PodSampler(sample_interval, stop)
    frontend_pf = controller_pf = None
    status_thread: threading.Thread | None = None
    since_iso = e2e.ts_utc_since()
    gate_manifest = [
        {
            "manifest_id": i + 1,
            "phase": "prefill_burst",
            "words": 2400,
            "max_tokens": 16,
            "concurrency": 8,
            "timeout_s": 300,
            "shape": "readiness_prefill",
        }
        for i in range(16)
    ]
    try:
        threading.Thread(target=sampler.run, daemon=True).start()
        env = scenario_env("s2_only")
        env["RLS_TEST_RUN_ID"] = f"readiness-{int(time.time())}"
        e2e.configure_controller(env)
        e2e.set_topology(1, 1)
        frontend_pf = e2e.start_port_forward(e2e.FRONTEND_SVC, 8000, e2e.NS)
        controller_pf = e2e.start_port_forward(f"svc/{e2e.CONTROLLER_DEPLOY}", 8080, e2e.CONTROLLER_NS)
        e2e.wait_http(f"http://127.0.0.1:{frontend_pf.local_port}/health", timeout_s=120)
        e2e.wait_http(f"http://127.0.0.1:{controller_pf.local_port}/healthz", timeout_s=120)
        e2e.wait_frontend_chat_ready(frontend_pf.local_port)
        status_thread = threading.Thread(target=status_poller, args=(controller_pf.local_port, status_rows, stop, sample_interval), daemon=True)
        status_thread.start()
        e2e.event(events, "readiness_prefill_signal", response=e2e.send_progress(controller_pf.local_port, 0.20, 32, 4096, 64))
        requests = e2e.run_manifest_phase(frontend_pf.local_port, gate_manifest, "prefill_burst", out_dir, "readiness")
        time.sleep(8)
        e2e.status_sample(controller_pf.local_port, status_rows, "readiness_after_load")
    finally:
        if frontend_pf:
            frontend_pf.stop()
        if controller_pf:
            controller_pf.stop()
        stop.set()
        if status_thread:
            status_thread.join(timeout=10)
        e2e.capture_logs(out_dir, since_iso)

    s2_eval = e2e.summarize_s2_evaluations(status_rows)
    passed = (
        s2_eval.get("count", 0) > 0
        or s2_eval.get("max_prefill_queue_depth", 0) > 0
        or e2e.summarize_requests(requests).get("valid_decode_pct", 0.0) >= MIN_VALID_DECODE_PCT
    )
    summary = e2e.finalize_artifacts(
        out_dir,
        events,
        requests,
        status_rows,
        sampler.rows,
        {"prefill_burst": e2e.summarize_requests(requests)},
        {"scenario": "readiness_gate", "passed": passed, "preparation": {}},
    )
    summary["passed"] = passed
    e2e.write_json(out_dir / "summary.json", summary)
    write_readiness_report(out_dir, summary)
    return summary


def run_scenario_once(
    suite_dir: Path,
    scenario: str,
    repeat: int,
    manifest: list[dict[str, Any]],
    sample_interval: float,
    observe_after_tail_s: int,
    abort_on_timeout: bool = True,
) -> dict[str, Any]:
    out_dir = suite_dir / scenario / f"run-{repeat:02d}"
    out_dir.mkdir(parents=True, exist_ok=True)
    nonce = f"{scenario}-run-{repeat}-{int(time.time())}"
    events: list[dict[str, Any]] = []
    requests: list[dict[str, Any]] = []
    status_rows: list[dict[str, Any]] = []
    phase_summaries: dict[str, Any] = {}
    phase_rows: dict[str, list[dict[str, Any]]] = {}
    stop = threading.Event()
    sampler = e2e.PodSampler(sample_interval, stop)
    frontend_pf = controller_pf = None
    status_thread: threading.Thread | None = None
    since_iso = e2e.ts_utc_since()
    setup_start = e2e.now_ts()
    preparation: dict[str, float | None] = {}
    aborted_reason: str | None = None
    try:
        threading.Thread(target=sampler.run, daemon=True).start()
        env = scenario_env(scenario)
        env["RLS_TEST_RUN_ID"] = nonce
        e2e.configure_controller(env)
        e2e.event(events, "controller_configured", scenario=scenario, env=env)
        e2e.set_topology(1, 1)
        e2e.event(events, "initial_1p1d_ready")
        frontend_pf = e2e.start_port_forward(e2e.FRONTEND_SVC, 8000, e2e.NS)
        controller_pf = e2e.start_port_forward(f"svc/{e2e.CONTROLLER_DEPLOY}", 8080, e2e.CONTROLLER_NS)
        e2e.wait_http(f"http://127.0.0.1:{frontend_pf.local_port}/health", timeout_s=120)
        e2e.wait_http(f"http://127.0.0.1:{controller_pf.local_port}/healthz", timeout_s=120)
        e2e.wait_frontend_chat_ready(frontend_pf.local_port)
        status_thread = threading.Thread(target=status_poller, args=(controller_pf.local_port, status_rows, stop, sample_interval), daemon=True)
        status_thread.start()
        e2e.status_sample(controller_pf.local_port, status_rows, "initial")

        if scenario == "baseline_minimal":
            ready = e2e.now_ts()
            preparation.update({"T_signal_recv": None, "T_warmup_start": None, "T_ready": ready})
            e2e.event(events, "baseline_static_1p1d_ready")
        else:
            preparation.update(send_warmup_and_wait(scenario, controller_pf.local_port, frontend_pf.local_port, events, status_rows))

        for phase in PHASES:
            if phase == "prefill_burst":
                preparation["T_burst_arrival"] = e2e.now_ts()
                e2e.event(events, "T_burst_arrival", scenario=scenario)
            rows = run_phase(scenario, phase, controller_pf.local_port, frontend_pf.local_port, manifest, out_dir, nonce, events, status_rows)
            phase_rows[phase] = rows
            phase_summary = e2e.summarize_requests(rows)
            phase_summaries[phase] = phase_summary
            requests.extend(rows)
            if abort_on_timeout and int(phase_summary.get("timeout_count", 0) or 0) > 0:
                aborted_reason = f"{phase} timeout_count={phase_summary.get('timeout_count')}"
                e2e.event(events, "run_aborted_on_timeout", scenario=scenario, phase=phase, reason=aborted_reason)
                break

        if not aborted_reason and observe_after_tail_s > 0:
            time.sleep(observe_after_tail_s)
            e2e.status_sample(controller_pf.local_port, status_rows, "after_tail_observe")

        if not aborted_reason and scenario in {"s3_only", "mixed_strategy"}:
            try:
                e2e.event(events, "batch_complete_signal", response=e2e.send_batch_complete(controller_pf.local_port))
            except Exception as exc:
                e2e.event(events, "batch_complete_signal_failed", error=str(exc))
            time.sleep(8)
            e2e.status_sample(controller_pf.local_port, status_rows, "after_batch_complete")
    finally:
        if frontend_pf:
            frontend_pf.stop()
        if controller_pf:
            controller_pf.stop()
        stop.set()
        if status_thread:
            status_thread.join(timeout=10)
        e2e.capture_logs(out_dir, since_iso)

    phase_allocations = {phase: phase_allocation(sampler.rows, rows) for phase, rows in phase_rows.items()}
    summary = e2e.finalize_artifacts(
        out_dir,
        events,
        requests,
        status_rows,
        sampler.rows,
        phase_summaries,
        {
            "scenario": scenario,
            "repeat": repeat,
            "manifest_request_count": len(manifest),
            "initial_topology": {"prefill": 1, "decode": 1},
            "warmup_target": None if scenario == "baseline_minimal" else {"prefill": 2, "decode": 2},
            "phase_allocations": phase_allocations,
            "_s2_history": e2e.s2_history(status_rows),
            "aborted": bool(aborted_reason),
            "aborted_reason": aborted_reason,
            "preparation": {
                **preparation,
                "setup_start_ts": setup_start,
                "setup_to_first_request_s": min((float(r["start_ts"]) for r in requests), default=e2e.now_ts()) - setup_start,
            },
        },
    )
    add_quality_and_effect(summary)
    if aborted_reason:
        summary["quality_gate"]["passed"] = False
        summary["scenario_gate"]["passed"] = False
        summary["scenario_gate"]["reasons"].append(aborted_reason)
        summary["performance_valid"] = False
    e2e.write_json(out_dir / "summary.json", summary)
    write_run_report(out_dir, summary)
    return summary


def row_from_summary(summary: dict[str, Any]) -> dict[str, Any]:
    overall = summary.get("overall_summary", {})
    alloc = summary.get("request_window_pod_allocation", {})
    tail = summary.get("tail_gpu_efficiency", {})
    gpu_s = float(alloc.get("gpu_allocated_seconds", 0.0) or 0.0)
    completion = float(overall.get("completion_tokens", 0.0) or 0.0)
    success = float(overall.get("success", 0.0) or 0.0)
    # --- "fair-cost" metrics: measure ONLY the post-warmup request serving plus
    # the discrete strategy actions, excluding the test harness's inter-phase
    # readiness/topology-verification waits and the cold-start warmup. ---
    phase_summ = summary.get("phase_summaries", {})
    phase_alloc = summary.get("phase_allocations", {})
    PHASES = ("prefill_burst", "balanced_decode", "decode_tail")
    def _pw(p: str) -> float:
        return float(phase_summ.get(p, {}).get("wall_s", 0.0) or 0.0)
    serving_wall = sum(_pw(p) for p in PHASES)  # pure request serving, no gaps
    serving_gpu_s = sum(float(phase_alloc.get(p, {}).get("gpu_allocated_seconds", 0.0) or 0.0) for p in PHASES)
    overall_wall = float(overall.get("wall_s", 0.0) or 0.0)
    switch_lat = summary.get("s2_switch_latencies_ms", []) or []
    s2_switch_total_ms = float(sum(float(x) for x in switch_lat))
    return {
        "repeat": summary.get("repeat"),
        "performance_valid": bool(summary.get("performance_valid")),
        "wall_s": float(overall.get("wall_s", 0.0) or 0.0),
        "valid_decode_pct": float(overall.get("valid_decode_pct", 0.0) or 0.0),
        "timeout_count": int(overall.get("timeout_count", 0) or 0),
        "req_s": float(overall.get("req_s", 0.0) or 0.0),
        "p95_latency_s": float(overall.get("p95_latency_s", 0.0) or 0.0),
        "completion_tps": float(overall.get("completion_tps", 0.0) or 0.0),
        "gpu_s": gpu_s,
        "requests_per_gpu_s": success / gpu_s if gpu_s > 0 else 0.0,
        "tokens_per_gpu_s": completion / gpu_s if gpu_s > 0 else 0.0,
        # Fair-cost (post-warmup serving only) metrics:
        "serving_wall_s": serving_wall,
        "orchestration_overhead_s": max(0.0, overall_wall - serving_wall),
        "serving_gpu_s": serving_gpu_s,
        "serving_tokens_per_gpu_s": completion / serving_gpu_s if serving_gpu_s > 0 else 0.0,
        "serving_requests_per_gpu_s": success / serving_gpu_s if serving_gpu_s > 0 else 0.0,
        "s2_switch_total_ms": s2_switch_total_ms,
        "prefill_wall_s": float(summary.get("phase_summaries", {}).get("prefill_burst", {}).get("wall_s", 0.0) or 0.0),
        "balanced_wall_s": float(summary.get("phase_summaries", {}).get("balanced_decode", {}).get("wall_s", 0.0) or 0.0),
        "tail_wall_s": float(summary.get("phase_summaries", {}).get("decode_tail", {}).get("wall_s", 0.0) or 0.0),
        "tail_decode_gpu_s_savings_pct": float(tail.get("tail_decode_gpu_s_savings_pct", 0.0) or 0.0),
        "tail_decode_gpu_s_saved": float(tail.get("tail_decode_gpu_s_saved", 0.0) or 0.0),
        "s2_executed_count": int(summary.get("s2_executed_count", 0) or 0),
        "s3_migrated_requests": int(summary.get("s3_migrated_requests", 0) or 0),
        "s3_drained_source_count": len(summary.get("s3_drained_sources", []) or []),
        "signal_to_ready_s": summary.get("preparation", {}).get("Signal-to-Ready"),
        "burst_safety_margin_s": summary.get("preparation", {}).get("Burst Safety Margin"),
    }


def aggregate_scenario(suite_dir: Path, scenario: str, summaries: list[dict[str, Any]]) -> dict[str, Any]:
    rows = [row_from_summary(summary) for summary in summaries]
    numeric_keys = [
        "wall_s",
        "valid_decode_pct",
        "timeout_count",
        "req_s",
        "p95_latency_s",
        "completion_tps",
        "gpu_s",
        "requests_per_gpu_s",
        "tokens_per_gpu_s",
        "serving_wall_s",
        "orchestration_overhead_s",
        "serving_gpu_s",
        "serving_tokens_per_gpu_s",
        "serving_requests_per_gpu_s",
        "s2_switch_total_ms",
        "prefill_wall_s",
        "balanced_wall_s",
        "tail_wall_s",
        "tail_decode_gpu_s_savings_pct",
        "tail_decode_gpu_s_saved",
        "signal_to_ready_s",
        "burst_safety_margin_s",
    ]
    metrics = {key: e2e.metric_stats([float(row[key]) for row in rows if row.get(key) is not None]) for key in numeric_keys}
    aggregate = {"scenario": scenario, "run_count": len(rows), "runs": rows, "metrics": metrics}
    out_dir = suite_dir / scenario
    e2e.write_json(out_dir / "aggregate-summary.json", aggregate)
    write_scenario_aggregate_report(out_dir, scenario, aggregate, summaries)
    return aggregate


def metric(aggregates: dict[str, dict[str, Any]], scenario: str, name: str) -> float:
    return float(aggregates.get(scenario, {}).get("metrics", {}).get(name, {}).get("mean", 0.0) or 0.0)


def action_sum(aggregates: dict[str, dict[str, Any]], scenario: str, name: str) -> int:
    return sum(int(row.get(name, 0) or 0) for row in aggregates.get(scenario, {}).get("runs", []))


def build_goal_analysis(aggregates: dict[str, dict[str, Any]]) -> dict[str, Any]:
    base_wall = metric(aggregates, "baseline_minimal", "wall_s")
    base_prefill = metric(aggregates, "baseline_minimal", "prefill_wall_s")
    base_tokens_gpu = metric(aggregates, "baseline_minimal", "tokens_per_gpu_s")
    wall_by_scenario = {s: metric(aggregates, s, "wall_s") for s in aggregates}
    tokens_gpu_by_scenario = {s: metric(aggregates, s, "tokens_per_gpu_s") for s in aggregates}
    best_wall = min((s for s, v in wall_by_scenario.items() if v > 0), key=wall_by_scenario.get, default=None)
    best_tokens_gpu = max(tokens_gpu_by_scenario, key=tokens_gpu_by_scenario.get, default=None)

    def improve(value: float, base: float) -> float:
        return (base - value) / base * 100.0 if base > 0 and value > 0 else 0.0

    def up(value: float, base: float) -> float:
        return (value - base) / base * 100.0 if base > 0 and value > 0 else 0.0

    return {
        "wall_by_scenario": wall_by_scenario,
        "tokens_per_gpu_s_by_scenario": tokens_gpu_by_scenario,
        "best_wall_scenario": best_wall,
        "best_tokens_per_gpu_s_scenario": best_tokens_gpu,
        "s2_prefill_wall_improvement_pct": improve(metric(aggregates, "s2_only", "prefill_wall_s"), base_prefill),
        "s2_wall_improvement_pct": improve(metric(aggregates, "s2_only", "wall_s"), base_wall),
        "s3_wall_improvement_pct": improve(metric(aggregates, "s3_only", "wall_s"), base_wall),
        "mixed_wall_improvement_pct": improve(metric(aggregates, "mixed_strategy", "wall_s"), base_wall),
        "s2_tokens_per_gpu_s_improvement_pct": up(metric(aggregates, "s2_only", "tokens_per_gpu_s"), base_tokens_gpu),
        "s3_tokens_per_gpu_s_improvement_pct": up(metric(aggregates, "s3_only", "tokens_per_gpu_s"), base_tokens_gpu),
        "mixed_tokens_per_gpu_s_improvement_pct": up(metric(aggregates, "mixed_strategy", "tokens_per_gpu_s"), base_tokens_gpu),
        "s3_tail_decode_gpu_s_savings_pct": metric(aggregates, "s3_only", "tail_decode_gpu_s_savings_pct"),
        "mixed_tail_decode_gpu_s_savings_pct": metric(aggregates, "mixed_strategy", "tail_decode_gpu_s_savings_pct"),
        "s2_only_s2_executed_count": action_sum(aggregates, "s2_only", "s2_executed_count"),
        "s3_only_migrated_requests": action_sum(aggregates, "s3_only", "s3_migrated_requests"),
        "mixed_s2_executed_count": action_sum(aggregates, "mixed_strategy", "s2_executed_count"),
        "mixed_migrated_requests": action_sum(aggregates, "mixed_strategy", "s3_migrated_requests"),
    }


def phase_table(summary: dict[str, Any]) -> list[str]:
    lines = [
        "| phase | requests | valid % | timeout | wall(s) | req/s | p95(s) | prompt tok/s | completion tok/s |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for phase in PHASES:
        row = summary.get("phase_summaries", {}).get(phase, {})
        lines.append(
            f"| {phase} | {row.get('requests', 0)} | {row.get('valid_decode_pct', 0):.2f} | "
            f"{row.get('timeout_count', 0)} | {row.get('wall_s', 0):.2f} | {row.get('req_s', 0):.2f} | "
            f"{row.get('p95_latency_s', 0):.2f} | {row.get('prompt_tps', 0):.2f} | {row.get('completion_tps', 0):.2f} |"
        )
    overall = summary.get("overall_summary", {})
    lines.append(
        f"| total | {overall.get('requests', 0)} | {overall.get('valid_decode_pct', 0):.2f} | "
        f"{overall.get('timeout_count', 0)} | {overall.get('wall_s', 0):.2f} | {overall.get('req_s', 0):.2f} | "
        f"{overall.get('p95_latency_s', 0):.2f} | {overall.get('prompt_tps', 0):.2f} | {overall.get('completion_tps', 0):.2f} |"
    )
    return lines


def write_readiness_report(out_dir: Path, summary: dict[str, Any]) -> None:
    s2_eval = summary.get("s2_evaluation_summary", {})
    lines = [
        "# Readiness Gate Report",
        "",
        f"generated_at: {e2e.ts_iso()}",
        f"- passed: {summary.get('passed')}",
        f"- S2 evaluation count: {s2_eval.get('count', 0)}",
        f"- max prefill queue depth: {s2_eval.get('max_prefill_queue_depth', 0)}",
        f"- max prefill worker active: {s2_eval.get('max_prefill_worker_active', 0)}",
        "",
        "This gate only proves that controller telemetry/worker sampling is visible before formal performance runs.",
    ]
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_run_report(out_dir: Path, summary: dict[str, Any]) -> None:
    prep = summary.get("preparation", {})
    alloc = summary.get("request_window_pod_allocation", {})
    tail = summary.get("tail_gpu_efficiency", {})
    lines = [
        f"# {summary.get('scenario')} run-{int(summary.get('repeat', 1)):02d} Report",
        "",
        f"generated_at: {e2e.ts_iso()}",
        "",
        "## Timing",
        "",
        f"- T_signal_recv: {prep.get('T_signal_recv')}",
        f"- T_warmup_start: {prep.get('T_warmup_start')}",
        f"- T_ready: {prep.get('T_ready')}",
        f"- T_burst_arrival: {prep.get('T_burst_arrival')}",
        f"- Signal-to-Ready(s): {prep.get('Signal-to-Ready')}",
        f"- Burst Safety Margin(s): {prep.get('Burst Safety Margin')}",
        "",
        "## Serving",
        "",
        *phase_table(summary),
        "",
        "## Evidence And Gates",
        "",
        f"- performance_valid: {summary.get('performance_valid')}",
        f"- quality_gate: {summary.get('quality_gate')}",
        f"- scenario_gate: {summary.get('scenario_gate')}",
        f"- request-window GPU seconds: {alloc.get('gpu_allocated_seconds', 0):.2f}",
        f"- S2 executed count: {summary.get('s2_executed_count', 0)}",
        f"- S2 directions: {summary.get('s2_directions', [])}",
        f"- S2 switch latencies(ms): {summary.get('s2_switch_latencies_ms', [])}",
        f"- S3 migrated requests: {summary.get('s3_migrated_requests', 0)}",
        f"- S3 drained sources: {summary.get('s3_drained_sources', [])}",
        f"- S3 scaled down to: {summary.get('s3_scaled_down_to', [])}",
        f"- tail decode GPU-second savings pct: {tail.get('tail_decode_gpu_s_savings_pct', 0):.2f}",
        "",
        "## Raw Data",
        "",
        "- requests.csv",
        "- pod_samples.csv",
        "- controller_status.jsonl",
        "- events.csv",
        "- logs/",
    ]
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_scenario_aggregate_report(out_dir: Path, scenario: str, aggregate: dict[str, Any], summaries: list[dict[str, Any]]) -> None:
    lines = [
        f"# {scenario} Aggregate",
        "",
        f"generated_at: {e2e.ts_iso()}",
        f"run_count: {aggregate.get('run_count')}",
        "",
        "| metric | mean | stdev | best | worst |",
        "|---|---:|---:|---:|---:|",
    ]
    for key, row in aggregate["metrics"].items():
        lines.append(f"| {key} | {row['mean']:.4f} | {row['stdev']:.4f} | {row['best']:.4f} | {row['worst']:.4f} |")
    lines.extend(
        [
            "",
            "## Action Evidence",
            "",
            f"- total S2 executed: {sum(int(s.get('s2_executed_count', 0) or 0) for s in summaries)}",
            f"- total S3 migrated requests: {sum(int(s.get('s3_migrated_requests', 0) or 0) for s in summaries)}",
            f"- total drained source count: {sum(len(s.get('s3_drained_sources', []) or []) for s in summaries)}",
        ]
    )
    (out_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_suite_report(suite_dir: Path, aggregates: dict[str, dict[str, Any]], readiness: dict[str, Any]) -> None:
    goal = build_goal_analysis(aggregates)
    e2e.write_json(suite_dir / "suite-goal-analysis.json", goal)
    base_wall = metric(aggregates, "baseline_minimal", "wall_s")
    base_tokens_gpu = metric(aggregates, "baseline_minimal", "tokens_per_gpu_s")
    lines = [
        "# RL-Scaling Four-Scenario Strategy E2E Report",
        "",
        f"generated_at: {e2e.ts_iso()}",
        f"readiness_gate_passed: {readiness.get('passed')}",
        "",
        "## Cross-Scenario Comparison",
        "",
        "| scenario | valid runs | wall(s) | wall vs baseline | prefill wall(s) | tokens/GPU-s | tokens/GPU-s vs baseline | S2 exec | S3 migrated | tail GPU-s saved % |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for scenario in SCENARIOS:
        agg = aggregates.get(scenario, {})
        runs = agg.get("runs", [])
        valid_runs = sum(1 for row in runs if row.get("performance_valid"))
        wall = metric(aggregates, scenario, "wall_s")
        prefill = metric(aggregates, scenario, "prefill_wall_s")
        tokens_gpu = metric(aggregates, scenario, "tokens_per_gpu_s")
        wall_delta = (base_wall - wall) / base_wall * 100.0 if base_wall > 0 and wall > 0 else 0.0
        token_delta = (tokens_gpu - base_tokens_gpu) / base_tokens_gpu * 100.0 if base_tokens_gpu > 0 and tokens_gpu > 0 else 0.0
        lines.append(
            f"| {scenario} | {valid_runs}/{len(runs)} | {wall:.2f} | {wall_delta:.2f}% | {prefill:.2f} | "
            f"{tokens_gpu:.4f} | {token_delta:.2f}% | {action_sum(aggregates, scenario, 's2_executed_count')} | "
            f"{action_sum(aggregates, scenario, 's3_migrated_requests')} | "
            f"{metric(aggregates, scenario, 'tail_decode_gpu_s_savings_pct'):.2f}% |"
        )
    lines.extend(
        [
            "",
            "## Goal Analysis",
            "",
            f"- S2 prefill wall improvement: {goal.get('s2_prefill_wall_improvement_pct', 0):.2f}%",
            f"- S2 overall wall improvement: {goal.get('s2_wall_improvement_pct', 0):.2f}%",
            f"- S3 overall wall improvement: {goal.get('s3_wall_improvement_pct', 0):.2f}%",
            f"- S3 tail decode GPU-second savings: {goal.get('s3_tail_decode_gpu_s_savings_pct', 0):.2f}%",
            f"- Mixed overall wall improvement: {goal.get('mixed_wall_improvement_pct', 0):.2f}%",
            f"- Mixed tail decode GPU-second savings: {goal.get('mixed_tail_decode_gpu_s_savings_pct', 0):.2f}%",
            f"- Best wall scenario: {goal.get('best_wall_scenario')}",
            f"- Best tokens/GPU-s scenario: {goal.get('best_tokens_per_gpu_s_scenario')}",
            "",
            "## Raw Artifact Index",
            "",
            "- workload-manifest.jsonl",
            "- readiness_gate/",
            "- baseline_minimal/run-01/",
            "- s2_only/run-01/",
            "- s3_only/run-01/",
            "- mixed_strategy/run-01/",
            "- suite-aggregate.json",
            "- suite-goal-analysis.json",
        ]
    )
    (suite_dir / "REPORT-zh.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_scenarios(raw: str) -> list[str]:
    if raw.strip().lower() in {"all", ""}:
        return SCENARIOS
    selected = [item.strip() for item in raw.split(",") if item.strip()]
    unknown = [item for item in selected if item not in SCENARIOS]
    if unknown:
        raise ValueError(f"unknown scenarios: {unknown}; valid={SCENARIOS}")
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description="Run RL-Scaling four-scenario strategy E2E matrix.")
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--scenarios", default="all")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--sample-interval", type=float, default=1.0)
    parser.add_argument("--observe-after-tail", type=int, default=75)
    parser.add_argument("--skip-readiness-gate", action="store_true")
    parser.add_argument("--continue-after-timeout", action="store_true")
    args = parser.parse_args()

    suite_dir = (
        Path(args.suite_dir)
        if args.suite_dir
        else Path(__file__).resolve().parent / "reports" / f"strategy-four-scenario-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    )
    suite_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = suite_dir / "workload-manifest.jsonl"
    if manifest_path.exists():
        manifest = load_manifest(manifest_path)
    else:
        manifest = build_manifest()
        write_manifest(manifest_path, manifest)

    write_progress(suite_dir, stage="suite_start", scenarios=args.scenarios, repeats=args.repeats, manifest_count=len(manifest))
    readiness = {"passed": None, "skipped": True}
    if not args.skip_readiness_gate:
        write_progress(suite_dir, stage="readiness_gate_start")
        readiness = run_readiness_gate(suite_dir, args.sample_interval)
        write_progress(suite_dir, stage="readiness_gate_done", passed=readiness.get("passed"))
        if not readiness.get("passed"):
            write_suite_report(suite_dir, {}, readiness)
            print("readiness gate failed; stop before formal performance runs", file=sys.stderr)
            return 2

    aggregates: dict[str, dict[str, Any]] = {}
    for scenario in parse_scenarios(args.scenarios):
        summaries: list[dict[str, Any]] = []
        write_progress(suite_dir, stage="scenario_start", scenario=scenario)
        for repeat in range(1, args.repeats + 1):
            write_progress(suite_dir, stage="run_start", scenario=scenario, repeat=repeat)
            summary = run_scenario_once(
                suite_dir,
                scenario,
                repeat,
                manifest,
                args.sample_interval,
                args.observe_after_tail,
                abort_on_timeout=not args.continue_after_timeout,
            )
            summaries.append(summary)
            write_progress(suite_dir, stage="run_done", scenario=scenario, repeat=repeat)
            if summary.get("aborted") and not args.continue_after_timeout:
                aggregates[scenario] = aggregate_scenario(suite_dir, scenario, summaries)
                e2e.write_json(suite_dir / "suite-aggregate.json", aggregates)
                write_suite_report(suite_dir, aggregates, readiness)
                write_progress(
                    suite_dir,
                    stage="suite_aborted_on_timeout",
                    scenario=scenario,
                    repeat=repeat,
                    reason=summary.get("aborted_reason"),
                    report=str(suite_dir / "REPORT-zh.md"),
                )
                print(f"REPORT={suite_dir / 'REPORT-zh.md'}")
                print(f"suite aborted on timeout: {summary.get('aborted_reason')}", file=sys.stderr)
                return 3
        aggregates[scenario] = aggregate_scenario(suite_dir, scenario, summaries)
        write_progress(suite_dir, stage="scenario_done", scenario=scenario)

    e2e.write_json(suite_dir / "suite-aggregate.json", aggregates)
    write_suite_report(suite_dir, aggregates, readiness)
    write_progress(suite_dir, stage="suite_done", report=str(suite_dir / "REPORT-zh.md"))
    print(f"REPORT={suite_dir / 'REPORT-zh.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
