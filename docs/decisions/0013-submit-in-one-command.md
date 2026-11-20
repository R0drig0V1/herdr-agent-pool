# 0013. Submit a task in one command

- Status: accepted, to be measured
- Date: 2026-11-19

## Context

A development agent finished a task with two skills: `commit` (inspect, run the checks,
commit) and `pr` (read the settings, rebase, run the checks again, push, `gh pr create`,
resolve its own herdr name, route, announce, report). Each step was a separate command, so a
separate turn, and every turn re-reads the agent's whole context (about 42,000 tokens after
decision 0011).

## Evidence

Benchmark run 9, 18 tasks, 402 development turns
([docs/benchmark/](../benchmark/README.md), "What the runs show", 8):

| Stage | Turns | Per task | Cache reads |
|-------|------:|---------:|------------:|
| Read the task and write the code | 26% | 5.9 | 18% |
| `commit` skill | 14% | 3.1 | 13% |
| `pr` skill | 31% | 6.8 | 33% |
| After the announcement (verdict, bounces, report) | 29% | 6.6 | 36% |

A task merged at the first try took about 17 turns, 11 of them after the code was written.
None of the nine `commit` and `pr` turns holds a decision, apart from what to stage and the
two texts (the commit message and the PR body). A bounce repeated most of them: rebase,
checks, push, announce.

## Decision

`plugin/scripts/submit-pr.sh` does the mechanical steps in one command: it refuses
uncommitted changes, finds the branch's open PR (and refuses one opened by another account),
rebases on the base, runs `scripts/check.sh` in a heavy slot on the rebased tree, pushes,
opens the PR and announces it to the integrator `integrator-pool.sh route` names. With a PR
already open (a bounce was fixed) the same command pushes, with a lease when the rebase
rewrote the branch, and announces again. Each outcome has its own exit code, and the `pr`
skill is a table of them.

The agent keeps what takes judgement: what to stage, the commit message, the PR body and
what the reviewer should look at. The `pr` skill is now "commit, then submit"; the brief
points to it alone. The `commit` skill stays for commits outside a submission.

Details that also save tokens or time:

- The checks run once, after the rebase, instead of before the commit and again before the
  push. A tree that already passed is not checked again (a re-run after a failed
  announcement).
- The checks' output goes to a log; only a failure prints its last 40 lines into the agent's
  context.

## Alternatives

- **Shorter skills, same steps**: decision 0003 already did that; the turns stayed.
- **Let the script commit too** (`git add -A` and a message from arguments): one command
  less, but staging everything is how secrets and build output get committed.
- **Put the command in the brief instead of a skill**: saves the turn that loads the skill,
  but every brief would carry the exit-code table on every turn of every agent.
- **No rebase by the author** (the integrator merges onto the current base anyway): the
  checks would run on a tree the integrator never sees, and conflicts would surface one
  step later, as a bounce.

## Consequences

- Expected, to be measured in the next run: a task merged at the first try goes from about
  17 turns to about 11, and a bounce costs fewer turns.
- A commit made before the checks ran can be red; the agent fixes it in a second commit (or
  amends it while nothing is pushed). The PR's merge is still verified as a whole.
- The force push after a bounce happens inside the script, where the guard hooks do not see
  the command: the script itself refuses the base and protected branches, and only forces a
  branch whose open PR is the caller's own.
- An agent that skips the skill and runs the steps by hand still works; nothing depends on
  the script having run.
