"""HTTP client that drives request migration on Dynamo decode workers.

Each worker exposes::

    POST {worker_url}/migrate_out      body={"request_id": str}
        -> {"status": "ok",
            "prompt_tokens": [...],
            "generated_tokens": [...],
            "sampling_params": {...},
            "stop_conditions": {...}}

    POST {worker_url}/migrate_in       body=<above payload + request_id>
        -> {"status": "ok"}

The orchestration is *recompute-prefill*: the controller fetches the
request's token state from the source, then resubmits it (prompt + already
generated tokens) on the target. The target redoes prefill but generation
continues seamlessly. See the design doc S3 feasibility note.
"""
from __future__ import annotations

from typing import Optional

import httpx


class MigrationClient:
    def __init__(self, timeout: float = 30.0, http_client: Optional[httpx.Client] = None) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self._client = http_client or httpx.Client(timeout=timeout)
        self._owns = http_client is None

    def migrate_out(self, source_url: str, request_id: str) -> dict:
        url = source_url.rstrip("/") + "/migrate_out"
        resp = self._client.post(url, json={"request_id": request_id})
        resp.raise_for_status()
        return resp.json()

    def migrate_in(self, target_url: str, payload: dict) -> dict:
        url = target_url.rstrip("/") + "/migrate_in"
        resp = self._client.post(url, json=payload)
        resp.raise_for_status()
        return resp.json()

    def migrate_one(self, source_url: str, target_url: str, request_id: str) -> dict:
        """End-to-end migration of a single request."""
        state = self.migrate_out(source_url, request_id)
        if state.get("status") != "ok":
            return {"status": "error", "stage": "out", "detail": state}
        # The target needs the request_id too.
        payload = dict(state)
        payload.setdefault("request_id", request_id)
        return self.migrate_in(target_url, payload)

    def close(self) -> None:
        if self._owns:
            self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
