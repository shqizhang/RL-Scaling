from dataclasses import replace
from unittest.mock import MagicMock

import pytest

from rl_scaling_controller.config import ControllerConfig, load_config
from rl_scaling_controller.consolidation import (
    ConsolidationController,
    ConsolidationDecisionEngine,
    MigrationPair,
)
from rl_scaling_controller.dgdsa_client import InMemoryDGDSAClient
from rl_scaling_controller.metrics_collector import (
    InMemoryMetricsCollector,
    WorkerState,
)


def _cfg(**overrides) -> ControllerConfig:
    base = replace(load_config(), consolidation_enabled=True, min_decode_replicas=1, consolidation_stable_samples=1)
    return replace(base, **overrides)


def _w(wid: str, in_flight: int = 0, capacity: int = 64, remaining: float = 30.0) -> WorkerState:
    return WorkerState(wid, f"http://{wid}", "decode", in_flight, 0, capacity, remaining)


# -------------------------------------------------------------- decision engine
class TestDecisionEngine:
    def test_disabled_returns_empty(self):
        e = ConsolidationDecisionEngine(replace(load_config(), consolidation_enabled=False))
        plans = e.evaluate([_w("a", 1)], batch_completion_pct=0.9)
        assert plans == []

    def test_below_completion_threshold(self):
        e = ConsolidationDecisionEngine(_cfg(min_batch_completion_pct=0.6))
        plans = e.evaluate([_w("a", 1), _w("b", 0)], batch_completion_pct=0.5)
        assert plans == []

    def test_at_min_replicas_no_op(self):
        e = ConsolidationDecisionEngine(_cfg(min_decode_replicas=2))
        plans = e.evaluate([_w("a", 1), _w("b", 0)], batch_completion_pct=0.9)
        assert plans == []

    def test_pairs_idle_source_with_busiest_target(self):
        # Pairing strategy: sort by in_flight asc, drain from the front,
        # consolidate onto the back (busiest = least likely to be drained later).
        e = ConsolidationDecisionEngine(_cfg(consolidation_threshold=3, per_request_migration_overhead=0.5))
        ws = [
            _w("a", in_flight=2, capacity=10, remaining=60),  # source candidate
            _w("b", in_flight=8, capacity=20, remaining=60),  # busiest -> target
            _w("c", in_flight=4, capacity=50, remaining=60),
        ]
        plans = e.evaluate(ws, batch_completion_pct=0.9)
        assert len(plans) == 1
        assert plans[0].source.worker_id == "a"
        assert plans[0].target.worker_id == "b"
        assert plans[0].request_count == 2

    def test_skips_when_target_lacks_capacity(self):
        e = ConsolidationDecisionEngine(_cfg(consolidation_threshold=10))
        ws = [
            _w("a", in_flight=5, capacity=1, remaining=60),
            _w("b", in_flight=5, capacity=2, remaining=60),  # only target; can't fit 5
        ]
        plans = e.evaluate(ws, batch_completion_pct=0.9)
        assert plans == []

    def test_cost_benefit_rejects_when_remaining_too_short(self):
        # 4 reqs * 0.5s = 2.0s migration; needs remaining > 4s
        e = ConsolidationDecisionEngine(_cfg(consolidation_threshold=10, per_request_migration_overhead=0.5))
        ws = [
            _w("a", in_flight=4, capacity=10, remaining=3.0),  # 2.0s !< 1.5s
            _w("b", in_flight=8, capacity=50, remaining=3.0),
        ]
        assert e.evaluate(ws, batch_completion_pct=0.9) == []

    def test_skips_when_source_above_consolidation_threshold(self):
        e = ConsolidationDecisionEngine(_cfg(consolidation_threshold=3))
        ws = [
            _w("a", in_flight=10, capacity=10, remaining=60),
            _w("b", in_flight=20, capacity=50, remaining=60),
        ]
        assert e.evaluate(ws, batch_completion_pct=0.9) == []

    def test_drains_multiple_sources_until_min(self):
        e = ConsolidationDecisionEngine(_cfg(consolidation_threshold=3, min_decode_replicas=1))
        ws = [
            _w("a", in_flight=1, capacity=10, remaining=60),
            _w("b", in_flight=2, capacity=10, remaining=60),
            _w("c", in_flight=8, capacity=50, remaining=60),
            _w("d", in_flight=8, capacity=50, remaining=60),
        ]
        plans = e.evaluate(ws, batch_completion_pct=0.9)
        # We have 4 workers, min=1 → can drain up to 3.
        # Sources picked: a (1), b (2). c & d are too busy to be sources but
        # serve as targets. So 2 plans expected.
        assert len(plans) == 2
        assert {p.source.worker_id for p in plans} == {"a", "b"}

    def test_zero_in_flight_source_skipped(self):
        e = ConsolidationDecisionEngine(_cfg(consolidation_threshold=3))
        ws = [
            _w("a", in_flight=0, capacity=10, remaining=60),
            _w("b", in_flight=2, capacity=10, remaining=60),
            _w("c", in_flight=8, capacity=50, remaining=60),
        ]
        plans = e.evaluate(ws, batch_completion_pct=0.9)
        assert len(plans) == 1
        assert plans[0].source.worker_id == "b"

    def test_migration_pair_rejects_zero_count(self):
        with pytest.raises(ValueError):
            MigrationPair(source=_w("a", 1), target=_w("b"), request_count=0)


# -------------------------------------------------------------- controller
class TestConsolidationController:
    @pytest.mark.asyncio
    async def test_disabled_does_nothing(self):
        ctrl = ConsolidationController(
            config=replace(load_config(), consolidation_enabled=False),
            metrics=InMemoryMetricsCollector(),
            dgdsa=InMemoryDGDSAClient(),
            client=MagicMock(),
            batch_completion_fn=lambda: 0.9,
        )
        assert await ctrl.control_loop_tick() is None

    @pytest.mark.asyncio
    async def test_executes_plans_and_scales_down(self):
        workers = [
            _w("a", in_flight=2, capacity=10, remaining=60),
            _w("b", in_flight=8, capacity=50, remaining=60),
        ]

        class M(InMemoryMetricsCollector):
            async def get_decode_worker_states(self):
                return workers

        m = M()
        d = InMemoryDGDSAClient()
        d.patch("decode", 4)
        client = MagicMock()
        client.migrate_one.return_value = {"status": "ok"}
        ctrl = ConsolidationController(
            config=_cfg(consolidation_threshold=3, per_request_migration_overhead=0.5),
            metrics=m, dgdsa=d, client=client,
            batch_completion_fn=lambda: 0.9,
        )
        decision = await ctrl.control_loop_tick()
        assert decision is not None
        assert decision.executed_pairs == 1
        assert client.migrate_one.call_count == 2  # 2 requests on source 'a'
        assert decision.scaled_down_to == 3
        assert d.get_replicas("decode") == 3

    @pytest.mark.asyncio
    async def test_waits_for_stable_samples_before_migrating(self):
        workers = [
            _w("a", in_flight=2, capacity=10, remaining=60),
            _w("b", in_flight=8, capacity=50, remaining=60),
        ]

        class M(InMemoryMetricsCollector):
            async def get_decode_worker_states(self):
                return workers

        client = MagicMock()
        ctrl = ConsolidationController(
            config=_cfg(
                consolidation_threshold=3,
                consolidation_stable_samples=2,
                consolidation_min_interval_seconds=0,
            ),
            metrics=M(),
            dgdsa=InMemoryDGDSAClient(),
            client=client,
            batch_completion_fn=lambda: 0.9,
        )
        assert await ctrl.control_loop_tick() is None
        client.migrate_one.assert_not_called()
        client.migrate_one.return_value = {"status": "ok"}

        decision = await ctrl.control_loop_tick()
        assert decision is not None
        assert decision.executed_pairs == 1
        assert client.migrate_one.call_count == 2

    @pytest.mark.asyncio
    async def test_stops_pair_after_declined_migration(self):
        workers = [
            _w("a", in_flight=4, capacity=10, remaining=60),
            _w("b", in_flight=8, capacity=50, remaining=60),
        ]

        class M(InMemoryMetricsCollector):
            async def get_decode_worker_states(self):
                return workers

        client = MagicMock()
        client.migrate_one.return_value = {
            "status": "declined",
            "rolled_back": True,
            "migrate_in": {"message": "request too young"},
        }
        ctrl = ConsolidationController(
            config=_cfg(consolidation_threshold=4),
            metrics=M(),
            dgdsa=InMemoryDGDSAClient(),
            client=client,
            batch_completion_fn=lambda: 0.9,
        )
        decision = await ctrl.control_loop_tick()
        assert decision is not None
        assert decision.migration_attempts == 1
        assert decision.migrated_requests == 0
        assert decision.declined_requests == 1
        assert decision.executed_pairs == 0
        assert client.migrate_one.call_count == 1

    @pytest.mark.asyncio
    async def test_scale_down_clamped_to_min(self):
        workers = [
            _w("a", in_flight=1, capacity=10, remaining=60),
            _w("b", in_flight=8, capacity=50, remaining=60),
        ]

        class M(InMemoryMetricsCollector):
            async def get_decode_worker_states(self):
                return workers

        d = InMemoryDGDSAClient()
        d.patch("decode", 1)  # already at min
        client = MagicMock()
        client.migrate_one.return_value = {"status": "ok"}
        ctrl = ConsolidationController(
            config=_cfg(consolidation_threshold=3, min_decode_replicas=1),
            metrics=M(), dgdsa=d, client=client,
            batch_completion_fn=lambda: 0.9,
        )
        decision = await ctrl.control_loop_tick()
        # With only 2 workers and min=1, max_to_drain=1; source 'a' eligible.
        assert decision is not None
        # decode replicas was 1; scale_down would yield max(1, 1-1)=1 → unchanged.
        assert d.get_replicas("decode") == 1

    @pytest.mark.asyncio
    async def test_returns_none_when_no_plans(self):
        class M(InMemoryMetricsCollector):
            async def get_decode_worker_states(self):
                return [_w("a", in_flight=8, capacity=1, remaining=60)]

        ctrl = ConsolidationController(
            config=_cfg(consolidation_threshold=3),
            metrics=M(),
            dgdsa=InMemoryDGDSAClient(),
            client=MagicMock(),
            batch_completion_fn=lambda: 0.9,
        )
        assert await ctrl.control_loop_tick() is None
