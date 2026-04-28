"""FastAPI-based signal receiver."""
from __future__ import annotations

import logging
from typing import Any, Callable, Dict

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .state_machine import ScalingStateMachine, State

logger = logging.getLogger(__name__)


class _BatchMetaModel(BaseModel):
    batch_size: int = Field(gt=0)
    avg_isl: int = Field(gt=0)
    avg_osl: int | None = None
    total_tokens: int | None = None


class _SamplingProgressBody(BaseModel):
    progress: float = Field(ge=0.0, le=1.0)
    batch_meta: _BatchMetaModel


class _SamplingDoneBody(BaseModel):
    batch_meta: _BatchMetaModel


def create_app(state_machine_factory: Callable[[], ScalingStateMachine]) -> FastAPI:
    """Build a FastAPI app that delegates to the supplied state machine.

    A factory is used (rather than passing the instance directly) to make the
    receiver easy to wire into the main entry-point alongside other services.
    """
    app = FastAPI(title="RL Scaling Controller", version="0.1.0")

    @app.get("/healthz")
    async def healthz() -> Dict[str, Any]:
        sm = state_machine_factory()
        return {"status": "ok", "state": sm.state.value}

    @app.get("/api/v1/status")
    async def status() -> Dict[str, Any]:
        sm = state_machine_factory()
        target = sm.current_target
        return {
            "state": sm.state.value,
            "current_target": (
                {
                    "prefill_replicas": target.prefill_replicas,
                    "decode_replicas": target.decode_replicas,
                }
                if target
                else None
            ),
            "history": [
                {
                    "from": h.from_state.value,
                    "to": h.to_state.value,
                    "at": h.at,
                }
                for h in sm.history[-20:]
            ],
        }

    @app.post("/api/v1/signals/sampling_progress")
    async def sampling_progress(body: _SamplingProgressBody) -> Dict[str, Any]:
        sm = state_machine_factory()
        try:
            new_state = sm.on_sampling_progress(body.progress, body.batch_meta.model_dump())
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"status": "ok", "state": new_state.value}

    @app.post("/api/v1/signals/sampling_done")
    async def sampling_done(body: _SamplingDoneBody) -> Dict[str, Any]:
        sm = state_machine_factory()
        try:
            new_state = sm.on_sampling_done(body.batch_meta.model_dump())
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"status": "ok", "state": new_state.value}

    @app.post("/api/v1/signals/batch_complete")
    async def batch_complete() -> Dict[str, Any]:
        sm = state_machine_factory()
        new_state = sm.on_batch_complete()
        return {"status": "ok", "state": new_state.value}

    @app.post("/api/v1/signals/training_done")
    async def training_done() -> Dict[str, Any]:
        # Currently a no-op: cooldown-driven scale-down handles GPU release.
        sm = state_machine_factory()
        return {"status": "ok", "state": sm.state.value}

    return app
