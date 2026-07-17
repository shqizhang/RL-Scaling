"""Thin DGDSA (DynamoGraphDeploymentScalingAdapter) client.

This module is intentionally split into a transport interface and an
``InMemoryDGDSAClient`` so unit tests can exercise the state machine without
needing a real Kubernetes cluster. The Kubernetes-backed client is loaded
lazily so importing this module never requires the ``kubernetes`` package.
"""
from __future__ import annotations

import logging
from typing import Dict, Protocol

logger = logging.getLogger(__name__)


class DGDSAClientProtocol(Protocol):
    def patch(self, service: str, replicas: int) -> None: ...

    def get_replicas(self, service: str) -> int: ...

    def prefer_delete(self, pod_names: list[str]) -> None: ...


class InMemoryDGDSAClient:
    """Records the replica state for tests / dry-run."""

    def __init__(self) -> None:
        self._replicas: Dict[str, int] = {}
        self.history: list[tuple[str, int]] = []

    def patch(self, service: str, replicas: int) -> None:
        if replicas < 0:
            raise ValueError("replicas must be >= 0")
        self._replicas[service] = replicas
        self.history.append((service, replicas))
        logger.debug("[in-memory] patch %s replicas=%d", service, replicas)

    def get_replicas(self, service: str) -> int:
        return self._replicas.get(service, 0)

    def prefer_delete(self, pod_names: list[str]) -> None:
        # No pods in the in-memory model; record for test assertions.
        self.history.append(("prefer_delete", len(pod_names)))


class K8sDGDSAClient:
    """Kubernetes-backed DGDSA client.

    Patches ``spec.replicas`` of ``DynamoGraphDeploymentScalingAdapter``
    objects named ``{dgd_name}-{service}``.
    """

    GROUP = "nvidia.com"
    VERSION = "v1alpha1"
    PLURAL = "dynamographdeploymentscalingadapters"

    def __init__(
        self,
        namespace: str,
        dgd_name: str,
        custom_api=None,
        apps_api=None,
        core_api=None,
        *,
        deployment_fallback_enabled: bool = False,
    ) -> None:
        self.namespace = namespace
        self.dgd_name = dgd_name
        self.deployment_fallback_enabled = deployment_fallback_enabled
        if custom_api is None:
            from kubernetes import client, config  # type: ignore

            try:
                config.load_incluster_config()
            except Exception:
                config.load_kube_config()
            custom_api = client.CustomObjectsApi()
            if apps_api is None:
                apps_api = client.AppsV1Api()
            if core_api is None:
                core_api = client.CoreV1Api()
        self._api = custom_api
        self._apps = apps_api
        self._core = core_api

    # Very negative deletion cost => the ReplicaSet controller removes THIS pod
    # first when the Deployment scales down. See prefer_delete().
    _PREFER_DELETE_COST = "-1000000"

    def prefer_delete(self, pod_names: list[str]) -> None:
        """Mark drained pods so a subsequent scale-down removes THEM, not a busy
        pod. Scaling a Deployment down only sets the replica count; Kubernetes
        picks which pod to terminate, and without a hint it may kill a pod that
        still has in-flight requests (observed in mixed S2+S3: the scaled-down
        victim was a busy decoder, not the drained source, so its long-tail
        requests died with EngineShutdown). Setting
        ``controller.kubernetes.io/pod-deletion-cost`` to a very negative value
        makes the ReplicaSet controller evict these (already-drained) pods
        first."""
        if self._core is None or not pod_names:
            return
        body = {
            "metadata": {
                "annotations": {
                    "controller.kubernetes.io/pod-deletion-cost": self._PREFER_DELETE_COST
                }
            }
        }
        for name in pod_names:
            try:
                self._core.patch_namespaced_pod(name=name, namespace=self.namespace, body=body)
                logger.info("marked drained pod %s for preferential deletion", name)
            except Exception as exc:  # noqa: BLE001
                logger.warning("failed to set pod-deletion-cost on %s: %s", name, exc)

    def _name(self, service: str) -> str:
        return f"{self.dgd_name}-{service}"

    def _component(self, service: str) -> str:
        if service == "decode":
            return "VllmDecodeWorker"
        if service == "prefill":
            return "VllmPrefillWorker"
        raise ValueError(f"unknown service: {service}")

    def _deployment_label_selector(self, service: str) -> str:
        return (
            f"nvidia.com/dynamo-component={self._component(service)},"
            f"nvidia.com/dynamo-graph-deployment-name={self.dgd_name}"
        )

    def _active_deployment_name(self, service: str) -> str:
        if self._apps is None:
            raise RuntimeError("AppsV1Api is not configured")
        deployments = self._apps.list_namespaced_deployment(
            namespace=self.namespace,
            label_selector=self._deployment_label_selector(service),
        ).items
        candidates = [
            d
            for d in deployments
            if int(getattr(getattr(d, "spec", None), "replicas", 0) or 0) > 0
            or int(getattr(getattr(d, "status", None), "replicas", 0) or 0) > 0
            or int(getattr(getattr(d, "status", None), "available_replicas", 0) or 0) > 0
        ]
        if not candidates:
            candidates = deployments
        if not candidates:
            raise RuntimeError(f"no deployment found for service={service}")
        candidates.sort(key=lambda d: getattr(getattr(d, "metadata", None), "creation_timestamp", None) or "")
        return candidates[-1].metadata.name

    def _patch_deployment(self, service: str, replicas: int) -> None:
        name = self._active_deployment_name(service)
        body = {"spec": {"replicas": int(replicas)}}
        self._apps.patch_namespaced_deployment_scale(
            name=name,
            namespace=self.namespace,
            body=body,
        )
        logger.info("Patched deployment %s replicas=%d", name, replicas)

    def _deployment_replicas(self, service: str) -> int:
        name = self._active_deployment_name(service)
        obj = self._apps.read_namespaced_deployment_scale(
            name=name,
            namespace=self.namespace,
        )
        return int(getattr(obj.spec, "replicas", 0) or 0)

    def patch(self, service: str, replicas: int) -> None:
        if replicas < 0:
            raise ValueError("replicas must be >= 0")
        if self.deployment_fallback_enabled:
            self._patch_deployment(service, replicas)
            return
        body = {"spec": {"replicas": int(replicas)}}
        self._api.patch_namespaced_custom_object_scale(
            group=self.GROUP,
            version=self.VERSION,
            namespace=self.namespace,
            plural=self.PLURAL,
            name=self._name(service),
            body=body,
        )
        logger.info("Patched %s replicas=%d", self._name(service), replicas)

    def get_replicas(self, service: str) -> int:
        if self.deployment_fallback_enabled:
            return self._deployment_replicas(service)
        obj = self._api.get_namespaced_custom_object_scale(
            group=self.GROUP,
            version=self.VERSION,
            namespace=self.namespace,
            plural=self.PLURAL,
            name=self._name(service),
        )
        return int(obj.get("spec", {}).get("replicas", 0))
