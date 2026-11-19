#!/usr/bin/env python3
"""Per-PR timings, bounces and force pushes of one benchmark run, read from GitHub.

Part of herdr-agent-pool's benchmark (docs/benchmark/README.md). Each run of the benchmark
uses its own base branch, so the PRs of a run are the ones against that base opened after the
run started.

Usage:

    benchmark/pr-stats.py <owner/repo> <base branch> --since <ISO time>

One line per PR: its branch, state, when it was opened (minutes from --since), how long it
stayed open, its comments, the comments that read like a bounce and its force pushes (GitHub's
`head_ref_force_pushed` events). Then the run's summary: PRs, merged, closed without a merge,
the wall time from --since to the last merge and the mean and longest time open.

Needs an authenticated `gh`. Python 3.9, standard library only.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime

BOUNCE_WORDS = ("bounce", "changes needed", "not merged")


def gh(*args: str):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def when(stamp: str) -> datetime:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("repo")
    p.add_argument("base")
    p.add_argument("--since", required=True)
    a = p.parse_args()
    fields = "number,headRefName,state,createdAt,mergedAt,closedAt,comments"
    prs = gh(
        "pr", "list", "--repo", a.repo, "--base", a.base, "--state", "all",
        "--limit", "200", "--json", fields,
    )  # fmt: skip
    prs = sorted((pr for pr in prs if pr["createdAt"] >= a.since), key=lambda pr: pr["number"])
    start, open_minutes, ends = when(a.since), [], []
    for pr in prs:
        events = gh("api", f"repos/{a.repo}/issues/{pr['number']}/events", "--paginate")
        pushes = sum(e["event"] == "head_ref_force_pushed" for e in events)
        end = pr["mergedAt"] or pr["closedAt"]
        opened = (when(pr["createdAt"]) - start).total_seconds() / 60
        stayed = (when(end) - when(pr["createdAt"])).total_seconds() / 60 if end else None
        if end:
            ends.append(when(end))
            open_minutes.append(stayed)
        bounces = sum(
            any(w in (c["body"] or "").lower() for w in BOUNCE_WORDS) for c in pr["comments"]
        )
        shown = f"{stayed:.1f}" if stayed is not None else "-"
        print(
            f"#{pr['number']:<4} {pr['headRefName']:<26} {pr['state']:<7} opened +{opened:5.1f} min"
            f"  open {shown} min  comments={len(pr['comments'])} bounce-like={bounces}"
            f" force-pushes={pushes}"
        )
    merged = sum(1 for pr in prs if pr["mergedAt"])
    closed = sum(1 for pr in prs if pr["state"] == "CLOSED")
    wall = (max(ends) - start).total_seconds() / 60 if ends else 0.0
    mean = sum(open_minutes) / len(open_minutes) if open_minutes else 0.0
    longest = max(open_minutes, default=0.0)
    print(
        f"PRs={len(prs)} merged={merged} closed_unmerged={closed} wall={wall:.1f} min"
        f" open_mean={mean:.1f} min open_max={longest:.1f} min"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
