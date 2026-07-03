"""Configuration loaded from environment variables.

Only the controller's S1 (rollout scale) needs values here at module load
time; S2/S3 fields are added in their respective sub-modules. All values are
overridable from environment for k8s deployment.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw is not None and raw != "" else default


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    return float(raw) if raw is not None and raw != "" else default


def _env_str(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.lower() in {"1", "true", "yes", "on"}


@dataclass
class ControllerConfig:
    # ─── Connectivity ───
    namespace: str = field(default_factory=lambda: _env_str("DYNAMO_NAMESPACE", "dynamo-system"))
    # DGD_NAME must match the DGD created by the upstream deployer.
    # The 1.0.1 disagg-router manifest names it `vllm-v1-disagg-router`, so the
    # operator creates DGDSAs named `vllm-v1-disagg-router-{prefill,decode}`.
    dgd_name: str = field(default_factory=lambda: _env_str("DGD_NAME", "vllm-v1-disagg-router"))
    prometheus_url: str = field(default_factory=lambda: _env_str(
        "PROMETHEUS_URL",
        "http://prometheus-kube-prometheus-prometheus.monitoring:9090",
    ))
    worker_sidecar_port: int = field(default_factory=lambda: _env_int("WORKER_SIDECAR_PORT", 9091))

    # ─── S1: Rollout scale ───
    pre_warm_threshold: float = field(default_factory=lambda: _env_float("PRE_WARM_THRESHOLD", 0.8))
    cooldown_seconds: int = field(default_factory=lambda: _env_int("COOLDOWN_SECONDS", 30))
    # Hard upper bound on how long COOL_DOWN waits for in-flight requests to
    # drain before forcing scale-to-zero. Total time in COOL_DOWN is bounded
    # by max(cooldown_seconds, drain_timeout_seconds).
    drain_timeout_seconds: int = field(default_factory=lambda: _env_int("DRAIN_TIMEOUT_SECONDS", 60))
    control_loop_interval: float = field(default_factory=lambda: _env_float("CONTROL_LOOP_INTERVAL", 5.0))

    # Capacity planner
    single_prefill_tps: int = field(default_factory=lambda: _env_int("SINGLE_PREFILL_TPS", 50000))
    max_concurrent_per_decode: int = field(default_factory=lambda: _env_int("MAX_CONCURRENT_PER_DECODE", 64))
    target_prefill_seconds: float = field(default_factory=lambda: _env_float("TARGET_PREFILL_SECONDS", 5.0))
    max_gpus: int = field(default_factory=lambda: _env_int("MAX_GPUS", 8))
    min_prefill_replicas: int = field(default_factory=lambda: _env_int("MIN_PREFILL_REPLICAS", 1))
    min_decode_replicas: int = field(default_factory=lambda: _env_int("MIN_DECODE_REPLICAS", 1))

    # ─── S2: Role switch ───
    role_switch_enabled: bool = field(default_factory=lambda: _env_bool("ROLE_SWITCH_ENABLED", False))
    prefill_queue_threshold: int = field(default_factory=lambda: _env_int("PREFILL_QUEUE_THRESHOLD", 10))
    decode_queue_threshold: int = field(default_factory=lambda: _env_int("DECODE_QUEUE_THRESHOLD", 10))
    decode_idle_threshold: float = field(default_factory=lambda: _env_float("DECODE_IDLE_THRESHOLD", 0.2))
    prefill_idle_threshold: float = field(default_factory=lambda: _env_float("PREFILL_IDLE_THRESHOLD", 0.2))
    min_switch_interval_seconds: float = field(default_factory=lambda: _env_float("MIN_SWITCH_INTERVAL", 30.0))

    # ─── S3: Consolidation ───
    consolidation_enabled: bool = field(default_factory=lambda: _env_bool("CONSOLIDATION_ENABLED", False))
    consolidation_threshold: int = field(default_factory=lambda: _env_int("CONSOLIDATION_THRESHOLD", 3))
    min_batch_completion_pct: float = field(default_factory=lambda: _env_float("MIN_BATCH_COMPLETION", 0.6))
    per_request_migration_overhead: float = field(default_factory=lambda: _env_float("PER_REQUEST_MIGRATION_OVERHEAD", 0.5))
    consolidation_scale_down_enabled: bool = field(default_factory=lambda: _env_bool("CONSOLIDATION_SCALE_DOWN_ENABLED", True))
    consolidation_stable_samples: int = field(default_factory=lambda: _env_int("CONSOLIDATION_STABLE_SAMPLES", 2))
    consolidation_min_interval_seconds: float = field(default_factory=lambda: _env_float("CONSOLIDATION_MIN_INTERVAL", 10.0))

    # Kubernetes scale transport. Production should use DGDSA when the Dynamo
    # operator is active. Test clusters can enable this fallback when the
    # operator is intentionally scaled down and DGDSA no longer reconciles
    # Deployments.
    k8s_scale_fallback_enabled: bool = field(default_factory=lambda: _env_bool("K8S_SCALE_FALLBACK_ENABLED", False))

    # ─── HTTP server ───
    http_host: str = field(default_factory=lambda: _env_str("HTTP_HOST", "0.0.0.0"))
    http_port: int = field(default_factory=lambda: _env_int("HTTP_PORT", 8080))


def load_config() -> ControllerConfig:
    return ControllerConfig()
