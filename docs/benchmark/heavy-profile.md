<!-- Design of the benchmark's second profile, "heavy": slow checks, large tasks and tasks that
     change code other tasks use. Built on 2026-11-20; its runs are at the end. The first
     profile and its runs are in README.md. -->

# The heavy profile (design)

Status: proposed on 2026-11-19, built on 2026-11-20 (the seed, the plan, the slot-wait log);
one run so far ([Runs](#runs)). The profile in [README.md](README.md) is called "light" below.

## Why a second profile

Ten runs of the light profile found the large effects (the plan review, union merges, the
lean start). It can no longer tell a small improvement from noise: runs 9 and 10 ran almost
the same plugin and differ by 30% in wall time. And three parts of the plugin never came
under load in it:

| Not exercised by the light profile | Why |
|------------------------------------|-----|
| Heavy slots, the queue for them, the pool of integrators | `scripts/check.sh` takes seconds, so nothing ever waits for a slot and one integrator keeps up with 10 agents (run 8) |
| Long development sessions | A task is one function: about 6 turns of work, a context that stays under 70,000 tokens, a branch that lives 3 minutes |
| Conflicts of meaning | Tasks collide only as text (two functions appended to one file); none changes code another task relies on |

A longer run of the same small tasks would repeat the light profile's numbers (run 7, 30
tasks, did). The heavy profile changes the kind of work, not its amount.

## The setup

- **Seed:** `textkit` after phases 1 and 2 (the final tree of light run 12, with its plan
  marked done), as the branch `heavy-seed` of `textkit-sandbox`: 14 public functions, a
  command line, 5 ADRs, 138 tests. Agents have real code to read before they change it. The
  seed also extends the public-function rule to packages (the names in `__all__` of a
  package's `__init__.py`) in `scripts/check.sh` and `tests/test_api.py`, so that the three
  large tasks do not each rewrite it.
- **Slow checks:** `scripts/check.sh` sleeps before the tests (`TEXTKIT_CHECK_SECONDS`,
  default 75; skipped in CI), so a failing check costs the wait too. The wait costs no
  tokens. With the machine's 2 heavy slots, every check of every agent and every merge
  verification queues for them.
- **Backlog:** phase 3, 10 tasks of three sizes:

  | Id | Size | Task | Built to |
  |----|------|------|----------|
  | H1 | large | Template engine, `textkit/template/` (lexer, parser, renderer; filters are the existing case helpers); a subcommand, a docs page, an ADR | long session, many files |
  | H2 | large | Markdown subset to HTML, `textkit/markdown/` (blocks, inlines, escaping); subcommand, docs page, ADR | long session, many files |
  | H3 | large | Line diff, `textkit/diff/` (LCS, unified format, apply); subcommand, docs page, ADR | long session, many files |
  | H4 | medium | Command registry: split `textkit/__main__.py` into `textkit/cli/`, one module per subcommand | H1-H3 add their subcommand to it: a dependency the plan must order |
  | H5 | medium | Error hierarchy: `textkit/errors.py`; every public function raises a `TextkitError` instead of `ValueError`; all tests follow | touches every module; tests written in parallel still expect `ValueError` and fail only after the merge |
  | H6 | medium | Tokenizer API: `_tokens.words` returns tokens with offsets; its callers follow | changes code H1 and H3 may call |
  | H7-H10 | small | `dedent`, `center`, `ngrams`, `levenshtein`: one function each, as in phases 1-2 | keep the queue mixed; the baseline to compare against |

  In the plan (`docs/phases/phase-3-text-tools.md` of the seed) they are T3.1 to T3.10: H4,
  H5, H6 (T3.1 to T3.3), H1, H2, H3 (T3.4 to T3.6), H7 to H10 (T3.7 to T3.10). As written
  before the review, only the three large tasks depend on another one (T3.1, the registry
  their subcommands go into); the error hierarchy does not inherit from `ValueError`, so a
  task written against `ValueError` in parallel turns red only once it is merged.

  Each large task: at least three modules and 40 tests. The numbered files (three ADRs) and
  the shared files (`README.md`, `CHANGELOG.md`, `textkit/__init__.py`) collide as before.
- **Plan review:** once, before the first run (`improve-plan`), and the reviewed plan is
  fixed for every run, as in the light profile. How it orders H4-H6 against H1-H3 is part of
  what the profile shows.
- **Agents, model, pinning, one base branch per run:** as in the light profile (at most 5
  development agents, Opus 5.5 with effort high).

## Configurations

1. **Single mode**: one integrator, the machine's 2 heavy slots.
2. **Pool mode**: a coordinator and 2 integrators, the same slots.

The light profile could not answer whether the pool pays (run 8: no, with checks of
seconds). This pair can. One run each first; a difference under about 30% in wall time or
10% in tokens needs a repeat before it counts.

## What is measured

As in the light profile (`pr-stats.py`, `measure.py`), plus:

| Metric | Source | Question |
|--------|--------|----------|
| Turns per stage, by task size | `benchmark/turn-stages.py` | Does the ceremony still take most of a task's turns when the task is large? |
| Largest context per session | `benchmark/turn-stages.py` | Do development agents pass 100,000 tokens? Is compaction needed for them too? |
| Time waiting for a heavy slot | `benchmark/slot-waits.py`, from the run log of `resource-budget.py` (label, seconds waited, seconds run, exit code) | Is the slot the bottleneck? Does the merge priority work? |
| Bounces by cause | PR comments, by hand: text conflict, failed verification, review finding | What does a conflict of meaning cost against a conflict of text? |
| Compactions of the integrator | `compact_boundary` lines of its transcript | After two or more, does it lose a PR's state or a user decision? |

## Faults: a separate drill

Faults make runs incomparable, so the two runs above have none. A third run, same plan,
injects them at fixed points of progress (by merge count, not by the clock):

| After merge | Fault | What should happen |
|-------------|-------|--------------------|
| 2 | A development agent's process is killed mid-task | Its uncommitted work and worktree are found; the task is dispatched again |
| 5 | A commit that breaks a test is pushed to the base | The base-red protocol: one owner, others keep working, no PR bounced for it |
| 7 | The user writes to the integrator: drop one task, add another | The plan changes, and the change survives a compaction |

An API cut (decision 0012) is not injected: it would cut every agent of the machine,
including the session that drives the run. It is measured when it happens.

## Cost

Estimates from the light profile's per-turn numbers, not measurements:

- Tokens: 40 to 60 million cache reads per run (a light run: 27 to 30 million).
- Wall time: 45 to 70 minutes per run.
- Once: writing the seed, the phase file and the check (no agent tokens), and the plan
  review (10 to 15 minutes).

## Choices

- Three large tasks, not four (a search index would have been the fourth): each adds an
  estimated 6 million cache reads.
- The check waits 75 seconds: with 2 slots that is a clear bottleneck for 5 agents; 30 would
  have made it a mild one.
- Open: whether the drill runs in single or pool mode (whichever the first two runs favour).

## Runs

The plan review ran once, before the first run: 32 minutes, three rounds, 34 findings (1
critical, 11 high), all accepted at least in part. It kept the ten tasks and added a
relation, "PR after X": the task starts at once but opens its pull request only once X is
merged (the three large tasks after T3.1, the command registry). Every run starts from that
reviewed plan (`14b7d58` in `textkit-sandbox`).

| Run | Configuration | Wall (min) | Ideal wall (min) | Open time mean / max (min) | Bounces | Messages sent | Integrator turns | New tokens | Cache reads |
|-----|---------------|-----------:|-----------------:|---------------------------:|--------:|--------------:|-----------------:|-----------:|------------:|
| H1 | single mode; main after decisions 0012 and 0013, the watcher fix and the `pr` skill committing with plain git | 39.1 | 30.7 | 7.5 / 22.2 | 7 | 49 | 94 | 1.61 M | 47.3 M |

- **Run H1** (2026-11-20, branch `heavy1`). No API error, no pause.
  - **The slots were not the bottleneck.** 29 checks took a heavy slot (19 of development
    agents, 10 merge verifications); 5 waited 5 seconds or more, 2 minutes in all, 54
    seconds at most. The two slots were busy 55% of the time.
  - **The integrator was.** From minute 17 to minute 32 three to five pull requests waited
    for it. The three large ones stayed open 19, 15 and 22 minutes, a small one 2.
  - **Bounces by cause** (7): three because the error hierarchy (T3.2) merged first and the
    open pull request had to follow it (a conflict of meaning, as designed); two for
    defects the integrator's review found (a crash on a lone surrogate, a quadratic pass
    that its ADR called linear); one text conflict; one rebase that left duplicate
    CHANGELOG lines.
  - **Large tasks pass 100,000 tokens.** Their sessions reached 166,000, 179,000 and
    197,000 tokens of context and made 60 to 71 turns; the three took 24.9 M of the 34.0 M
    cache reads of the development agents. Half of the development cache reads (51%) came
    after the announcement: a bounce is answered with the whole session in context.
  - **The integrator was compacted once, late**: at 249,000 tokens, in minute 34. It was
    never idle before.
  - Turns per task by stage: work 17.8, commit 3.2, `pr` 3.0, after the announcement 12.7.
    Seven of the ten agents still loaded the `commit` skill.
