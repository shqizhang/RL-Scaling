# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
"""Block-ID bridge: exposes KVCacheManager.get_block_ids() via Unix socket.

Loaded at Python startup via a .pth file.  In the EngineCore subprocess,
KVCacheManager.__init__ is monkey-patched to start a background thread
that serves block-ID queries over a Unix domain socket.

The handler process (MigrationHandler / RequestBlockIndex) connects as a
client to query block IDs for in-flight requests.  This bridges the
process boundary between the AsyncMPClient handler and the EngineCore
subprocess without modifying vLLM's IPC protocol.

Protocol (text, newline-delimited):
    Request:  "GET_BLOCKS <request_id>\n"
    Response: JSON line: {"block_ids": [[1,2,3], ...]} or {"error": "..."}

    Request:  "LIST_REQUESTS\n"
    Response: JSON line: {"request_ids": ["id1", "id2", ...]}
"""
from __future__ import annotations

import json
import logging
import os
import socket
import struct
import threading
from typing import Any, Optional

logger = logging.getLogger(__name__)

SOCKET_PATH = os.environ.get(
    "DYNAMO_BLOCK_BRIDGE_SOCKET", "/tmp/dynamo_kv_block_bridge.sock"
)

_original_kvcm_init: Any = None
_server_started = False


# ---------------------------------------------------------------------------
# Server side (runs inside EngineCore subprocess)
# ---------------------------------------------------------------------------


def _start_block_id_server(kv_cache_manager: Any) -> None:
    """Start a daemon thread serving block-ID queries."""
    global _server_started
    if _server_started:
        return
    _server_started = True

    # Clean up stale socket from previous run
    try:
        os.unlink(SOCKET_PATH)
    except OSError:
        pass

    def _handle_client(conn: socket.socket) -> None:
        try:
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            line = data.decode("utf-8").strip()

            if line.startswith("GET_BLOCKS "):
                request_id = line[len("GET_BLOCKS "):]
                try:
                    # Try exact match first
                    block_ids = kv_cache_manager.get_block_ids(request_id)
                    # Check if result is non-empty (non-trivial)
                    has_blocks = any(len(ids) > 0 for ids in block_ids)
                    if has_blocks:
                        response = {"block_ids": [list(ids) for ids in block_ids]}
                    else:
                        # Exact match returned empty — try prefix match.
                        # vLLM appends a suffix to Dynamo's base request_id.
                        matched_id = None
                        for mgr in kv_cache_manager.coordinator.single_type_managers:
                            for key in mgr.req_to_blocks:
                                if key.startswith(request_id):
                                    matched_id = key
                                    break
                            if matched_id:
                                break
                        if matched_id:
                            block_ids = kv_cache_manager.get_block_ids(matched_id)
                            response = {
                                "block_ids": [list(ids) for ids in block_ids],
                                "matched_id": matched_id,
                            }
                        else:
                            response = {"block_ids": [list(ids) for ids in block_ids]}
                except KeyError:
                    response = {"error": f"request {request_id!r} not found"}
                except Exception as exc:
                    response = {"error": str(exc)}
            elif line == "LIST_REQUESTS":
                try:
                    # Request tracking lives in coordinator.single_type_managers
                    req_ids: list[str] = []
                    for mgr in kv_cache_manager.coordinator.single_type_managers:
                        req_ids.extend(mgr.req_to_blocks.keys())
                    # Deduplicate (same request tracked in multiple managers)
                    response = {"request_ids": list(set(req_ids))}
                except Exception as exc:
                    response = {"error": str(exc)}
            elif line == "PING":
                response = {"status": "ok"}
            elif line == "DEBUG":
                try:
                    info: dict = {
                        "kvcm_id": id(kv_cache_manager),
                        "kvcm_type": type(kv_cache_manager).__name__,
                        "has_coordinator": hasattr(kv_cache_manager, "coordinator"),
                    }
                    if hasattr(kv_cache_manager, "coordinator"):
                        coord = kv_cache_manager.coordinator
                        info["coord_id"] = id(coord)
                        info["coord_type"] = type(coord).__name__
                        info["has_stm"] = hasattr(coord, "single_type_managers")
                        if hasattr(coord, "single_type_managers"):
                            stms = coord.single_type_managers
                            info["num_stm"] = len(stms)
                            mgr_info = []
                            for i, mgr in enumerate(stms):
                                mi = {
                                    "idx": i,
                                    "type": type(mgr).__name__,
                                    "has_req_to_blocks": hasattr(mgr, "req_to_blocks"),
                                }
                                if hasattr(mgr, "req_to_blocks"):
                                    rtb = mgr.req_to_blocks
                                    mi["rtb_type"] = type(rtb).__name__
                                    mi["rtb_len"] = len(rtb)
                                    mi["rtb_keys"] = list(rtb.keys())[:10]
                                mgr_info.append(mi)
                            info["managers"] = mgr_info
                    response = info
                except Exception as exc:
                    response = {"error": f"DEBUG failed: {exc}"}
            else:
                response = {"error": f"unknown command: {line!r}"}

            payload = json.dumps(response).encode("utf-8") + b"\n"
            conn.sendall(payload)
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _server_loop() -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o666)
        sock.listen(16)
        sock.settimeout(2.0)
        logger.info(
            "[BlockBridge] Server started at %s (pid=%d)", SOCKET_PATH, os.getpid()
        )

        while True:
            try:
                conn, _ = sock.accept()
                # Handle each client in a short-lived thread to avoid blocking
                threading.Thread(
                    target=_handle_client, args=(conn,), daemon=True
                ).start()
            except socket.timeout:
                continue
            except Exception:
                continue

    t = threading.Thread(target=_server_loop, daemon=True, name="block-id-bridge")
    t.start()


def _patched_kvcm_init(self: Any, *args: Any, **kwargs: Any) -> None:
    """Wraps KVCacheManager.__init__ to start the bridge server."""
    _original_kvcm_init(self, *args, **kwargs)
    _start_block_id_server(self)


# ---------------------------------------------------------------------------
# Client side (used by handler process)
# ---------------------------------------------------------------------------


def query_block_ids(
    request_id: str, socket_path: str = SOCKET_PATH, timeout: float = 2.0
) -> Optional[list[list[int]]]:
    """Query block IDs for a request from the bridge server.

    Returns list[list[int]] (per KV-group block IDs) or None on failure.
    """
    if not os.path.exists(socket_path):
        return None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(socket_path)
        sock.sendall(f"GET_BLOCKS {request_id}\n".encode("utf-8"))

        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
        sock.close()

        result = json.loads(data.decode("utf-8").strip())
        if "block_ids" in result:
            return result["block_ids"]
        return None
    except Exception:
        return None


def list_tracked_requests(
    socket_path: str = SOCKET_PATH, timeout: float = 2.0
) -> Optional[list[str]]:
    """List all request IDs tracked by the KVCacheManager."""
    if not os.path.exists(socket_path):
        return None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(socket_path)
        sock.sendall(b"LIST_REQUESTS\n")

        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
        sock.close()

        result = json.loads(data.decode("utf-8").strip())
        if "request_ids" in result:
            return result["request_ids"]
        return None
    except Exception:
        return None


def ping(socket_path: str = SOCKET_PATH, timeout: float = 1.0) -> bool:
    """Check if the bridge server is reachable."""
    if not os.path.exists(socket_path):
        return False
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(socket_path)
        sock.sendall(b"PING\n")
        data = sock.recv(1024)
        sock.close()
        return b"ok" in data
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Apply monkeypatch (runs at import time via .pth file)
# ---------------------------------------------------------------------------

_NIXL_META_PATH = "/tmp/dynamo_nixl_meta.json"
_original_nixl_worker_init: Any = None


def _patched_nixl_worker_init(self: Any, *args: Any, **kwargs: Any) -> None:
    """Wraps NixlConnectorWorker.__init__ to export NIXL metadata."""
    _original_nixl_worker_init(self, *args, **kwargs)
    try:
        import socket as _sock

        meta = {
            "engine_id": str(self.engine_id),
            "host": _sock.gethostbyname(_sock.gethostname()),
            "port": getattr(self, "side_channel_port", None)
            or getattr(self.kv_transfer_config, "nixl_side_channel_port", None)
            or getattr(self.kv_transfer_config, "kv_port", None)
            or 14579,  # vLLM default KVTransferConfig.kv_port
        }
        # Write metadata for handler process to read
        with open(_NIXL_META_PATH, "w") as f:
            json.dump(meta, f)
        logger.info(
            "[BlockBridge] NIXL meta exported: engine_id=%s host=%s port=%s",
            meta["engine_id"],
            meta["host"],
            meta["port"],
        )
    except Exception as exc:
        logger.warning("[BlockBridge] Failed to export NIXL meta: %s", exc)


def read_nixl_meta() -> Optional[dict]:
    """Read NIXL metadata exported by the NixlConnectorWorker bridge."""
    try:
        with open(_NIXL_META_PATH, "r") as f:
            meta = json.load(f)
        if meta.get("engine_id") and meta.get("host"):
            return meta
        return None
    except (FileNotFoundError, json.JSONDecodeError):
        return None


try:
    from vllm.v1.core.kv_cache_manager import KVCacheManager

    _original_kvcm_init = KVCacheManager.__init__
    KVCacheManager.__init__ = _patched_kvcm_init  # type: ignore[method-assign]
except ImportError:
    # Not a vLLM environment — silently skip.
    pass

try:
    from vllm.distributed.kv_transfer.kv_connector.v1.nixl_connector import (
        NixlConnectorWorker,
    )

    _original_nixl_worker_init = NixlConnectorWorker.__init__
    NixlConnectorWorker.__init__ = _patched_nixl_worker_init  # type: ignore[method-assign]
except ImportError:
    pass
