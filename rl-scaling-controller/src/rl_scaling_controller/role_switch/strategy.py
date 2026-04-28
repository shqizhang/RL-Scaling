"""Helpers for picking the best worker to flip roles."""
from __future__ import annotations

from typing import Iterable, Optional, Sequence

from ..metrics_collector import WorkerState


def find_most_idle_worker(
    workers: Iterable[WorkerState], role: str
) -> Optional[WorkerState]:
    """Return the worker with the lowest ``in_flight_requests`` matching ``role``.

    Returns ``None`` when no worker matches.
    """
    candidates: Sequence[WorkerState] = [w for w in workers if w.role == role]
    if not candidates:
        return None
    return min(candidates, key=lambda w: w.in_flight_requests)
