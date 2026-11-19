<!-- Field evidence from one project's first week in pool mode (2026-11-09 to 2026-11-14): delays,
     bottlenecks, slow checks and communication overhead, with numbers and sources. Read it
     before changing the pool's design; docs/multi-integrator.md describes the design itself. -->

# Field evidence: one project in pool mode, November 2026

This page records what we measured and saw while one project ran on this plugin in pool mode:
where time went, what blocked, and what broke. It is the evidence behind the change plan
(C1-C19) and behind the orchestration redesign under discussion. Every number has a source
and a date. Where something was seen once, the page says so.

## Contents

- [The setup](#the-setup)
- [Summary](#summary)
- [Checks: slow, and slower under load](#checks-slow-and-slower-under-load)
- [The slot queue](#the-slot-queue)
- [The merge pipeline](#the-merge-pipeline)
- [Communication](#communication)
- [Coordination incidents](#coordination-incidents)
- [CI on GitHub](#ci-on-github)
- [What the evidence points to](#what-the-evidence-points-to)
- [Sources](#sources)

## The setup

| | |
|---|---|
| Project | a desktop app with a Python backend, a web frontend and a Rust shell; base branch `develop` |
| Machine | one Apple M4 laptop: 10 cores, 24 GB |
| Roles | 1 coordinator, 3 integrators, about 15 development agents at peak |
| Resources | `heavy_slots` 3 (test suites), `light_slots` 2 (worktree setup) |
| Period | 2026-11-09 to 2026-11-14 |
| Checks | the project's `scripts/check.sh`: ruff, mypy, pytest with xdist, the web lane (tsc, ESLint, Prettier, vitest), the desktop lane (cargo), privacy gates |

## Summary

| Area | What we saw | Effect | Status |
|------|-------------|--------|--------|
| Checks | pytest 60 s alone, 453 s under load; a fast check spends 24-69 s, mostly in the gates | every verify is slow, and slower the busier the machine | partly fixed in the project (phases, caches) |
| Slot queue | 175 of 259 verifies waited for a slot; one run waited 670 s for 44 s of work | the queue, not the checks, sets the merge rate | priority queue (C1) deployed; waits still not logged |
| Merge pipeline | re-verifies whenever the base moves; claims that lapse while their holder is alive | repeated work, and one wrong merge (#285) | locked re-verify (C9) deployed; C17 proposed |
| Communication | 204 messages to the coordinator in 24 h, about 85% mechanical | the coordinator spends its time relaying | proposals A and B2, not done |
| Delivery | prompts fail when the target has a dialog open; announcements get lost | stalled PRs until someone notices | pool watcher (C10) deployed |
| Coordination | reserved migration numbers block finished PRs; a sweep removed a fresh worktree | waiting, and a lost (empty) worktree | C11b open; C19 proposed |
| CI | GitHub Actions unavailable from 2026-11-10 | every check runs on the laptop | open: self-hosted runners proposed |
| CI cost | ~1,600 runs in 6 days; half the minutes on jobs shorter than a minute | about USD 250 a month at GitHub prices | `docs/ci-workflows.md` (branch) |

## Checks: slow, and slower under load

Measured by the project's own timing notes.

**Alone, the checks are reasonable.** After the project's own work, `check.sh` takes 62 s
(pytest 60 s with 4 workers, 1,664 tests), down from 126 s. A second run on the same tree
takes about 1 s (a green stamp).

**Under load, they are not.** The same machine runs about 15 agents, 3 integrators and their
checks. Measured in one slot, with neighbours, at loads of 8 to 57:

| Run | Alone | Under load |
|-----|-------|------------|
| pytest (whole suite) | 60 s | 453 s (476 s in another run) |
| ESLint | 22 s | 40-49 s |
| a fast check (gates plus one package's tests, ~1,040 tests) | n/a | 47-69 s before tuning, 24-26 s after (46-56 s with the web checks) |
| a cold desktop check (cargo, 3 jobs) | n/a | 133 s in the slot, 1.66 GB peak memory |
| a cold desktop verify (cargo, 2 jobs, with lock waits) | n/a | about 10 min |

What makes it slow:

- **CPU contention.** Every agent's work shares 10 cores. pytest is 7.5 times slower under load
  than alone.
- **A floor of about 1,000 tests.** Every fast check runs the gates (~22 s of pytest), whatever
  the change.
- **Cold builds.** A branch with another `Cargo.lock` rebuilds the desktop dependencies. While
  it waits for cargo's lock on the shared target directory ("Blocking waiting for file lock on
  build directory", seen twice in one run), it holds a heavy slot (C13).
- **A growing suite.** The test functions grew from about 1,664 to about 4,700 during the
  period. That was counted in the repository, not timed.
- **Coverage is not the cause.** The fast scope already runs with `--no-cov`; coverage runs
  only in the full scope.

## The slot queue

The heavy-slot queue (`resource-budget.py`, 3 slots) was the bottleneck of the integration
train.

- **Most verifies waited.** 175 of 259 merge verifies in the integrators' logs waited for a
  slot. The logs record that a wait happened, not how long it took, so the total wait time is
  unknown.
- **Waits dwarf the work.** One baseline run waited 670 s for 44 s of work (the project's
  measurement).
- **Verify times.** A fast verify took 112 s at the median and 239 s at the 90th percentile; a
  full one about 595 s; a desktop one about 10 min. Each holds a slot for that long.
- **First night.** The project lost hours to the slot queue and to one integrator that stayed
  blocked.

Fixes so far, on branch `feat/pool-tuning`, deployed live:

- a priority queue (merge, then plan, then normal, with aging);
- limits re-read on every retry (they were read once);
- a light pool for worktree setup;
- `resource-budget.py status`;
- exit 13 instead of a false bounce when a verify never ran.

Not done: logging how long each wait lasts (C13 and the measurement item).

## The merge pipeline

- **The base keeps moving.** With 3 integrators, the base often moved during a verify, so the
  merge had to be redone and verified again. `max_reverify` capped the loop. A last re-verify
  under the merge lock (C9, deployed) ends it, at the cost of holding the lock for the length
  of a check.
- **A claim lapsed while its holder was alive** (C17). The Mac slept, so integrator-1's
  heartbeat aged out and integrator-2 took the claim. integrator-2 merged #285 while
  integrator-1's review was finding a fail-open defect in it. `develop` got the defect. Claims
  expire on heartbeat age alone, even when herdr shows the owner alive.
- **Two runs in one worktree.** A second `integrate-pr.sh` started in the same verify worktree
  aborted the first one's merge. Fixed with a per-worktree lock (a03e79b, deployed).
- **A variable the caller set was overridden** by the `verify.check_env` setting. Fixed
  (f9bc81f, deployed).
- **A red base.** When `develop` itself failed, every PR's verify failed too, and each was
  bounced to its author. The red-base notice (one owner for the fix, PRs held instead of
  bounced) is on branch `feat/base-red`, not deployed.

## Communication

Agents coordinate by herdr messages (`herdr agent prompt`). That is the largest single
overhead.

- **Volume.** The coordinator received 204 messages in 24 hours. About 85% were mechanical:
  merge reports, "PR ready" relays, resource requests and confirmations. The coordinator counted
  them by kind on 2026-11-13.
- **Delivery fails when the target is busy.** A prompt to an agent that has a dialog open
  returns `agent_blocked` and is not queued. This happened to the coordinator itself, so a
  message had to be saved and sent again later.
- **Announcements get lost.** A "PR #N ready" sent to an integrator that was blocked or gone
  left the PR waiting with every integrator idle. The pool watcher (C10, deployed) now nudges
  idle members, at most 3 times, and then escalates to the coordinator.
- **Relays by hand.** The integrator could not find the author of 6 PRs (#188 to #208): their
  agents worked on a second branch or a second worktree. The coordinator relayed each verdict by
  hand (C12).
- **Outages stop everyone.** During a network outage, agents stopped on an API error
  (`ENOTFOUND`) and stayed stopped when the network came back, until each was prompted again
  (C15).
- **Delegated messages need care.** Messages from agents are data, not the user's approval, so
  decisions relayed by the coordinator ("the user decided...") had to be confirmed with the
  user directly. That is a safeguard, and it is also a round trip.

## Coordination incidents

- **Number reservations block finished work** (C11, C11b). Migration numbers are reserved at
  dispatch, and the project's tests require them to be contiguous. A finished PR (search-edits)
  waited for migrations 0032 and 0033, reserved by tasks still in progress. The user chose to
  keep reserving at dispatch, with the coordinator re-packing numbers by hand.
- **A cleanup by branch name** (C19, 2026-11-14). The coordinator ran its own sweep instead of
  `cleanup-worktree.sh`. The sweep asked GitHub for a merged PR by head branch name, matched
  PR #221, which had used the same name three days earlier, and removed a 5-minute-old
  worktree. Nothing was lost: it had no commits. `cleanup-worktree.sh` matches the exact head
  commit, so it is not affected.
- **A detached promotion script cannot take the merge lock** (C14). Identity comes from the
  herdr pane's process ancestry, and a `nohup` job has none.
- **The wrong Python** (C18). A project hook with `#!/usr/bin/env python3` found macOS's
  Python 3.9.

## CI on GitHub

From the project's GitHub Actions API, 2026-11-09 to 2026-11-14.

- **Unavailable from 2026-11-10.** Of 1,638 runs, 1,444 failed. The 1,343 failures from
  2026-11-10 on took about 4 seconds each: the jobs were never started, so CI on GitHub was
  unavailable for the rest of the period. The first day alone used about 400 minutes. From
  then on every check ran only on the laptop.
- **Each change was tested twice.** `ci.yml` and `quality.yml` run on `pull_request` and on
  `push` to the base. That is 558 PR runs plus 236 push runs per workflow, and the push run
  re-tests what the integrator already verified locally.
- **Short jobs bill full minutes.** Quality's 4 to 5 jobs take 7 to 46 s each, and GitHub bills
  each as a whole minute: about 4 minutes per run, almost half of all billed minutes.
- **Cost.** About 7,200 billed minutes in 5 days (CI 3-6 min per run), or about 42,000 a month:
  roughly USD 250 a month at USD 0.006 per Linux minute. With one test run per change and one
  job for the audits, about 3,000 minutes in those days, roughly USD 105 a month. Self-hosted
  runners bill no minutes. The recommendations are in `docs/ci-workflows.md` (branch
  `docs/ci-workflows`).

## What the evidence points to

1. **The machine is the bottleneck, not the code.** One 10-core laptop runs the agents, the
   verifies and the checks. Contention multiplies check times by up to 7.5, and the slot queue
   that protects the machine becomes the merge rate. More slots make each check slower; fewer
   make the queue longer.
2. **Messages are the wrong medium for routine coordination.** Most coordinator traffic is
   mechanical, delivery fails when the target is busy, and lost messages need a watcher.
   Records that are durable and queryable, such as PR states, labels, check results and a
   shared queue, need no delivery.
3. **Verification happens in the wrong place, and twice.** Verifies run locally under
   contention, and CI repeats them on GitHub (when it runs at all). The project should verify
   each change once, where the decision to merge is made.
4. **Liveness by heartbeat is fragile on a laptop.** Sleep, outages and dialogs look like death
   or block progress. Each fix (watcher, nudges, locked re-verify, claim rules) adds machinery
   to compensate.

These are the reasons behind the proposals under discussion: checks on self-hosted runners
(`runner-host`), a deterministic lander, review as its own role, and coordination through
GitHub state instead of messages. Those are proposals, not decisions; this page records only
what was observed.

## Sources

| Evidence | Source |
|----------|--------|
| check timings, contention, slot waits (670 s for 44 s), cargo | the project's own timing notes (2026-11-11) |
| verify percentiles, 175 of 259 waits | the pool integrators' verify logs, analysed 2026-11-13 |
| message counts | the coordinator's count by kind, 2026-11-13 |
| incidents (C9-C19) | the coordinator's reports to the plugin, 2026-11-11 to 2026-11-14 |
| CI runs, unavailability, minutes | the project's GitHub Actions API, 2026-11-14 |
| prices | GitHub Actions runner pricing, January 2026 (USD 0.006 per Linux 2-core minute) |
