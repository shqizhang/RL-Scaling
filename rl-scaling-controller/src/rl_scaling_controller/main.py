"""Application entry point: builds the controller, starts the HTTP server,
and runs a background control loop tick every ``control_loop_interval`` seconds.
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from contextlib import asynccontextmanager
from typing import Optional

import uvicorn

from .capacity_planner import CapacityPlanner
from .consolidation import ConsolidationController, MigrationClient
from .config import ControllerConfig, load_config
from .dgdsa_client import DGDSAClientProtocol, InMemoryDGDSAClient, K8sDGDSAClient
from .metrics_collector import (
    InMemoryMetricsCollector,
    MetricsCollectorProtocol,
    PrometheusMetricsCollector,
)
from .role_switch import DualModeClient, ElasticRoleSwitchController
from .signal_receiver import create_app
from .state_machine import ScalingStateMachine, _StateMachineConfig

logger = logging.getLogger(__name__)


@dataclass
class StrategyRuntime:
    batch_completion_pct: float = 0.0
    s2: Optional[ElasticRoleSwitchController] = None
    s3: Optional[ConsolidationController] = None
    tick_errors: list[str] = field(default_factory=list)

    def status(self) -> dict:
        def _s2_history():
            if not self.s2:
                return []
            rows = []
            for item in self.s2.history[-20:]:
                rows.append(
                    {
                        "worker_url": item.worker_url,
                        "from_role": item.from_role,
                        "to_role": item.to_role,
                        "reason": item.reason,
                        "executed": item.executed,
                        "result": (
                            {
                                "status": item.result.status,
                                "switch_time_ms": item.result.switch_time_ms,
                                "new_role": item.result.new_role,
                            }
                            if item.result
                            else None
                        ),
                    }
                )
            return rows

        def _s3_history():
            if not self.s3:
                return []
            rows = []
            for item in self.s3.history[-20:]:
                rows.append(
                    {
                        "plans": [
                            {
                                "source": p.source.worker_id,
                                "target": p.target.worker_id,
                                "request_count": p.request_count,
                            }
                            for p in item.plans
                        ],
                        "executed_pairs": item.executed_pairs,
                        "migration_attempts": getattr(item, "migration_attempts", 0),
                        "migrated_requests": getattr(item, "migrated_requests", 0),
                        "declined_requests": getattr(item, "declined_requests", 0),
                        "drained_sources": getattr(item, "drained_sources", []),
                        "scaled_down_to": item.scaled_down_to,
                        "scale_down_blocked_reason": getattr(item, "scale_down_blocked_reason", None),
                        "error": item.error,
                    }
                )
            return rows

        return {
            "batch_completion_pct": self.batch_completion_pct,
            "s2_enabled": self.s2 is not None,
            "s3_enabled": self.s3 is not None,
            "s2_history": _s2_history(),
            "s3_history": _s3_history(),
            "tick_errors": self.tick_errors[-20:],
        }


def _build_state_machine(
    cfg: ControllerConfig,
    dgdsa: DGDSAClientProtocol,
    metrics: Optional[MetricsCollectorProtocol],
) -> ScalingStateMachine:
    planner = CapacityPlanner(
        single_prefill_tps=cfg.single_prefill_tps,
        max_concurrent_per_decode=cfg.max_concurrent_per_decode,
        target_prefill_seconds=cfg.target_prefill_seconds,
        max_gpus=cfg.max_gpus,
        min_prefill_replicas=cfg.min_prefill_replicas,
        min_decode_replicas=cfg.min_decode_replicas,
    )
    return ScalingStateMachine(
        config=_StateMachineConfig(
            pre_warm_threshold=cfg.pre_warm_threshold,
            cooldown_seconds=cfg.cooldown_seconds,
            drain_timeout_seconds=cfg.drain_timeout_seconds,
        ),
        dgdsa=dgdsa,
        planner=planner,
        metrics=metrics,
    )


def build(
    cfg: Optional[ControllerConfig] = None,
    dgdsa: Optional[DGDSAClientProtocol] = None,
    metrics: Optional[MetricsCollectorProtocol] = None,
):
    cfg = cfg or load_config()
    if dgdsa is None:
        try:
            dgdsa = K8sDGDSAClient(
                namespace=cfg.namespace,
                dgd_name=cfg.dgd_name,
                deployment_fallback_enabled=cfg.k8s_scale_fallback_enabled,
            )
        except Exception as exc:
            logger.warning("Falling back to InMemoryDGDSAClient: %s", exc)
            dgdsa = InMemoryDGDSAClient()
    if metrics is None:
        metrics = PrometheusMetricsCollector(
            cfg.prometheus_url,
            namespace=cfg.namespace,
            dgd_name=cfg.dgd_name,
            worker_sidecar_port=cfg.worker_sidecar_port,
            max_concurrent_per_decode=cfg.max_concurrent_per_decode,
        )
    sm = _build_state_machine(cfg, dgdsa, metrics)
    strategy = StrategyRuntime()
    if cfg.consolidation_enabled:
        strategy.s3 = ConsolidationController(
            config=cfg,
            metrics=metrics,
            dgdsa=dgdsa,
            client=MigrationClient(timeout=90.0),
            batch_completion_fn=lambda: strategy.batch_completion_pct,
        )
    if cfg.role_switch_enabled:
        strategy.s2 = ElasticRoleSwitchController(
            config=cfg,
            metrics=metrics,
            client=DualModeClient(timeout=90.0),
        )
    app = create_app(
        lambda: sm,
        on_sampling_progress=lambda progress: setattr(strategy, "batch_completion_pct", progress),
        strategy_status_factory=strategy.status,
    )
    return cfg, sm, app, strategy


async def _control_loop(sm: ScalingStateMachine, strategy: StrategyRuntime, interval: float) -> None:
    while True:
        try:
            if strategy.s3 is not None:
                await strategy.s3.control_loop_tick()
            if strategy.s2 is not None:
                await strategy.s2.evaluate_and_execute()
            await sm.control_loop_tick()
        except Exception as exc:  # noqa: BLE001
            logger.exception("control_loop tick failed")
            strategy.tick_errors.append(str(exc))
        await asyncio.sleep(interval)


@asynccontextmanager
async def _lifespan(app, sm, strategy, interval):
    task = asyncio.create_task(_control_loop(sm, strategy, interval))
    try:
        yield
    finally:
        task.cancel()


def main() -> None:  # pragma: no cover - thin glue
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    cfg, sm, app, strategy = build()

    @app.on_event("startup")
    async def _start():
        app.state.bg = asyncio.create_task(_control_loop(sm, strategy, cfg.control_loop_interval))

    @app.on_event("shutdown")
    async def _stop():
        app.state.bg.cancel()

    uvicorn.run(app, host=cfg.http_host, port=cfg.http_port)


if __name__ == "__main__":  # pragma: no cover
    main()
