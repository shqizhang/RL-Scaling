"""Decision engine for elastic role switching (S2.7)."""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from typing import List, Optional

from ..config import ControllerConfig
from ..metrics_collector import ClusterMetrics, MetricsCollectorProtocol
from .dual_mode_client import DualModeClient, SwitchResult
from .strategy import find_most_idle_worker

logger = logging.getLogger(__name__)


@dataclass
class RoleSwitchDecision:
    """A single switch the controller has chosen to perform."""

    worker_url: str
    from_role: str
    to_role: str
    reason: str
    executed: bool = False
    result: Optional[SwitchResult] = None


@dataclass
class ElasticRoleSwitchController:
    config: ControllerConfig
    metrics: MetricsCollectorProtocol
    client: DualModeClient
    clock: callable = field(default=time.monotonic)
    _last_switch_time: float = field(default=-1e18, init=False)
    history: List[RoleSwitchDecision] = field(default_factory=list, init=False)

    # ------------------------------------------------------------------ helpers
    def _can_switch(self) -> bool:
        if not self.config.role_switch_enabled:
            return False
        return (self.clock() - self._last_switch_time) >= self.config.min_switch_interval_seconds

    def _decide(self, cluster: ClusterMetrics, decode_workers, prefill_workers) -> Optional[RoleSwitchDecision]:
        # Decode -> Prefill: prefill backlogged AND a decode worker is idle.
        if (
            cluster.prefill_queue_depth >= self.config.prefill_queue_threshold
            and cluster.decode_utilization <= self.config.decode_idle_threshold
            and cluster.decode_worker_count > self.config.min_decode_replicas
        ):
            target = find_most_idle_worker(decode_workers, role="decode")
            if target is None:
                return None
            return RoleSwitchDecision(
                worker_url=target.addr,
                from_role="decode",
                to_role="prefill",
                reason=(
                    f"prefill_queue={cluster.prefill_queue_depth}>={self.config.prefill_queue_threshold} "
                    f"and decode_util={cluster.decode_utilization:.2f}<={self.config.decode_idle_threshold:.2f}"
                ),
            )

        # Prefill -> Decode: decode backlogged AND a prefill worker is idle.
        if (
            cluster.decode_queue_depth >= self.config.decode_queue_threshold
            and cluster.prefill_utilization <= self.config.prefill_idle_threshold
            and cluster.prefill_worker_count > self.config.min_prefill_replicas
        ):
            target = find_most_idle_worker(prefill_workers, role="prefill")
            if target is None:
                return None
            return RoleSwitchDecision(
                worker_url=target.addr,
                from_role="prefill",
                to_role="decode",
                reason=(
                    f"decode_queue={cluster.decode_queue_depth}>={self.config.decode_queue_threshold} "
                    f"and prefill_util={cluster.prefill_utilization:.2f}<={self.config.prefill_idle_threshold:.2f}"
                ),
            )
        return None

    # ------------------------------------------------------------------ public
    async def evaluate_and_execute(self) -> Optional[RoleSwitchDecision]:
        """Run a single decision tick. Returns the decision (executed or not)."""
        if not self._can_switch():
            return None
        cluster = await self.metrics.get_cluster_metrics()
        workers = await self.metrics.get_decode_worker_states() or []
        decision = self._decide(cluster, decode_workers=workers, prefill_workers=workers)
        if decision is None:
            return None
        try:
            decision.result = self.client.switch_role(decision.worker_url, decision.to_role)
            decision.executed = decision.result.status == "ok"
            if decision.executed:
                self._last_switch_time = self.clock()
        except Exception as exc:  # noqa: BLE001
            logger.warning("Role switch failed: %s", exc)
            decision.executed = False
        self.history.append(decision)
        return decision
