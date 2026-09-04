#!/usr/bin/env python3
"""ws-parity peer: connect, send one text frame, print the echo, close."""

from __future__ import annotations

import asyncio
import sys


async def main() -> None:
    url = sys.argv[1]
    payload = sys.argv[2] if len(sys.argv) > 2 else "ping"
    try:
        import websockets
    except ImportError:
        print("SKIP no websockets", file=sys.stderr)
        raise SystemExit(2)
    async with websockets.connect(url) as ws:
        await ws.send(payload)
        print(await ws.recv())


if __name__ == "__main__":
    asyncio.run(main())
