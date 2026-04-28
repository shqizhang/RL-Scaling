import pytest

from rl_scaling_controller.capacity_planner import CapacityPlanner, ScaleTarget


@pytest.fixture
def planner():
    return CapacityPlanner(
        single_prefill_tps=50_000,
        max_concurrent_per_decode=64,
        target_prefill_seconds=5.0,
        max_gpus=8,
    )


class TestCapacityPlanner:
    # Design example: batch=128, isl=500 -> total=64000, P=ceil(64000/250000)=1
    # but min_prefill=1, decode=ceil(128/64)=2.
    def test_design_doc_example(self, planner):
        target = planner.compute({"batch_size": 128, "avg_isl": 500})
        assert target == ScaleTarget(prefill_replicas=1, decode_replicas=2)

    def test_large_batch_increases_prefill(self, planner):
        # batch=512, isl=2000 -> total=1024000 -> P=ceil(1024000/250000)=5, D=ceil(512/64)=8 capped
        target = planner.compute({"batch_size": 512, "avg_isl": 2000})
        assert target.prefill_replicas == 5
        assert target.decode_replicas >= 1
        assert target.total() <= 8

    def test_minimum_replicas_enforced(self, planner):
        target = planner.compute({"batch_size": 1, "avg_isl": 1})
        assert target.prefill_replicas >= 1
        assert target.decode_replicas >= 1

    def test_explicit_total_tokens_used(self, planner):
        # Override total_tokens to force higher prefill demand.
        target = planner.compute({"batch_size": 8, "avg_isl": 100, "total_tokens": 1_000_000})
        assert target.prefill_replicas == 4  # ceil(1e6 / 2.5e5) = 4

    def test_capped_at_max_gpus(self, planner):
        target = planner.compute({"batch_size": 100_000, "avg_isl": 4096})
        assert target.total() <= 8

    @pytest.mark.parametrize("bad", [
        {"batch_size": 0, "avg_isl": 10},
        {"batch_size": 10, "avg_isl": 0},
        {"avg_isl": 10},
        {"batch_size": "x", "avg_isl": 1},
    ])
    def test_bad_meta_rejected(self, planner, bad):
        with pytest.raises(ValueError):
            planner.compute(bad)

    def test_invalid_constructor_rejected(self):
        with pytest.raises(ValueError):
            CapacityPlanner(0, 1, 1.0, 8)
        with pytest.raises(ValueError):
            CapacityPlanner(1, 1, 0.0, 8)
        with pytest.raises(ValueError):
            CapacityPlanner(1, 1, 1.0, 1, min_prefill_replicas=1, min_decode_replicas=1)
