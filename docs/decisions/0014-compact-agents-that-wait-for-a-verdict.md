# 0014. Compact development agents that wait for a verdict

- Status: accepted, to be measured
- Date: 2026-11-20

## Context

A development agent that announced its pull request is idle until the verdict arrives. A
bounce is then answered in the same session, with everything it took to build the task
still in context: every turn of the fix re-reads it. Decision 0010 compacts the idle
integrator; nothing did the same for the agents.

## Evidence

The two runs of the benchmark's heavy profile (`docs/benchmark/heavy-profile.md`, runs H1
and H2), where three of the ten tasks are packages of several modules:

- The three large sessions reached 166,000 to 197,000 tokens of context (H1) and 154,000
  to 175,000 (H2). A task of one function stays near 50,000; the medium ones reached 61,000
  to 113,000.
- After announcing, those three sessions made 22, 31 and 35 more turns in H1 and 24, 33 and
  40 in H2: one to three bounces each, every turn at that context.
- Half of the development agents' cache reads came after the announcement in both runs:
  17.2 M of 34.0 M (H1) and 17.3 M of 33.9 M (H2).
- The wait is long enough: the first verdict of a large pull request took 4 to 10 minutes
  in single mode. In pool mode two of them took under 2 minutes.
- Compacting the integrator at 249,000 tokens (H1) took 27 seconds and left 17,000.

## Decision

`compact-waiting.py` runs one pass a minute from both watchers (`integrator-watch.sh`,
`integrator-pool.sh watch`), without tokens. A development agent gets one
`/compact <what to keep>` when all of this holds:

- it is `idle` or `done`;
- it waits for a verdict: an open pull request against the base branch has its branch as
  head, at the commit its worktree is on;
- its context is above `agent_compact_tokens` (default 100000; `0` turns it off);
- it was not compacted at that commit already, and its last turn did not stop on an API
  error (decision 0012 handles that).

The instruction keeps the task and its acceptance criteria, the branch, worktree and pull
request, what was announced, the decisions and their reasons, the files changed and how
they were tested; it drops file contents, diffs and test output. A new commit announced
after a bounce may be compacted again.

## Alternatives

- **Compact from `submit-pr.sh`**, right after the announcement: a script cannot run a
  slash command in its own session; only text typed into the pane can.
- **A fresh agent for each bounce**, given the pull request and the findings: it loses the
  author's reasons, and needs a second dispatch per bounce.
- **A lower automatic compaction threshold in Claude Code**: it would also compact in the
  middle of the work, when the detail is in use, instead of at the pause.
- **Compact every waiting agent**, whatever its size: a session of 50,000 tokens gains
  little and the compaction costs about one turn.

## Consequences

- A compaction costs about one turn at the old context and half a minute. It pays back
  after two or three turns; a pull request merged at the first try (three more turns) gains
  little, a bounced one gains most of its remaining cost.
- The summary may lose a detail the fix needs. The worktree, the pull request and its
  comments hold the facts, so the agent re-reads them; whether fixes get worse (a second
  bounce) is what the next heavy run measures.
- A verdict that arrives in under a minute beats the watcher: that bounce is answered at
  the full context, and the compaction comes at the next wait.
- A verdict that arrives during the compaction waits in the agent's input queue.
- `/compact` is typed into the agent's pane, like the watcher's other messages: if the user
  is typing there at that moment, it lands in their input.
- It reads the context from Claude Code's transcript, as decision 0010 does: not a
  documented interface; when it cannot be read, nothing is compacted.
