#!/usr/bin/env python3
"""Measure the agents of one benchmark run from Claude Code's session transcripts.

Part of herdr-agent-pool's benchmark (docs/benchmark/README.md). Claude Code keeps one
directory of transcripts per working directory under `~/.claude/projects/`, named after the
path with `/` turned into `-`. The main worktree of the benchmark repository and every
development worktree next to it (`<repo>-<agent>`) therefore have their own directory.

Usage:

    benchmark/measure.py <repo directory name> --since <ISO time> [--until <ISO time>]

For each session with activity in the window it prints one line: turns (API responses),
tokens (input, cache writes, cache reads, output), messages it sent to other agents
(`herdr agent prompt` in its Bash calls), messages it received (user turns that start with
herdr's agent-message header), the skills it ran and its first and last timestamps. Then the
totals, the agent-minutes of the development agents (sum of first-to-last spans) and the
ideal wall time with five agents (agent-minutes / 5).

Runs are told apart by time only, so run them one after another, never two at once.
Python 3.9, standard library only.
"""

from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import re
from datetime import datetime
from typing import Any

HEADER = "[herdr message from agent"
SLOTS = 5
COUNTED = ("turns", "in", "cache_write", "cache_read", "out", "sent", "received")


def text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    return " ".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def rows(path: str, since: str, until: str):
    for line in open(path, errors="replace"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        stamp = row.get("timestamp", "")
        if stamp and since <= stamp and (not until or stamp <= until):
            yield row


def tool_calls(msg: dict[str, Any]):
    for part in msg.get("content") or []:
        if isinstance(part, dict) and part.get("type") == "tool_use":
            yield part.get("name"), part.get("input") or {}


def measure(path: str, since: str, until: str) -> dict[str, Any] | None:
    counts: collections.Counter = collections.Counter()
    skills: collections.Counter = collections.Counter()
    stamps: list[str] = []
    seen: set[str] = set()
    for row in rows(path, since, until):
        stamps.append(row["timestamp"])
        msg = row.get("message") or {}
        if row.get("type") == "assistant":
            if msg.get("id") not in seen:  # one API response can span several rows
                seen.add(msg.get("id"))
                usage = msg.get("usage") or {}
                counts["turns"] += 1
                counts["in"] += usage.get("input_tokens", 0)
                counts["cache_write"] += usage.get("cache_creation_input_tokens", 0)
                counts["cache_read"] += usage.get("cache_read_input_tokens", 0)
                counts["out"] += usage.get("output_tokens", 0)
            for name, inp in tool_calls(msg):
                if name == "Bash":
                    counts["sent"] += len(
                        re.findall(r"herdr agent prompt\s+\S", inp.get("command", ""))
                    )
                elif name == "Skill":
                    skills[inp.get("skill", "?")] += 1
        elif row.get("type") == "user" and HEADER in text_of(msg.get("content"))[:200]:
            counts["received"] += 1
    if not counts["turns"]:
        return None
    return {"counts": counts, "skills": dict(skills), "first": min(stamps), "last": max(stamps)}


def minutes(first: str, last: str) -> float:
    def parse(s: str) -> datetime:
        return datetime.fromisoformat(s[:19])

    return (parse(last) - parse(first)).total_seconds() / 60


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("repo", help="the benchmark repository's directory name, e.g. textkit-sandbox")
    p.add_argument("--since", required=True, help="ISO time, e.g. 2026-11-19T02:10:40Z")
    p.add_argument("--until", default="")
    a = p.parse_args()
    base = os.path.expanduser("~/.claude/projects")
    total: collections.Counter = collections.Counter()
    dev_minutes = 0.0
    for d in sorted(glob.glob(f"{base}/*-{a.repo}") + glob.glob(f"{base}/*-{a.repo}-*")):
        role = os.path.basename(d).split(f"-{a.repo}", 1)[1].lstrip("-") or "(main worktree)"
        for path in sorted(glob.glob(f"{d}/*.jsonl")):
            m = measure(path, a.since, a.until)
            if not m:
                continue
            c = m["counts"]
            span = minutes(m["first"], m["last"])
            if role != "(main worktree)":
                dev_minutes += span
            print(
                f"{role:20} " + " ".join(f"{k}={c[k]}" for k in COUNTED)
                + f" minutes={span:.1f} skills={m['skills']}"
            )  # fmt: skip
            total.update({k: c[k] for k in COUNTED})
    new = total["in"] + total["cache_write"] + total["out"]
    print("TOTAL " + " ".join(f"{k}={total[k]}" for k in COUNTED) + f" new_tokens={new}")
    print(f"agent-minutes={dev_minutes:.0f} ideal_wall_{SLOTS}_agents={dev_minutes / SLOTS:.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
