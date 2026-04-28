"""HTTP transport abstraction (sync). Allows pluggable transports for testing."""
from __future__ import annotations

from typing import Any, Dict, Protocol


class Transport(Protocol):
    def post(self, path: str, json: Dict[str, Any]) -> Dict[str, Any]: ...

    def close(self) -> None: ...


class HttpxTransport:
    """Default transport built on httpx.Client."""

    def __init__(self, base_url: str, timeout: float = 5.0) -> None:
        import httpx

        self._client = httpx.Client(timeout=timeout)
        self._base = base_url.rstrip("/")

    def post(self, path: str, json: Dict[str, Any]) -> Dict[str, Any]:
        resp = self._client.post(f"{self._base}{path}", json=json)
        resp.raise_for_status()
        if not resp.content:
            return {}
        return resp.json()

    def close(self) -> None:
        self._client.close()
