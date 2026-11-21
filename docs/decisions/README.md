<!-- Index of the design decisions of herdr-agent-pool itself (not of the projects that use
     it, whose ADRs live in their own docs/decisions/). One file per decision. -->

# Design decisions

Each decision is one file, `NNNN-title.md`: context, decision, alternatives, the evidence
behind it and how to tell later whether it still holds. A decision backed by a measurement
links to the benchmark run in [docs/benchmark/](../benchmark/README.md); a later decision that
changes an earlier one says so in both files.

The point is continuous improvement: before changing a mechanism, read its decision, and
after changing it, measure it the same way and record the result.

| # | Decision | Status |
|---|----------|--------|
| [0001](0001-measure-with-a-benchmark.md) | Measure workflow changes with a reproducible benchmark | accepted |
| [0002](0002-no-base-moved-broadcast.md) | No "base moved" broadcast; announced branches are not rewritten | accepted |
| [0003](0003-short-skills-with-references.md) | Short skills, rare branches in reference files | accepted |
| [0004](0004-ask-before-someone-elses-pr.md) | Ask the user before working on someone else's pull request | accepted |
| [0005](0005-lander.md) | A lander script merges; the queue label is the approval | accepted, with a known gap |
| [0006](0006-union-merge-for-append-only-files.md) | `merge=union` for append-only files | accepted |
| [0007](0007-review-the-plan-before-dispatch.md) | Review a phase's plan before its first dispatch | accepted |
| [0008](0008-guideline-counts-working-agents.md) | The sessions guideline counts working agents only | accepted |
| [0009](0009-number-at-merge.md) | Number new ADRs and migrations at merge time | accepted |
| [0010](0010-slim-integrator.md) | A slimmer single-mode integrator: plan ticks in the merge, a token-free watcher, compaction | accepted, to be measured |
| [0011](0011-lean-agent-start.md) | Start development agents with a lean tool set | accepted, to be measured |
| [0012](0012-retry-agents-stopped-by-an-api-error.md) | Ask agents stopped by an API error to continue | accepted |
| [0013](0013-submit-in-one-command.md) | Submit a task in one command | accepted, measured (run 11) |
| [0014](0014-compact-agents-that-wait-for-a-verdict.md) | Compact development agents that wait for a verdict | accepted, to be measured |
| [0015](0015-branch-check-pool.md) | A project chooses the pool of its branch checks | accepted, to be measured |
