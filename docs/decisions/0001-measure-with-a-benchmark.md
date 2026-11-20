# 0001. Measure workflow changes with a reproducible benchmark

- Status: accepted
- Date: 2026-11-19

## Context

Changes to the workflow (prompts, skills, scripts) were judged by reading them and by field
reports from real projects. Field reports are slow, mix many causes and cannot be repeated.
The question "does this make the agents faster, cheaper or less in each other's way?" had no
direct answer.

## Decision

Every change meant to make the workflow more efficient is measured with the benchmark in
[docs/benchmark/](../benchmark/README.md): a public synthetic repository (`textkit-sandbox`),
a fixed 18-task backlog in two phases designed to collide (shared files, shared numbering,
dependency chains), five development agents at most, one model and effort level, and one base
branch per run, so every run keeps its own history. The scripts in `benchmark/` read the
results from GitHub and from Claude Code's session transcripts.

What a run reports: wall time from the first dispatch to the last merge, the ideal wall time
(agent-minutes / 5), the wait from opening a PR to its merge, bounces, force pushes, messages
between agents, turns, and tokens (new tokens and cache reads).

## Alternatives

- **Field reports only.** Real, but slow and not comparable between changes.
- **Unit tests only.** They prove the scripts are correct, not that agents work well together.

## Consequences

- A run costs real tokens (about 1.3 to 1.7 M new tokens and 40 to 55 M cache reads with
  Opus 5.5) and 20 to 60 minutes, and needs the user nearby for the occasional dialog.
- Results vary between runs: one run per configuration shows large effects, not small ones.
- A decision that cites a run says which; a later run that contradicts it reopens the decision.
