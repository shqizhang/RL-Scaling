"""Prometheus-backed metrics collector with an in-memory implementation for tests."""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Protocol

logger = logging.getLogger(__name__)


@dataclass
class WorkerState:
    worker_id: str
    addr: str
    role: str
    in_flight_requests: int = 0
    active_kv_blocks: int = 0
    available_capacity: int = 0
    estimated_remaining_time: float = 0.0


@dataclass
class ClusterMetrics:
    prefill_queue_depth: int = 0
    decode_queue_depth: int = 0
    prefill_utilization: float = 0.0
    decode_utilization: float = 0.0
    prefill_workers: List[WorkerState] = field(default_factory=list)
    decode_workers: List[WorkerState] = field(default_factory=list)

    @property
    def prefill_worker_count(self) -> int:
        return len(self.prefill_workers)

    @property
    def decode_worker_count(self) -> int:
        return len(self.decode_workers)


class MetricsCollectorProtocol(Protocol):
    async def get_ready_worker_count(self, service: str) -> int: ...

    async def get_cluster_metrics(self) -> ClusterMetrics: ...

    async def get_decode_worker_states(self) -> List[WorkerState]: ...

    async def get_worker_request_count(self, worker_id: str) -> int: ...


class InMemoryMetricsCollector:
    """Test/double implementation. Ready counts and cluster snapshot are mutable."""

    def __init__(self) -> None:
        self.ready_counts: Dict[str, int] = {"prefill": 0, "decode": 0}
        self.cluster = ClusterMetrics()

    async def get_ready_worker_count(self, service: str) -> int:
        return self.ready_counts.get(service, 0)

    async def get_cluster_metrics(self) -> ClusterMetrics:
        return self.cluster

    async def get_decode_worker_states(self) -> List[WorkerState]:
        return list(self.cluster.decode_workers)

    async def get_worker_request_count(self, worker_id: str) -> int:
        for w in self.cluster.prefill_workers + self.cluster.decode_workers:
            if w.worker_id == worker_id:
                return w.in_flight_requests
        return 0


class PrometheusMetricsCollector:
    """Queries a Prometheus instance for Dynamo metrics.

    Wraps a small set of PromQL queries; designed so we never crash the
    controller if Prometheus is temporarily unreachable (returns 0 / empty).
    """

    def __init__(self, prometheus_url: str, http_client=None, timeout: float = 5.0) -> None:
        self.url = prometheus_url.rstrip("/")
        if http_client is None:
            import httpx

            http_client = httpx.AsyncClient(timeout=timeout)
        self._http = http_client

    async def _query(self, expr: str) -> Optional[float]:
        try:
            resp = await self._http.get(f"{self.url}/api/v1/query", params={"query": expr})
            resp.raise_for_status()
            data = resp.json()
            result = data.get("data", {}).get("result", [])
            if not result:
                return 0.0
            return float(result[0]["value"][1])
        except Exception as exc:  # noqa: BLE001
            logger.warning("prometheus query %r failed: %s", expr, exc)
            return None

    async def get_ready_worker_count(self, service: str) -> int:
        # Use kube_pod_status_ready{condition="true"} from kube-state-metrics
        expr = (
            f'count(kube_pod_status_ready{{condition="true",'
            f'pod=~".*{service}.*"}})'
        )
        v = await self._query(expr)
        return int(v) if v is not None else 0

    async def get_cluster_metrics(self) -> ClusterMetrics:
        cm = ClusterMetrics()
        cm.prefill_queue_depth = int(await self._query(
            'sum(dynamo_frontend_queued_requests{role="prefill"})'
        ) or 0)
        cm.decode_queue_depth = int(await self._query(
            'sum(dynamo_frontend_queued_requests{role="decode"})'
        ) or 0)
        cm.prefill_utilization = float(await self._query(
            'avg(dynamo_worker_gpu_utilization{role="prefill"})'
        ) or 0.0)
        cm.decode_utilization = float(await self._query(
            'avg(dynamo_worker_gpu_utilization{role="decode"})'
        ) or 0.0)
        return cm

    async def get_decode_worker_states(self) -> List[WorkerState]:
        # Real implementation would iterate workers via service discovery /
        # Prometheus label values. For the controller skeleton we leave it
        # empty; integration tests rely on InMemoryMetricsCollector.
        return []

    async def get_worker_request_count(self, worker_id: str) -> int:
        v = await self._query(
            f'sum(dynamo_worker_in_flight_requests{{worker_id="{worker_id}"}})'
        )
        return int(v) if v is not None else 0
