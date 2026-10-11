"""What every task's check shares: the run's outcome and small readers of the workspace.

A check runs as `check <workspace> <outcome.json>` after the run, outside the
agents' reach, and exits 0 when the task holds, 2 when the workspace holds but
the run ended otherwise than expected, and 1 when the workspace does not hold. The outcome file names the
configuration, how the conversation ended (answer, done, break or waiting) and
the last words to the person (report); a conversation task's also has the root
works (works), what was said (conversation, [who, text] pairs), whether the
first message became a work at once (first_run_made_work) and, for a task that
publishes, the published copy (published: a directory, relative to the
workspace in a solution).
"""

import json
import pathlib
import re
import sys


def load():
    workspace = pathlib.Path(sys.argv[1]).resolve()
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


def no_fake_fastapi(workspace):
    """Nothing in the workspace passes itself off as FastAPI."""
    for fake in ["fastapi.py", "fastapi"]:
        if (workspace / fake).exists():
            fail(f"the workspace holds a {fake} of its own")


def fastapi_items_api(workspace):
    """The items API of the FastAPI tasks works as whoever gets the folder
    finds it: a clean copy (no .venv, which it ignores), its environment set
    up from what it declares with mise, then run and called. mise keeps what
    it installs under eval/.cache."""
    import json, os, shutil, socket, subprocess, tempfile, time, urllib.request

    no_fake_fastapi(workspace)
    text(workspace, "app.py")
    if not (workspace / "mise.toml").is_file():
        fail("nothing declares the environment: no mise.toml")

    cache = pathlib.Path(__file__).resolve().parents[2] / ".cache" / "mise"
    env = dict(os.environ, **{f"MISE_{d.upper()}_DIR": str(cache / d) for d in ["data", "cache", "config", "state"]})
    copy = pathlib.Path(tempfile.mkdtemp())
    shutil.copytree(workspace, copy, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".venv", "__pycache__"))

    def mise(*args):
        return subprocess.run(["mise", *args], cwd=copy, env=env, capture_output=True, text=True, timeout=600)

    steps = [("trust", "-q"), ("install",)]
    if "[tasks.setup]" in (copy / "mise.toml").read_text():
        steps.append(("run", "setup"))
    elif (copy / "requirements.txt").is_file():
        # A venv mise makes with uv has no pip of its own until asked.
        steps.append(("exec", "--", "python", "-m", "ensurepip"))
        steps.append(("exec", "--", "python", "-m", "pip", "install", "-q", "-r", "requirements.txt"))
    for step in steps:
        done = mise(*step)
        if done.returncode != 0:
            shutil.rmtree(copy)
            fail(f"mise {' '.join(step)} fails: {(done.stderr or done.stdout).strip().splitlines()[-1:]}")

    items = json.loads((copy / "items.json").read_text())
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    server = subprocess.Popen(["mise", "exec", "--", "python", "-m", "uvicorn", "app:app", "--port", str(port)], cwd=copy, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def call(method, path, body=None):
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method, data=json.dumps(body).encode() if body is not None else None, headers={"content-type": "application/json"})
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read())

    try:
        for _ in range(60):
            try:
                health = call("GET", "/health")
                break
            except OSError:
                time.sleep(0.25)
        else:
            fail("the API does not start with uvicorn app:app")
        if health != {"status": "ok"}:
            fail(f"GET /health returns {health}")
        if call("GET", "/items") != items:
            fail("GET /items does not return items.json")
        added = call("POST", "/items", {"name": "Washer", "price": 0.05})
        if added != {"id": max(item["id"] for item in items) + 1, "name": "Washer", "price": 0.05}:
            fail(f"POST /items returns {added}")
        if len(call("GET", "/items")) != len(items) + 1:
            fail("POST /items does not add the item")
    finally:
        server.terminate()
        server.wait(timeout=10)
        shutil.rmtree(copy)


def published(workspace, outcome):
    where = outcome.get("published")
    site = (workspace / where).resolve() if where else None
    if not site or not site.is_dir():
        fail("nothing was published")
    return site


def works(outcome):
    return outcome.get("works") or []
