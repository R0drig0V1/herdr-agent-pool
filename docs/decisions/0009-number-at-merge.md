# 0009. Number new ADRs and migrations at merge time

- Status: accepted (PR #11)
- Date: 2026-11-19

## Context

Projects declare numbered files (`numbered_files`: ADRs, migrations) whose numbers must not
clash. The dispatcher reserved the next number when it dispatched a task and wrote it in the
brief (`pool-state.py reserve`).

## Evidence

Benchmark run 1: a task holding the reserved ADR 0002 finished before the task holding 0001.
The project's check requires contiguous numbers from 0001, so the finished task's own check
failed in its worktree; the agent stopped and asked the user whether to commit a red check.
A reservation makes finished work wait for unfinished work, and interrupts the user.

## Decision

Authors take the next free number on their own base, so their check passes; two parallel
branches may take the same number. `integrate-pr.sh` renumbers at merge
(`plugin/scripts/renumber.py`): after the merge and before the verification, each numbered
file the PR adds that is not the next free number in the merged tree is moved to it, and its
references are rewritten in the files the PR changed. Each rename is printed
(`RENUMBERED ...`) and recorded in the merge commit. The verification runs on the renumbered
tree.

## Alternatives

- **Reserve at dispatch** (before): numbers are stable during the work, but order the merges.
- **Reserve at PR time**: still orders the merges when two PRs are open at once.
- **The project drops contiguity** (timestamps, "unique and increasing"): simplest, but a
  project's rule, not the plugin's.

## Consequences

- No task waits on another one's number, and no question to the user.
- A reference the rewrite rule does not recognise (an unpadded `ADR 1`, a bare number in
  prose) keeps the old number; only the project's check can catch it.

## Amendment: mentions by kind (2026-11-19)

Benchmark runs 7 and 9: an ADR renumbered at merge kept its mentions as "ADR 0001" in a
docstring, the README table, `CHANGELOG.md` and a test name, since those lines hold neither
the file name nor its slug. Run 7 bounced a PR to make its mentions safe; in run 9 the
integrator asked for a follow-up PR, whose change of the shared files then failed another
PR's verification. `renumber.py` now also rewrites the old number in the PR's added lines
when the kind's name precedes it (`ADR 0001`, `adr_0001`, `ADRs-0001`). Such a line can only
mean the PR's own file: the number was free on the author's base. Authors need no rule about
how to write a mention.
- The number an author used may change at merge; the merge commit says so.
