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


class K8sDGDSAClient:
    """Kubernetes-backed DGDSA client.

    Patches ``spec.replicas`` of ``DynamoGraphDeploymentScalingAdapter``
    objects named ``{dgd_name}-{service}``.
    """

    GROUP = "dynamo.nvidia.com"
    VERSION = "v1alpha1"
    PLURAL = "dynamographdeploymentscalingadapters"

    def __init__(self, namespace: str, dgd_name: str, custom_api=None) -> None:
        self.namespace = namespace
        self.dgd_name = dgd_name
        if custom_api is None:
            from kubernetes import client, config  # type: ignore

            try:
                config.load_incluster_config()
            except Exception:
                config.load_kube_config()
            custom_api = client.CustomObjectsApi()
        self._api = custom_api

    def _name(self, service: str) -> str:
        return f"{self.dgd_name}-{service}"

    def patch(self, service: str, replicas: int) -> None:
        if replicas < 0:
            raise ValueError("replicas must be >= 0")
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
        obj = self._api.get_namespaced_custom_object_scale(
            group=self.GROUP,
            version=self.VERSION,
            namespace=self.namespace,
            plural=self.PLURAL,
            name=self._name(service),
        )
        return int(obj.get("spec", {}).get("replicas", 0))
