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
    # True => the source is ALREADY idle (0 in-flight) and is being released
    # directly (drain-free consolidation): no migration happens, the controller
    # skips straight to cordon + mark-drained + scale-down. request_count is 0.
    is_release: bool = False

    def __post_init__(self):
        if self.is_release:
            if self.request_count != 0:
                raise ValueError("release pair must have request_count == 0")
            return
        if self.request_count <= 0:
            raise ValueError("request_count must be positive")


@dataclass
class ConsolidationDecisionEngine:
    config: ControllerConfig

    # ------------------------------------------------------------------ helpers
    def _migration_time_seconds(self, request_count: int) -> float:
        return request_count * self.config.per_request_migration_overhead

    def _is_worth_migrating(self, source: WorkerState, request_count: int) -> bool:
        """Cost/benefit gate: migrate only if migration is < 50% of remaining runtime.

        NOTE (2026-07): this gate is **not claimed as a validated safety
        property**. It depends on ``estimated_remaining_time``, which is a
        heuristic derived from token progress divided by an assumed decode
        rate. With the previously mis-calibrated rate (20 tok/s vs ~150-2000
        measured) the predicate was always true, so the gate never declined a
        single migration in any run -- it was decorative. It is retained as a
        conservative guard, and can be switched off explicitly via
        ``worth_migrating_gate_enabled=false`` rather than being left silently
        always-passing.
        """
        if not getattr(self.config, "worth_migrating_gate_enabled", True):
            return True
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

        # --- Idle-decoder release (drain-free consolidation) ---
        # A decoder already at 0 in-flight, beyond min_decode_replicas, can be
        # released directly: there is nothing to migrate FROM it, yet keeping it
        # idle wastes a GPU. This is the KEY case for MIXED (S2+S3): after an S2
        # P->D switch-back the stragglers are concentrated on one decoder while
        # the re-created decoder sits empty (a 3+0 split), which the migration
        # pass above skips (src.in_flight <= 0). Emit such empty decoders as
        # release-only pairs; the controller skips migration and scales them
        # down. Bounded by the same max_to_drain (never drop below the floor).
        busiest = sorted_workers[-1] if sorted_workers else None
        if busiest is not None:
            for w in sorted_workers:
                if len(chosen_sources) >= max_to_drain:
                    break
                if w.worker_id in chosen_sources or w.worker_id in chosen_targets:
                    continue
                if w.in_flight_requests == 0 and w.worker_id != busiest.worker_id:
                    plans.append(MigrationPair(source=w, target=busiest, request_count=0, is_release=True))
                    chosen_sources.add(w.worker_id)

        return plans
