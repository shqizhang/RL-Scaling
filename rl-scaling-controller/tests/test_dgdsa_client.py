import pytest

from rl_scaling_controller.dgdsa_client import InMemoryDGDSAClient, K8sDGDSAClient


class TestInMemoryDGDSAClient:
    def test_patch_and_get(self):
        c = InMemoryDGDSAClient()
        c.patch("prefill", 3)
        assert c.get_replicas("prefill") == 3
        assert c.get_replicas("decode") == 0

    def test_history_recorded(self):
        c = InMemoryDGDSAClient()
        c.patch("prefill", 1)
        c.patch("decode", 2)
        c.patch("prefill", 0)
        assert c.history == [("prefill", 1), ("decode", 2), ("prefill", 0)]

    def test_negative_replicas_rejected(self):
        c = InMemoryDGDSAClient()
        with pytest.raises(ValueError):
            c.patch("prefill", -1)


class _FakeCustomApi:
    def __init__(self):
        self.calls = []
        self.scales = {}

    def patch_namespaced_custom_object_scale(self, **kwargs):
        self.calls.append(kwargs)
        self.scales[kwargs["name"]] = kwargs["body"]["spec"]["replicas"]

    def get_namespaced_custom_object_scale(self, **kwargs):
        return {"spec": {"replicas": self.scales.get(kwargs["name"], 0)}}


class _Obj:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class _FakeAppsApi:
    def __init__(self):
        self.calls = []
        self.replicas = {
            "rl-serving-vllmdecodeworker-abcd": 3,
            "rl-serving-vllmdecodeworker-old": 0,
            "rl-serving-vllmprefillworker-abcd": 2,
        }

    def list_namespaced_deployment(self, **kwargs):
        selector = kwargs["label_selector"]
        if "VllmDecodeWorker" in selector:
            names = ["rl-serving-vllmdecodeworker-old", "rl-serving-vllmdecodeworker-abcd"]
        else:
            names = ["rl-serving-vllmprefillworker-abcd"]
        return _Obj(
            items=[
                _Obj(
                    metadata=_Obj(name=name, creation_timestamp=name),
                    spec=_Obj(replicas=self.replicas[name]),
                    status=_Obj(replicas=self.replicas[name], available_replicas=self.replicas[name]),
                )
                for name in names
            ]
        )

    def patch_namespaced_deployment_scale(self, **kwargs):
        self.calls.append(kwargs)
        self.replicas[kwargs["name"]] = kwargs["body"]["spec"]["replicas"]

    def read_namespaced_deployment_scale(self, **kwargs):
        return _Obj(spec=_Obj(replicas=self.replicas[kwargs["name"]]))


class TestK8sDGDSAClient:
    def test_patch_calls_scale_subresource(self):
        api = _FakeCustomApi()
        c = K8sDGDSAClient(namespace="ns", dgd_name="rl-serving", custom_api=api)
        c.patch("prefill", 4)
        assert len(api.calls) == 1
        call = api.calls[0]
        assert call["group"] == "nvidia.com"
        assert call["version"] == "v1alpha1"
        assert call["namespace"] == "ns"
        assert call["plural"] == "dynamographdeploymentscalingadapters"
        assert call["name"] == "rl-serving-prefill"
        assert call["body"]["spec"]["replicas"] == 4

    def test_get_replicas(self):
        api = _FakeCustomApi()
        c = K8sDGDSAClient(namespace="ns", dgd_name="rl-serving", custom_api=api)
        c.patch("decode", 7)
        assert c.get_replicas("decode") == 7

    def test_negative_replicas_rejected(self):
        api = _FakeCustomApi()
        c = K8sDGDSAClient(namespace="ns", dgd_name="x", custom_api=api)
        with pytest.raises(ValueError):
            c.patch("prefill", -1)

    def test_deployment_fallback_patches_active_worker_deployment(self):
        api = _FakeCustomApi()
        apps = _FakeAppsApi()
        c = K8sDGDSAClient(
            namespace="ns",
            dgd_name="rl-serving",
            custom_api=api,
            apps_api=apps,
            deployment_fallback_enabled=True,
        )
        c.patch("decode", 1)
        assert api.calls == []
        assert apps.calls[0]["name"] == "rl-serving-vllmdecodeworker-abcd"
        assert apps.calls[0]["body"]["spec"]["replicas"] == 1
        assert c.get_replicas("decode") == 1
