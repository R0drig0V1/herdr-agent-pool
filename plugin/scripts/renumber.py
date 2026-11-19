#!/usr/bin/env python3
"""Give a merged PR's numbered files the next free numbers on the base they merge onto.

Part of the herdr-agent-pool plugin (docs/multi-integrator.md, "Numbered files"). Authors
take the next free number on their own base, so two parallel branches may add the same ADR
or migration number; integrate-pr.sh runs this script after `git merge --no-ff --no-commit`
of the PR (HEAD is then the base) and before the verification, which therefore checks the
renumbered tree. Re-merges onto a moved base run it again.

The rule, for every kind of the project setting `numbered_files` ({kind: regex with one
group, the number}, matched against whole paths):

* The PR's files of the kind are the ones the merge adds relative to HEAD (a rename is not an
  addition). The next free number is one above every other file of the kind in the merged
  tree. The PR's files, in ascending order of number, keep their number when it is the next
  free one and are otherwise moved (`git mv`) to it, keeping the rest of the path and the
  zero padding; each one takes the next number after the previous.
* In the files the PR changed (relative to HEAD) and nowhere else: the old file name without
  its extension (the whole name when it is only the number) becomes the new one everywhere,
  when no letter or digit precedes it and no letter, digit, `-` or `_` follows it. The bare
  old number (no letter or digit on either side) is replaced only in lines the PR adds, and
  only in a line that also contains the file's slug (the name without number and
  extension), in a table row (`|`-delimited) of an index file (a changed file that is not a
  numbered file, in the numbered file's directory or its parent), in a heading (`#`) of
  the renamed file itself, or in a line that names it by its kind: the kind's name (any
  case, optionally plural) right before the old number, separated by one space, `-`, `_`
  or `#` (`ADR 0001`, `adr_0001`, `Migration-0003`). A line the PR adds that names
  the old number by its kind means the PR's own file: on the PR's base that number was
  free, which is why the author took it.
* A table whose numbered rows were in ascending order, apart from the rewritten ones, is
  sorted again by number.

Usage:
  renumber.py apply --kinds JSON    renumber and rewrite (staged); prints one line per rename,
                                    `RENUMBERED <kind> <old path> -> <new path>`
  renumber.py keys --kinds JSON     only print the old numbers that `apply` would change, one
                                    per line (integrate-pr.sh lets union-rows.py keep two index
                                    rows with such a key; works while the merge has conflicts)

Exit codes: 0 done (also when nothing changed); 1 a git command or a file failed; 2 usage.
Python 3.9 compatible, standard library only.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass

WORD = "A-Za-z0-9"


@dataclass
class Rename:
    kind: str
    old: str  # path
    new: str  # path
    old_num: str
    new_num: str
    slug: str


def git(*args: str) -> str:
    proc = subprocess.run(["git", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise OSError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def index_paths() -> list[str]:
    """Paths in the index (an unmerged path once)."""
    return sorted({p for p in git("ls-files", "-z").split("\0") if p})


def added_paths() -> set[str]:
    """Paths the merge adds relative to HEAD (renames detected and left out)."""
    fields = git("diff", "--cached", "--name-status", "-M", "-z", "HEAD").split("\0")
    added, i = set(), 0
    while i < len(fields) - 1:
        status = fields[i]
        if status.startswith(("R", "C")):
            i += 3
            continue
        if status == "A":
            added.add(fields[i + 1])
        i += 2
    return added


def stem(path: str) -> str:
    base = os.path.basename(path)
    return base.rsplit(".", 1)[0] if "." in base[1:] else base


def name(path: str, slug: str) -> str:
    return stem(path) if slug else os.path.basename(path)


def plan_kind(kind: str, regex: re.Pattern[str], paths: list[str], added: set[str]) -> list[Rename]:
    mine, taken = [], []
    for path in paths:
        match = regex.fullmatch(path)
        if not match or not match.group(1) or not match.group(1).isdigit():
            continue
        (mine if path in added else taken).append((int(match.group(1)), path, match))
    nxt = max((n for n, _, _ in taken), default=0) + 1
    renames = []
    for number, path, match in sorted(mine, key=lambda t: (t[0], t[1])):
        if number != nxt:
            old_num = match.group(1)
            new_num = str(nxt).zfill(len(old_num))
            start, end = match.span(1)
            new = path[:start] + new_num + path[end:]
            slug = stem(path).replace(old_num, "", 1).strip("-_. ")
            renames.append(Rename(kind, path, new, old_num, new_num, slug))
        nxt += 1
    return renames


def plan(kinds: dict[str, str]) -> list[Rename]:
    paths, added = index_paths(), added_paths()
    renames = []
    for kind in sorted(kinds):
        renames.extend(plan_kind(kind, re.compile(kinds[kind]), paths, added))
    return renames


def move(renames: list[Rename]) -> None:
    """git mv every file to its new path, through a temporary name (targets may swap)."""
    for i, r in enumerate(renames):
        git("mv", "--", r.old, f"{r.old}.renumber-{i}")
    for i, r in enumerate(renames):
        git("mv", "--", f"{r.old}.renumber-{i}", r.new)


def is_row(line: str) -> bool:
    return line.lstrip().startswith("|")


def first_cell(row: str) -> str:
    cell = row.strip().strip("|").split("|", 1)[0].strip()
    link = re.match(r"\[([^\]]*)\]", cell)
    return link.group(1) if link else cell


def is_index(path: str, r: Rename, kinds: dict[str, str]) -> bool:
    if any(re.fullmatch(rx, path) for rx in kinds.values()):
        return False
    here = os.path.dirname(r.new)
    return os.path.dirname(path) in (here, os.path.dirname(here))


def names_kind(line: str, r: Rename) -> bool:
    """The line names the old number by the kind (`ADR 0001`, `adr_0001`, `ADRs-0001`)."""
    kind = re.escape(r.kind)
    pattern = rf"(?<![{WORD}]){kind}s?[ _#-]{r.old_num}(?![{WORD}])"
    return re.search(pattern, line, re.IGNORECASE) is not None


def number_map(path: str, line: str, renames: list[Rename], kinds: dict[str, str]) -> dict:
    """{old number: new number} for the bare numbers this added line may have rewritten."""
    out: dict[str, str | None] = {}
    for r in renames:
        ok = (r.slug and r.slug in line) or (is_row(line) and is_index(path, r, kinds))
        ok = ok or (path == r.new and line.lstrip().startswith("#")) or names_kind(line, r)
        if ok:
            out[r.old_num] = r.new_num if out.get(r.old_num, r.new_num) == r.new_num else None
    return {k: v for k, v in out.items() if v is not None}


def rewrite_line(line: str, stems: dict[str, str], numbers: dict[str, str]) -> str:
    tokens = sorted([*stems, *numbers], key=len, reverse=True)
    if not tokens:
        return line
    pattern = f"(?<![{WORD}])({'|'.join(map(re.escape, tokens))})(?![{WORD}])"

    def swap(m: re.Match[str]) -> str:
        tok, after = m.group(1), line[m.end() : m.end() + 1]
        if tok in stems:
            return tok if after in ("-", "_") else stems[tok]
        return numbers[tok]

    return re.sub(pattern, swap, line)


def resort_tables(lines: list[str], changed: set[int]) -> list[str]:
    """Sort a table's numbered rows by number again, if they were sorted apart from `changed`."""
    out, i = list(lines), 0
    while i < len(out):
        if not is_row(out[i]):
            i += 1
            continue
        j = i
        while j < len(out) and is_row(out[j]):
            j += 1
        pos = [k for k in range(i, j) if first_cell(out[k]).isdigit()]
        kept = [int(first_cell(out[k])) for k in pos if k not in changed]
        if any(k in changed for k in pos) and kept == sorted(kept):
            rows = sorted((out[k] for k in pos), key=lambda row: int(first_cell(row)))
            for k, row in zip(pos, rows):
                out[k] = row
        i = j
    return out


def added_lines(path: str, lines: list[str]) -> set[int]:
    """Indexes of `lines` (the merged file) that the PR adds relative to HEAD."""
    proc = subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True)
    try:
        before = proc.stdout.decode().splitlines(keepends=True) if proc.returncode == 0 else []
    except UnicodeDecodeError:
        before = []
    added: set[int] = set()
    matcher = difflib.SequenceMatcher(None, before, lines, autojunk=False)
    for tag, _, _, j1, j2 in matcher.get_opcodes():
        if tag in ("insert", "replace"):
            added.update(range(j1, j2))
    return added


def rewrite_file(path: str, renames: list[Rename], kinds: dict[str, str]) -> None:
    try:
        with open(path, encoding="utf-8", newline="") as f:
            lines = f.read().splitlines(keepends=True)
    except (OSError, UnicodeDecodeError):
        return  # a binary file, or one the PR deleted
    # The name without extension, or the whole name when it is only the number.
    stems = {name(r.old, r.slug): name(r.new, r.slug) for r in renames}
    new_lines, changed, fresh = [], set(), added_lines(path, lines)
    for k, line in enumerate(lines):
        numbers = number_map(path, line, renames, kinds) if k in fresh else {}
        new = rewrite_line(line, stems, numbers)
        if new != line:
            changed.add(k)
        new_lines.append(new)
    if not changed:
        return
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write("".join(resort_tables(new_lines, changed)))
    git("add", "--", path)


def apply(kinds: dict[str, str]) -> int:
    renames = plan(kinds)
    if not renames:
        return 0
    move(renames)
    changed = git("diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD").split("\0")
    for path in [p for p in changed if p and os.path.isfile(p)]:
        rewrite_file(path, renames, kinds)
    for r in renames:
        print(f"RENUMBERED {r.kind} {r.old} -> {r.new}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="renumber.py")
    parser.add_argument("cmd", choices=("apply", "keys"))
    parser.add_argument("--kinds", required=True, help="numbered_files as JSON")
    args = parser.parse_args()
    try:
        kinds = json.loads(args.kinds)
        if not isinstance(kinds, dict):
            raise ValueError("--kinds must be a JSON object")
        if args.cmd == "keys":
            for old in sorted({r.old_num for r in plan(kinds)}):
                print(old)
            return 0
        return apply(kinds)
    except (OSError, ValueError, re.error) as exc:
        print(f"renumber: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
