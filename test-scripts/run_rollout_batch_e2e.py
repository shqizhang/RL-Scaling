#!/usr/bin/env python3
"""Production-faithful RL-rollout E2E test.

One continuous, realistic rollout batch per scenario, measured uniformly
end-to-end (T_batch = last completion - dispatch), with mechanism triggering
driven by the real production signals (sampling_progress reflecting ACTUAL
completion fraction) + the controller's live Prometheus reactions. No in-line
topology-verification gates inside the measured window; switches/consolidations
are observed post-hoc from the controller decision log.

Design doc: docs/PLAN-production-faithful-test-2026-07.md
Reuses all plumbing from rls_strategy_common (port-forwards, controller config,
topology, pod sampler, the fixed pod-allocation integral, request submission,
mechanism history).

Primary metrics (Tier 1): T_batch, prefill/decode GPU-hours, U_GPU (KV-cache
occupancy). Gates: 100% valid / 0 timeouts. Scenario order is counterbalanced
across rounds (rotation) to defeat the within-round position confound.
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import rls_strategy_common as e2e

SCENARIOS = ["baseline_1p1d", "static_2p2d", "s2_only", "s3_only", "mixed"]
WORKLOAD_MODE = "flat"  # set by main(): "flat" (one batch) or "phased" (shaped arrival)
# Map our scenario names to the tuned controller env from the phase-based suite.
_ENV_ALIAS = {
    "baseline_1p1d": "baseline_minimal",
    "static_2p2d": "2p2d_static",
    "s2_only": "s2_only",
    "s3_only": "s3_only",
    "mixed": "mixed_strategy",
}
PROM_NS = "monitoring"
PROM_SVC = "svc/prometheus-kube-prometheus-prometheus"
PROM_REMOTE_PORT = 9090
# KV-cache occupancy: the real, exported, LLM-meaningful utilisation signal on
# this cluster (DCGM per-GPU util is not scraped). Higher = GPU carrying more
# live decode work; S3 should RAISE decode occupancy by removing idle decoders.
UGPU_QUERY = "dynamo_component_gpu_cache_usage_percent"
QUEUE_QUERY = "dynamo_frontend_queued_requests"


# --------------------------------------------------------------- controller env
def scenario_env(name: str) -> dict[str, str]:
    """Per-scenario controller config. Thresholds are the cluster-calibrated
    values validated in the phase-based round 2 (6/6 S2, 3/3 S3)."""
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
    disabled = {"PRE_WARM_THRESHOLD": "2.0", "ROLE_SWITCH_ENABLED": "false",
                "CONSOLIDATION_ENABLED": "false", "CONSOLIDATION_SCALE_DOWN_ENABLED": "false"}
    s2 = {"PRE_WARM_THRESHOLD": "0.80", "ROLE_SWITCH_ENABLED": "true",
          "CONSOLIDATION_ENABLED": "false", "CONSOLIDATION_SCALE_DOWN_ENABLED": "false",
          "PREFILL_QUEUE_THRESHOLD": "1", "DECODE_QUEUE_THRESHOLD": "2",
          "DECODE_IDLE_THRESHOLD": "0.30", "PREFILL_IDLE_THRESHOLD": "0.30",
          "MIN_SWITCH_INTERVAL": "60", "ROLE_SWITCH_VERIFY_TIMEOUT": "60",
          "ROLE_SWITCH_VERIFY_POLL_INTERVAL": "1"}
    s3 = {"PRE_WARM_THRESHOLD": "0.80", "ROLE_SWITCH_ENABLED": "false",
          "CONSOLIDATION_ENABLED": "true", "CONSOLIDATION_SCALE_DOWN_ENABLED": "true",
          "CONSOLIDATION_THRESHOLD": "1", "CONSOLIDATION_STABLE_SAMPLES": "1",
          "CONSOLIDATION_MIN_INTERVAL": "4", "MIN_BATCH_COMPLETION": "0.92",
          "PER_REQUEST_MIGRATION_OVERHEAD": "0.10"}
    if name == "baseline_1p1d":
        return {**base, **disabled}
    if name == "static_2p2d":
        return {**base, **disabled, "PRE_WARM_THRESHOLD": "0.80"}
    if name == "s2_only":
        return {**base, **s2}
    if name == "s3_only":
        return {**base, **s3}
    if name == "mixed":
        # S2/S3 DESYNC: in mixed, S3's idle-release used to fire on the decoder
        # an S2 P->D had just re-created, racing the router (24x 5xx in
        # B_decode). Require more consecutive stable observations and a longer
        # min-interval so S3 waits for the post-switch topology to settle before
        # releasing; pair with the controller-side cordon settle.
        return {**base, **s2, **s3, "ROLE_SWITCH_ENABLED": "true", "MIN_SWITCH_INTERVAL": "60",
                "CONSOLIDATION_STABLE_SAMPLES": "3", "CONSOLIDATION_MIN_INTERVAL": "10",
                "CONSOLIDATION_CORDON_SETTLE": "1.5"}
    raise ValueError(name)


# --------------------------------------------------------------- workload model
def build_rollout_batch(seed: int, size: int, straggler_frac: float, concurrency: int = 48) -> list[dict[str, Any]]:
    """One realistic RL rollout batch: a bulk of natural-EOS completions with a
    heavy right tail of long stragglers (the well-known RL-inference tail).

    Documented synthetic distribution (no real trace available; reproducible):
      * prompt: 300-500 words (bounded for the no-RDMA KV-transport budget).
      * bulk (1-straggler_frac): max_tokens in {64,128,256}, natural EOS.
      * tail (straggler_frac): a FEW very long stragglers (ignore_eos,
        max_tokens=7000 ~= 30-100x the bulk), staggered so the KV router
        spreads them across decoders (=> a migratable source S3 can EMPTY to
        free a GPU) and the tail extends well past bulk completion (so the
        post-consolidation reclaim window is substantial). Peak KV on the 1P1D
        baseline (~n_strag x 7000) stays < the ~24k thrash budget for n<=3.
    """
    rng = random.Random(seed)
    n_strag = max(3, round(size * straggler_frac))
    n_bulk = size - n_strag
    rows: list[dict[str, Any]] = []
    idx = 1
    bulk_lengths = [64, 128, 256]
    for _ in range(n_bulk):
        rows.append({
            "manifest_id": idx, "phase": "rollout",
            "words": rng.randint(300, 500),
            "max_tokens": rng.choice(bulk_lengths),
            "concurrency": concurrency,   # bounded client parallelism (tunnel-safe burst)
            "timeout_s": 420, "shape": "bulk", "ignore_eos": False,
            "launch_delay_s": 0,
        })
        idx += 1
    # Stragglers: staggered so they land on different decoders. 7000 tokens x
    # n_strag stays under the 1P1D KV thrash ceiling for n<=3.
    for i in range(n_strag):
        rows.append({
            "manifest_id": idx, "phase": "rollout",
            "words": rng.randint(300, 500),
            "max_tokens": 7000,
            "concurrency": concurrency, "timeout_s": 420, "shape": "straggler",
            "ignore_eos": True, "launch_delay_s": i * 3,
        })
        idx += 1
    rng.shuffle(rows)          # realistic interleaving of bulk and stragglers
    for order, r in enumerate(rows, 1):
        r["manifest_id"] = order
    return rows


def build_phased_batch(seed: int, pa: dict[str, Any]) -> list[dict[str, Any]]:
    """Shaped-arrival, 3-phase workload so each mechanism has a CLEAN regime
    (learning from the phased-optimization plan + our own analysis):
      * Phase A (prefill burst): long prompts, short output, dispatched at t0
        -> prefill queue high, decode idle -> the D->P trigger window.
      * Phase B (decode dense): medium prompts, long output, arriving after an
        offset (no new long prompts) -> decode queue high, prefill idle -> P->D.
      * Phase C (tail): a few ignore_eos stragglers -> S3 consolidation.
    Phases are separated by per-request launch offsets (NOT gates); measurement
    is per-phase serving time (see build_summary). All scenarios reuse the same
    manifest/seed."""
    rng = random.Random(seed)
    rows: list[dict[str, Any]] = []
    idx = 1
    # Phase A — prefill-heavy burst (long prompt, short decode).
    for _ in range(pa["a_n"]):
        rows.append({"manifest_id": idx, "phase": "A_prefill", "shape": "A_prefill",
                     "words": rng.randint(pa["a_words"] - 150, pa["a_words"] + 150),
                     "max_tokens": rng.choice([64, 96, 128]), "concurrency": pa["a_n"],
                     "timeout_s": 600, "ignore_eos": False, "launch_delay_s": 0.0}); idx += 1
    # Phase B — decode-heavy (medium prompt, long decode), arrives after A.
    for _ in range(pa["b_n"]):
        rows.append({"manifest_id": idx, "phase": "B_decode", "shape": "B_decode",
                     "words": rng.randint(pa["b_words"] - 100, pa["b_words"] + 100),
                     "max_tokens": pa["b_out"], "concurrency": pa["b_n"],
                     "timeout_s": 600, "ignore_eos": False, "launch_delay_s": float(pa["b_offset"])}); idx += 1
    # Phase C — long-tail stragglers, staggered, arrive last.
    for i in range(pa["c_n"]):
        rows.append({"manifest_id": idx, "phase": "C_tail", "shape": "C_tail",
                     "words": rng.randint(40, 64), "max_tokens": pa["c_out"], "concurrency": pa["c_n"],
                     "timeout_s": 600, "ignore_eos": True, "launch_delay_s": float(pa["c_offset"]) + i * 3.0}); idx += 1
    return rows


def run_phased_with_progress(frontend_port, controller_port, manifest, out_dir, nonce, meta, events):
    """Dispatch each request at t0 + its launch_delay via a dedicated thread
    (so a delayed request never blocks a bounded pool slot). Sends
    sampling_progress from the real completion fraction. Returns (rows, t0, t_end,
    phase_dispatch)."""
    done = {"n": 0}
    lock = threading.Lock()
    stop_prog = threading.Event()
    rows: list[dict[str, Any]] = []
    phase_dispatch: dict[str, float] = {}

    def progress_thread():
        e2e.send_progress(controller_port, 0.0, meta["batch_size"], meta["avg_isl"], meta["avg_osl"])
        while not stop_prog.is_set():
            with lock:
                frac = done["n"] / max(1, meta["batch_size"])
            try:
                e2e.send_progress(controller_port, round(frac, 3), meta["batch_size"], meta["avg_isl"], meta["avg_osl"])
            except Exception:
                pass
            stop_prog.wait(2.0)

    t0 = e2e.now_ts()
    e2e.event(events, "T0_batch_dispatch", batch=meta)
    prog = threading.Thread(target=progress_thread, daemon=True); prog.start()

    def submit_at(item):
        delay = float(item.get("launch_delay_s", 0) or 0)
        wait = (t0 + delay) - e2e.now_ts()
        if wait > 0:
            time.sleep(wait)
        ph = str(item.get("phase", ""))
        with lock:
            if ph not in phase_dispatch:
                phase_dispatch[ph] = e2e.now_ts()
                e2e.event(events, "phase_dispatch", phase=ph)
        r = e2e.submit_manifest_request(frontend_port, {**item, "launch_delay_s": 0}, out_dir, nonce)
        with lock:
            done["n"] += 1
            rows.append(r)

    threads = [threading.Thread(target=submit_at, args=(item,), daemon=True) for item in manifest]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    t_end = e2e.now_ts()
    stop_prog.set(); prog.join(timeout=5)
    e2e.send_batch_complete(controller_port)
    e2e.event(events, "T_end_batch_complete", completed=len(rows))
    rows.sort(key=lambda r: int(r["manifest_id"]))
    return rows, t0, t_end, phase_dispatch


def batch_meta(manifest: list[dict[str, Any]]) -> dict[str, int]:
    n = len(manifest)
    avg_isl = int(sum(int(r["words"]) * 1.3 for r in manifest) / max(1, n))  # ~1.3 tok/word
    avg_osl = int(sum(int(r["max_tokens"]) for r in manifest) / max(1, n))
    return {"batch_size": n, "avg_isl": avg_isl, "avg_osl": avg_osl}


# --------------------------------------------------------------- prometheus
def prom_query(prom_port: int, query: str) -> list[dict[str, Any]]:
    url = f"http://127.0.0.1:{prom_port}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
        return data.get("data", {}).get("result", [])
    except Exception:
        return []


class PromSampler(threading.Thread):
    """Samples KV-cache occupancy (U_GPU proxy) + queue depth over time."""
    def __init__(self, prom_port: int, stop: threading.Event, interval: float = 2.0):
        super().__init__(daemon=True)
        self.prom_port, self.stop, self.interval = prom_port, stop, interval
        self.rows: list[dict[str, Any]] = []

    def run(self) -> None:
        while not self.stop.is_set():
            ts = e2e.now_ts()
            occ = prom_query(self.prom_port, UGPU_QUERY)
            q = prom_query(self.prom_port, QUEUE_QUERY)
            self.rows.append({
                "ts": ts, "iso": e2e.ts_iso(),
                "kv_occupancy": [{"labels": r.get("metric", {}), "v": float(r.get("value", [0, 0])[1])} for r in occ],
                "queued": [{"labels": r.get("metric", {}), "v": float(r.get("value", [0, 0])[1])} for r in q],
            })
            self.stop.wait(self.interval)


# --------------------------------------------------------------- batch runner
def run_rollout_with_progress(
    frontend_port: int, controller_port: int, manifest: list[dict[str, Any]],
    out_dir: Path, nonce: str, meta: dict[str, int], events: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], float, float]:
    """Dispatch the whole batch at once; a progress thread emits sampling_progress
    with the REAL completion fraction (drives S3's batch-completion gate and the
    controller's batch context). Returns (rows, T0, T_end)."""
    done = {"n": 0}
    lock = threading.Lock()
    stop_prog = threading.Event()

    def progress_thread() -> None:
        # sampling_progress with the real fraction, ~every 2s, like a trainer.
        e2e.send_progress(controller_port, 0.0, meta["batch_size"], meta["avg_isl"], meta["avg_osl"])
        while not stop_prog.is_set():
            with lock:
                frac = done["n"] / max(1, meta["batch_size"])
            try:
                e2e.send_progress(controller_port, round(frac, 3), meta["batch_size"], meta["avg_isl"], meta["avg_osl"])
            except Exception:
                pass
            stop_prog.wait(2.0)

    prog = threading.Thread(target=progress_thread, daemon=True)
    concurrency = max(1, int(manifest[0].get("concurrency", len(manifest))))
    t0 = e2e.now_ts()
    e2e.event(events, "T0_batch_dispatch", batch=meta)
    prog.start()
    rows: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(e2e.submit_manifest_request, frontend_port, item, out_dir, nonce) for item in manifest]
        for fut in as_completed(futures):
            r = fut.result()
            with lock:
                done["n"] += 1
            rows.append(r)
    t_end = e2e.now_ts()
    stop_prog.set()
    prog.join(timeout=5)
    e2e.send_batch_complete(controller_port)
    e2e.event(events, "T_end_batch_complete", completed=len(rows))
    rows.sort(key=lambda r: int(r["manifest_id"]))
    return rows, t0, t_end


def _delete_not_ready_workers() -> None:
    """Delete decode/prefill worker pods that are not Ready so they reschedule
    cleanly. Used when a fresh worker crash-loops on cold start (vLLM engine-core
    init race) and stalls a topology transition."""
    import subprocess
    try:
        out = subprocess.run(
            ["kubectl", "-n", e2e.NS, "get", "pods", "-o",
             "jsonpath={range .items[*]}{.metadata.name}{'|'}{.status.containerStatuses[0].ready}{'\\n'}{end}"],
            capture_output=True, text=True, timeout=30).stdout
        for line in out.splitlines():
            if "|" not in line:
                continue
            name, ready = line.split("|", 1)
            if ("decodeworker" in name or "prefillworker" in name) and ready.strip() != "true":
                subprocess.run(["kubectl", "-n", e2e.NS, "delete", "pod", name, "--grace-period=10"],
                               capture_output=True, text=True, timeout=60)
    except Exception:
        pass


# --------------------------------------------------------------- warmup (pre-T0)
def prewarm(scenario: str, controller_port: int, frontend_port: int, events: list[dict[str, Any]]) -> None:
    """Bring the scenario's start topology up and model-ready BEFORE the clock.
    Never counted in T_batch."""
    target = (1, 1) if scenario == "baseline_1p1d" else (2, 2)
    # Keep-alive batch context so the controller does NOT cooldown-scale the
    # workers to 0 during model load (that collapse forces a full cold restart).
    # PRE_WARM_THRESHOLD gates scale-UP: baseline (2.0) stays at 1P1D MIN, others
    # (0.80) permit 2P2D. This signal only prevents the collapse.
    e2e.send_progress(controller_port, 0.85, batch_size=128, avg_isl=3072, avg_osl=512)
    # Force the EXACT desired replicas (deterministic topology). RESILIENT: a
    # fresh worker's vLLM engine-core can crash-loop on cold start under topology
    # churn (GPU/CUDA/NIXL init race), which makes set_topology's rollout wait
    # time out. Don't let that kill the suite: delete not-ready worker pods so
    # they reschedule cleanly, and retry.
    for attempt in range(3):
        try:
            e2e.set_topology(*target)
            break
        except Exception as exc:  # noqa: BLE001
            e2e.event(events, "prewarm_set_topology_retry", scenario=scenario, attempt=attempt, error=str(exc)[:200])
            _delete_not_ready_workers()
            time.sleep(20)
    else:
        e2e.set_topology(*target)  # final attempt; if it raises, the run aborts honestly
    # Wait for the EXACT topology: both up-scaled pods ready AND any down-scaled
    # pods terminated, so e.g. baseline is truly 1P1D (not a lingering 2nd pod).
    deadline = time.time() + 480
    while time.time() < deadline:
        try:
            p, d = e2e.count_ready_by_component()
        except Exception:
            p, d = -1, -1
        if p == target[0] and d == target[1]:
            break
        time.sleep(5)
    # Re-assert keep-alive after any scale settling, then confirm model-ready.
    e2e.send_progress(controller_port, 0.85, batch_size=128, avg_isl=3072, avg_osl=512)
    for _ in range(3):
        e2e.wait_frontend_chat_ready(frontend_port, timeout_s=300)
        time.sleep(1)
    e2e.event(events, "prewarm_ready", scenario=scenario, topology={"prefill": target[0], "decode": target[1]})


# --------------------------------------------------------------- one run
def run_scenario_once(suite_dir: Path, scenario: str, repeat: int, position: int,
                      manifest: list[dict[str, Any]], sample_interval: float) -> dict[str, Any]:
    out_dir = suite_dir / scenario / f"run-{repeat:02d}"
    out_dir.mkdir(parents=True, exist_ok=True)
    events: list[dict[str, Any]] = []
    status_rows: list[dict[str, Any]] = []
    stop = threading.Event()
    since_iso = e2e.ts_utc_since()
    nonce = f"{scenario}-r{repeat}-{int(time.time())}"
    meta = batch_meta(manifest)
    frontend_pf = controller_pf = prom_pf = None
    sampler = e2e.PodSampler(sample_interval, stop)
    prom_sampler = None
    status_thread = None
    try:
        e2e.configure_controller(scenario_env(scenario))
        frontend_pf = e2e.start_port_forward(e2e.FRONTEND_SVC, 8000, e2e.NS)
        controller_pf = e2e.start_port_forward(f"svc/{e2e.CONTROLLER_DEPLOY}", 8080, e2e.CONTROLLER_NS)
        prom_pf = e2e.start_port_forward(PROM_SVC, PROM_REMOTE_PORT, PROM_NS)
        e2e.wait_http(f"http://127.0.0.1:{frontend_pf.local_port}/health", timeout_s=120)
        e2e.wait_http(f"http://127.0.0.1:{controller_pf.local_port}/healthz", timeout_s=120)
        threading.Thread(target=sampler.run, daemon=True).start()
        prom_sampler = PromSampler(prom_pf.local_port, stop)
        prom_sampler.start()
        status_thread = threading.Thread(
            target=_status_loop, args=(controller_pf.local_port, status_rows, stop, sample_interval), daemon=True)
        status_thread.start()

        # --- pre-warm (OUTSIDE the measured window) ---
        prewarm(scenario, controller_pf.local_port, frontend_pf.local_port, events)
        e2e.status_sample(controller_pf.local_port, status_rows, "after_prewarm")

        # --- MEASURED WINDOW: no gates. flat batch OR shaped-arrival phased ---
        if WORKLOAD_MODE == "phased":
            rows, t0, t_end, _phd = run_phased_with_progress(
                frontend_pf.local_port, controller_pf.local_port, manifest, out_dir, nonce, meta, events)
        else:
            rows, t0, t_end = run_rollout_with_progress(
                frontend_pf.local_port, controller_pf.local_port, manifest, out_dir, nonce, meta, events)

        # brief post-window so the GPU timeline captures the S3 scale-down settle
        # (NOT part of T_batch; T_batch = [t0, t_end]).
        time.sleep(8)
        e2e.status_sample(controller_pf.local_port, status_rows, "after_batch")
    finally:
        stop.set()
        for pf in (frontend_pf, controller_pf, prom_pf):
            if pf:
                try: pf.stop()
                except Exception: pass
        if status_thread:
            status_thread.join(timeout=10)
        if prom_sampler:
            prom_sampler.join(timeout=10)
        try: e2e.capture_logs(out_dir, since_iso)
        except Exception: pass

    # Persist raw samples for post-hoc inspection / analysis.
    _write_csv(out_dir / "requests.csv", rows)
    _write_csv(out_dir / "pod_samples.csv", sampler.rows)
    e2e.write_json(out_dir / "prom_samples.json", prom_sampler.rows if prom_sampler else [])
    summary = build_summary(scenario, repeat, position, rows, t0, t_end, meta,
                            sampler.rows, prom_sampler.rows if prom_sampler else [], status_rows, events, out_dir)
    e2e.write_json(out_dir / "summary.json", summary)
    e2e.write_json(out_dir / "events.json", events)
    return summary


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    keys = sorted({k for r in rows for k in r.keys()})
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in keys})


def _status_loop(port: int, rows: list[dict[str, Any]], stop: threading.Event, interval: float) -> None:
    while not stop.is_set():
        try:
            e2e.status_sample(port, rows, "poll")
        except Exception:
            pass
        stop.wait(interval)


# --------------------------------------------------------------- summary
def ugpu_over_window(prom_rows: list[dict[str, Any]], t0: float, t_end: float) -> dict[str, Any]:
    """Mean decode-side KV-cache occupancy over [t0,t_end]. Decode component is
    identified by the label containing 'decode' (robust to exact label name)."""
    def decode_val(sample: dict[str, Any]) -> float | None:
        vals = []
        for entry in sample.get("kv_occupancy", []):
            lbls = " ".join(f"{k}={v}" for k, v in entry.get("labels", {}).items()).lower()
            if "decode" in lbls:
                vals.append(entry["v"])
        if not vals:
            # fall back to all components if role label absent
            vals = [e["v"] for e in sample.get("kv_occupancy", [])]
        return (sum(vals) / len(vals)) if vals else None
    in_win = [s for s in prom_rows if t0 <= s["ts"] <= t_end + 8]
    dvals = [v for s in in_win if (v := decode_val(s)) is not None]
    return {
        "decode_kv_occupancy_mean": (sum(dvals) / len(dvals)) if dvals else 0.0,
        "decode_kv_occupancy_max": max(dvals) if dvals else 0.0,
        "samples": len(dvals),
    }


def per_phase_metrics(rows, pod_rows) -> dict[str, Any]:
    """Per-phase serving time + GPU integration, windowed to each phase's own
    request timestamps (no gates involved). D->P is judged on the A_prefill
    phase, P->D on B_decode, S3 on C_tail."""
    out: dict[str, Any] = {}
    phases = sorted({str(r.get("phase", "")) for r in rows if r.get("phase")})
    for ph in phases:
        prs = [r for r in rows if str(r.get("phase", "")) == ph]
        starts = [float(r["start_ts"]) for r in prs if r.get("start_ts")]
        ends = [float(r["end_ts"]) for r in prs if r.get("end_ts")]
        if not starts or not ends:
            continue
        st, en = min(starts), max(ends)
        alloc = e2e.summarize_pod_allocation(pod_rows, st, en)
        valid = sum(1 for r in prs if r.get("valid_decode"))
        out[ph] = {
            "n": len(prs), "valid_pct": 100.0 * valid / max(1, len(prs)),
            "serving_wall_s": en - st,
            "prefill_gpu_s": float(alloc.get("prefill_allocated_seconds", 0) or 0),
            "decode_gpu_s": float(alloc.get("spec_decode_allocated_seconds", 0) or 0),
            "avg_decode_gpus": (float(alloc.get("spec_decode_allocated_seconds", 0) or 0) / (en - st)) if en > st else 0.0,
            "completion_tokens": sum(int(r.get("completion_tokens", 0) or 0) for r in prs),
            "p95_latency_s": e2e.percentile([float(r["latency_s"]) for r in prs if r.get("latency_s")], 0.95),
        }
    return out


def build_summary(scenario, repeat, position, rows, t0, t_end, meta, pod_rows, prom_rows, status_rows, events, out_dir) -> dict[str, Any]:
    q = e2e.summarize_requests(rows)
    t_batch = t_end - t0
    alloc = e2e.summarize_pod_allocation(pod_rows, t0, t_end)
    phase_metrics = per_phase_metrics(rows, pod_rows)
    ugpu = ugpu_over_window(prom_rows, t0, t_end)
    s2h = e2e.s2_history(status_rows)
    s3h = e2e.s3_history(status_rows)
    s2_exec = sum(1 for it in s2h if it.get("executed"))
    s3_mig = sum(int(it.get("migrated_requests", 0) or 0) for it in s3h)
    s3_drained = [src for it in s3h for src in (it.get("drained_sources") or [])]
    completion = float(q.get("completion_tokens", 0) or 0)
    prefill_gpu_s = float(alloc.get("prefill_allocated_seconds", 0) or 0)
    # SPEC (desired-replica) decode GPU-s = the honest lag-free decode-GPU-hours.
    decode_gpu_s = float(alloc.get("spec_decode_allocated_seconds", 0) or 0)
    total_gpu_s = float(alloc.get("spec_gpu_allocated_seconds", 0) or 0)
    return {
        "scenario": scenario, "repeat": repeat, "position_in_round": position,
        # Tier 2: quality gates
        "valid_decode_pct": float(q.get("valid_decode_pct", 0) or 0),
        "timeout_count": int(q.get("timeout_count", 0) or 0),
        "http_5xx_count": int(q.get("http_5xx_count", 0) or 0),
        "success": int(q.get("success", 0) or 0),
        "request_count": len(rows),
        # Tier 1: primary outcomes
        "T_batch_s": t_batch,
        "prefill_gpu_s": prefill_gpu_s,
        "decode_gpu_s": decode_gpu_s,
        "total_gpu_s": total_gpu_s,
        "gpu_hours": total_gpu_s / 3600.0,
        # Average GPUs allocated over the batch (GPU-seconds / makespan) -- the
        # intuitive "how many GPUs did this scenario hold on average". S3 should
        # show avg_decode_gpus < 2 (drops to 1 for the post-consolidation tail).
        "avg_prefill_gpus": (prefill_gpu_s / t_batch) if t_batch > 0 else 0.0,
        "avg_decode_gpus": (decode_gpu_s / t_batch) if t_batch > 0 else 0.0,
        "avg_total_gpus": (total_gpu_s / t_batch) if t_batch > 0 else 0.0,
        "decode_kv_occupancy_mean": ugpu["decode_kv_occupancy_mean"],
        "decode_kv_occupancy_max": ugpu["decode_kv_occupancy_max"],
        "min_spec_decode_replicas": int(alloc.get("min_spec_decode_replicas", 0) or 0),
        # Tier 4: efficiency ratios
        "tokens_per_gpu_s": completion / total_gpu_s if total_gpu_s > 0 else 0.0,
        "requests_per_gpu_s": int(q.get("success", 0) or 0) / total_gpu_s if total_gpu_s > 0 else 0.0,
        # Tier 3: mechanism evidence
        "s2_executed_count": s2_exec,
        "s2_switch_total_ms": sum(
            float(it.get("switch_time_ms", it.get("switch_ms", it.get("duration_ms", 0))) or 0)
            for it in s2h if it.get("executed")),
        "s3_migrated_requests": s3_mig,
        "s3_drained_source_count": len(s3_drained),
        # Per-phase attribution (D->P => A_prefill, P->D => B_decode, S3 => C_tail)
        "phase_metrics": phase_metrics,
        # business_wall == T_batch by construction (no gates in the measured
        # window); recorded so the report can prove no harness contamination.
        "business_wall_s": t_batch,
        "overhead_vs_tbatch_s": 0.0,
        # diagnostics
        "completion_tokens": completion,
        "p50_latency_s": float(q.get("p50_latency_s", 0) or 0),
        "p95_latency_s": float(q.get("p95_latency_s", 0) or 0),
        "ugpu_samples": ugpu["samples"],
        "batch_meta": meta,
        "t0": t0, "t_end": t_end,
    }


# --------------------------------------------------------------- aggregate
_AGG_KEYS = ["valid_decode_pct", "timeout_count", "http_5xx_count", "T_batch_s",
             "avg_prefill_gpus", "avg_decode_gpus", "avg_total_gpus",
             "prefill_gpu_s", "decode_gpu_s", "total_gpu_s", "gpu_hours",
             "decode_kv_occupancy_mean", "decode_kv_occupancy_max", "min_spec_decode_replicas",
             "tokens_per_gpu_s", "requests_per_gpu_s", "s2_executed_count",
             "s2_switch_total_ms", "s3_migrated_requests", "s3_drained_source_count",
             "completion_tokens", "p50_latency_s", "p95_latency_s"]


def _mean(xs): return sum(xs) / len(xs) if xs else 0.0
def _sd(xs):
    if len(xs) < 2: return 0.0
    m = _mean(xs); return (sum((x - m) ** 2 for x in xs) / (len(xs) - 1)) ** 0.5


def aggregate_scenario(scenario: str, runs: list[dict[str, Any]]) -> dict[str, Any]:
    agg = {"scenario": scenario, "run_count": len(runs), "runs": runs}
    for k in _AGG_KEYS:
        vals = [float(r.get(k, 0) or 0) for r in runs]
        agg[f"{k}_mean"] = _mean(vals)
        agg[f"{k}_sd"] = _sd(vals)
    return agg


# --------------------------------------------------------------- main
def counterbalanced(round_idx: int) -> list[str]:
    """Rotate the scenario order each round so no scenario is always in the same
    (cold/warm) slot -> defeats the within-round position confound."""
    r = round_idx % len(SCENARIOS)
    return SCENARIOS[r:] + SCENARIOS[:r]


def main() -> int:
    ap = argparse.ArgumentParser(description="Production-faithful RL-rollout E2E test.")
    ap.add_argument("--suite-dir", default="")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--batch-size", type=int, default=96)
    ap.add_argument("--straggler-frac", type=float, default=0.03)
    ap.add_argument("--seed", type=int, default=20260718)
    ap.add_argument("--sample-interval", type=float, default=1.0)
    ap.add_argument("--scenarios", default="all", help="comma-separated subset, or 'all'")
    ap.add_argument("--workload", default="flat", choices=["flat", "phased"])
    # phased-workload phase parameters (calibratable)
    ap.add_argument("--a-n", type=int, default=32); ap.add_argument("--a-words", type=int, default=1200)
    ap.add_argument("--b-n", type=int, default=24); ap.add_argument("--b-words", type=int, default=450)
    ap.add_argument("--b-out", type=int, default=1200); ap.add_argument("--b-offset", type=float, default=22.0)
    ap.add_argument("--c-n", type=int, default=3); ap.add_argument("--c-out", type=int, default=6000)
    ap.add_argument("--c-offset", type=float, default=40.0)
    ap.add_argument("--continue-after-timeout", action="store_true")
    args = ap.parse_args()
    global WORKLOAD_MODE
    WORKLOAD_MODE = args.workload
    active = SCENARIOS if args.scenarios.strip().lower() in {"all", ""} else [s.strip() for s in args.scenarios.split(",") if s.strip()]

    suite_dir = Path(args.suite_dir) if args.suite_dir else Path(f"reports/rollout-5scenario-{time.strftime('%Y%m%d-%H%M%S')}")
    suite_dir.mkdir(parents=True, exist_ok=True)
    # ONE shared batch, reused byte-for-byte by every scenario/round.
    if args.workload == "phased":
        pa = {"a_n": args.a_n, "a_words": args.a_words, "b_n": args.b_n, "b_words": args.b_words,
              "b_out": args.b_out, "b_offset": args.b_offset, "c_n": args.c_n, "c_out": args.c_out,
              "c_offset": args.c_offset}
        manifest = build_phased_batch(args.seed, pa)
    else:
        manifest = build_rollout_batch(args.seed, args.batch_size, args.straggler_frac)
    (suite_dir / "workload-manifest.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in manifest) + "\n", encoding="utf-8")

    def progress(**d): e2e.write_json(suite_dir / "progress.json", {"ts": e2e.now_ts(), "iso": e2e.ts_iso(), **d})

    runs_by_scn: dict[str, list[dict[str, Any]]] = {s: [] for s in SCENARIOS}
    aborted = None
    for rp in range(1, args.repeats + 1):
        order = [s for s in counterbalanced(rp - 1) if s in active]
        progress(stage="round_start", repeat=rp, order=order)
        for pos, scn in enumerate(order, 1):
            # Resume: if this run already completed (e.g. a prior launch died on
            # an infra timeout), reuse it instead of re-running.
            existing = suite_dir / scn / f"run-{rp:02d}" / "summary.json"
            if existing.exists():
                try:
                    summary = json.loads(existing.read_text(encoding="utf-8"))
                    runs_by_scn[scn].append(summary)
                    progress(stage="run_resumed", repeat=rp, scenario=scn, position=pos)
                    continue
                except Exception:
                    pass
            progress(stage="run_start", repeat=rp, scenario=scn, position=pos)
            summary = run_scenario_once(suite_dir, scn, rp, pos, manifest, args.sample_interval)
            runs_by_scn[scn].append(summary)
            if summary["timeout_count"] > 0 and not args.continue_after_timeout:
                aborted = f"timeout in {scn} r{rp}: {summary['timeout_count']}"
                progress(stage="aborted", reason=aborted)
                break
        if aborted:
            break
        progress(stage="round_done", repeat=rp)

    # per-scenario aggregates
    aggregates = {}
    for scn in SCENARIOS:
        if runs_by_scn[scn]:
            agg = aggregate_scenario(scn, runs_by_scn[scn])
            aggregates[scn] = agg
            e2e.write_json(suite_dir / scn / "aggregate-summary.json", agg)
    # SINGLE consolidated data file (all runs + all aggregates) for analysis.
    e2e.write_json(suite_dir / "consolidated-data.json", {
        "suite": suite_dir.name,
        "config": {"repeats": args.repeats, "batch_size": args.batch_size,
                   "straggler_frac": args.straggler_frac, "seed": args.seed,
                   "workload": args.workload, "manifest_size": len(manifest),
                   "phase_params": (pa if args.workload == "phased" else None)},
        "scenarios": SCENARIOS,
        "aborted": aborted,
        "aggregates": aggregates,
        "all_runs": [r for scn in SCENARIOS for r in runs_by_scn[scn]],
    })
    progress(stage="suite_done", aborted=aborted, consolidated="consolidated-data.json")
    print(f"SUITE {'ABORTED: ' + aborted if aborted else 'DONE'} -> {suite_dir}")
    return 1 if aborted else 0


if __name__ == "__main__":
    raise SystemExit(main())
