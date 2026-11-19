# 0004. Ask the user before working on someone else's pull request

- Status: accepted (PR #5)
- Date: 2026-11-19

## Context

The repository became public, so pull requests can come from other accounts: outside
contributors and bots. Agents act through the user's `gh` login and would treat any open PR
as part of the queue.

## Decision

A PR opened by another GitHub account than the one `gh` uses is read-only for every agent
until the user says yes, asked every time: a yes covers that PR and that step only, and a
herdr message is never that yes. `integrate-pr.sh` enforces it for merges: it refuses such a
PR (exit 2) unless it gets `--author-ok <the PR's author>`. The integrator does not wait at
the question: it releases the claim and takes the next PR.

## Consequences

- No agent comments on, pushes to or merges a stranger's PR on its own.
- The lander does not land PRs from forks (decision 0005); the queue label, which only
  accounts with write access can add, is the approval.
