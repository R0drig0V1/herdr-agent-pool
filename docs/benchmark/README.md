<!-- The benchmark of herdr-agent-pool: how workflow changes are measured with real agents on a
     synthetic project, the method, how to run it, and every run so far with its numbers.
     Decisions that rely on a run link here (docs/decisions/). -->

# Benchmark

Workflow changes are measured, not guessed (decision
[0001](../decisions/0001-measure-with-a-benchmark.md)). This page is the method and the
record: add every new run to [Runs](#runs), with what changed and what it showed.

## Contents

- [The setup](#the-setup)
- [What is measured](#what-is-measured)
- [Running it](#running-it)
- [Runs](#runs)
- [What the runs show](#what-the-runs-show)
- [Caveats](#caveats)

## The setup

- **Project:** [`textkit-sandbox`](https://github.com/R0drig0V1/textkit-sandbox), public and
  throwaway: `textkit`, a small Python package of text helpers (standard library only). Its
  `scripts/check.sh` runs the tests and checks three shared artefacts every task touches: the
  README's function table, `CHANGELOG.md` and the ADR numbering (unique, contiguous from 0001).
  Its CI runs the same check on every pull request (GitHub Actions, free for public
  repositories).
- **Backlog:** 18 tasks in two phases (`docs/phases/` on the seed commit), built to collide:
  several tasks write the same module and the same shared files, four write ADRs and need
  "the next number", and dependency chains run up to a final usage guide that needs every
  other task.
- **One base branch per run** (`run1`, `run2`, ...) from the same seed, so every run keeps its
  own history and PRs, and runs are compared on the same work.
- **Agents:** one integrator in the main worktree, at most 5 development agents at a time, the
  same kickoff prompt, Opus 5.5 with effort high (set in the run branch's
  `.claude/settings.json`, so every session and worktree inherits it).
- **Plugin version:** pinned per run from a local clone registered as a directory marketplace,
  so work on the plugin cannot change it during a run.

## What is measured

| Metric | Source | Meaning |
|--------|--------|---------|
| Wall time | `benchmark/pr-stats.py` | from the run's start to the last merge |
| Open time | `benchmark/pr-stats.py` | a PR's time from opened to merged: queueing, verification, bounces |
| Bounces, force pushes | `benchmark/pr-stats.py` | bounce-like comments; `head_ref_force_pushed` events |
| Agent-minutes, ideal wall | `benchmark/measure.py` | sum of the development agents' active spans; that sum / 5 is the wall time if 5 agents were busy all the time |
| Turns, messages | `benchmark/measure.py` | API responses; `herdr agent prompt` calls sent and agent messages received |
| Tokens | `benchmark/measure.py` | new tokens (input + cache writes + output) and cache reads, from the session transcripts |

About 97% of the tokens are cache reads: every turn reads the conversation again (about
70,000 tokens per turn in these runs). The number of turns drives the cost far more than the
size of the prompts.

## Running it

1. Create the run's base branch from the seed (`textkit-sandbox` `main`), install the plugin
   version under test with its `install.sh`, fill in the template's TODOs as the earlier runs
   did, set `base_branch` to the run's branch and the model and effort in
   `.claude/settings.json`, and push.
2. Check out the run branch in the main worktree, record the start time
   (`date -u +%Y-%m-%dT%H:%M:%SZ`), and launch the integrator inside herdr with the kickoff:

   > Run phases 1 and 2 (docs/phases/) to the end: dispatch their tasks keeping at most 5
   > development agents at a time, respect the dependencies between tasks, integrate the PRs
   > as they arrive, and stop when all 18 tasks are merged.

3. Stay near: answer dialogs the agents raise and note each one (they are findings too). Keep
   the machine awake.
4. When the plan shows 18 ticked tasks and no agent works, measure:

   ```bash
   benchmark/pr-stats.py R0drig0V1/textkit-sandbox <run branch> --since <start>
   benchmark/measure.py textkit-sandbox --since <start> [--until <end>]
   ```

5. Close the run's workspaces and remove its worktrees before the next run: the next run reuses
   the branch and agent names.

## Runs

All on 2026-11-19, the same seed, Opus 5.5 with effort high, at most 5 development agents.

| Run | Configuration | Wall (min) | Ideal wall (min) | Open time mean / max (min) | Bounces | Force pushes | Messages sent | Integrator turns | New tokens | Cache reads |
|-----|---------------|-----------:|-----------------:|---------------------------:|--------:|-------------:|--------------:|-----------------:|-----------:|------------:|
| 1 | herdr-agent-pool before decisions 0002-0003, plan as written | 35.4 | 21.9 | 2.4 / 7.9 | 8 | 13 | 69 | 106 | 1.65 M | 52.4 M |
| 2 | decisions 0002-0003; plan reviewed first (+11.5 min, not in the wall time) | **17.9** | 12.4 | **0.9 / 2.2** | **3** | **3** | 54 | **83** | **1.25 M** | 40.6 M |
| 3 | run 2 plus the lander in Actions (decision 0005), reviewed plan | 62.5 | 39.4 | 5.1 / 24.1 | 4 | 9 | 61 | 139 | 1.54 M | 56.5 M |
| 4 | the two-level plugin claude-code-herdr (4f9ded4), reviewed plan | 36.0 (about 23 without a 13-min machine sleep) | 41.1 | 3.0 / 13.3 | 7 | 12 | 40 | 87 | 1.45 M | **39.3 M** |
| 5 | `main` after decisions 0006-0008 plus 0009 (PR #11), reviewed plan | 27.7 (about 23 without a 5-min machine sleep) | 29.4 | 3.4 / 12.7 | 9 | 9 | 39 | 103 | 1.36 M | 43.5 M |
| 6 | repeat of run 5 (same plugin, plan and seed) | 20.3 | 22.6 | 1.8 / 6.2 | 8 | 8 | 29 | 87 | 1.39 M | 40.6 M |
| 7 | as run 6, 30 tasks (phase 3: 12 independent tasks), up to 10 agents, single mode; phase 3 reviewed by the integrator during the run | 31.7 (phase 3 waited about 18 min for its review) | 13.8 (10 agents) | 2.3 / 5.1 | 10 | 10 | 54 | 116 | 2.24 M | 65.2 M |
| 8 | as run 7, pool mode: a coordinator and 3 integrators; phase 3 already reviewed | 25.5 | 19.4 (10 agents) | 2.1 / 6.6 | 14 | 13 | 124 | 73 + 124 + 112 + 75 | 2.55 M | 93.2 M |

Notes per run:

- **Run 1.** All 8 bounces were append conflicts in `CHANGELOG.md`, the README table and test
  files; two tasks bounced twice. Every run stopped once at the sessions-guideline question
  (decision 0008). One agent stopped for a red check caused by an ADR number reserved by an
  unfinished task.
- **Run 2.** The integrator ran `improve-plan` at the user's request before dispatching: 3
  rounds, 18 findings; it chained tasks that write the same module, sorted shared rows and
  made the specs exact. Runs 3 and 4 use this reviewed plan. Its numbers count from the
  first dispatch, after the review.
- **Run 3.** The lander merged every PR (47 runs, none failed) but nothing woke the
  integrator after a merge or a bounce: it sat idle 14 minutes, and again later, until the user
  wrote to it. One agent asked for a force push because of a stale remote-tracking branch
  from run 2.
- **Run 4.** The machine slept at 11:07; the integrator stood still about 13 minutes until the
  user asked it to resend. The two-level plugin left its 17 development sessions open after
  their merges (no cleanup), which inflates its agent-minutes.
- **Run 5.** No question to the user and no stop: the guideline (0008) did not block the start.
  `CHANGELOG.md` and the ADR index were in no conflict (0006), one ADR was renumbered at merge
  and no task waited for a number (0009); the integrator sent 12 messages against 28 in run 2.
  But all 9 bounces were code conflicts: the integrator dispatched four tasks that append a
  function to the same module (`textkit/strings.py`) and its test file at once, and each merge
  moved the end of the file. The machine slept about 5 minutes (lid closed, 12:04:49 to
  12:09:42 UTC); three sessions then had to redo a response cut by the sleep.
- **Run 6.** A repeat of run 5 with the machine awake throughout: 20.3 minutes against about 23
  for run 5 without its sleep, so one configuration varies by a few minutes between runs.
  Again no stop for the user and no conflict on the shared files; 8 bounces, all of them code
  appended to `textkit/strings.py` and `tests/test_strings.py` by tasks dispatched at once.
- **Runs 7 and 8** add phase 3 (12 independent tasks, one new module each) for width, and up
  to 10 agents. Run 7 (one integrator): phase 3 waited about 18 minutes for its plan review
  (decision 0007) while 8 of the 10 agent slots were free; one PR bounced to make its ADR
  references safe for renumbering (decision 0009). Run 8 (pool, 3 integrators, phase 3
  already reviewed): 20% faster, but 43% more cache reads (93.2 M against 65.2 M) and 2.3
  times the messages; the coordinator and the three integrators took half of all cache reads.
  A PR waited about as long for its merge in both runs (2.1 and 2.3 min on average), so one
  integrator kept up with 10 agents: the time run 8 gained came from not waiting for the
  review, not from more integrators.

## What the runs show

1. **The plan matters most.** The reviewed plan halved the agents' working time and cut
   bounces from 8 to 3 (decision 0007).
2. **Conflicts come from shared append-only files**, not from code (decision 0006).
3. **Turns drive the cost.** A bounced or vague task takes 2 to 4 times the turns of a clean
   one, and every turn re-reads about 70,000 tokens (decision 0003).
4. **The integrator is the most expensive agent and the serial bottleneck**: about a third of
   the cache reads. Both plugins' integrators took about the same turns (83 in run 2, 87 in
   run 4), but this plugin's sent twice the messages (28 against 14) and its agents bounced
   less (3 against 7). The extra steps of this plugin (slots, reservations, the board, the
   questions they raise) are worth their turns only when they prevent a collision.
5. **Every stop that waits for the user stops the whole run**: the guideline question, a red
   check caused by a reservation, a force push the auto mode refused, a machine asleep.
6. **Code appended to one file by parallel tasks still collides** (runs 5 and 6: 9 and 8
   bounces, against 3 in run 2, where the dispatch order differed). `merge=union` is no
   answer for code. In run 6 a bounce cost its agent about 9 turns, and the 8 bounces about
   14% of the run's turns and 12% of its tokens, but only a few minutes of wall time, since
   other tasks went on meanwhile. Open question, deferred by the user (2026-11-19): accept
   these conflicts as the price of parallelism, serialize tasks that write the same file
   (cheaper conflicts, less parallelism for large tasks), ask authors to insert new code in a
   sorted position, or let `integrate-pr.sh` resolve conflicts where both sides only add
   lines and merge when the check passes.
7. **The pool pays only when one integrator cannot keep up.** With 10 agents on small tasks
   whose check takes seconds, one integrator merged as fast as three; the pool cost 43% more
   cache reads and twice the messages. It should pay off when a merge's verification is slow
   (a long test suite), which this benchmark does not have yet.
8. **Reviewing a phase's plan blocks it** (run 7): review the next phase while the current one
   runs, or let the phase's tasks that depend on nothing start during the review.
9. **A mechanical merger needs a wake-up.** The lander is reliable, but without an event that
   tells the integrator what happened, the run waits (decision 0005).

## Caveats

- One run per configuration: differences of a few minutes are noise; the large ones (plan,
  lander wake-up, append conflicts) are not.
- Run 2 changed the plugin and the plan at once; runs 3 and 4 reuse its plan, so 2 against 4
  compares the plugins and 2 against 3 isolates the lander.
- Agent-minutes count a session from its first to its last activity, including waits for a
  verdict, and sessions that are never closed may record later activity.
- Wall times include interruptions (dialogs, the machine sleeping), noted per run.
