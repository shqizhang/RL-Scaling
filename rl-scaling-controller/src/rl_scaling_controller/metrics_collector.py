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
    healthy: bool = True
    health_reason: str = "ok"
    switch_capable: bool = True


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

    def __init__(
        self,
        prometheus_url: str,
        http_client=None,
        timeout: float = 5.0,
        *,
        namespace: str = "dynamo-system",
        dgd_name: str = "vllm-v1-disagg-router",
        worker_sidecar_port: int = 9091,
        max_concurrent_per_decode: int = 64,
        k8s_core_api=None,
    ) -> None:
        self.url = prometheus_url.rstrip("/")
        self.namespace = namespace
        self.dgd_name = dgd_name
        self.worker_sidecar_port = worker_sidecar_port
        self.max_concurrent_per_decode = max_concurrent_per_decode
        if http_client is None:
            import httpx

            http_client = httpx.AsyncClient(timeout=timeout)
        self._http = http_client
        self._k8s_core = k8s_core_api

    @property
    def k8s_core(self):
        if self._k8s_core is None:
            from kubernetes import client, config  # type: ignore

            try:
                config.load_incluster_config()
            except Exception:
                config.load_kube_config()
            self._k8s_core = client.CoreV1Api()
        return self._k8s_core

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
        workers = await self.get_worker_states()
        cm.prefill_workers = [w for w in workers if w.role == "prefill"]
        cm.decode_workers = [w for w in workers if w.role == "decode"]
        if cm.prefill_queue_depth == 0:
            cm.prefill_queue_depth = sum(w.in_flight_requests for w in cm.prefill_workers)
        if cm.decode_queue_depth == 0:
            cm.decode_queue_depth = sum(w.in_flight_requests for w in cm.decode_workers)
        if cm.decode_workers and cm.decode_utilization == 0.0:
            busy = sum(w.in_flight_requests for w in cm.decode_workers)
            capacity = max(1, len(cm.decode_workers) * self.max_concurrent_per_decode)
            cm.decode_utilization = min(1.0, busy / capacity)
        if cm.prefill_workers and cm.prefill_utilization == 0.0:
            busy = sum(w.in_flight_requests for w in cm.prefill_workers)
            capacity = max(1, len(cm.prefill_workers) * self.max_concurrent_per_decode)
            cm.prefill_utilization = min(1.0, busy / capacity)
        return cm

    async def get_decode_worker_states(self) -> List[WorkerState]:
        return [w for w in await self.get_worker_states() if w.role == "decode"]

    async def get_worker_states(self) -> List[WorkerState]:
        workers: List[WorkerState] = []
        for component, role in (
            ("VllmDecodeWorker", "decode"),
            ("VllmPrefillWorker", "prefill"),
        ):
            workers.extend(await self._discover_component_workers(component, role))
        return workers

    async def _discover_component_workers(self, component: str, expected_role: str) -> List[WorkerState]:
        label_selector = (
            f"nvidia.com/dynamo-component={component},"
            f"nvidia.com/dynamo-graph-deployment-name={self.dgd_name}"
        )
        try:
            pods = self.k8s_core.list_namespaced_pod(
                namespace=self.namespace,
                label_selector=label_selector,
            ).items
        except Exception as exc:  # noqa: BLE001
            logger.warning("list worker pods failed: %s", exc)
            return []

        states: List[WorkerState] = []
        for pod in pods:
            if getattr(pod.status, "phase", "") != "Running":
                continue
            conditions = getattr(pod.status, "conditions", []) or []
            ready = any(getattr(c, "type", "") == "Ready" and getattr(c, "status", "") == "True" for c in conditions)
            if not ready:
                continue
            pod_ip = getattr(pod.status, "pod_ip", None)
            pod_name = getattr(pod.metadata, "name", "")
            if not pod_ip:
                continue
            addr = f"http://{pod_ip}:{self.worker_sidecar_port}"
            role = await self._sidecar_role(addr)
            active = await self._sidecar_active_count(addr)
            switch_capable = role in {"prefill", "decode"} and active is not None
            if not switch_capable and expected_role == "prefill":
                role = "prefill"
                healthy = True
                health_reason = "static_prefill_no_sidecar"
            else:
                healthy = switch_capable
                health_reason = "ok" if healthy else "sidecar_unreachable_or_invalid"
            active_count = int(active or 0)
            capacity = max(0, self.max_concurrent_per_decode - active_count) if healthy else 0
            remaining = 60.0 if active_count > 0 else 0.0
            states.append(
                WorkerState(
                    worker_id=pod_name,
                    addr=addr,
                    role=role or "unknown",
                    in_flight_requests=active_count,
                    active_kv_blocks=0,
                    available_capacity=capacity,
                    estimated_remaining_time=remaining,
                    healthy=healthy,
                    health_reason=health_reason,
                    switch_capable=switch_capable,
                )
            )
        return states

    async def _sidecar_role(self, addr: str) -> Optional[str]:
        try:
            resp = await self._http.get(addr.rstrip("/") + "/v1/role")
            resp.raise_for_status()
            role = str(resp.json().get("current_role") or "unknown")
            return role if role in {"prefill", "decode"} else None
        except Exception as exc:  # noqa: BLE001
            logger.warning("worker sidecar role probe failed for %s: %s", addr, exc)
            return None

    async def _sidecar_active_count(self, addr: str) -> Optional[int]:
        try:
            resp = await self._http.get(addr.rstrip("/") + "/v1/active_requests")
            resp.raise_for_status()
            body = resp.json()
            return len(body) if isinstance(body, list) else 0
        except Exception as exc:  # noqa: BLE001
            logger.warning("worker sidecar active-request probe failed for %s: %s", addr, exc)
            return None

    async def get_worker_request_count(self, worker_id: str) -> int:
        v = await self._query(
            f'sum(dynamo_worker_in_flight_requests{{worker_id="{worker_id}"}})'
        )
        return int(v) if v is not None else 0
