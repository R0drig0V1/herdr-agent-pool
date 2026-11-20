#!/usr/bin/env python3
"""Compact the development agents that wait for a verdict with a large context.

Part of the herdr-agent-pool plugin (decision 0014). A development agent that announced its
pull request sits idle until the verdict arrives, and it answers a bounce with its whole
session in context: every turn of the fix re-reads what it took to build the task. The
watchers (`integrator-watch.sh`, `integrator-pool.sh watch`) run one pass of this script
every minute; it spends no Claude tokens itself, a compaction costs about one turn.

Usage: compact-waiting.py

One pass, for every named herdr agent in a development worktree of this repository
(`agents-in-repo.py --dev-only`) that is `idle` or `done`:

* It waits for a verdict when an open pull request against the base branch has its branch
  as head, at the commit its worktree is on (what it announced is what GitHub has).
* When its context (`context-tokens.py`) is above `agent_compact_tokens` (default 100000;
  `0` turns this off), one `herdr agent prompt` types `/compact <what to keep>` into it.
* Once per announced commit: after a bounce is fixed and submitted again, the new head may
  be compacted again. An agent that is `working` or `blocked`, whose last turn stopped on
  an API error (`retry-stalled.py` handles it), or without a readable transcript is left
  alone. A verdict that arrives during the compaction waits in the agent's input queue.

`gh pr list` runs only on a pass that has an agent over the threshold.

State: <git common dir>/herdr-agent-pool/compact-waiting/<name>.json (the head compacted).

One line on stdout per action: `COMPACT <name> <tokens>`.

Inside Claude Code only the integrator or the coordinator runs it. Exit codes: 0 ok (also
when `gh` fails: said on stderr, the next pass tries again); 1 not in a git repository, the
role, or invalid settings; 2 `agents-in-repo.py` or `herdr agent list` failed.

Python 3.9 compatible: it runs under the system `python3`.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
COMPACT = (
    "/compact Keep: your task (its id, brief and acceptance criteria), your branch, worktree "
    "and pull request number, what you announced and to whom, the decisions you took and "
    "why, the files you changed, how you tested them, and anything still open. Drop: file "
    "contents, diffs, test output and logs already acted on; the worktree and the pull "
    "request hold the rest."
)


def _load(name: str) -> Any:
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), f"{HERE}/{name}.py")
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


CTX = _load("context-tokens")
RETRY = _load("retry-stalled")


def run(*command: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(command), capture_output=True, text=True)


def idle_agents() -> list[tuple[str, str, str]]:
    """(name, branch, worktree) of the idle or done development agents of this repository."""
    proc = run(f"{HERE}/agents-in-repo.py", "--dev-only")
    if proc.returncode != 0:
        print(
            f"compact-waiting: {proc.stderr.strip() or 'agents-in-repo.py failed'}", file=sys.stderr
        )
        raise SystemExit(proc.returncode if proc.returncode in (1, 2) else 2)
    rows = [line.split("\t") for line in proc.stdout.splitlines()]
    return [(r[0], r[3], r[4]) for r in rows if len(r) >= 5 and r[2] in ("idle", "done")]


def open_heads(base: str) -> dict[str, str] | None:
    """Branch -> head commit of the open pull requests against `base` (None: gh failed)."""
    proc = run(
        "gh", "pr", "list", "--base", base, "--state", "open", "--limit", "200",
        "--json", "headRefName,headRefOid",
    )  # fmt: skip
    try:
        rows = json.loads(proc.stdout) if proc.returncode == 0 else None
    except ValueError:
        rows = None
    if not isinstance(rows, list):
        print("compact-waiting: gh pr list failed; no compaction this pass", file=sys.stderr)
        return None
    return {
        str(r.get("headRefName")): str(r.get("headRefOid")) for r in rows if isinstance(r, dict)
    }


def read_head(path: str) -> str:
    try:
        with open(path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        return ""
    return str(state.get("head", "")) if isinstance(state, dict) else ""


def candidate(name: str, worktree: str, state_file: str, limit: int) -> tuple[str, int] | None:
    """(head, tokens) when the agent is over the limit and not yet compacted at its head."""
    head = run("git", "-C", worktree, "rev-parse", "HEAD").stdout.strip()
    if not head or read_head(state_file) == head:
        return None
    try:
        session, cwd = CTX.agent_session(name)
        path = CTX.transcript_path(CTX.projects_dir(), cwd, session)
        tokens = CTX.context_tokens(path)
    except (RuntimeError, OSError, CTX.Unreadable):
        return None  # no session or transcript yet: nothing to compact
    if tokens <= limit or RETRY.last_error(path) is not None:
        return None
    return head, tokens


def settings() -> tuple[str, int, str]:
    """(base branch, agent_compact_tokens, state directory); exits 1 when unusable."""
    common = run("git", "rev-parse", "--path-format=absolute", "--git-common-dir")
    if common.returncode != 0:
        print("compact-waiting: not inside a git repository", file=sys.stderr)
        raise SystemExit(1)
    config = run(f"{HERE}/project-config.py")
    if config.returncode != 0:
        print(config.stderr.strip() or "compact-waiting: invalid settings", file=sys.stderr)
        raise SystemExit(1)
    values = json.loads(config.stdout)
    state_dir = os.path.join(common.stdout.strip(), "herdr-agent-pool", "compact-waiting")
    return values["base_branch"], int(values["agent_compact_tokens"]), state_dir


def main() -> int:
    if len(sys.argv) != 1:
        print("usage: compact-waiting.py", file=sys.stderr)
        return 1
    role = os.environ.get("CLAUDE_ROLE", "")
    if os.environ.get("CLAUDECODE") == "1" and role not in ("integrator", "coordinator"):
        print("compact-waiting: only the integrator or the coordinator runs it", file=sys.stderr)
        return 1
    base, limit, state_dir = settings()
    if limit <= 0:
        return 0
    os.makedirs(state_dir, exist_ok=True)
    found = []
    for name, branch, worktree in idle_agents():
        state_file = os.path.join(state_dir, re.sub(r"[^A-Za-z0-9_.-]", "%", name) + ".json")
        hit = candidate(name, worktree, state_file, limit)
        if hit:
            found.append((name, branch, state_file, *hit))
    heads = open_heads(base) if found else None
    for name, branch, state_file, head, tokens in found if heads else []:
        if heads.get(branch) != head:
            continue  # nothing announced at this commit: it is not waiting for a verdict
        if run("herdr", "agent", "prompt", name, COMPACT).returncode != 0:
            continue  # herdr did not take it: the next pass tries again
        with open(state_file, "w") as f:
            json.dump({"head": head}, f)
        print(f"COMPACT {name} {tokens}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
