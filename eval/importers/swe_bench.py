"""SWE-bench and SWE-bench Pro instances (JSONL) to Equivalent Exchange tasks.

An instance becomes a task whose workspace is the repository at
`base_commit` and whose instruction is the `problem_statement`. The verifier
restores and applies the `test_patch`, then runs the FAIL_TO_PASS tests and
the PASS_TO_PASS tests with the test command; both must pass. The gold
`patch`, when present, is the task's solution for the selftest.

Fields read: `instance_id`, `repo` (`owner/name`), `base_commit`,
`problem_statement`, `FAIL_TO_PASS` and `PASS_TO_PASS` (SWE-bench) or
`fail_to_pass` and `pass_to_pass` (Pro), each a list or a JSON string of one,
`test_patch`, `patch`, and the test command from `test_cmd` or
`test_command`, else the importer's default. A command holding `{tests}` has
the quoted test names put there; otherwise they are appended.
"""

import json
import pathlib
import shlex
import subprocess
import tempfile

import common


def field(instance, *names, default=None):
    return next((instance[n] for n in names if instance.get(n) not in (None, "")), default)


def tests(value):
    if isinstance(value, str):
        value = json.loads(value) if value.strip() else []
    return list(value or [])


def repo_source(repos, repo):
    """The local clone of `owner/name` under `repos`: `owner__name`, `owner/name` or `name`."""
    owner, _, name = repo.partition("/")
    candidates = [repos / f"{owner}__{name}", repos / owner / name, repos / name]
    for path in candidates:
        if (path / ".git").exists() or (path / "HEAD").is_file():
            return path
    raise FileNotFoundError(f"no clone of {repo} under {repos} (tried {', '.join(map(str, candidates))})")


def checkout(source, commit, destination):
    """One-commit repository of `source` at `commit` in `destination`, with no remote."""
    destination.mkdir(parents=True, exist_ok=True)
    git = ["git", "-C", str(destination), "-c", "protocol.file.allow=always"]
    for args in (
        ["init", "-q"],
        ["fetch", "-q", "--depth", "1", f"file://{source.resolve()}", commit],
        ["checkout", "-q", "FETCH_HEAD"],
    ):
        subprocess.run(git + args, check=True, capture_output=True)


def run_block(label, command, names):
    if not names:
        return ""
    quoted = " ".join(shlex.quote(n) for n in names)
    line = command.replace("{tests}", quoted) if "{tests}" in command else f"{command} {quoted}"
    return f'{line} || {{ echo "{label} tests failed"; exit 1; }}\n'


def verify_script(base, command, fail_to_pass, pass_to_pass, has_test_patch):
    head = "#!/usr/bin/env bash\nset -u\n"
    if has_test_patch:
        head += (
            f'git apply --numstat "$VERIFY_DIR/test.patch" | cut -f3 | while read -r f; do\n'
            f'  git checkout -q {shlex.quote(base)} -- "$f" 2>/dev/null || rm -f "$f"\n'
            "done\n"
            'git apply "$VERIFY_DIR/test.patch" || { echo "the test patch does not apply"; exit 1; }\n'
        )
    return head + run_block("FAIL_TO_PASS", command, fail_to_pass) + run_block("PASS_TO_PASS", command, pass_to_pass)


def convert(instance, repos, out, default_command):
    """Convert one instance; return the task folder."""
    base = instance["base_commit"]
    command = field(instance, "test_cmd", "test_command", default=default_command)
    f2p = tests(field(instance, "FAIL_TO_PASS", "fail_to_pass", default=[]))
    if not f2p:
        raise ValueError(f"{instance.get('instance_id')}: no FAIL_TO_PASS tests")
    p2p = tests(field(instance, "PASS_TO_PASS", "pass_to_pass", default=[]))
    task = common.write_task(
        out, "swe-bench", common.safe_name(instance["instance_id"]), instance["problem_statement"], None
    )
    checkout(repo_source(pathlib.Path(repos), instance["repo"]), base, task / "workspace")
    test_patch = instance.get("test_patch") or ""
    if test_patch:
        (task / "verify" / "test.patch").write_text(test_patch)
    common.write_executable(
        task / "verify" / "run-tests.sh", verify_script(base, command, f2p, p2p, bool(test_patch))
    )
    if instance.get("patch"):
        (task / "solution" / "gold.patch").write_text(instance["patch"])
        common.write_executable(task / "solution" / "solve", 'git apply "$SOLUTION_DIR/gold.patch"\n')
    return task


def read(path):
    with open(path) as handle:
        return [json.loads(line) for line in handle if line.strip()]
