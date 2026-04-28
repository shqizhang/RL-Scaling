"""S2 Elastic Role Switch — Python controller module.

Implements the high-level decision logic from design doc S2.7 to dynamically
flip a worker's disaggregation role between *prefill* and *decode* based on
runtime queue depth and idle utilisation. Heavy GPU work (NIXL reconfig,
KV-pool reconfig) lives inside the Dynamo worker as a ``DualModeWorker`` and
is coordinated over HTTP by :class:`DualModeClient`.
"""
from .controller import ElasticRoleSwitchController, RoleSwitchDecision
from .dual_mode_client import DualModeClient
from .strategy import find_most_idle_worker

__all__ = [
    "ElasticRoleSwitchController",
    "RoleSwitchDecision",
    "DualModeClient",
    "find_most_idle_worker",
]
