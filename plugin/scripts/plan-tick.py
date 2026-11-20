#!/usr/bin/env python3
"""Tick the plan tasks a pull request completed, inside its merge.

Part of the herdr-agent-pool plugin. In single mode integrate-pr.sh runs it after
`git merge --no-ff --no-commit` of the PR (and after renumber.py), before the verification,
so the merge commit carries the ticks and the check runs on the ticked tree; a re-merge
onto a moved base ticks again. Pool mode does not use it (the coordinator ticks from the
merge reports). The project setting `plan_ticks_in_merge` (default true) turns it off.

The PR body (stdin) lists its tasks under the heading `## Plan tasks completed`, up to the
next `## ` heading. Task ids there look like `T1.2`: capital letters, then numbers joined by
dots (`T1`, `T1.2`, `AB2.10.3`), as whole tokens, so `T1.1` is not part of `T1.10`.

For each id, in `docs/phases/*.md` (relative to the current directory), among the task lines
(`- [ ] ...` or `- [x] ...`, indentation allowed):

* exactly one open line whose text starts with the id (after `*`, `_`, `` ` `` or `~`):
  that line is ticked (`- [ ]` becomes `- [x]`);
* none, but one ticked line starting with it: already ticked;
* no line starts with it, but exactly one open line that starts with no other task id
  contains it as a whole token: ticked (a line of task T1.10 that mentions T1.1 is T1.10's);
* otherwise (several candidates, or none): left alone.

Output: `PLAN-TICKED <id> <file>` per tick, `PLAN-UNTICKED <id> (<why>)` per listed id it
did not tick (not found, already ticked, ambiguous). With `--stage` the changed files are
staged (`git add`).

Usage: plan-tick.py [--stage] < PR-body

Exit codes: 0 done (also when nothing was listed or ticked); 1 a file or git failed.
Python 3.9 compatible, standard library only.
"""

from __future__ import annotations

import argparse
import glob
import re
import subprocess
import sys

HEADING = re.compile(r"^## Plan tasks completed\b")
TASK_ID = re.compile(r"(?<![A-Za-z0-9_.])([A-Z]+[0-9]+(?:\.[0-9]+)*)(?![A-Za-z0-9_]|\.[0-9])")
TASK_LINE = re.compile(r"^(\s*- \[)([ xX])(\] )(.*)$")
LEAD = "*_`~ "


def section(body: str) -> str:
    """The text under `## Plan tasks completed`, up to the next `## ` heading."""
    lines, inside = [], False
    for line in body.splitlines():
        if line.startswith("## "):
            inside = bool(HEADING.match(line))
            continue
        if inside:
            lines.append(line)
    return "\n".join(lines)


def listed_ids(body: str) -> list[str]:
    """The task ids of the PR body's plan section, in order, without repeats."""
    seen: dict[str, None] = {}
    for match in TASK_ID.finditer(section(body)):
        seen.setdefault(match.group(1), None)
    return list(seen)


def token(task_id: str) -> re.Pattern[str]:
    """`task_id` as a whole token (not inside a longer id)."""
    return re.compile(r"(?<![A-Za-z0-9_.])" + re.escape(task_id) + r"(?![A-Za-z0-9_]|\.[0-9])")


def lead_id(text: str) -> str | None:
    """The task id the task text starts with (after emphasis marks), if any."""
    match = TASK_ID.match(text.lstrip(LEAD))
    return match.group(1) if match else None


Place = tuple[str, int]  # (file, line index)


def candidates(plan: dict[str, list[str]], task_id: str) -> dict[str, list[Place]]:
    """Task lines mentioning `task_id`: open/done, leading with it or containing it."""
    found: dict[str, list[Place]] = {"open_lead": [], "open_any": [], "done_lead": []}
    pattern = token(task_id)
    for path, lines in plan.items():
        for i, line in enumerate(lines):
            match = TASK_LINE.match(line)
            if not match or not pattern.search(match.group(4)):
                continue
            state = "open" if match.group(2) == " " else "done"
            lead = lead_id(match.group(4))
            if lead == task_id:
                found[f"{state}_lead"].append((path, i))
            elif lead is None and state == "open":
                found["open_any"].append((path, i))
    return found


def choose(found: dict[str, list[Place]]) -> tuple[Place | None, str]:
    """The line to tick, or None and why not."""
    if len(found["open_lead"]) == 1:
        return found["open_lead"][0], ""
    if len(found["open_lead"]) > 1:
        return None, f"ambiguous: {len(found['open_lead'])} open tasks start with it"
    if found["done_lead"]:
        return None, "already ticked"
    if len(found["open_any"]) == 1:
        return found["open_any"][0], ""
    if found["open_any"]:
        return None, f"ambiguous: {len(found['open_any'])} open tasks mention it"
    return None, "no such task in docs/phases"


def tick(plan: dict[str, list[str]], ids: list[str]) -> tuple[list[str], set[str]]:
    """Tick `ids` in `plan` (in place); returns the output lines and the changed files."""
    out, changed = [], set()
    for task_id in ids:
        place, why = choose(candidates(plan, task_id))
        if place is None:
            out.append(f"PLAN-UNTICKED {task_id} ({why})")
            continue
        path, i = place
        plan[path][i] = TASK_LINE.sub(r"\1x\3\4", plan[path][i], count=1)
        changed.add(path)
        out.append(f"PLAN-TICKED {task_id} {path}")
    return out, changed


def read_plan() -> dict[str, list[str]]:
    """docs/phases/*.md, each as a list of lines (line ends kept apart: see write_plan)."""
    plan = {}
    for path in sorted(glob.glob("docs/phases/*.md")):
        with open(path, encoding="utf-8", newline="") as f:
            plan[path] = f.read().split("\n")
    return plan


def write_plan(plan: dict[str, list[str]], changed: set[str], stage: bool) -> None:
    for path in sorted(changed):
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(plan[path]))
    if stage and changed:
        subprocess.run(["git", "add", "--", *sorted(changed)], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--stage", action="store_true", help="git add the changed files")
    args = parser.parse_args()
    ids = listed_ids(sys.stdin.read())
    if not ids:
        return 0
    try:
        plan = read_plan()
        out, changed = tick(plan, ids)
        write_plan(plan, changed, args.stage)
    except (OSError, UnicodeDecodeError, subprocess.CalledProcessError) as exc:
        print(f"plan-tick: {exc}", file=sys.stderr)
        return 1
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
