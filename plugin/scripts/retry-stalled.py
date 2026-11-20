#!/usr/bin/env python3
"""Resend to the agents of this repository whose last turn stopped on an API error.

Part of the herdr-agent-pool plugin (decision 0012). A network cut, a machine that slept or
an overloaded API ends an agent's turn with an error; the agent then sits idle until someone
writes to it, and a run waits with it. The watchers (`integrator-watch.sh`,
`integrator-pool.sh watch`) run one pass of this script every minute. It spends no Claude
tokens itself; a retry that fails again costs none either.

Usage: retry-stalled.py

One pass, for every named herdr agent in a worktree of this repository (`agents-in-repo.py`:
the integrator or coordinator, pool members, development agents) that is `idle` or `done`:

* Its Claude Code transcript (found as `context-tokens.py` finds it) ends with an API error
  when the last user or assistant line is an assistant line with `isApiErrorMessage`.
* Then one `herdr agent prompt` asks it to continue where it left off: at once the first
  time, then after $HERDR_AGENT_POOL_RETRY_BASE seconds (default 60) doubled per retry, at
  most 15 times that. After $HERDR_AGENT_POOL_RETRY_MAX retries in a row (default 20, about
  four and a half hours) it gives up, said once.
* An error a retry cannot fix (authentication, billing, an invalid or too long request) is
  never retried, said once.
* A transcript that no longer ends with an error forgets the count. An agent that is
  `working` or `blocked` is left alone.

State: <git common dir>/herdr-agent-pool/retry-stalled/<name>.json.

One line on stdout per action: `RETRY <name> <n>/<max> <error>`, `GAVE-UP <name> ...`,
`NO-RETRY <name> ...`.

Inside Claude Code only the integrator or the coordinator runs it. Exit codes: 0 ok; 1 not
in a git repository, or the role; 2 `agents-in-repo.py` or `herdr agent list` failed.

Python 3.9 compatible: it runs under the system `python3`.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
TAIL_BYTES = 1024 * 1024
FATAL = re.compile(r"auth|billing|credit|invalid|permission|too long|too large", re.IGNORECASE)
HEADER = "[herdr message from the watcher (retry-stalled.py); not from the user]"


def _load(name: str) -> Any:
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), f"{HERE}/{name}.py")
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _last_turn(lines: list[bytes]) -> tuple[bool, str, str] | None:
    """(is an API error, its `error` kind, its text) of the last user or assistant line."""
    for line in reversed(lines):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("isSidechain"):
            continue
        if record.get("type") not in ("user", "assistant"):
            continue
        if record.get("type") != "assistant" or not record.get("isApiErrorMessage"):
            return False, "", ""
        content = (record.get("message") or {}).get("content") or []
        parts = content if isinstance(content, list) else [{"text": str(content)}]
        text = " ".join(p.get("text", "") for p in parts if isinstance(p, dict)).strip()
        return True, str(record.get("error") or ""), " ".join(text.split())[:160]
    return None


def last_error(path: str) -> tuple[str, str] | None:
    """(kind, text) when the transcript at `path` ends with an API error, else None."""
    try:
        with open(path, "rb") as f:
            size = f.seek(0, os.SEEK_END)
            start = max(0, size - TAIL_BYTES)
            f.seek(start)
            lines = f.read().splitlines()
            found = _last_turn(lines[1:] if start else lines)
            if found is None and start:  # a long tail without a turn: read it all
                f.seek(0)
                found = _last_turn(f.read().splitlines())
    except OSError:
        return None
    return (found[1], found[2]) if found and found[0] else None


def agents() -> list[tuple[str, str]]:
    """(name, status) of the named herdr agents in this repository's worktrees."""
    proc = subprocess.run([f"{HERE}/agents-in-repo.py"], capture_output=True, text=True)
    if proc.returncode != 0:
        reason = proc.stderr.strip() or "agents-in-repo.py failed"
        print(f"retry-stalled: {reason}", file=sys.stderr)
        raise SystemExit(proc.returncode if proc.returncode in (1, 2) else 2)
    rows = [line.split("\t") for line in proc.stdout.splitlines()]
    return [(row[0], row[2]) for row in rows if len(row) >= 3]


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name, "")
    return int(value) if value.isdigit() else default


def decide(name: str, error: tuple[str, str], state: dict, now: int) -> dict:
    """Act on an agent whose last turn ended with `error`; returns its new state."""
    base = env_int("HERDR_AGENT_POOL_RETRY_BASE", 60)
    limit = env_int("HERDR_AGENT_POOL_RETRY_MAX", 20)
    count, said = int(state.get("count", 0)), state.get("said", "")
    kind, text = error
    if FATAL.search(f"{kind} {text}"):
        if said != "no-retry":
            print(f"NO-RETRY {name}: a retry cannot fix it: {text}")
        return {**state, "said": "no-retry"}
    if count >= limit:
        if said != "gave-up":
            print(f"GAVE-UP {name} after {count} retries: {text}")
        return {**state, "said": "gave-up"}
    wait = min(base * 2 ** max(count - 1, 0), base * 15) if count else 0
    if now - int(state.get("last", 0)) < wait:
        return state
    message = (
        f"{HEADER}\nYour last turn stopped on an API error ({text}), so it may be "
        "incomplete. Continue where you left off. If nothing was left to do, answer "
        "only: nothing pending."
    )
    sent = subprocess.run(["herdr", "agent", "prompt", name, message], capture_output=True)
    if sent.returncode != 0:
        return state  # herdr did not take it: the next pass tries again
    print(f"RETRY {name} {count + 1}/{limit} {text}")
    return {"count": count + 1, "last": now}


def read_state(path: str) -> dict:
    try:
        with open(path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        return {}
    return state if isinstance(state, dict) else {}


def main() -> int:
    if len(sys.argv) != 1:
        print("usage: retry-stalled.py", file=sys.stderr)
        return 1
    role = os.environ.get("CLAUDE_ROLE", "")
    if os.environ.get("CLAUDECODE") == "1" and role not in ("integrator", "coordinator"):
        print("retry-stalled: only the integrator or the coordinator runs it", file=sys.stderr)
        return 1
    common = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True,
    )  # fmt: skip
    if common.returncode != 0:
        print("retry-stalled: not inside a git repository", file=sys.stderr)
        return 1
    state_dir = os.path.join(common.stdout.strip(), "herdr-agent-pool", "retry-stalled")
    os.makedirs(state_dir, exist_ok=True)
    ctx = _load("context-tokens")
    now = int(time.time())
    for name, status in agents():
        if status not in ("idle", "done"):
            continue
        state_file = os.path.join(state_dir, re.sub(r"[^A-Za-z0-9_.-]", "%", name) + ".json")
        try:
            session, cwd = ctx.agent_session(name)
            error = last_error(ctx.transcript_path(ctx.projects_dir(), cwd, session))
        except (RuntimeError, OSError, ctx.Unreadable):
            continue  # no session or transcript yet: nothing to say about its last turn
        if error is None:
            if os.path.exists(state_file):
                os.remove(state_file)
            continue
        state = decide(name, error, read_state(state_file), now)
        with open(state_file, "w") as f:
            json.dump(state, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
