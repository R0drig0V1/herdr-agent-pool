# 0007. Review a phase's plan before its first dispatch

- Status: accepted (PR #9)
- Date: 2026-11-19

## Context

`/herdr-agent-pool:improve-plan` (the `plan-adversary` agent) was available but optional, and
dispatchers started agents on the plan as written.

## Evidence

In benchmark run 2 the integrator ran the review first, at the user's request: 3 rounds, 18
findings, 11.5 minutes. It found by itself the causes of run 1's bounces (modules created by
several tasks in parallel, appends at the same spot) and the vague specifications, chained
the tasks that collide and made the specs exact. Against run 1: agent-minutes 110 to 62,
bounces 8 to 3, force pushes 13 to 3, wall time from the first dispatch 35.4 to 17.9 minutes
(about 29 minutes including the review).

## Decision

Before a phase's first dispatch, when `docs/plan-reviews/` has no review of the phase, the
dispatcher runs `/herdr-agent-pool:improve-plan`, unless the user said to skip it.

## Consequences

- A review costs minutes and tokens once per phase; it paid for itself in the measured run.
- Run 2 also changed the plugin version, so part of its gain belongs to decisions 0002 and
  0003; the size of the gap in agent-minutes points at the plan.
