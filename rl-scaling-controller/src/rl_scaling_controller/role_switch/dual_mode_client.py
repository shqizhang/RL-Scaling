"""HTTP client that asks a Dynamo worker to flip its role.

The worker exposes ``POST /switch_role`` (registered when the worker is
launched with ``--dual-mode``) and returns a JSON document of the form::

    {"status": "ok", "switch_time_ms": 4321.0, "new_role": "decode"}

This module purposefully has *no* knowledge of Kubernetes — the caller is
expected to resolve the worker's pod IP / service URL ahead of time.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import httpx


@dataclass
class SwitchResult:
    status: str
    switch_time_ms: float
    new_role: str


class DualModeClient:
    """Thin wrapper around ``POST {worker_url}/switch_role``."""

    def __init__(
        self,
        timeout: float = 30.0,
        http_client: Optional[httpx.Client] = None,
    ) -> None:
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self._client = http_client or httpx.Client(timeout=timeout)
        self._owns_client = http_client is None

    def switch_role(self, worker_url: str, target_role: str) -> SwitchResult:
        if target_role not in ("prefill", "decode"):
            raise ValueError(f"target_role must be 'prefill' or 'decode', got {target_role!r}")
        url = worker_url.rstrip("/") + "/switch_role"
        resp = self._client.post(url, json={"target_role": target_role})
        resp.raise_for_status()
        body = resp.json()
        return SwitchResult(
            status=body.get("status", "unknown"),
            switch_time_ms=float(body.get("switch_time_ms", 0.0)),
            new_role=body.get("new_role", target_role),
        )

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()
