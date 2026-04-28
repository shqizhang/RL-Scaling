"""RL Signal SDK — emit lifecycle events to the RL Scaling Controller."""
from .events import BatchMeta
from .emitter import RLSignalEmitter

__all__ = ["RLSignalEmitter", "BatchMeta"]
__version__ = "0.1.0"
