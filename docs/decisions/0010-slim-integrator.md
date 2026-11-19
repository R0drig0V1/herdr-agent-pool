# 0010. A slimmer single-mode integrator: plan ticks in the merge, a token-free watcher

- Status: accepted, to be measured
- Date: 2026-11-19

## Context

The integrator is the most expensive agent and the serial bottleneck (benchmark, "What the
runs show", 4): about a third of the cache reads of a run, 83 to 139 turns for 18 tasks
(runs 1-6), and every turn re-reads about 70,000 tokens. Per merged PR, single mode spent
turns on steps with no judgement in them: after `integrate-pr.sh`, a separate
`docs(plan): tick ...` commit (edit, the `commit` skill, push), then `cleanup-worktree.sh
--list` and `cleanup-worktree.sh <branch>` once the author was idle, then waiting for the
next announcement. In run 3 the lander merged the PRs, but nothing woke the integrator
afterwards: it sat idle 14 minutes, and again later, until the user wrote to it (decision
0005, "Consequences").

## Decision

Mechanical steps move from the integrator's turns into scripts, in single mode only:

1. **Plan ticks inside the merge.** `integrate-pr.sh` runs `plan-tick.py` after the
   `--no-commit` merge (and `renumber.py`), before the verification: each task id the PR body
   lists under "Plan tasks completed" (`T1.2`, a whole token, so `T1.1` is not `T1.10`) ticks
   the one open task line in `docs/phases/*.md` that starts with it (or the only open line
   that mentions it and starts with no other id). Each tick is printed (`PLAN-TICKED`) and
   recorded in the merge commit; ids it cannot tick are printed (`PLAN-UNTICKED`, with the
   reason). The check runs on the ticked tree, and re-merges under the lock tick again.
   `plan_ticks_in_merge: false` turns it off.
2. **A token-free watcher.** `integrator-watch.sh`, started once by the `integrate` skill in
   the background, runs a pass every minute: it cleans up every worktree
   `cleanup-worktree.sh --list` reports `ready` (after a grace, so the merged verdict reaches
   the author first), and when the integrator is `idle` or `done` it sends one message with
   what changed: open PRs that wait for a verdict at a new head, and queued PRs that the
   lander merged or took out of the queue. Never while it works or is blocked, each item once.

Pool mode is unchanged: the coordinator ticks from the merge reports and cleans up, and
`integrator-pool.sh watch` nudges the members.

## Alternatives

- **Batch the plan ticks** (one `docs(plan)` commit per few merges): fewer turns, but the plan
  lags behind the base and the integrator still spends the turns.
- **Tick in a second commit from the script**: no turns either, but a second push per PR under
  the merge lock, and a commit the check never saw.
- **Let the lander or an Actions workflow tick and wake the integrator**: needs a GitHub-side
  event path into the local herdr server, which does not exist.
- **`/loop` the integrate skill** (the old fallback): it wakes the integrator on a timer
  whether or not anything changed, which costs a full turn (about 70,000 tokens) each time.

## Evidence

From docs/benchmark/README.md: the integrator took 106, 83, 139, 87, 103 and 87 turns in runs
1 to 6; about 97% of all tokens are cache reads, about 70,000 per turn; run 3 lost 14 minutes
and more to an integrator that nothing woke after lander merges. Not yet measured with this
change: the next run of the benchmark with this configuration records it.

## Consequences

- Per PR, the integrator reviews, runs `integrate-pr.sh` and sends the verdict; the plan
  commit and the cleanup leave its turns. It commits `docs(plan)` only for a
  `PLAN-UNTICKED` task the PR did complete, or when a phase is done.
- The PR body must name each task by its id; a plan without ids gets `PLAN-UNTICKED` lines
  and the old manual tick.
- "Decided" for the watcher means a recorded bounce or hold of that head (both modes record
  them), a `queue` or `needs-human` label, or a merge; a verdict given only in a comment,
  without a recorded bounce, is not seen, so such a PR is news once per head.
- How to tell it still holds: integrator turns per merged PR and the idle gaps after merges,
  against runs 5 and 6.
