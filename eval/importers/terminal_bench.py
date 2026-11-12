"""Terminal-Bench task folders to Equivalent Exchange tasks.

A Terminal-Bench task folder holds `task.yaml` (the `instruction`), a
`Dockerfile` (at the root or in `environment/`), `run-tests.sh`, `tests/`
and, optionally, `solution.sh`. The eval runs agents in a sandboxed
workspace, not in a container, so the image is not built: the files its
`COPY`/`ADD` lines put under the `WORKDIR` become the workspace, and the
`RUN` lines are not executed. Tasks that need what only those lines install
fail their solution in the selftest; the importer does not guess them.
"""

import pathlib
import re
import shlex
import shutil

import common

# Files of the folder that belong to the verifier or the task, never to the workspace.
NOT_WORKSPACE = {"tests", "run-tests.sh", "solution.sh", "solution.yaml", "task.yaml", "Dockerfile",
                 "docker-compose.yaml", "environment"}


def parse_yaml(text):
    """The top-level keys of a task.yaml: plain, quoted and `|` / `>` block scalars; nesting is skipped."""
    data, lines, i = {}, text.splitlines(), 0
    while i < len(lines):
        match = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", lines[i])
        i += 1
        if not match:
            continue
        key, value = match.groups()
        if value[:1] in ("|", ">"):
            block = []
            while i < len(lines) and (lines[i].startswith((" ", "\t")) or not lines[i].strip()):
                block.append(lines[i])
                i += 1
            indent = min((len(l) - len(l.lstrip()) for l in block if l.strip()), default=0)
            body = [l[indent:] for l in block]
            data[key] = ("\n".join(body) if value[0] == "|" else " ".join(l.strip() for l in body)).strip()
        else:
            data[key] = value.strip().strip("\"'")
    return data


def copies(dockerfile):
    """(sources, destination, into) of each COPY/ADD, the destination relative to the final WORKDIR.

    `into` is true when the destination is a directory (trailing slash or several sources).
    Destinations outside the WORKDIR are returned apart, as skipped.
    """
    workdir, raw, found, skipped = pathlib.PurePosixPath("/"), [], [], []
    for line in re.sub(r"\\\n", " ", dockerfile.read_text()).splitlines():
        words = shlex.split(line, comments=True)
        if not words:
            continue
        step, args = words[0].upper(), [w for w in words[1:] if not w.startswith("--")]
        if step == "WORKDIR" and args:
            workdir = workdir / args[0]
        elif step in ("COPY", "ADD") and len(args) >= 2:
            raw.append((args[:-1], workdir / args[-1], args[-1].endswith("/") or len(args) > 2))
    for sources, dest, into in raw:
        try:
            found.append((sources, dest.relative_to(workdir), into))
        except ValueError:
            skipped.append(" ".join(sources))
    return found, skipped


def build_workspace(source, destination):
    """Copy what the Dockerfile copies into `destination`; return (dockerfile or None, warnings)."""
    dockerfile = next((p for p in (source / "Dockerfile", source / "environment" / "Dockerfile") if p.is_file()), None)
    if dockerfile is None:
        return None, ["no Dockerfile: the workspace starts empty"]
    context, warnings = dockerfile.parent.resolve(), []
    found, skipped = copies(dockerfile)
    warnings += [f"COPY outside the WORKDIR skipped: {s}" for s in skipped]
    for sources, dest, into in found:
        for src in sources:
            path = (context / src).resolve()
            if not path.exists():
                warnings.append(f"COPY source missing: {src}")
            elif path.is_dir():
                for child in path.iterdir():
                    if path != context or child.name not in NOT_WORKSPACE:
                        _copy(child, destination / dest / child.name)
            else:
                _copy(path, destination / dest / path.name if into else destination / dest)
    return dockerfile, warnings


def _copy(src, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dest, dirs_exist_ok=True, symlinks=True)
    else:
        shutil.copy2(src, dest)


def convert(source, out):
    """Convert one Terminal-Bench task folder; return (task folder, warnings)."""
    source = pathlib.Path(source)
    spec = parse_yaml((source / "task.yaml").read_text())
    if not spec.get("instruction"):
        raise ValueError(f"{source}: task.yaml has no instruction")
    task = common.write_task(out, "terminal-bench", common.safe_name(source.name), spec["instruction"], None)
    dockerfile, warnings = build_workspace(source, task / "workspace")
    if dockerfile:
        shutil.copy2(dockerfile, task / "verify" / "Dockerfile")  # kept for reference, never built
    script = next((p for p in (source / "run-tests.sh", source / "tests" / "run-tests.sh") if p.is_file()), None)
    if script is None:
        raise ValueError(f"{source}: no run-tests.sh")
    common.write_executable(task / "verify" / "run-tests.sh", script.read_text())
    if (source / "tests").is_dir():
        shutil.copytree(source / "tests", task / "verify" / "tests", dirs_exist_ok=True)
    if (source / "solution.sh").is_file():
        common.write_executable(task / "solution" / "solve", (source / "solution.sh").read_text())
    else:
        warnings.append("no solution.sh: the selftest cannot prove this task solvable")
    return task, warnings
