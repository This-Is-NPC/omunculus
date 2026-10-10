"""What every task's check shares: the run's outcome and small readers of the workspace.

A check runs as `check <workspace> <outcome.json>` after the run, outside the
agents' reach, and exits 0 when the task holds, 2 when the workspace holds but
the run ended otherwise than expected, and 1 when the workspace does not hold. The outcome file names the
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


# An unexpected ending is told only once the workspace has been checked, so a
# failure says whether the files were wrong.
_ended_otherwise = None


def ok(reason="holds"):
    if _ended_otherwise:
        print(_ended_otherwise)
        sys.exit(2)
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
    global _ended_otherwise
    if outcome["outcome"] not in allowed:
        _ended_otherwise = f"ended as {outcome['outcome']}, expected {' or '.join(allowed)}"


def docx_paragraphs(workspace, name):
    """The paragraphs of a .docx as (style, text): its style id, or "", and its runs' text joined."""
    import zipfile
    import xml.etree.ElementTree as tree

    path = workspace / name
    if not path.is_file():
        fail(f"{name} is missing")
    try:
        with zipfile.ZipFile(path) as archive:
            document = tree.fromstring(archive.read("word/document.xml"))
    except (zipfile.BadZipFile, KeyError, tree.ParseError):
        fail(f"{name} is not a Word document")
    w = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    paragraphs = []
    for paragraph in document.iter(f"{w}p"):
        style = paragraph.find(f"{w}pPr/{w}pStyle")
        text = "".join(node.text or "" for node in paragraph.iter(f"{w}t"))
        paragraphs.append((style.get(f"{w}val") if style is not None else "", text))
    return paragraphs
