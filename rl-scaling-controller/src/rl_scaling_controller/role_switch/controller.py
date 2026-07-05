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
class RoleSwitchEvaluation:
    """One controller tick snapshot, including skipped decisions."""

    at: float
    prefill_queue_depth: int
    decode_queue_depth: int
    prefill_utilization: float
    decode_utilization: float
    prefill_worker_count: int
    decode_worker_count: int
    prefill_worker_active: int
    decode_worker_active: int
    prefill_workers: list[dict]
    decode_workers: list[dict]
    selected_action: Optional[str] = None
    skip_reason: Optional[str] = None


@dataclass
class ElasticRoleSwitchController:
    config: ControllerConfig
    metrics: MetricsCollectorProtocol
    client: DualModeClient
    clock: callable = field(default=time.monotonic)
    _last_switch_time: float = field(default=-1e18, init=False)
    history: List[RoleSwitchDecision] = field(default_factory=list, init=False)
    evaluation_history: List[RoleSwitchEvaluation] = field(default_factory=list, init=False)

    # ------------------------------------------------------------------ helpers
    def _can_switch(self) -> bool:
        if not self.config.role_switch_enabled:
            return False
        return (self.clock() - self._last_switch_time) >= self.config.min_switch_interval_seconds

    @staticmethod
    def _worker_snapshot(workers) -> list[dict]:
        return [
            {
                "worker_id": worker.worker_id,
                "role": worker.role,
                "in_flight_requests": worker.in_flight_requests,
                "available_capacity": worker.available_capacity,
                "estimated_remaining_time": worker.estimated_remaining_time,
            }
            for worker in workers
            if worker is not None
        ]

    @staticmethod
    def _active_sum(workers) -> int:
        return sum(getattr(worker, "in_flight_requests", 0) for worker in workers if worker is not None)

    @staticmethod
    def _role_count(workers, role: str) -> int:
        return len([worker for worker in workers if worker is not None and worker.role == role])

    def _record_evaluation(
        self,
        cluster: ClusterMetrics,
        decode_workers,
        prefill_workers,
        *,
        selected_action: Optional[str] = None,
        skip_reason: Optional[str] = None,
    ) -> None:
        self.evaluation_history.append(
            RoleSwitchEvaluation(
                at=self.clock(),
                prefill_queue_depth=cluster.prefill_queue_depth,
                decode_queue_depth=cluster.decode_queue_depth,
                prefill_utilization=cluster.prefill_utilization,
                decode_utilization=cluster.decode_utilization,
                prefill_worker_count=cluster.prefill_worker_count,
                decode_worker_count=cluster.decode_worker_count,
                prefill_worker_active=self._active_sum(prefill_workers),
                decode_worker_active=self._active_sum(decode_workers),
                prefill_workers=self._worker_snapshot(prefill_workers),
                decode_workers=self._worker_snapshot(decode_workers),
                selected_action=selected_action,
                skip_reason=skip_reason,
            )
        )
        self.evaluation_history = self.evaluation_history[-100:]

    def _skip_reason(self, cluster: ClusterMetrics, decode_workers, prefill_workers) -> str:
        d_to_p = [
            (
                "prefill_queue_depth",
                cluster.prefill_queue_depth,
                ">=",
                self.config.prefill_queue_threshold,
                cluster.prefill_queue_depth >= self.config.prefill_queue_threshold,
            ),
            (
                "decode_utilization",
                cluster.decode_utilization,
                "<=",
                self.config.decode_idle_threshold,
                cluster.decode_utilization <= self.config.decode_idle_threshold,
            ),
            (
                "decode_worker_count",
                cluster.decode_worker_count,
                ">",
                self.config.min_decode_replicas,
                cluster.decode_worker_count > self.config.min_decode_replicas,
            ),
            ("decode_target_available", self._role_count(decode_workers, "decode"), ">", 0, bool(find_most_idle_worker([w for w in decode_workers if w is not None], role="decode"))),
        ]
        p_to_d = [
            (
                "decode_queue_depth",
                cluster.decode_queue_depth,
                ">=",
                self.config.decode_queue_threshold,
                cluster.decode_queue_depth >= self.config.decode_queue_threshold,
            ),
            (
                "prefill_utilization",
                cluster.prefill_utilization,
                "<=",
                self.config.prefill_idle_threshold,
                cluster.prefill_utilization <= self.config.prefill_idle_threshold,
            ),
            (
                "prefill_worker_count",
                cluster.prefill_worker_count,
                ">",
                self.config.min_prefill_replicas,
                cluster.prefill_worker_count > self.config.min_prefill_replicas,
            ),
            ("prefill_target_available", self._role_count(prefill_workers, "prefill"), ">", 0, bool(find_most_idle_worker([w for w in prefill_workers if w is not None], role="prefill"))),
        ]
        failed_d_to_p = [f"{name}={value}{op}{threshold}" for name, value, op, threshold, ok in d_to_p if not ok]
        failed_p_to_d = [f"{name}={value}{op}{threshold}" for name, value, op, threshold, ok in p_to_d if not ok]
        return "d_to_p_blocked:" + ",".join(failed_d_to_p) + ";p_to_d_blocked:" + ",".join(failed_p_to_d)

    def _decide(self, cluster: ClusterMetrics, decode_workers, prefill_workers) -> Optional[RoleSwitchDecision]:
        # Decode -> Prefill: prefill backlogged AND a decode worker is idle.
        if (
            cluster.prefill_queue_depth >= self.config.prefill_queue_threshold
            and cluster.decode_utilization <= self.config.decode_idle_threshold
            and cluster.decode_worker_count > self.config.min_decode_replicas
        ):
            target = find_most_idle_worker(decode_workers, role="decode")
            if target is None:
                self._record_evaluation(cluster, decode_workers, prefill_workers, skip_reason="d_to_p_no_decode_target")
                return None
            self._record_evaluation(cluster, decode_workers, prefill_workers, selected_action="decode_to_prefill")
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
                self._record_evaluation(cluster, decode_workers, prefill_workers, skip_reason="p_to_d_no_prefill_target")
                return None
            self._record_evaluation(cluster, decode_workers, prefill_workers, selected_action="prefill_to_decode")
            return RoleSwitchDecision(
                worker_url=target.addr,
                from_role="prefill",
                to_role="decode",
                reason=(
                    f"decode_queue={cluster.decode_queue_depth}>={self.config.decode_queue_threshold} "
                    f"and prefill_util={cluster.prefill_utilization:.2f}<={self.config.prefill_idle_threshold:.2f}"
                ),
            )
        self._record_evaluation(
            cluster,
            decode_workers,
            prefill_workers,
            skip_reason=self._skip_reason(cluster, decode_workers, prefill_workers),
        )
        return None

    # ------------------------------------------------------------------ public
    async def evaluate_and_execute(self) -> Optional[RoleSwitchDecision]:
        """Run a single decision tick. Returns the decision (executed or not)."""
        if not self._can_switch():
            return None
        cluster = await self.metrics.get_cluster_metrics()
        decode_workers = list(getattr(cluster, "decode_workers", []) or [])
        prefill_workers = list(getattr(cluster, "prefill_workers", []) or [])
        if not decode_workers:
            decode_workers = await self.metrics.get_decode_worker_states() or []
        decision = self._decide(cluster, decode_workers=decode_workers, prefill_workers=prefill_workers)
        if decision is None:
            return None
        logger.info(
            "S2 role switch decision: from=%s to=%s worker=%s reason=%s "
            "prefill_workers=%s decode_workers=%s",
            decision.from_role,
            decision.to_role,
            decision.worker_url,
            decision.reason,
            cluster.prefill_worker_count,
            cluster.decode_worker_count,
        )
        try:
            decision.result = self.client.switch_role(decision.worker_url, decision.to_role)
            decision.executed = decision.result.status == "ok"
            if decision.executed:
                self._last_switch_time = self.clock()
            logger.info(
                "S2 role switch result: executed=%s status=%s worker=%s new_role=%s switch_time_ms=%s",
                decision.executed,
                decision.result.status,
                decision.worker_url,
                decision.result.new_role,
                decision.result.switch_time_ms,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("Role switch failed: %s", exc)
            decision.executed = False
        self.history.append(decision)
        return decision
