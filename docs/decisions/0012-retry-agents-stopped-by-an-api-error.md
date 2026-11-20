# 0012. Ask agents stopped by an API error to continue

- Status: accepted
- Date: 2026-11-19

## Context

A network cut, a machine that slept or an overloaded API ends an agent's turn with an API
error. Claude Code retries by itself first; once it gives up, the agent is idle and waits
until someone writes to it. Nothing in the workflow noticed.

## Evidence

- Benchmark run 10, first attempt: the integrator's turn ended with "Can't reach the API
  server (ENOTFOUND)" seconds after the start, before any dispatch. The run stood still for
  two and a half hours, until the user asked how it was going.
- Runs 4 and 5: the machine slept (13 and 5 minutes); in run 4 the integrator stood still
  until the user wrote to it, in run 5 three sessions had to redo a response cut by the sleep.
- The transcripts of the benchmark's sessions hold six such endings, all marked the same way:
  an assistant line with `isApiErrorMessage` ("Connection lost mid-response", "Your computer
  went to sleep mid-response", "Can't reach the API server").

## Decision

`retry-stalled.py` runs one pass a minute from both watchers (`integrator-watch.sh`,
`integrator-pool.sh watch`), without tokens: every named agent in a worktree of the
repository that is `idle` or `done` and whose transcript ends with an API error gets one
`herdr agent prompt` to continue where it left off. The first retry is immediate, the next
ones wait 1, 2, 4, 8 and then 15 minutes; after 20 in a row it gives up and says so once. An
error a retry cannot fix (authentication, billing, an invalid or too long request) is never
retried. A turn that ends well resets the count.

Single mode's watcher now starts with the integrator's session (the SessionStart hook,
detached) instead of on the first `integrate` pass: in run 10 the integrator stopped before
that pass. Started that way it may outlive the session, so it ends by itself when the
integrator has been gone from herdr for five passes.

## Alternatives

- **Read the pane** for "API Error": depends on what the terminal shows and on scrollback;
  the transcript marks the error explicitly.
- **Only tell the user** (a notification): keeps the run waiting for a person, which is what
  failed.
- **Retry from a Stop hook inside the agent's session**: a hook cannot start a new turn
  after an API error, and a session that lost the network may not run it.
- **Let the integrator check its agents**: costs turns, and does not cover the integrator
  itself.

## Consequences

- A retry that fails again costs no tokens (the request does not reach the API). One that
  succeeds on an agent that had in fact finished costs one short turn ("nothing pending").
- The message arrives as a herdr message from the watcher, like its wake-ups: if the user is
  typing in that pane at that moment, it lands in their input.
- The marker (`isApiErrorMessage`) is Claude Code's transcript format, not a documented
  interface: if it changes, retries stop silently (the tests pin the format the plugin reads).
- In single mode the watcher runs from the session's start, so cleanup and compaction no
  longer wait for the first PR either.
