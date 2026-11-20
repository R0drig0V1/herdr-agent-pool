# 0010. A slimmer single-mode integrator: plan ticks in the merge, a token-free watcher, compaction

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
3. **Compaction by the watcher.** When the integrator is `idle` or `done` and its context is
   above `integrator_compact_tokens` (default 120000; 0 turns it off), the watcher types one
   `/compact <what to keep>` into it: the open PRs and their state (claimed, bounced, held,
   waiting), the verdicts not yet sent, the plan progress and what the user asked; old tool
   output goes. The context is the last assistant message's input plus cache tokens in its
   Claude Code transcript (`context-tokens.py`: the session id and `cwd` from `herdr agent
   list`, `~/.claude/projects/<cwd, each non-alphanumeric as ->/<session>.jsonl`). At
   most once per idle period and once every 10 minutes, never while it works or is blocked,
   and not at all when the transcript cannot be read (said once). A pass that compacts leaves
   its news for the next pass, so the wake-up finds the smaller context.

Pool mode is unchanged: the coordinator ticks from the merge reports and cleans up, and
`integrator-pool.sh watch` nudges the members.

## Alternatives

- **Batch the plan ticks** (one `docs(plan)` commit per few merges): fewer turns, but the plan
  lags behind the base and the integrator still spends the turns.
- **Tick in a second commit from the script**: no turns either, but a second push per PR under
  the merge lock, and a commit the check never saw.
- **Let the lander or an Actions workflow tick and wake the integrator**: needs a GitHub-side
  event path into the local herdr server, which does not exist.
- **Let Claude Code's auto-compaction do it**: it fires near the model's window, far above the
  size where re-reading the context already dominates the integrator's cost.
- **Restart the integrator with a fresh session**: drops the context completely, including what
  the user asked and verdicts in flight, and needs a new kickoff; `/compact` keeps a summary.
- **`/loop` the integrate skill** (the old fallback): it wakes the integrator on a timer
  whether or not anything changed, which costs a full turn (about 70,000 tokens) each time.

## Evidence

From docs/benchmark/README.md: the integrator took 106, 83, 139, 87, 103 and 87 turns in runs
1 to 6; about 97% of all tokens are cache reads, about 70,000 per turn; run 3 lost 14 minutes
and more to an integrator that nothing woke after lander merges. Run 7 (30 tasks, with the
plan ticks and the watcher): the integrator's context grew from 46.6k tokens at its first turn
to 301.6k at its last, and since every turn re-reads all of it, its 116 turns cost 20.4M
cache-read tokens, a third of the run. Its real state lives in GitHub and files (PRs, labels,
pool-state, the plan), not in the conversation, which is what makes compaction safe. Not yet
measured: the compaction itself; the next run records it.

## Consequences

- Per PR, the integrator reviews, runs `integrate-pr.sh` and sends the verdict; the plan
  commit and the cleanup leave its turns. It commits `docs(plan)` only for a
  `PLAN-UNTICKED` task the PR did complete, or when a phase is done.
- The PR body must name each task by its id; a plan without ids gets `PLAN-UNTICKED` lines
  and the old manual tick.
- "Decided" for the watcher means a recorded bounce or hold of that head (both modes record
  them), a `queue` or `needs-human` label, or a merge; a verdict given only in a comment,
  without a recorded bounce, is not seen, so such a PR is news once per head.
- A compaction can lose what only the conversation held: a decision the user gave in a
  sentence, a review in progress, a verdict decided but not yet sent. It only happens while
  the integrator is idle (no review in flight), the instructions name what to keep, and the
  skill tells it to trust GitHub and the files over its memory afterwards.
- Each compaction is one summarising turn over the whole context; it pays for itself when the
  integrator then takes more than a few turns.
- How to tell it still holds: integrator turns per merged PR and the idle gaps after merges,
  against runs 5 and 6; for the compaction, cache-read tokens per integrator turn and the
  `COMPACT` lines, against run 7.

## Amendment (2026-11-20): pool mode too

The pool's members and its coordinator were never compacted: in the benchmark's heavy run H2
(`docs/benchmark/heavy-profile.md`) the two integrators ended at 198,000 and 228,000 tokens
of context. `integrator-pool.sh compact`, run by `integrator-pool.sh watch` every minute,
applies the same rule to each live member and to the coordinator: idle or done, context
above `integrator_compact_tokens`, at most once per idle period and once every 10 minutes.
A member keeps its claimed PRs and their state and the verdicts not yet sent; the
coordinator keeps the plan progress, the agents and their tasks, the pool's state and the
merge reports not yet ticked. As in single mode, an integrator that is never idle is not
compacted: in heavy run H1 the single integrator reached 249,000 tokens before its first
idle minute. Not measured in a run.

