#!/usr/bin/env python3
"""Test bridge for Model.Command: one counter call, then a text turn."""

from __future__ import annotations

import json
import sys


def send(message: dict) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def main() -> None:
    opening = json.loads(sys.stdin.readline())
    names = [tool.get("name") for tool in opening.get("tools") or []]
    if "counter" in names:
        send({"type": "call", "id": 1, "name": "counter", "args": {}})
        reply = json.loads(sys.stdin.readline())
        if not reply.get("ok"):
            send({"type": "error", "output": str(reply.get("output"))})
            return
    send({"type": "text", "output": "benchmark complete"})


if __name__ == "__main__":
    main()
