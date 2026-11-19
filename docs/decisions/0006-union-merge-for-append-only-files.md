# 0006. `merge=union` for append-only files

- Status: accepted (PR #9)
- Date: 2026-11-19

## Context

Many pull requests append to the same few files: a changelog, an index of decisions, a table
of functions. Two branches that append at the same spot conflict, and the second one bounces.

## Evidence

Benchmark run 1 (plan as written): all 8 bounces were such append conflicts, in
`CHANGELOG.md`, the README's function table and shared test files, followed by 13 force
pushes. Two tasks bounced twice. A bounced task took 2 to 4 times the turns of a clean one.

## Decision

The project template ships a `.gitattributes` marking `CHANGELOG.md` and the docs indexes
`merge=union`: git keeps the lines both sides added, in the integrator's merge and in an
author's rebase. Projects add their own append-only files.

## Alternatives

- **Keep the rows sorted** (what the plan review did in run 2): fewer collisions, not none.
- **`integrate-pr.sh --union-rows`**: resolves index rows, but only when the integrator thinks
  of passing it; it did not in run 1.

## Consequences

- A union merge never removes lines, so it is only for files whose changes add whole lines.
  The check still runs on every merge and catches a bad result (a duplicated row).
- Projects installed earlier get it only by copying `template/.gitattributes`.
