import pytest

from rl_scaling_controller.capacity_planner import CapacityPlanner
from rl_scaling_controller.dgdsa_client import InMemoryDGDSAClient
from rl_scaling_controller.metrics_collector import InMemoryMetricsCollector
from rl_scaling_controller.state_machine import (
    ScalingStateMachine,
    State,
    _StateMachineConfig,
)


class FakeClock:
    def __init__(self, t: float = 0.0) -> None:
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance(self, dt: float) -> None:
        self.t += dt


@pytest.fixture
def context():
    clock = FakeClock()
    dgdsa = InMemoryDGDSAClient()
    metrics = InMemoryMetricsCollector()
    planner = CapacityPlanner(50_000, 64, 5.0, 8)
    sm = ScalingStateMachine(
        config=_StateMachineConfig(pre_warm_threshold=0.8, cooldown_seconds=30),
        dgdsa=dgdsa,
        planner=planner,
        metrics=metrics,
        clock=clock,
    )
    return sm, dgdsa, metrics, clock


class TestSamplingProgressTriggersPreWarm:
    def test_below_threshold_no_action(self, context):
        sm, dgdsa, _, _ = context
        sm.on_sampling_progress(0.5, {"batch_size": 8, "avg_isl": 100})
        assert sm.state == State.IDLE
        assert dgdsa.get_replicas("prefill") == 0

    def test_at_threshold_triggers_warmup(self, context):
        sm, dgdsa, _, _ = context
        sm.on_sampling_progress(0.8, {"batch_size": 128, "avg_isl": 500})
        assert sm.state == State.WARM_UP
        assert dgdsa.get_replicas("prefill") >= 1
        assert dgdsa.get_replicas("decode") >= 1

    def test_progress_in_warm_up_is_ignored(self, context):
        sm, dgdsa, _, _ = context
        sm.on_sampling_progress(0.9, {"batch_size": 128, "avg_isl": 500})
        history_len = len(dgdsa.history)
        sm.on_sampling_progress(0.95, {"batch_size": 128, "avg_isl": 500})
        # No new patches should be issued.
        assert len(dgdsa.history) == history_len

    @pytest.mark.parametrize("p", [-0.1, 1.1])
    def test_invalid_progress(self, context, p):
        sm = context[0]
        with pytest.raises(ValueError):
            sm.on_sampling_progress(p, {"batch_size": 1, "avg_isl": 1})


class TestSamplingDone:
    def test_from_idle_warms_up_immediately(self, context):
        sm, dgdsa, _, _ = context
        sm.on_sampling_done({"batch_size": 64, "avg_isl": 200})
        assert sm.state == State.WARM_UP
        assert dgdsa.get_replicas("prefill") >= 1

    def test_no_op_in_active(self, context):
        sm, dgdsa, metrics, _ = context
        sm.on_sampling_progress(0.9, {"batch_size": 128, "avg_isl": 500})
        # Force ACTIVE
        metrics.ready_counts = {"prefill": 8, "decode": 8}
        # Run async tick synchronously via asyncio
        import asyncio
        asyncio.run(sm.control_loop_tick())
        assert sm.state == State.ACTIVE
        history_len = len(dgdsa.history)
        sm.on_sampling_done({"batch_size": 128, "avg_isl": 500})
        assert sm.state == State.ACTIVE
        assert len(dgdsa.history) == history_len

    def test_during_cool_down_re_warms(self, context):
        sm, dgdsa, metrics, clock = context
        sm.on_sampling_done({"batch_size": 64, "avg_isl": 200})
        metrics.ready_counts = {"prefill": 8, "decode": 8}
        import asyncio
        asyncio.run(sm.control_loop_tick())  # ACTIVE
        sm.on_batch_complete()
        assert sm.state == State.COOL_DOWN
        sm.on_sampling_done({"batch_size": 64, "avg_isl": 200})
        assert sm.state == State.WARM_UP


class TestControlLoop:
    def test_warm_up_to_active_when_workers_ready(self, context):
        sm, _, metrics, _ = context
        sm.on_sampling_done({"batch_size": 128, "avg_isl": 500})
        target = sm.current_target
        metrics.ready_counts = {
            "prefill": target.prefill_replicas,
            "decode": target.decode_replicas,
        }
        import asyncio
        asyncio.run(sm.control_loop_tick())
        assert sm.state == State.ACTIVE

    def test_warm_up_stays_when_workers_not_ready(self, context):
        sm, _, metrics, _ = context
        sm.on_sampling_done({"batch_size": 128, "avg_isl": 500})
        metrics.ready_counts = {"prefill": 0, "decode": 0}
        import asyncio
        asyncio.run(sm.control_loop_tick())
        assert sm.state == State.WARM_UP

    def test_cool_down_drains_to_idle_after_grace(self, context):
        sm, dgdsa, metrics, clock = context
        sm.on_sampling_done({"batch_size": 64, "avg_isl": 200})
        metrics.ready_counts = {"prefill": 8, "decode": 8}
        import asyncio
        asyncio.run(sm.control_loop_tick())  # ACTIVE
        sm.on_batch_complete()
        clock.advance(31)
        asyncio.run(sm.control_loop_tick())
        assert sm.state == State.IDLE
        assert dgdsa.get_replicas("prefill") == 0
        assert dgdsa.get_replicas("decode") == 0

    def test_cool_down_stays_within_grace(self, context):
        sm, dgdsa, metrics, clock = context
        sm.on_sampling_done({"batch_size": 64, "avg_isl": 200})
        metrics.ready_counts = {"prefill": 8, "decode": 8}
        import asyncio
        asyncio.run(sm.control_loop_tick())  # ACTIVE
        sm.on_batch_complete()
        clock.advance(5)
        asyncio.run(sm.control_loop_tick())
        assert sm.state == State.COOL_DOWN


class TestIllegalTransitions:
    def test_active_cannot_go_directly_to_idle(self, context):
        sm = context[0]
        sm.on_sampling_done({"batch_size": 1, "avg_isl": 1})
        # Force into ACTIVE
        metrics = context[2]
        metrics.ready_counts = {"prefill": 8, "decode": 8}
        import asyncio
        asyncio.run(sm.control_loop_tick())
        assert not sm.transition_to(State.IDLE)
        assert sm.state == State.ACTIVE

    def test_batch_complete_outside_active_logs_and_returns(self, context):
        sm = context[0]
        # IDLE → batch_complete should be no-op and not crash
        sm.on_batch_complete()
        assert sm.state == State.IDLE


class TestHistory:
    def test_history_tracks_transitions(self, context):
        sm, _, metrics, clock = context
        sm.on_sampling_done({"batch_size": 4, "avg_isl": 10})
        metrics.ready_counts = {"prefill": 8, "decode": 8}
        import asyncio
        asyncio.run(sm.control_loop_tick())
        sm.on_batch_complete()
        clock.advance(31)
        asyncio.run(sm.control_loop_tick())
        states = [(h.from_state, h.to_state) for h in sm.history]
        assert (State.IDLE, State.WARM_UP) in states
        assert (State.WARM_UP, State.ACTIVE) in states
        assert (State.ACTIVE, State.COOL_DOWN) in states
        assert (State.COOL_DOWN, State.IDLE) in states
