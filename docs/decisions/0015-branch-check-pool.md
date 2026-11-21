# 0015. A project chooses the pool of its branch checks

- Status: accepted, to be measured
- Date: 2026-11-21

## Context

A development agent runs the project's `scripts/check.sh` on its branch twice per task at
most: the `commit` skill, and `submit-pr.sh` on the rebased tree. Both ran it in the heavy
pool of `resource-budget.py`, always: no setting changed that. Merge verifications
(`verify-merge.sh`) compete for the same heavy slots. Their `merge` priority orders the
waiters, but it cannot take a slot from a holder: a merge that arrives while every heavy slot
holds a development agent's check waits for one of them to finish.

A project can make its branch check lean (lint, types, only the affected tests) and leave
the full suite to its CI. Such a check still held a heavy slot. The only way around it was
to set `HERDR_AGENT_POOL_SLOT` in the agent's environment, which is the identity of a slot
holder: it skips the floor for everything the agent runs, and the guard blocks it.

## Evidence

- A consuming project on a machine with 2 heavy slots: with a lean branch check, merges
  still waited behind the agents' checks, and its queue of pull requests grew.
- The benchmark's heavy runs ([heavy-profile.md](../benchmark/heavy-profile.md)): the two
  slots were busy 55% (H1) and 72% (H2) of the time, and in H2 12 checks waited 5 seconds or
  more, 7.3 minutes in all. 18 of H2's 39 heavy checks were development agents' checks.
- No measurement yet of the light pool's waits: worktree setups are the only light work
  today, and the run log only says how long they waited.

## Decision

1. **A setting**, `checks.branch_pool` in `.claude/herdr-agent-pool.json`, `heavy` (the
   default: nothing changes for existing projects) or `light`. `project-config.py` validates
   it; `submit-pr.sh` and the `commit` skill pass it as `--pool` to `resource-budget.py run`.
   `verify-merge.sh` is unchanged: heavy, with merge priority.
2. **A check can escalate itself.** Every command `resource-budget.py run` starts gets
   `HERDR_AGENT_POOL_RESOURCE_BUDGET`, the wrapper's absolute path, so a light-pool check
   wraps only its heavy step (the project's "run everything" mode) in
   `"$HERDR_AGENT_POOL_RESOURCE_BUDGET" run --pool heavy -- ...`.
3. **Nesting is per pool.** A light slot never sets `HERDR_AGENT_POOL_SLOT`; it sets its own
   `HERDR_AGENT_POOL_LIGHT_SLOT`. Inside a heavy slot every nested `run` runs at once (as
   before); inside a light slot a nested light `run` runs at once and a nested heavy `run`
   waits for a heavy slot. The guard blocks setting either marker or the wrapper's path.
4. **Two pools, not three.** Lean checks share the light pool with worktree setup.

## Alternatives

- **A third pool, `check`, with its own limit.** It would keep a new agent's setup from
  waiting behind lean checks, which can take a minute or two. Not now: it adds a limit to
  every machine's `resources.json`, a section to the board and the status, and one more
  thing that runs at once on the machine, whose total the two pools bound today; and there is
  no measurement of the setup waits it would save. A setup that waits does not lose work, and
  `light_slots` can be raised per machine. `branch_pool` accepts only `heavy` and `light`, so
  a `check` value can be added later without breaking a valid file.
- **Reserve a heavy slot for merges.** It frees the merges, but development agents then share
  the one slot left, and a lean check still holds heavy memory it does not need.
- **Pre-empt: let a merge take a slot from an agent's check.** A killed check is wasted
  work, and the floor never kills a holder.
- **Let the project export `HERDR_AGENT_POOL_SLOT`.** It is the identity of a holder: it
  skips the floor for every command, nested heavy steps included.

## Consequences

- With `light`, development agents' checks compete with each other and with worktree setups
  for the light slots (default 2), and merge verifications have the heavy slots to
  themselves, apart from the heavy steps checks escalate.
- An escalated check keeps its light slot while it waits for the heavy one. It cannot
  deadlock: no heavy holder waits for a light slot (a nested light `run` inside a heavy slot
  runs at once).
- A lean check that should have been heavy now runs alongside the heavy slots' holders: the
  setting is the project's statement that its branch check is light. Its CI has to run the
  full suite.
- `scripts/check.sh` run by hand has no `HERDR_AGENT_POOL_RESOURCE_BUDGET`: a check that
  escalates falls back to running the step directly (docs/reference.md, "Resources").

## How to tell whether it holds

Run the benchmark's heavy profile with `checks.branch_pool` set to `light` and compare it with
H1/H2: `benchmark/slot-waits.py <repo> --since <start>` for the merge verifications' heavy
waits, and `--pool light` for the setups (labels `worktree-setup ...` and `verify-merge
setup ...`). When setups wait more than a minute behind checks in a run, add the `check`
pool (or raise `light_slots`) and amend this decision.
