import pytest
from fastapi.testclient import TestClient

from rl_scaling_controller.capacity_planner import CapacityPlanner
from rl_scaling_controller.dgdsa_client import InMemoryDGDSAClient
from rl_scaling_controller.metrics_collector import InMemoryMetricsCollector
from rl_scaling_controller.signal_receiver import create_app
from rl_scaling_controller.state_machine import (
    ScalingStateMachine,
    State,
    _StateMachineConfig,
)


@pytest.fixture
def client():
    sm = ScalingStateMachine(
        config=_StateMachineConfig(pre_warm_threshold=0.8, cooldown_seconds=1),
        dgdsa=InMemoryDGDSAClient(),
        planner=CapacityPlanner(50_000, 64, 5.0, 8),
        metrics=InMemoryMetricsCollector(),
    )
    app = create_app(lambda: sm)
    return TestClient(app), sm


class TestSignalReceiverEndpoints:
    def test_healthz(self, client):
        c, _ = client
        r = c.get("/healthz")
        assert r.status_code == 200
        assert r.json()["state"] == "idle"

    def test_status_initial(self, client):
        c, _ = client
        r = c.get("/api/v1/status")
        assert r.status_code == 200
        body = r.json()
        assert body["state"] == "idle"
        assert body["current_target"] is None
        assert body["history"] == []

    def test_sampling_progress_triggers_warm_up(self, client):
        c, sm = client
        r = c.post("/api/v1/signals/sampling_progress", json={
            "progress": 0.85,
            "batch_meta": {"batch_size": 128, "avg_isl": 500},
        })
        assert r.status_code == 200
        assert r.json()["state"] == "warm_up"
        assert sm.state == State.WARM_UP

    def test_sampling_progress_validates_progress(self, client):
        c, _ = client
        r = c.post("/api/v1/signals/sampling_progress", json={
            "progress": 1.5,
            "batch_meta": {"batch_size": 1, "avg_isl": 1},
        })
        assert r.status_code == 422  # pydantic validation

    def test_sampling_progress_validates_batch_meta(self, client):
        c, _ = client
        r = c.post("/api/v1/signals/sampling_progress", json={
            "progress": 0.9,
            "batch_meta": {"batch_size": 0, "avg_isl": 1},
        })
        assert r.status_code == 422

    def test_sampling_done_full_lifecycle(self, client):
        c, sm = client
        r = c.post("/api/v1/signals/sampling_done", json={
            "batch_meta": {"batch_size": 4, "avg_isl": 10},
        })
        assert r.json()["state"] == "warm_up"

    def test_batch_complete(self, client):
        c, sm = client
        # Force ACTIVE
        c.post("/api/v1/signals/sampling_done", json={
            "batch_meta": {"batch_size": 4, "avg_isl": 10}
        })
        sm.metrics.ready_counts = {"prefill": 8, "decode": 8}
        import asyncio
        asyncio.run(sm.control_loop_tick())
        r = c.post("/api/v1/signals/batch_complete")
        assert r.json()["state"] == "cool_down"

    def test_status_includes_current_target_after_warmup(self, client):
        c, _ = client
        c.post("/api/v1/signals/sampling_done", json={
            "batch_meta": {"batch_size": 128, "avg_isl": 500}
        })
        r = c.get("/api/v1/status")
        body = r.json()
        assert body["current_target"]["prefill_replicas"] >= 1
        assert body["current_target"]["decode_replicas"] >= 1
        assert any(h["to"] == "warm_up" for h in body["history"])
