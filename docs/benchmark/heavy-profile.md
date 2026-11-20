<!-- Design of the benchmark's second profile, "heavy": slow checks, large tasks and tasks that
     change code other tasks use. A proposal: nothing of it is built yet. The first profile and
     every run so far are in README.md. -->

# The heavy profile (design)

Status: proposed on 2026-11-19, not built. The profile in [README.md](README.md) is called
"light" below.

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

- **Seed:** `textkit` after phases 1 and 2 (the final tree of a finished light run, with its
  plan marked done), as the branch `heavy-seed` of `textkit-sandbox`: 20 public functions, a
  command line, 5 ADRs. Agents have real code to read before they change it.
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
| Time waiting for a heavy slot | needs a line per run in `resource-budget.py` (label, seconds waited, seconds run) | Is the slot the bottleneck? Does the merge priority work? |
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

## Open choices

- 3 large tasks or 4 (a search index would be the fourth): each adds an estimated 6 million
  cache reads.
- The check's wait: 75 seconds makes 2 slots a clear bottleneck for 5 agents; 30 would make
  them a mild one.
- Whether the drill runs in single or pool mode (whichever the first two runs favour).
