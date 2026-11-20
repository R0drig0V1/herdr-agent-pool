#!/usr/bin/env python3
"""Time spent waiting for a heavy slot during a benchmark run.

Reads the run log of the plugin's resource-budget.py (`runs.jsonl` in its state directory,
one line per command that queued for a slot) and answers "was the slot the bottleneck?":
how long each kind of check waited before it ran, and how long it ran.

Rows are grouped by who ran the check: `merge` is an integrator's merge verification
(priority merge), `plan` the coordinator's own checks, `dev` everything else. A row belongs
to the run when its working directory contains REPO and it queued inside the time window.

Usage: slot-waits.py REPO --since ISO [--until ISO] [--log PATH] [--top N]

    slot-waits.py textkit-sandbox --since 2026-11-20T13:08:13Z

Python 3.9 compatible, no dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any

DEFAULT_LOG = os.path.join(
    os.environ.get(
        "HERDR_AGENT_POOL_RESOURCES_DIR",
        os.path.join(os.path.expanduser("~"), ".cache", "herdr-agent-pool", "resources"),
    ),
    "runs.jsonl",
)
GROUPS = {"merge": "merge", "plan": "plan"}  # priority -> group; anything else is "dev"


def epoch(iso: str) -> float:
    """Seconds since the epoch of an ISO time (a trailing Z means UTC)."""
    stamp = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.timestamp()


def read_rows(paths: list[str], repo: str, since: float, until: float) -> list[dict[str, Any]]:
    """The log rows of the run, oldest first; unreadable lines are skipped."""
    rows = []
    for path in paths:
        try:
            with open(path, errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for line in lines:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict) or repo not in str(row.get("cwd", "")):
                continue
            if since <= float(row.get("queued", 0)) <= until:
                rows.append(row)
    return sorted(rows, key=lambda r: r["queued"])


def summary(name: str, rows: list[dict[str, Any]]) -> str:
    waits = [float(r.get("waited") or 0) for r in rows]
    runs = [float(r["ran"]) for r in rows if r.get("ran") is not None]
    waited = sum(1 for w in waits if w >= 5)
    failed = sum(1 for r in rows if r.get("exit") not in (0, None))
    mean = sum(waits) / len(waits) if waits else 0.0
    return (
        f"{name:<6} runs={len(rows)} waited_5s_or_more={waited} "
        f"wait_total={sum(waits) / 60:.1f} min wait_mean={mean:.0f} s "
        f"wait_max={max(waits, default=0):.0f} s run_total={sum(runs) / 60:.1f} min "
        f"not_green={failed}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("repo", help="text the working directory must contain")
    parser.add_argument("--since", required=True, help="ISO time the run started")
    parser.add_argument("--until", default="", help="ISO time the run ended (default: now)")
    parser.add_argument("--log", default=DEFAULT_LOG, help=f"run log (default: {DEFAULT_LOG})")
    parser.add_argument("--top", type=int, default=5, help="longest waits to list")
    args = parser.parse_args()
    until = epoch(args.until) if args.until else float("inf")
    rows = read_rows([f"{args.log}.1", args.log], args.repo, epoch(args.since), until)
    heavy = [r for r in rows if r.get("pool") == "heavy"]
    if not heavy:
        print("no heavy run in the log for that repository and window", file=sys.stderr)
        return 1
    groups: dict[str, list[dict[str, Any]]] = {"dev": [], "merge": [], "plan": []}
    for row in heavy:
        groups[GROUPS.get(str(row.get("priority")), "dev")].append(row)
    for name, members in groups.items():
        if members:
            print(summary(name, members))
    print(summary("ALL", heavy))
    span = max(r["queued"] + float(r.get("waited") or 0) + float(r.get("ran") or 0) for r in heavy)
    busy = sum(float(r.get("ran") or 0) for r in heavy)
    print(f"slot-seconds used={busy:.0f} over {(span - heavy[0]['queued']) / 60:.1f} min")
    for row in sorted(heavy, key=lambda r: -float(r.get("waited") or 0))[: args.top]:
        where = os.path.basename(str(row.get("cwd", "?")))
        print(
            f"  waited {float(row.get('waited') or 0):>5.0f} s  ran {row.get('ran')} s  "
            f"exit {row.get('exit')}  [{row.get('priority')}] {where}: {row.get('label')}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
