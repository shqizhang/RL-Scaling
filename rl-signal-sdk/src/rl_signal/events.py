"""Event payload models for the RL Scaling SDK."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Dict, Optional


@dataclass
class BatchMeta:
    """Batch metadata RL frameworks know during sampling.

    Fields map directly to the JSON payload sent to the controller.
    """

    batch_size: int
    avg_isl: int
    avg_osl: Optional[int] = None
    total_tokens: Optional[int] = None

    def __post_init__(self) -> None:
        if self.batch_size <= 0:
            raise ValueError("batch_size must be > 0")
        if self.avg_isl <= 0:
            raise ValueError("avg_isl must be > 0")
        if self.total_tokens is None:
            self.total_tokens = self.batch_size * self.avg_isl

    def to_dict(self) -> Dict[str, Any]:
        return {k: v for k, v in asdict(self).items() if v is not None}
