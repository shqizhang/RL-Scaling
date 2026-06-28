"""HTTP client that drives request migration on Dynamo decode workers.

Each worker exposes::

    POST {source_url}/migrate
        body={"request_id": str, "target_url": str}

The source sidecar owns the full coordinated protocol:
``migrate_out -> remote migrate_in -> migration_complete/rollback``. Keeping
that sequence inside the source worker is important for the connector path,
because source KV blocks may be held until the destination accepts the request.
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

    def migrate(self, source_url: str, target_url: str, request_id: str) -> dict:
        url = source_url.rstrip("/") + "/migrate"
        resp = self._client.post(
            url,
            json={"request_id": request_id, "target_url": target_url.rstrip("/")},
        )
        resp.raise_for_status()
        return resp.json()

    def migrate_one(self, source_url: str, target_url: str, request_id: str) -> dict:
        """End-to-end migration of a single request."""
        return self.migrate(source_url, target_url, request_id)

    def close(self) -> None:
        if self._owns:
            self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
