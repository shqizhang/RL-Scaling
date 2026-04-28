"""TDD tests for the RL Signal SDK."""
from __future__ import annotations

from typing import Any, Dict, List

import pytest

from rl_signal import BatchMeta, RLSignalEmitter
from rl_signal.emitter import (
    BATCH_COMPLETE_PATH,
    SAMPLING_DONE_PATH,
    SAMPLING_PROGRESS_PATH,
    TRAINING_DONE_PATH,
)


class _FakeTransport:
    def __init__(self) -> None:
        self.calls: List[Dict[str, Any]] = []
        self.closed = False

    def post(self, path: str, json: Dict[str, Any]) -> Dict[str, Any]:
        self.calls.append({"path": path, "json": json})
        return {"status": "ok"}

    def close(self) -> None:
        self.closed = True


# ─── BatchMeta validation ───

class TestBatchMeta:
    def test_total_tokens_defaults_to_batch_x_isl(self):
        meta = BatchMeta(batch_size=8, avg_isl=128)
        assert meta.total_tokens == 8 * 128

    def test_explicit_total_tokens_preserved(self):
        meta = BatchMeta(batch_size=8, avg_isl=128, total_tokens=999)
        assert meta.total_tokens == 999

    def test_to_dict_drops_none_values(self):
        meta = BatchMeta(batch_size=2, avg_isl=10)
        d = meta.to_dict()
        assert "avg_osl" not in d
        assert d["batch_size"] == 2 and d["total_tokens"] == 20

    @pytest.mark.parametrize("kwargs", [
        {"batch_size": 0, "avg_isl": 1},
        {"batch_size": 1, "avg_isl": 0},
    ])
    def test_invalid_metas_rejected(self, kwargs):
        with pytest.raises(ValueError):
            BatchMeta(**kwargs)


# ─── Emitter behavior ───

@pytest.fixture
def emitter():
    transport = _FakeTransport()
    em = RLSignalEmitter(transport=transport)
    return em, transport


class TestEmitter:
    def test_requires_url_or_transport(self):
        with pytest.raises(ValueError):
            RLSignalEmitter()

    def test_sampling_progress_posts_payload(self, emitter):
        em, t = emitter
        em.sampling_progress(0.8, BatchMeta(batch_size=4, avg_isl=10))
        assert len(t.calls) == 1
        call = t.calls[0]
        assert call["path"] == SAMPLING_PROGRESS_PATH
        assert call["json"]["progress"] == 0.8
        assert call["json"]["batch_meta"]["batch_size"] == 4

    @pytest.mark.parametrize("p", [-0.1, 1.5])
    def test_sampling_progress_rejects_out_of_range(self, emitter, p):
        em, _ = emitter
        with pytest.raises(ValueError):
            em.sampling_progress(p, BatchMeta(batch_size=1, avg_isl=1))

    def test_sampling_done_posts_payload(self, emitter):
        em, t = emitter
        em.sampling_done(BatchMeta(batch_size=4, avg_isl=10))
        assert t.calls[-1]["path"] == SAMPLING_DONE_PATH
        assert "batch_meta" in t.calls[-1]["json"]

    def test_batch_complete_posts_empty_body(self, emitter):
        em, t = emitter
        em.batch_complete()
        assert t.calls[-1]["path"] == BATCH_COMPLETE_PATH
        assert t.calls[-1]["json"] == {}

    def test_training_done_posts_empty_body(self, emitter):
        em, t = emitter
        em.training_done()
        assert t.calls[-1]["path"] == TRAINING_DONE_PATH

    def test_context_manager_closes_transport(self):
        t = _FakeTransport()
        with RLSignalEmitter(transport=t) as em:
            em.batch_complete()
        assert t.closed

    def test_errors_suppressed_by_default(self):
        class BoomTransport:
            def post(self, *a, **k):
                raise RuntimeError("boom")

            def close(self):
                pass

        em = RLSignalEmitter(transport=BoomTransport())
        result = em.batch_complete()
        assert result["status"] == "error"

    def test_errors_raised_when_suppress_disabled(self):
        class BoomTransport:
            def post(self, *a, **k):
                raise RuntimeError("boom")

            def close(self):
                pass

        em = RLSignalEmitter(transport=BoomTransport(), suppress_errors=False)
        with pytest.raises(RuntimeError):
            em.batch_complete()
