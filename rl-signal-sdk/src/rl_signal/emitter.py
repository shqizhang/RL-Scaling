"""High-level emitter API used by RL Training Frameworks."""
from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from .events import BatchMeta
from .transport import HttpxTransport, Transport

logger = logging.getLogger(__name__)

SAMPLING_PROGRESS_PATH = "/api/v1/signals/sampling_progress"
SAMPLING_DONE_PATH = "/api/v1/signals/sampling_done"
BATCH_COMPLETE_PATH = "/api/v1/signals/batch_complete"
TRAINING_DONE_PATH = "/api/v1/signals/training_done"


class RLSignalEmitter:
    """Emit RL lifecycle signals to the RL Scaling Controller.

    The emitter is intentionally synchronous: signals are emitted from training
    code that is already at synchronization points, and we want the call to
    complete or fail loudly before the next phase starts.
    """

    def __init__(
        self,
        controller_url: Optional[str] = None,
        timeout: float = 5.0,
        transport: Optional[Transport] = None,
        suppress_errors: bool = True,
    ) -> None:
        if transport is None:
            if not controller_url:
                raise ValueError("controller_url required when no transport given")
            transport = HttpxTransport(controller_url, timeout=timeout)
        self._transport = transport
        self._suppress_errors = suppress_errors

    # ─── Lifecycle events ───
    def sampling_progress(self, progress: float, batch_meta: BatchMeta) -> Dict[str, Any]:
        if not 0.0 <= progress <= 1.0:
            raise ValueError("progress must be in [0, 1]")
        return self._post(
            SAMPLING_PROGRESS_PATH,
            {"progress": float(progress), "batch_meta": batch_meta.to_dict()},
        )

    def sampling_done(self, batch_meta: BatchMeta) -> Dict[str, Any]:
        return self._post(SAMPLING_DONE_PATH, {"batch_meta": batch_meta.to_dict()})

    def batch_complete(self) -> Dict[str, Any]:
        return self._post(BATCH_COMPLETE_PATH, {})

    def training_done(self) -> Dict[str, Any]:
        return self._post(TRAINING_DONE_PATH, {})

    # ─── Resource management ───
    def close(self) -> None:
        self._transport.close()

    def __enter__(self) -> "RLSignalEmitter":
        return self

    def __exit__(self, *exc_info) -> None:
        self.close()

    # ─── Internal ───
    def _post(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            return self._transport.post(path, payload)
        except Exception as exc:  # noqa: BLE001
            logger.warning("rl-signal post %s failed: %s", path, exc)
            if not self._suppress_errors:
                raise
            return {"status": "error", "error": str(exc)}
