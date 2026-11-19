# 0005. A lander script merges; the queue label is the approval

- Status: accepted, with a known gap (PR #1; gap measured in benchmark run 3)
- Date: 2026-11-19

## Context

The integrator is the most expensive agent (about a third of all tokens, more than 100 turns
in an 18-task run) and the serial bottleneck: it reviews, verifies, merges, ticks the plan,
cleans up and sends verdicts, one PR at a time. Merging is mechanical: merge onto the current
base, run the check, push exactly what was verified.

## Decision

`plugin/scripts/land.py` (docs/lander.md) merges the open PRs labelled `queue`, oldest first,
verifying each merge, and bounces conflicts and red checks with a counted comment up to
`needs-human`. It runs as a GitHub Actions workflow (one concurrency group per base) or in a
terminal with `--watch`. The integrator reviews and adds `queue`.

The queue label is the approval by default (`--approval label`). In a project where every
agent acts as one GitHub account, a formal review approval is impossible: GitHub does not
let an account approve its own pull requests. `--approval review` keeps the review gate for
reviewers with their own identity. PRs from forks are never landed.

## Evidence

Run 3 (the run 2 configuration plus the lander in Actions): 47 lander runs, none failed, and
a queued PR merged about 30 seconds after the label. But the run took 62.5 minutes against
17.9 for run 2. The integrator sat idle for 14 minutes, and again later, until the user wrote
to it: nothing told it that the lander had merged or bounced a PR, so verdicts, plan ticks
and the next dispatches waited.

## Consequences

- The lander is reliable, but it is not yet an efficiency gain. Before it replaces the local
  merge, the integrator needs a wake-up on lander outcomes: a token-free watcher that prompts
  it when a queued PR merges or leaves the queue (`integrator-watch.sh`, decision 0010).
- Each PR also pays the CI run in Actions plus the lander run (about a minute) where the
  local merge pays nothing extra.
