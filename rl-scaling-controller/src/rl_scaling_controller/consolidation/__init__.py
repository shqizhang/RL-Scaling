"""S3 — Request Consolidation (RL-Scaling).

Towards the tail of a batch a few stragglers keep many decode workers
half-busy. The consolidation controller migrates those requests onto fewer
workers so the freed-up workers can be scaled to zero.

Per the design doc S3 feasibility alert, full KV-D2D migration is gated on a
new Rust transfer primitive that does not yet exist, so the migration HTTP
endpoints in Dynamo currently use a *recompute-prefill* fallback. The Python
decision engine here is identical for both paths.
"""
from .controller import ConsolidationController, ConsolidationDecision
from .decision_engine import ConsolidationDecisionEngine, MigrationPair
from .migration_client import MigrationClient

__all__ = [
    "ConsolidationController",
    "ConsolidationDecision",
    "ConsolidationDecisionEngine",
    "MigrationPair",
    "MigrationClient",
]
