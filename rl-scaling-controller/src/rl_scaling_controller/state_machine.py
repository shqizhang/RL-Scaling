"""Scaling state machine.

States:
    IDLE       — no GPU allocated, waiting for an RL signal.
    WARM_UP    — scaled up; waiting for workers to become Ready.
    ACTIVE     — workers Ready and serving inference.
    COOL_DOWN  — batch complete; waiting for the cooldown grace period.

Allowed transitions:
    IDLE -> WARM_UP
    WARM_UP -> ACTIVE | COOL_DOWN     (COOL_DOWN: pre-warm canceled)
    ACTIVE -> COOL_DOWN
    COOL_DOWN -> IDLE | WARM_UP       (WARM_UP: a new batch arrived during cooldown)

The state machine is intentionally synchronous; the only async surface is
``control_loop_tick`` which polls metrics and times out the cooldown.
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Awaitable, Callable, List, Mapping, Optional, Protocol

from .capacity_planner import CapacityPlanner, ScaleTarget

logger = logging.getLogger(__name__)


class State(str, Enum):
    IDLE = "idle"
    WARM_UP = "warm_up"
    ACTIVE = "active"
    COOL_DOWN = "cool_down"


_TRANSITIONS: dict[State, set[State]] = {
    State.IDLE: {State.WARM_UP},
    # WARM_UP -> COOL_DOWN covers two cases:
    #   (a) pre-warm canceled before workers became Ready, and
    #   (b) batch finished so fast that batch_complete arrived before the
    #       Prometheus poll could move us to ACTIVE.
    State.WARM_UP: {State.ACTIVE, State.COOL_DOWN},
    State.ACTIVE: {State.COOL_DOWN},
    State.COOL_DOWN: {State.IDLE, State.WARM_UP},
}


class DGDSAClientProtocol(Protocol):
    def patch(self, service: str, replicas: int) -> None: ...


class MetricsCollectorProtocol(Protocol):
    async def get_ready_worker_count(self, service: str) -> int: ...


@dataclass
class StateChange:
    from_state: State
    to_state: State
    at: float


@dataclass
class ScalingStateMachine:
    config: "_StateMachineConfig"
    dgdsa: DGDSAClientProtocol
    planner: CapacityPlanner
    metrics: Optional[MetricsCollectorProtocol] = None
    clock: Callable[[], float] = time.monotonic
    state: State = State.IDLE
    current_target: Optional[ScaleTarget] = None
    _state_entered_at: float = field(default=0.0)
    history: List[StateChange] = field(default_factory=list)

    def __post_init__(self) -> None:
        self._state_entered_at = self.clock()

    # ─── Public state interface ───
    def transition_to(self, new_state: State) -> bool:
        if new_state == self.state:
            return False
        if new_state not in _TRANSITIONS[self.state]:
            logger.warning("Illegal transition %s -> %s, ignoring", self.state, new_state)
            return False
        prev = self.state
        self.state = new_state
        now = self.clock()
        self._state_entered_at = now
        self.history.append(StateChange(prev, new_state, now))
        logger.info("State transition: %s -> %s", prev, new_state)
        return True

    @property
    def time_in_state(self) -> float:
        return self.clock() - self._state_entered_at

    # ─── Event handlers ───
    def on_sampling_progress(self, progress: float, batch_meta: Mapping[str, int]) -> State:
        if not 0.0 <= progress <= 1.0:
            raise ValueError("progress must be in [0, 1]")
        if self.state != State.IDLE:
            return self.state
        if progress < self.config.pre_warm_threshold:
            return self.state
        target = self.planner.compute(batch_meta)
        self._scale_to(target)
        self.transition_to(State.WARM_UP)
        return self.state

    def on_sampling_done(self, batch_meta: Mapping[str, int]) -> State:
        target = self.planner.compute(batch_meta)
        if self.state == State.IDLE:
            self._scale_to(target)
            self.transition_to(State.WARM_UP)
        elif self.state == State.COOL_DOWN:
            # New batch arrived before cooldown finished — re-scale up.
            self._scale_to(target)
            self.transition_to(State.WARM_UP)
        elif self.state == State.WARM_UP:
            # If the new target needs more replicas than currently scheduled,
            # patch upward (never downward in WARM_UP — risk of dropping warmups).
            if self.current_target is None or target.total() > self.current_target.total():
                self._scale_to(target)
        # ACTIVE: nothing to do.
        return self.state

    def on_batch_complete(self) -> State:
        # Accept from ACTIVE (normal path) and from WARM_UP (tiny batch that
        # finished before workers were marked Ready by Prometheus). Reject
        # from IDLE/COOL_DOWN (no batch in flight).
        if self.state not in (State.ACTIVE, State.WARM_UP):
            logger.warning("batch_complete ignored in state %s", self.state)
            return self.state
        self.transition_to(State.COOL_DOWN)
        return self.state

    # ─── Async control loop tick (drives WARM_UP→ACTIVE and COOL_DOWN→IDLE) ───
    async def control_loop_tick(self) -> State:
        if self.state == State.WARM_UP and self.metrics is not None:
            assert self.current_target is not None
            ready_p = await self.metrics.get_ready_worker_count("prefill")
            ready_d = await self.metrics.get_ready_worker_count("decode")
            if (
                ready_p >= self.current_target.prefill_replicas
                and ready_d >= self.current_target.decode_replicas
            ):
                self.transition_to(State.ACTIVE)
        elif self.state == State.COOL_DOWN:
            # Two gates must clear before scale-to-zero:
            #   (1) cooldown_seconds elapsed (catches stragglers from RL loop), and
            #   (2) no in-flight requests across the cluster (so KV blocks can be
            #       evicted cleanly and KVPublisher can emit removed events to
            #       the Router KVIndexer before pods terminate).
            # Gate (2) is bounded by drain_timeout_seconds to guarantee progress.
            cooldown_done = self.time_in_state >= self.config.cooldown_seconds
            inflight = await self._inflight_total()
            drain_done = inflight == 0
            drain_forced = self.time_in_state >= self.config.drain_timeout_seconds
            if cooldown_done and (drain_done or drain_forced):
                if not drain_done:
                    logger.warning(
                        "drain timeout (%ss) hit with %d in-flight; forcing scale-to-zero",
                        self.config.drain_timeout_seconds,
                        inflight,
                    )
                self.dgdsa.patch("prefill", 0)
                self.dgdsa.patch("decode", 0)
                self.current_target = None
                self.transition_to(State.IDLE)
        return self.state

    async def _inflight_total(self) -> int:
        if self.metrics is None:
            return 0
        getter = getattr(self.metrics, "get_cluster_metrics", None)
        if getter is None:
            return 0
        try:
            cm = await getter()
        except Exception as exc:  # noqa: BLE001
            logger.warning("inflight probe failed, treating as 0: %s", exc)
            return 0
        return int(getattr(cm, "prefill_queue_depth", 0)) + int(getattr(cm, "decode_queue_depth", 0))

    # ─── Internals ───
    def _scale_to(self, target: ScaleTarget) -> None:
        self.current_target = target
        self.dgdsa.patch("prefill", target.prefill_replicas)
        self.dgdsa.patch("decode", target.decode_replicas)


@dataclass
class _StateMachineConfig:
    pre_warm_threshold: float
    cooldown_seconds: float
    drain_timeout_seconds: float = 60.0
