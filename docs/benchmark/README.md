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

A second profile with slow checks and large tasks is proposed in
[heavy-profile.md](heavy-profile.md).

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
| Time waiting for a heavy slot | `benchmark/slot-waits.py` | per kind of check (development, merge verification, coordinator): how many waited, for how long, and how long they ran; from the run log of `resource-budget.py` |
| Turns per stage | `benchmark/turn-stages.py` | a development agent's turns split into work, the `commit` skill, the `pr` skill and what follows the announcement; each session's first and largest context |

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
| 1 | herdr-agent-pool before decisions 0002-0003, plan as written | 35.4 | 21.9 | 2.4 / 7.9 | 9 | 13 | 69 | 106 | 1.65 M | 52.4 M |
| 2 | decisions 0002-0003; plan reviewed first (+11.5 min, not in the wall time) | **17.9** | 12.4 | **0.9 / 2.2** | **3** | **3** | 54 | **83** | **1.25 M** | 40.6 M |
| 3 | run 2 plus the lander in Actions (decision 0005), reviewed plan | 62.5 | 39.4 | 5.1 / 24.1 | 9 | 9 | 61 | 139 | 1.54 M | 56.5 M |
| 4 | the two-level plugin claude-code-herdr (4f9ded4), reviewed plan | 36.0 (about 23 without a 13-min machine sleep) | 41.1 | 3.0 / 13.3 | 7 | 12 | 40 | 87 | 1.45 M | **39.3 M** |
| 5 | `main` after decisions 0006-0008 plus 0009 (PR #11), reviewed plan | 27.7 (about 23 without a 5-min machine sleep) | 29.4 | 3.4 / 12.7 | 9 | 9 | 39 | 103 | 1.36 M | 43.5 M |
| 6 | repeat of run 5 (same plugin, plan and seed) | 20.3 | 22.6 | 1.8 / 6.2 | 8 | 8 | 29 | 87 | 1.39 M | 40.6 M |
| 7 | as run 6, 30 tasks (phase 3: 12 independent tasks), up to 10 agents, single mode; phase 3 reviewed by the integrator during the run | 31.7 (phase 3 waited about 18 min for its review) | 13.8 (10 agents) | 2.3 / 5.1 | 10 | 10 | 54 | 116 | 2.24 M | 65.2 M |
| 8 | as run 7, pool mode: a coordinator and 3 integrators; phase 3 already reviewed | 25.5 | 19.4 (10 agents) | 2.1 / 6.6 | 14 | 13 | 124 | 73 + 124 + 112 + 75 | 2.55 M | 93.2 M |
| 9 | as run 6, plus the watcher and compaction of the integrator (decision 0010) and the lean start of development agents (decision 0011) | 20.3 | 16.9 | 1.6 / 5.8 | 8 | 8 | 32 | 101 | 1.24 M | **27.3 M** |
| 10 | as run 9, plus mentions rewritten at a renumber (decision 0009's amendment) | 26.7 | 27.5 | 2.6 / 5.9 | 9 | 9 | 56 | 103 | 1.33 M | 29.8 M |
| 11 | as run 10, plus one command to submit a task (decision 0013) and retries after an API error (decision 0012) | not comparable (the machine slept about 8 hours) | - | - | 9 | 8 | 50 | 118 | 1.40 M | **25.1 M** |
| 12 | as run 11, repeated for the times | 20.7 | 14.2 | 1.8 / 4.6 | 9 | 9 | 37 | 96 | **1.22 M** | **24.4 M** |

Notes per run:

Bounces count the PR comments that ask for a rebase or a fix; runs 1 and 3 were recounted
when `pr-stats.py` learned the later wordings ("conflict ...", "Your turn: ... Rebase"), from 8
and 4.

- **Run 1.** All 9 bounces were append conflicts in `CHANGELOG.md`, the README table and test
  files; two tasks bounced twice. Every run stopped once at the sessions-guideline question
  (decision 0008). One agent stopped for a red check caused by an ADR number reserved by an
  unfinished task.
- **Run 2.** The integrator ran `improve-plan` at the user's request before dispatching: 3
  rounds, 18 findings; it chained tasks that write the same module, sorted shared rows and
  made the specs exact. Runs 3 and 4 use this reviewed plan. Its numbers count from the
  first dispatch, after the review.
- **Run 3.** The lander merged every PR (47 runs, none failed); its bounces were requests to
  rebase after another PR landed. But nothing woke the
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
- **Run 9.** Run 6's configuration with decisions 0010 and 0011: the same turns (503) and
  wall time (20.3 min), a third fewer cache reads (27.3 M against 40.6 M). A development
  agent's turn read 41,800 tokens against 69,700 (-40%), from the lean start; the agents
  made the same number of turns (402 against 416). The integrator compacted once, at
  158,000 tokens down to 67,000 (it was busy when it crossed 120,000), and read 104,000
  tokens per turn against 133,000. The 8 bounces were the same code conflicts in
  `textkit/strings.py`. One renumbered ADR kept stale mentions ("ADR 0001" in a docstring,
  the README table, `CHANGELOG.md`, a test name): the integrator asked for a follow-up PR,
  whose change then failed another PR's verification (fixed in `renumber.py`, decision
  0009's amendment). The last task, the usage guide, depends on all others and ran alone
  for the last 4 minutes. An idle agent's automatic recap kept it marked as working, so
  its worktree was not cleaned up and its agent-minutes ran on.
- **Run 10.** The first attempt never started: the integrator's first turn ended with "Can't
  reach the API server" and it stood still for two and a half hours until the user asked
  (decision 0012); the numbers are the second attempt's. The renumbered ADR's mentions were
  rewritten in the merge and no follow-up PR was needed. Slower than run 9 (26.7 against
  20.3 minutes) on the same plugin: the integrator was never idle between minutes 3 and 18,
  so the watcher compacted it only at 196,000 tokens (the threshold is 120,000), PRs waited
  2.6 minutes on average against 1.6, and the integrator pushed a commit of its own that
  re-sorted the README and CHANGELOG rows, which bounced two open PRs. Of the 9 bounces, 6
  were code appended to one module, 2 came from that commit and 1 was a review finding (an
  ADR and its code disagreed). A development agent's turn read 42,200 tokens, as in run 9.
- **Run 11.** The machine slept from minute 5 for about 8 hours, so the times do not count;
  the turns and tokens do. It also tested decision 0012 for real: while the machine slept the
  watcher retried the integrator and one agent six times each, and once the network was back
  both went on without anyone writing to them. The first attempt was stopped after 40
  seconds: the watcher had not started (it failed without an argument, as the SessionStart
  hook starts it; fixed). With `submit-pr.sh` the `pr` skill took 3.1 turns per task against
  6.8 in run 9, and a task merged at the first try 12 to 14 turns against about 17; the
  development agents made 353 turns and 13.9 M cache reads against 402 and 16.8 M (-12% and
  -17%). They still ran the `commit` skill first (2.8 turns per task), because the `pr` skill
  named it. What follows the announcement is now the largest stage (7.3 turns per task, 45%
  of the development cache reads): three turns even without a bounce (the report, then the
  merged verdict's board note and final line). The integrator was compacted twice, at
  138,000 and 148,000 tokens.
- **Run 12.** Run 11 again, with the machine awake: no API error, no pause. The tokens and
  turns repeat run 11 (353 development turns in both; 24.4 M cache reads against 25.1 M), so
  the saving of `submit-pr.sh` holds: 11% fewer cache reads than run 9. The wall time does
  not move: 20.7 minutes against 20.3 in runs 6 and 9, although the agents worked less (71
  agent-minutes, an ideal wall of 14.2 minutes against 16.9). The other 6.5 minutes are not
  agent work: the nine bounces all fell on six of the first nine pull requests (most of
  them conflicts in code added to the same module, item 6), and the last three tasks ran one at a time because each
  depends on the one before (minutes 13 to 20). The integrator was compacted once, at
  167,000 tokens. A local branch left by an earlier run made the integrator pick another
  branch name for one task; it changed nothing else.

## What the runs show

1. **The plan matters most.** The reviewed plan halved the agents' working time and cut
   bounces from 9 to 3 (decision 0007).
2. **Conflicts came from shared append-only files** (decision 0006) until `merge=union`;
   since then they come from code appended to the same module (item 6).
3. **Turns drive the cost.** A bounced or vague task takes 2 to 4 times the turns of a clean
   one, and every turn re-reads the whole context (decision 0003). A smaller context per turn
   is the other lever: the lean start cut a development agent's turn from about 70,000 to
   42,000 tokens (run 9).
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
8. **A development agent spends more turns on the ceremony than on the task** (run 9, 18
   tasks, 402 turns): 26% of the turns read the task and write the code; the `commit` skill
   takes 14%, the `pr` skill 31% (rebase, a second run of the checks, push, the PR, its own
   name, the announcement, a summary) and what follows the announcement 29% (the verdict, a
   bounce, the final report). A task merged at the first try takes about 17 turns, 11 of them
   after the code is written. One command for the mechanical steps (decision 0013) took the
   `pr` skill from 6.8 to 3.1 turns per task (run 11); what follows the announcement is then
   the largest stage.
9. **Compaction that waits for an idle integrator comes late when it is never idle** (run 10:
   196,000 tokens against a threshold of 120,000).
10. **Reviewing a phase's plan blocks it** (run 7): review the next phase while the current one
   runs, or let the phase's tasks that depend on nothing start during the review.
11. **A mechanical merger needs a wake-up.** The lander is reliable, but without an event that
   tells the integrator what happened, the run waits (decision 0005).

## Caveats

- One run per configuration: differences of a few minutes are noise; the large ones (plan,
  lander wake-up, append conflicts) are not. Runs 9 and 10 ran almost the same plugin and
  differ by 6 minutes of wall time (30%) and 9% of cache reads: the tokens per turn repeat
  well, the wall time does not. Runs 11 and 12 ran the same plugin and differ by 3% of cache
  reads and have the same number of development turns.
- Run 2 changed the plugin and the plan at once; runs 3 and 4 reuse its plan, so 2 against 4
  compares the plugins and 2 against 3 isolates the lander.
- Agent-minutes count a session from its first to its last activity, including waits for a
  verdict, and sessions that are never closed may record later activity.
- Wall times include interruptions (dialogs, the machine sleeping), noted per run.
