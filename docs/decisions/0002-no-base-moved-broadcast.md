# 0002. No "base moved" broadcast; announced branches are not rewritten

- Status: accepted (PR #7)
- Date: 2026-11-19

## Context

After each merge the integrator told every other development agent "the base moved, rebase".
Every PR is already verified merged onto the current base, so a real clash comes back to its
author as a bounce anyway.

## Evidence

A first run (1 integrator, 3 agents, 6 tasks): the broadcasts were 6 of the 18 messages agents
received, and 3 reached an agent whose PR was already closed. One author obeyed while the
integrator was verifying its branch, rebased and force-pushed; the verified commit landed,
but GitHub showed the PR as closed instead of merged, and its branch and worktree were left
behind.

## Decision

The integrator does not send the broadcast. After announcing a PR, an author does not
rebase, amend or force-push its branch unless the PR bounced.

## Consequences

- About a third fewer messages per task, and no rewrite races during verification.
- An author whose branch is far behind learns it from a bounce, not from a broadcast.
- The rule lives in prompts only; a guard that blocks a force-push of an announced branch
  would enforce it (not done).
