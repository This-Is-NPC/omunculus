"""What every task's check shares: the run's outcome and small readers of the workspace.

A check runs as `check <workspace> <outcome.json>` after the run, outside the
agents' reach, and exits 0 when the task holds. The outcome file names the
configuration, how the conversation ended (answer, done, break or waiting) and
the last words to the person (report).
"""

import json
import pathlib
import re
import sys


def load():
    workspace = pathlib.Path(sys.argv[1])
    outcome = json.loads(pathlib.Path(sys.argv[2]).read_text())
    return workspace, outcome


def fail(reason):
    print(reason)
    sys.exit(1)


def ok(reason="holds"):
    print(reason)
    sys.exit(0)


def text(workspace, name):
    path = workspace / name
    if not path.is_file():
        fail(f"{name} is missing")
    return path.read_text()


def section(markdown, title):
    """The lines under `## title`, up to the next heading of that level or above."""
    match = re.search(rf"^##\s+{re.escape(title)}\s*$(.*?)(?=^#{{1,2}}\s|\Z)", markdown, re.M | re.S)
    if not match:
        fail(f"no '## {title}' section")
    return match.group(1)


def bullets(block):
    return [line.strip()[2:] for line in block.splitlines() if re.match(r"\s*[-*]\s", line)]


def expect_outcome(outcome, *allowed):
    if outcome["outcome"] not in allowed:
        fail(f"ended as {outcome['outcome']}, expected {' or '.join(allowed)}")
