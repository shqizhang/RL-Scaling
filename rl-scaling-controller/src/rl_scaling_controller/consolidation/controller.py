"""Top-level consolidation controller — runs one decision tick.

Wired into the main control loop when ``CONSOLIDATION_ENABLED`` is set.
Migrates a few stragglers, then asks the DGDSA scaler to drop the now-empty
decode replicas (subject to ``min_decode_replicas``).
"""
from __future__ import annotations

import logging
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

    @property
    def engine(self) -> ConsolidationDecisionEngine:
        return ConsolidationDecisionEngine(self.config)

    async def control_loop_tick(self) -> Optional[ConsolidationDecision]:
        if not self.config.consolidation_enabled:
            return None

        completion = float(self.batch_completion_fn())
        workers = await self.metrics.get_decode_worker_states() or []
        plans = self.engine.evaluate(decode_workers=workers, batch_completion_pct=completion)
        if not plans:
            return None

        decision = ConsolidationDecision(plans=plans)
        try:
            for pair in plans:
                # The controller can only see in_flight at decision time; we
                # honestly don't know the request_ids without another metrics
                # call. The Dynamo-side `/migrate_out` therefore accepts a
                # special "*" token meaning "next ready request". Repeat
                # migration_count times.
                for _ in range(pair.request_count):
                    self.client.migrate_one(
                        source_url=pair.source.addr,
                        target_url=pair.target.addr,
                        request_id="*",
                    )
                decision.executed_pairs += 1

            # Drop the drained decode replicas down to (current - drained).
            current = self.dgdsa.get_replicas("decode")
            new_count = max(self.config.min_decode_replicas, current - decision.executed_pairs)
            if new_count != current:
                self.dgdsa.patch("decode", new_count)
                decision.scaled_down_to = new_count
        except Exception as exc:  # noqa: BLE001
            logger.exception("consolidation tick failed")
            decision.error = str(exc)
        self.history.append(decision)
        return decision
