"""What the importers share: they turn one foreign task into one Equivalent Exchange task folder.

The folder is the task format of eval/README.md. The verifier lives in
`verify/`, outside `workspace/`, and the generated `check` runs it with
`verify()` of tasks/_lib/check.py.
"""

import json
import pathlib
import shutil

CONFIGURATIONS = ["solo", "delegation", "workflow", "negotiated", "human-gated"]

CHECK = '''#!/usr/bin/env python3
from check import *

import pathlib

workspace, outcome = load()
expect_outcome(outcome, "done", "answer")
verify(workspace, pathlib.Path(__file__).resolve().parent / "verify")
ok()
'''


def write_task(out, scenario, name, instruction, workspace, configurations=None):
    """Create `<out>/<scenario>/<name>/` and return it, its `workspace/` left to the caller to fill
    when `workspace` is None, else copied from that directory."""
    task = pathlib.Path(out) / scenario / name
    if task.exists():
        shutil.rmtree(task)
    (task / "workspace").mkdir(parents=True)
    (task / "verify").mkdir()
    (task / "solution").mkdir()
    if workspace:
        shutil.copytree(workspace, task / "workspace", dirs_exist_ok=True, symlinks=True)
    (task / "instruction.md").write_text(instruction.strip() + "\n")
    configurations = configurations or CONFIGURATIONS
    (task / "task.toml").write_text(
        f"scenario = {json.dumps(scenario)}\n"
        "critical = false\n"
        f"configurations = {json.dumps(configurations)}\n"
        'needs = ["fs.write", "sandbox.write", "bash"]\n\n'
        '[expect]\noutcome = ["done", "answer"]\n\n'
        '[human]\n"fs.write" = "grant"\n"sandbox.write" = "grant"\n"bash" = "grant"\n'
    )
    check = task / "check"
    check.write_text(CHECK)
    check.chmod(0o755)
    (task / "solution" / "outcome.json").write_text(
        json.dumps({"outcome": "done", "report": "Done.", "delete": []}, indent=2) + "\n"
    )
    return task


def write_executable(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


def safe_name(text):
    return "".join(c if c.isalnum() or c in "-_." else "-" for c in text).strip("-")
