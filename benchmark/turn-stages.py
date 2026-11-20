#!/usr/bin/env python3
"""Where the development agents' turns go: stages of a task, from the session transcripts.

Part of herdr-agent-pool's benchmark (docs/benchmark/README.md). `measure.py` counts a
session's turns; this script splits the turns of the development sessions (the worktrees next
to the benchmark repository) into the stages of a task:

    work      until the first call of the `commit` or `pr` skill: read the task, write the code
    commit    from the `commit` skill until the `pr` skill
    pr        from the `pr` skill until the announcement is sent (`herdr agent prompt`, or the
              first run of `submit-pr.sh`, which sends it)
    after     what follows the announcement: the verdict, bounces, the final report

Usage:

    benchmark/turn-stages.py <repo directory name> --since <ISO time> [--until <ISO time>]

Prints, per stage, the turns (API responses), their share, the turns per task and the cache
reads; then one line per session with its turns, its first and largest context (the prompt
of a turn: input + cache writes + cache reads) and its turns per stage.

Python 3.9, standard library only.
"""

from __future__ import annotations

import argparse
import collections
import glob
import json
import os
from typing import Any

STAGES = ("work", "commit", "pr", "after")
ORDER = {name: i for i, name in enumerate(STAGES)}


def turns_of(path: str, since: str, until: str) -> list[dict[str, Any]]:
    """One dict per API response in the window: context, cache reads and what it called."""
    seen: dict[str, dict[str, Any]] = {}
    for line in open(path, errors="replace"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        stamp, msg = row.get("timestamp", ""), row.get("message") or {}
        if row.get("type") != "assistant" or msg.get("model") == "<synthetic>":
            continue
        if not (since <= stamp and (not until or stamp <= until)):
            continue
        turn = seen.get(msg.get("id"))
        if turn is None:
            usage = msg.get("usage") or {}
            read = usage.get("cache_read_input_tokens", 0)
            context = read + usage.get("input_tokens", 0)
            context += usage.get("cache_creation_input_tokens", 0)
            turn = seen[msg.get("id")] = {"context": context, "read": read, "calls": set()}
        for part in msg.get("content") or []:
            if isinstance(part, dict) and part.get("type") == "tool_use":
                turn["calls"].add(call_kind(part.get("name"), part.get("input") or {}))
    return list(seen.values())


def call_kind(name: str, inp: dict[str, Any]) -> str:
    if name == "Skill":
        return "skill:" + str(inp.get("skill", "")).split(":")[-1]
    command = inp.get("command", "") if name == "Bash" else ""
    if "herdr agent prompt" in command or "submit-pr.sh" in command:
        return "announce"
    return "other"


def stage_turns(turns: list[dict[str, Any]]) -> list[str]:
    """The stage of each turn, in order: a stage starts with the turn that calls its skill."""
    stage, out = "work", []
    for turn in turns:
        for skill, name in (("skill:commit", "commit"), ("skill:pr", "pr")):
            if skill in turn["calls"] and ORDER[stage] < ORDER[name]:
                stage = name
        out.append(stage)
        if stage == "pr" and "announce" in turn["calls"]:
            stage = "after"
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("repo", help="the benchmark repository's directory name, e.g. textkit-sandbox")
    p.add_argument("--since", required=True)
    p.add_argument("--until", default="")
    a = p.parse_args()
    base = os.path.expanduser("~/.claude/projects")
    total: dict[str, list[int]] = {s: [0, 0] for s in STAGES}
    sessions = []
    for path in sorted(glob.glob(f"{base}/*-{a.repo}-*/*.jsonl")):
        turns = turns_of(path, a.since, a.until)
        if not turns:
            continue
        role = os.path.basename(os.path.dirname(path)).split(f"-{a.repo}-", 1)[1]
        per: collections.Counter = collections.Counter()
        for turn, stage in zip(turns, stage_turns(turns)):
            per[stage] += 1
            total[stage][0] += 1
            total[stage][1] += turn["read"]
        largest = max(t["context"] for t in turns)
        sessions.append((role, len(turns), turns[0]["context"], largest, dict(per)))
    count = sum(v[0] for v in total.values()) or 1
    read = sum(v[1] for v in total.values()) or 1
    print(f"sessions={len(sessions)} turns={count} cache_read={read}")
    for stage in STAGES:
        n, r = total[stage]
        print(
            f"{stage:7} turns={n} ({n / count:.0%}) per_task={n / max(len(sessions), 1):.1f}"
            f" cache_read={r} ({r / read:.0%})"
        )
    for role, n, first, largest, per in sorted(sessions, key=lambda s: -s[1]):
        print(f"{role:24} turns={n} first_context={first} max_context={largest} {per}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
