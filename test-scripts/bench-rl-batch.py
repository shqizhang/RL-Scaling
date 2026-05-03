#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
"""Bench: end-to-end batch wall-time with vs. without RL-Scaling.

Issues a fixed batch of OpenAI-compatible completions against the Dynamo
frontend and measures:
  - total wall-clock time of the batch
  - per-request first-token latency (TTFT)
  - per-request total latency
  - p50 / p95 / max for each metric

The script can be run twice (once with --baseline, once with --rls) and the
two runs diffed by `bench-diff` (or just eyeballed via the printed summary)
to show the Phase-2 improvement target from TEST_PLAN.zh-CN.md §P2.3:

    end-to-end batch wall-clock improvement >= 20% with migration enabled.

Usage::

    python3 bench-rl-batch.py \\
        --frontend http://localhost:8000 \\
        --model Qwen/Qwen3-0.6B \\
        --concurrency 8 --requests 32 \\
        --prompt-tokens 256 --max-tokens 128 \\
        --tag baseline > /tmp/bench-baseline.json

    python3 bench-rl-batch.py [...] --tag rls > /tmp/bench-rls.json

The output is one JSON object per line on stderr (progress) and a final
summary JSON on stdout.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from dataclasses import dataclass, field, asdict
from typing import Optional

try:
    import aiohttp
except ImportError:
    print("aiohttp is required: pip install aiohttp", file=sys.stderr)
    sys.exit(2)


def _build_prompt(n_tokens: int) -> str:
    """Build a deterministic prompt of approximately ``n_tokens`` tokens."""
    # ~1 token per word on average for English; pad with deterministic filler.
    words = [f"word{i}" for i in range(max(1, n_tokens))]
    return " ".join(words)


@dataclass
class RequestResult:
    request_id: str
    ttft_ms: Optional[float] = None
    total_ms: Optional[float] = None
    output_tokens: int = 0
    status: str = "ok"
    error: str = ""


async def _stream_one(
    session: aiohttp.ClientSession,
    url: str,
    payload: dict,
    rid: str,
    timeout: float,
) -> RequestResult:
    res = RequestResult(request_id=rid)
    t0 = time.monotonic()
    first_token_t: Optional[float] = None
    try:
        async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
            if resp.status != 200:
                res.status = "http_error"
                res.error = f"HTTP {resp.status}: {(await resp.text())[:200]}"
                return res
            async for raw in resp.content:
                if not raw:
                    continue
                line = raw.decode("utf-8", errors="ignore").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    j = json.loads(data)
                except json.JSONDecodeError:
                    continue
                choices = j.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or choices[0].get("text") or ""
                if isinstance(delta, dict):
                    delta = delta.get("content") or ""
                if delta:
                    if first_token_t is None:
                        first_token_t = time.monotonic()
                    res.output_tokens += 1
        res.total_ms = (time.monotonic() - t0) * 1000.0
        if first_token_t is not None:
            res.ttft_ms = (first_token_t - t0) * 1000.0
    except asyncio.TimeoutError:
        res.status = "timeout"
        res.error = f"timeout after {timeout}s"
    except Exception as exc:  # noqa: BLE001
        res.status = "error"
        res.error = repr(exc)
    return res


async def _run_batch(args) -> dict:
    url = f"{args.frontend.rstrip('/')}/v1/chat/completions"
    prompt = _build_prompt(args.prompt_tokens)
    payload_template = {
        "model": args.model,
        "stream": True,
        "max_tokens": args.max_tokens,
        "temperature": 0.0,
        "messages": [{"role": "user", "content": prompt}],
    }

    sem = asyncio.Semaphore(args.concurrency)
    results: list[RequestResult] = []

    async def _one(idx: int):
        async with sem:
            payload = dict(payload_template)
            rid = f"{args.tag}-{idx}"
            timeout = float(args.timeout)
            return await _stream_one(session, url, payload, rid, timeout)

    t_start = time.monotonic()
    async with aiohttp.ClientSession() as session:
        tasks = [asyncio.create_task(_one(i)) for i in range(args.requests)]
        for done in asyncio.as_completed(tasks):
            r = await done
            results.append(r)
            print(json.dumps(asdict(r)), file=sys.stderr, flush=True)
    t_end = time.monotonic()

    return _summarise(results, batch_wall_ms=(t_end - t_start) * 1000.0, args=args)


def _summarise(results: list[RequestResult], batch_wall_ms: float, args) -> dict:
    ok = [r for r in results if r.status == "ok"]
    ttfts = [r.ttft_ms for r in ok if r.ttft_ms is not None]
    totals = [r.total_ms for r in ok if r.total_ms is not None]
    out_tokens = [r.output_tokens for r in ok]

    def _pct(xs, q):
        if not xs:
            return None
        s = sorted(xs)
        idx = max(0, min(len(s) - 1, int(round(q / 100 * (len(s) - 1)))))
        return s[idx]

    summary = {
        "tag": args.tag,
        "frontend": args.frontend,
        "model": args.model,
        "concurrency": args.concurrency,
        "requests": args.requests,
        "ok": len(ok),
        "errors": len(results) - len(ok),
        "batch_wall_ms": round(batch_wall_ms, 1),
        "ttft_ms": {
            "p50": _pct(ttfts, 50),
            "p95": _pct(ttfts, 95),
            "max": max(ttfts) if ttfts else None,
            "mean": round(statistics.mean(ttfts), 1) if ttfts else None,
        },
        "total_ms": {
            "p50": _pct(totals, 50),
            "p95": _pct(totals, 95),
            "max": max(totals) if totals else None,
            "mean": round(statistics.mean(totals), 1) if totals else None,
        },
        "output_tokens": {
            "total": sum(out_tokens),
            "mean": round(statistics.mean(out_tokens), 1) if out_tokens else 0,
        },
    }
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--frontend", default="http://localhost:8000",
                    help="Dynamo frontend URL (default: http://localhost:8000)")
    ap.add_argument("--model", required=True, help="Model name (must match served model)")
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--requests", type=int, default=32)
    ap.add_argument("--prompt-tokens", type=int, default=256,
                    help="Approx prompt length in tokens (deterministic filler)")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--timeout", type=float, default=120.0,
                    help="Per-request timeout in seconds")
    ap.add_argument("--tag", default="run", help="Free-form tag attached to the summary")
    args = ap.parse_args()

    summary = asyncio.run(_run_batch(args))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
