#!/usr/bin/env python3
"""Print the current context size, in tokens, of a herdr agent's Claude Code session.

Part of the herdr-agent-pool plugin. `integrator-watch.sh` uses it to decide when to compact
the single-mode integrator (`integrator_compact_tokens`, decision 0010). It only reads:
`herdr agent list` and the session's transcript; it never sends input to any pane.

Usage: context-tokens.py NAME

The agent named NAME in `herdr agent list` gives its session id (`agent_session.value`) and
its `cwd`. Claude Code keeps the transcript at

    <projects>/<cwd with every character outside [A-Za-z0-9] replaced by "-">/<session>.jsonl

(`/Users/me/my.app` -> `-Users-me-my-app`), where <projects> is
`$HERDR_AGENT_POOL_CLAUDE_PROJECTS`, else `$CLAUDE_CONFIG_DIR/projects`, else
`~/.claude/projects`. When that file is missing, the one `<projects>/*/<session>.jsonl` is
used (session ids are unique), so a cwd that changed or a name Claude Code shortened still
resolves.

The context is input_tokens + cache_creation_input_tokens + cache_read_input_tokens of the
last assistant message's `usage` (the prompt that turn sent). A compaction recorded after it
(a `compact_boundary` system line) replaces it with the boundary's `postTokens` (0 when
absent): the next turn starts from the summary.

Prints the number. Exit codes: 0 ok, 1 the transcript cannot be found or read, or has no
assistant message yet (the reason on stderr), 2 `herdr agent list` failed or has no such
agent with a session id.

Python 3.9 compatible: it runs under the system `python3`.
"""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
from typing import Any

TAIL_BYTES = 4 * 1024 * 1024
USAGE_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")


class Unreadable(Exception):
    """The transcript cannot be used (exit 1)."""


def projects_dir() -> str:
    override = os.environ.get("HERDR_AGENT_POOL_CLAUDE_PROJECTS")
    if override:
        return override
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(config, "projects")


def transcript_path(projects: str, cwd: str, session: str) -> str:
    """The transcript of `session` started in `cwd` (raises Unreadable when there is none)."""
    if not re.fullmatch(r"[A-Za-z0-9-]+", session):
        raise Unreadable(f"unusable session id {session!r}")
    path = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", cwd), session + ".jsonl")
    if os.path.isfile(path):
        return path
    found = glob.glob(os.path.join(glob.escape(projects), "*", session + ".jsonl"))
    if len(found) == 1:
        return found[0]
    raise Unreadable(f"no transcript {path} (nor one {session}.jsonl under {projects})")


def _record_tokens(record: Any) -> int | None:
    """The context a transcript line sets, or None when the line says nothing about it."""
    if not isinstance(record, dict) or record.get("isSidechain"):
        return None
    if record.get("type") == "system" and record.get("subtype") == "compact_boundary":
        meta = record.get("compactMetadata") or {}
        post = meta.get("postTokens") if isinstance(meta, dict) else None
        return post if isinstance(post, int) and not isinstance(post, bool) else 0
    message = record.get("message")
    if record.get("type") != "assistant" or not isinstance(message, dict):
        return None
    usage = message.get("usage")
    if message.get("model") == "<synthetic>" or not isinstance(usage, dict):
        return None
    values = [usage.get(k) or 0 for k in USAGE_KEYS]
    if not all(isinstance(v, int) for v in values):
        return None
    return sum(values)


def _last_tokens(lines: list[bytes]) -> int | None:
    for line in reversed(lines):
        try:
            tokens = _record_tokens(json.loads(line))
        except ValueError:
            continue
        if tokens is not None:
            return tokens
    return None


def context_tokens(path: str) -> int:
    """Context size of the transcript at `path` (raises Unreadable)."""
    try:
        with open(path, "rb") as f:
            size = f.seek(0, os.SEEK_END)
            start = max(0, size - TAIL_BYTES)
            f.seek(start)
            lines = f.read().splitlines()
            tokens = _last_tokens(lines[1:] if start else lines)
            if tokens is None and start:  # a long tail without one: read it all
                f.seek(0)
                tokens = _last_tokens(f.read().splitlines())
    except OSError as exc:
        raise Unreadable(f"cannot read {path}: {exc}") from exc
    if tokens is None:
        raise Unreadable(f"{path} has no assistant message with a usage yet")
    return tokens


def agent_session(name: str) -> tuple[str, str]:
    """(session id, cwd) of the herdr agent `name` (raises RuntimeError)."""
    proc = subprocess.run(["herdr", "agent", "list"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"herdr agent list failed: {proc.stderr.strip() or proc.returncode}")
    try:
        agents = json.loads(proc.stdout)["result"]["agents"]
    except (ValueError, KeyError, TypeError) as exc:
        raise RuntimeError(f"unexpected herdr agent list output: {exc}") from exc
    for agent in agents if isinstance(agents, list) else []:
        if not isinstance(agent, dict) or agent.get("name") != name:
            continue
        session = (agent.get("agent_session") or {}).get("value")
        cwd = agent.get("cwd")
        if isinstance(session, str) and session and isinstance(cwd, str) and cwd:
            return session, cwd
        raise RuntimeError(f"herdr agent {name} has no session id or cwd")
    raise RuntimeError(f"no herdr agent named {name}")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1].startswith("-"):
        print("usage: context-tokens.py NAME", file=sys.stderr)
        return 2
    try:
        session, cwd = agent_session(sys.argv[1])
    except (RuntimeError, OSError) as exc:
        print(f"context-tokens: {exc}", file=sys.stderr)
        return 2
    try:
        print(context_tokens(transcript_path(projects_dir(), cwd, session)))
    except Unreadable as exc:
        print(f"context-tokens: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
