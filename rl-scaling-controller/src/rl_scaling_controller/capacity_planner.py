"""Capacity planning: batch metadata -> required prefill/decode replicas."""
from __future__ import annotations

from dataclasses import dataclass
from math import ceil
from typing import Mapping


@dataclass(frozen=True)
class ScaleTarget:
    prefill_replicas: int
    decode_replicas: int

    def total(self) -> int:
        return self.prefill_replicas + self.decode_replicas


class CapacityPlanner:
    """Translate batch metadata into a (prefill, decode) replica plan.

    Formulas (see design S1.4.4):
      N_prefill = ceil(total_tokens / (single_prefill_tps * target_prefill_seconds))
      N_decode  = ceil(batch_size / max_concurrent_per_decode)

    Constraints:
      * N_prefill + N_decode <= max_gpus
      * N_prefill >= min_prefill_replicas (>=1)
      * N_decode  >= min_decode_replicas (>=1)
    """

    def __init__(
        self,
        single_prefill_tps: int,
        max_concurrent_per_decode: int,
        target_prefill_seconds: float,
        max_gpus: int,
        min_prefill_replicas: int = 1,
        min_decode_replicas: int = 1,
    ) -> None:
        if single_prefill_tps <= 0 or max_concurrent_per_decode <= 0:
            raise ValueError("throughput parameters must be positive")
        if target_prefill_seconds <= 0:
            raise ValueError("target_prefill_seconds must be > 0")
        if max_gpus < min_prefill_replicas + min_decode_replicas:
            raise ValueError("max_gpus too small for min replicas")
        self.single_prefill_tps = single_prefill_tps
        self.max_concurrent_per_decode = max_concurrent_per_decode
        self.target_prefill_seconds = target_prefill_seconds
        self.max_gpus = max_gpus
        self.min_prefill_replicas = max(1, min_prefill_replicas)
        self.min_decode_replicas = max(1, min_decode_replicas)

    def compute(self, batch_meta: Mapping[str, int]) -> ScaleTarget:
        try:
            batch_size = int(batch_meta["batch_size"])
            avg_isl = int(batch_meta["avg_isl"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"invalid batch_meta: {batch_meta!r}") from exc
        if batch_size <= 0 or avg_isl <= 0:
            raise ValueError("batch_size and avg_isl must be positive")

        total_tokens = int(batch_meta.get("total_tokens") or batch_size * avg_isl)

        prefill = ceil(total_tokens / (self.single_prefill_tps * self.target_prefill_seconds))
        decode = ceil(batch_size / self.max_concurrent_per_decode)

        prefill = max(self.min_prefill_replicas, prefill)
        decode = max(self.min_decode_replicas, decode)

        # Cap at hardware. Prefer giving prefill priority; remainder to decode.
        prefill = min(prefill, self.max_gpus - self.min_decode_replicas)
        decode = min(decode, self.max_gpus - prefill)
        decode = max(self.min_decode_replicas, decode)
        return ScaleTarget(prefill_replicas=prefill, decode_replicas=decode)
