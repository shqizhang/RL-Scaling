"""Application entry point: builds the controller, starts the HTTP server,
and runs a background control loop tick every ``control_loop_interval`` seconds.
"""
from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from typing import Optional

import uvicorn

from .capacity_planner import CapacityPlanner
from .config import ControllerConfig, load_config
from .dgdsa_client import DGDSAClientProtocol, InMemoryDGDSAClient, K8sDGDSAClient
from .metrics_collector import (
    InMemoryMetricsCollector,
    MetricsCollectorProtocol,
    PrometheusMetricsCollector,
)
from .signal_receiver import create_app
from .state_machine import ScalingStateMachine, _StateMachineConfig

logger = logging.getLogger(__name__)


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
            dgdsa = K8sDGDSAClient(namespace=cfg.namespace, dgd_name=cfg.dgd_name)
        except Exception as exc:
            logger.warning("Falling back to InMemoryDGDSAClient: %s", exc)
            dgdsa = InMemoryDGDSAClient()
    if metrics is None:
        metrics = PrometheusMetricsCollector(cfg.prometheus_url)
    sm = _build_state_machine(cfg, dgdsa, metrics)
    app = create_app(lambda: sm)
    return cfg, sm, app


async def _control_loop(sm: ScalingStateMachine, interval: float) -> None:
    while True:
        try:
            await sm.control_loop_tick()
        except Exception:  # noqa: BLE001
            logger.exception("control_loop tick failed")
        await asyncio.sleep(interval)


@asynccontextmanager
async def _lifespan(app, sm, interval):
    task = asyncio.create_task(_control_loop(sm, interval))
    try:
        yield
    finally:
        task.cancel()


def main() -> None:  # pragma: no cover - thin glue
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    cfg, sm, app = build()

    @app.on_event("startup")
    async def _start():
        app.state.bg = asyncio.create_task(_control_loop(sm, cfg.control_loop_interval))

    @app.on_event("shutdown")
    async def _stop():
        app.state.bg.cancel()

    uvicorn.run(app, host=cfg.http_host, port=cfg.http_port)


if __name__ == "__main__":  # pragma: no cover
    main()
