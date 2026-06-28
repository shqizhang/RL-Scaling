"""Top-level consolidation controller — runs one decision tick.

Wired into the main control loop when ``CONSOLIDATION_ENABLED`` is set.
Migrates a few stragglers, then asks the DGDSA scaler to drop the now-empty
decode replicas (subject to ``min_decode_replicas``).
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional

from ..config import ControllerConfig
from ..dgdsa_client import DGDSAClientProtocol
from ..metrics_collector import MetricsCollectorProtocol
from .decision_engine import ConsolidationDecisionEngine, MigrationPair
from .migration_client import MigrationClient

logger = logging.getLogger(__name__)


@dataclass
class ConsolidationDecision:
    plans: List[MigrationPair]
    executed_pairs: int = 0
    migration_attempts: int = 0
    migrated_requests: int = 0
    declined_requests: int = 0
    scaled_down_to: Optional[int] = None
    error: Optional[str] = None


@dataclass
class ConsolidationController:
    config: ControllerConfig
    metrics: MetricsCollectorProtocol
    dgdsa: DGDSAClientProtocol
    client: MigrationClient
    batch_completion_fn: Callable[[], float]
    history: List[ConsolidationDecision] = field(default_factory=list, init=False)
    pending_windows: dict[str, int] = field(default_factory=dict, init=False)
    last_action_ts: float = field(default=0.0, init=False)

    @property
    def engine(self) -> ConsolidationDecisionEngine:
        return ConsolidationDecisionEngine(self.config)

    @staticmethod
    def _plan_key(pair: MigrationPair) -> str:
        return f"{pair.source.worker_id}->{pair.target.worker_id}:{pair.request_count}"

    async def control_loop_tick(self) -> Optional[ConsolidationDecision]:
        if not self.config.consolidation_enabled:
            return None

        completion = float(self.batch_completion_fn())
        workers = await self.metrics.get_decode_worker_states() or []
        plans = self.engine.evaluate(decode_workers=workers, batch_completion_pct=completion)
        if not plans:
            self.pending_windows.clear()
            return None

        now = time.monotonic()
        min_interval = max(0.0, float(self.config.consolidation_min_interval_seconds))
        if self.last_action_ts and (now - self.last_action_ts) < min_interval:
            logger.info(
                "S3 consolidation gated by cooldown: remaining_s=%.3f plans=%s",
                min_interval - (now - self.last_action_ts),
                [self._plan_key(pair) for pair in plans],
            )
            return None

        stable_required = max(1, int(self.config.consolidation_stable_samples))
        current_keys = {self._plan_key(pair) for pair in plans}
        self.pending_windows = {
            key: count for key, count in self.pending_windows.items() if key in current_keys
        }
        ready_plans: List[MigrationPair] = []
        for pair in plans:
            key = self._plan_key(pair)
            count = self.pending_windows.get(key, 0) + 1
            self.pending_windows[key] = count
            if count >= stable_required:
                ready_plans.append(pair)

        if not ready_plans:
            logger.info(
                "S3 consolidation waiting for stable window: required=%s pending=%s",
                stable_required,
                self.pending_windows,
            )
            return None

        decision = ConsolidationDecision(plans=ready_plans)
        logger.info(
            "S3 consolidation decision: completion=%.3f threshold=%.3f plans=%s",
            completion,
            self.config.min_batch_completion_pct,
            [
                {
                    "source": pair.source.worker_id,
                    "source_active": pair.source.in_flight_requests,
                    "target": pair.target.worker_id,
                    "target_capacity": pair.target.available_capacity,
                    "request_count": pair.request_count,
                }
                for pair in ready_plans
            ],
        )
        try:
            for pair in ready_plans:
                # The controller can only see in_flight at decision time; we
                # honestly don't know the request_ids without another metrics
                # call. The Dynamo-side `/migrate_out` therefore accepts a
                # special "*" token meaning "next ready request". Repeat
                # migration_count times.
                pair_migrated = 0
                for _ in range(pair.request_count):
                    result = self.client.migrate_one(
                        source_url=pair.source.addr,
                        target_url=pair.target.addr,
                        request_id="*",
                    )
                    decision.migration_attempts += 1
                    if result.get("status") == "ok":
                        pair_migrated += 1
                        decision.migrated_requests += 1
                        continue

                    decision.declined_requests += 1
                    logger.info(
                        "S3 migration stopped for pair after non-ok response: "
                        "source=%s target=%s status=%s rolled_back=%s message=%s",
                        pair.source.worker_id,
                        pair.target.worker_id,
                        result.get("status"),
                        result.get("rolled_back"),
                        (result.get("migrate_in") or {}).get("message") or result.get("message"),
                    )
                    break
                if pair_migrated:
                    decision.executed_pairs += 1
                logger.info(
                    "S3 consolidation executed: source=%s target=%s request_count=%s migrated=%s",
                    pair.source.worker_id,
                    pair.target.worker_id,
                    pair.request_count,
                    pair_migrated,
                )
            if decision.executed_pairs:
                self.last_action_ts = time.monotonic()
                self.pending_windows.clear()

            if self.config.consolidation_scale_down_enabled:
                # Drop the drained decode replicas down to (current - drained).
                current = self.dgdsa.get_replicas("decode")
                new_count = max(self.config.min_decode_replicas, current - decision.executed_pairs)
                if new_count != current:
                    self.dgdsa.patch("decode", new_count)
                    decision.scaled_down_to = new_count
                    logger.info("S3 consolidation scaled decode replicas: %s -> %s", current, new_count)
        except Exception as exc:  # noqa: BLE001
            logger.exception("consolidation tick failed")
            decision.error = str(exc)
        self.history.append(decision)
        return decision
