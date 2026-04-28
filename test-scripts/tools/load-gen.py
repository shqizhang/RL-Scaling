#!/usr/bin/env python3
"""Tiny load generator used by test-s1/s2/s3 scripts.

It hits the controller's debug generate endpoint (`/api/v1/debug/generate`)
which is a thin wrapper over the OpenAI-compatible `/v1/completions` route
that the Dynamo frontend exposes. Supports:

    --url URL              controller base URL (e.g. http://localhost:8080)
    --num N                number of requests
    --max-tokens N         per-request output cap
    --seed N               RNG seed for reproducibility
    --pin-worker-index N   force routing to a specific worker (test-only)
    --background           do not wait for completion
    --capture              print concatenated outputs to stdout

This is intentionally dependency-free (only stdlib + httpx if available) so
it can be copied to any cluster jump-host.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import urllib.request
import uuid


def _post(url: str, body: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.load(resp)


async def _one(url: str, args: argparse.Namespace, idx: int) -> str:
    body = {
        "request_id": f"loadgen-{uuid.uuid4()}",
        "prompt": f"hello world {args.seed + idx}",
        "max_tokens": args.max_tokens,
        "seed": args.seed + idx,
    }
    if args.pin_worker_index is not None:
        body["x_pin_worker_index"] = args.pin_worker_index
    loop = asyncio.get_running_loop()
    resp = await loop.run_in_executor(None, _post, f"{url}/api/v1/debug/generate", body)
    return resp.get("text", "")


async def _main(args: argparse.Namespace) -> None:
    tasks = [asyncio.create_task(_one(args.url, args, i)) for i in range(args.num)]
    if args.background:
        # fire-and-forget: do not await; the caller can `wait` from shell
        await asyncio.sleep(0.5)
        return
    outputs = await asyncio.gather(*tasks, return_exceptions=True)
    if args.capture:
        print("\n".join(str(o) for o in outputs))


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--num", type=int, default=1)
    p.add_argument("--max-tokens", type=int, default=64)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--pin-worker-index", type=int, default=None)
    p.add_argument("--background", action="store_true")
    p.add_argument("--capture", action="store_true")
    args = p.parse_args()
    try:
        asyncio.run(_main(args))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
