"""Picks (source_worker, target_worker, request_count) tuples to migrate.

Two-pointer pairing of *idle* workers (low ``in_flight_requests``, i.e. the
ones we want to drain to zero) onto *target* workers (those with sufficient
``available_capacity``). Cost / benefit gating ensures we only migrate when
the migration time is comfortably less than the source worker's remaining
runtime.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, List, Optional, Sequence

from ..config import ControllerConfig
from ..metrics_collector import WorkerState


@dataclass(frozen=True)
class MigrationPair:
    source: WorkerState
    target: WorkerState
    request_count: int

    def __post_init__(self):
        if self.request_count <= 0:
            raise ValueError("request_count must be positive")


@dataclass
class ConsolidationDecisionEngine:
    config: ControllerConfig

    # ------------------------------------------------------------------ helpers
    def _migration_time_seconds(self, request_count: int) -> float:
        return request_count * self.config.per_request_migration_overhead

    def _is_worth_migrating(self, source: WorkerState, request_count: int) -> bool:
        # Only migrate if the migration time is < 50% of remaining runtime.
        if source.estimated_remaining_time <= 0:
            return False
        return self._migration_time_seconds(request_count) < (source.estimated_remaining_time * 0.5)

    # ------------------------------------------------------------------ public
    def evaluate(
        self,
        decode_workers: Sequence[WorkerState],
        batch_completion_pct: float,
    ) -> List[MigrationPair]:
        """Return a list of pairs to migrate; empty when nothing to do."""
        if not self.config.consolidation_enabled:
            return []
        if batch_completion_pct < self.config.min_batch_completion_pct:
            return []
        if len(decode_workers) <= self.config.min_decode_replicas:
            return []

        # Sort: candidates to drain (lowest in-flight first) at the front,
        # candidates to receive (most spare capacity first) at the back.
        sorted_workers = sorted(decode_workers, key=lambda w: w.in_flight_requests)
        i, j = 0, len(sorted_workers) - 1
        plans: List[MigrationPair] = []

        # Track which workers we've chosen as a source so we don't pick the
        # same worker as both source and target in the same pass.
        chosen_sources: set[str] = set()
        chosen_targets: set[str] = set()

        # Don't drop below ``min_decode_replicas`` even after consolidation.
        max_to_drain = max(0, len(sorted_workers) - self.config.min_decode_replicas)

        while i < j and len(chosen_sources) < max_to_drain:
            src = sorted_workers[i]
            tgt = sorted_workers[j]
            if src.worker_id == tgt.worker_id:
                break
            if src.in_flight_requests <= 0:
                # Already drained -- skip.
                i += 1
                continue
            if src.in_flight_requests > self.config.consolidation_threshold:
                # Source still too busy to bother draining.
                break
            if tgt.available_capacity < src.in_flight_requests:
                # Target can't absorb -- try the next-most-spare target.
                j -= 1
                continue
            if not self._is_worth_migrating(src, src.in_flight_requests):
                i += 1
                continue
            if src.worker_id in chosen_targets or tgt.worker_id in chosen_sources:
                break

            plans.append(MigrationPair(source=src, target=tgt, request_count=src.in_flight_requests))
            chosen_sources.add(src.worker_id)
            chosen_targets.add(tgt.worker_id)
            i += 1
        return plans
