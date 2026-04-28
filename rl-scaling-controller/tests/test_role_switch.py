from dataclasses import replace

import pytest

from rl_scaling_controller.config import ControllerConfig, load_config
from rl_scaling_controller.metrics_collector import (
    ClusterMetrics,
    InMemoryMetricsCollector,
    WorkerState,
)
from rl_scaling_controller.role_switch import (
    DualModeClient,
    ElasticRoleSwitchController,
    find_most_idle_worker,
)
from rl_scaling_controller.role_switch.controller import RoleSwitchDecision
from rl_scaling_controller.role_switch.dual_mode_client import SwitchResult


# --------------------------------------------------------------------- helpers
class FakeClock:
    def __init__(self, t: float = 0.0) -> None:
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance(self, dt: float) -> None:
        self.t += dt


class FakeDualModeClient:
    def __init__(self, *, status: str = "ok", switch_time_ms: float = 1234.0) -> None:
        self.status = status
        self.switch_time_ms = switch_time_ms
        self.calls = []

    def switch_role(self, worker_url: str, target_role: str) -> SwitchResult:
        self.calls.append((worker_url, target_role))
        return SwitchResult(status=self.status, switch_time_ms=self.switch_time_ms, new_role=target_role)


def _cfg(**overrides) -> ControllerConfig:
    base = load_config()  # all defaults
    return replace(base, role_switch_enabled=True, **overrides)


def _metrics_with(workers, cluster) -> InMemoryMetricsCollector:
    m = InMemoryMetricsCollector()
    m.cluster = cluster

    async def _get_workers():
        return workers

    async def _get_cluster():
        return cluster

    m.get_decode_worker_states = _get_workers
    m.get_cluster_metrics = _get_cluster
    return m


# --------------------------------------------------------------------- tests
class TestStrategy:
    def test_picks_lowest_in_flight(self):
        ws = [
            WorkerState("w1", "http://a", "decode", in_flight_requests=10, active_kv_blocks=0,
                        available_capacity=0, estimated_remaining_time=0),
            WorkerState("w2", "http://b", "decode", in_flight_requests=2, active_kv_blocks=0,
                        available_capacity=0, estimated_remaining_time=0),
            WorkerState("w3", "http://c", "prefill", in_flight_requests=0, active_kv_blocks=0,
                        available_capacity=0, estimated_remaining_time=0),
        ]
        assert find_most_idle_worker(ws, "decode").worker_id == "w2"
        assert find_most_idle_worker(ws, "prefill").worker_id == "w3"
        assert find_most_idle_worker(ws, "missing") is None
        assert find_most_idle_worker([], "decode") is None


class TestDecodeToPrefill:
    async def test_triggers_when_prefill_backlogged_and_decode_idle(self):
        workers = [
            WorkerState("w1", "http://a", "decode", 0, 0, 0, 0),
            WorkerState("w2", "http://b", "decode", 5, 0, 0, 0),
        ]
        cluster = ClusterMetrics(
            prefill_queue_depth=20, decode_queue_depth=0,
            prefill_utilization=1.0, decode_utilization=0.05,
            prefill_workers=[None, None], decode_workers=workers,
        )
        metrics = _metrics_with(workers, cluster)
        client = FakeDualModeClient()
        ctrl = ElasticRoleSwitchController(
            config=_cfg(min_decode_replicas=1, prefill_queue_threshold=10),
            metrics=metrics, client=client, clock=FakeClock(100.0),
        )
        d = await ctrl.evaluate_and_execute()
        assert d is not None
        assert d.from_role == "decode" and d.to_role == "prefill"
        assert d.executed is True
        assert client.calls == [("http://a", "prefill")]

    async def test_skipped_when_at_min_decode_replicas(self):
        workers = [WorkerState("w1", "http://a", "decode", 0, 0, 0, 0)]
        cluster = ClusterMetrics(20, 0, 1.0, 0.0, [None], workers)
        metrics = _metrics_with(workers, cluster)
        ctrl = ElasticRoleSwitchController(
            config=_cfg(min_decode_replicas=1),
            metrics=metrics, client=FakeDualModeClient(), clock=FakeClock(100.0),
        )
        assert await ctrl.evaluate_and_execute() is None


class TestPrefillToDecode:
    async def test_triggers_when_decode_backlogged_and_prefill_idle(self):
        workers = [
            WorkerState("w1", "http://a", "prefill", 0, 0, 0, 0),
            WorkerState("w2", "http://b", "prefill", 4, 0, 0, 0),
        ]
        cluster = ClusterMetrics(
            prefill_queue_depth=0, decode_queue_depth=15,
            prefill_utilization=0.05, decode_utilization=1.0,
            prefill_workers=workers, decode_workers=[None, None],
        )
        metrics = _metrics_with(workers, cluster)
        client = FakeDualModeClient()
        ctrl = ElasticRoleSwitchController(
            config=_cfg(min_prefill_replicas=1, decode_queue_threshold=10),
            metrics=metrics, client=client, clock=FakeClock(100.0),
        )
        d = await ctrl.evaluate_and_execute()
        assert d is not None
        assert d.from_role == "prefill" and d.to_role == "decode"
        assert client.calls == [("http://a", "decode")]


class TestDebounce:
    async def test_min_switch_interval_blocks_rapid_switches(self):
        workers = [
            WorkerState("w1", "http://a", "decode", 0, 0, 0, 0),
            WorkerState("w2", "http://b", "decode", 5, 0, 0, 0),
        ]
        cluster = ClusterMetrics(20, 0, 1.0, 0.0, [None, None], workers)
        metrics = _metrics_with(workers, cluster)
        clock = FakeClock(1000.0)
        ctrl = ElasticRoleSwitchController(
            config=_cfg(min_switch_interval_seconds=30.0),
            metrics=metrics, client=FakeDualModeClient(), clock=clock,
        )
        first = await ctrl.evaluate_and_execute()
        assert first is not None and first.executed
        clock.advance(5)
        assert await ctrl.evaluate_and_execute() is None
        clock.advance(30)
        second = await ctrl.evaluate_and_execute()
        assert second is not None and second.executed


class TestDisabled:
    async def test_disabled_controller_does_nothing(self):
        cluster = ClusterMetrics(100, 100, 0.0, 0.0, [None]*5, [None]*5)
        metrics = _metrics_with([], cluster)
        ctrl = ElasticRoleSwitchController(
            config=replace(load_config(), role_switch_enabled=False),
            metrics=metrics, client=FakeDualModeClient(), clock=FakeClock(),
        )
        assert await ctrl.evaluate_and_execute() is None


class TestNoTriggerConditions:
    async def test_no_trigger_when_neither_imbalanced(self):
        workers = [WorkerState("w1", "http://a", "decode", 0, 0, 0, 0)]
        cluster = ClusterMetrics(0, 0, 0.5, 0.5, [None, None], [None, None])
        metrics = _metrics_with(workers, cluster)
        ctrl = ElasticRoleSwitchController(
            config=_cfg(), metrics=metrics, client=FakeDualModeClient(), clock=FakeClock(100.0),
        )
        assert await ctrl.evaluate_and_execute() is None


class TestClientFailure:
    async def test_failed_switch_does_not_update_last_switch_time(self):
        workers = [
            WorkerState("w1", "http://a", "decode", 0, 0, 0, 0),
            WorkerState("w2", "http://b", "decode", 5, 0, 0, 0),
        ]
        cluster = ClusterMetrics(20, 0, 1.0, 0.0, [None, None], workers)
        metrics = _metrics_with(workers, cluster)
        clock = FakeClock(1000.0)
        client = FakeDualModeClient(status="error")
        ctrl = ElasticRoleSwitchController(
            config=_cfg(), metrics=metrics, client=client, clock=clock,
        )
        d = await ctrl.evaluate_and_execute()
        assert d is not None and d.executed is False
        # debounce window should NOT have started
        clock.advance(0.01)
        d2 = await ctrl.evaluate_and_execute()
        assert d2 is not None  # can try again


class TestDualModeClient:
    def test_validates_target_role(self):
        c = DualModeClient()
        with pytest.raises(ValueError):
            c.switch_role("http://x", "garbage")
        c.close()

    def test_validates_timeout(self):
        with pytest.raises(ValueError):
            DualModeClient(timeout=0)
