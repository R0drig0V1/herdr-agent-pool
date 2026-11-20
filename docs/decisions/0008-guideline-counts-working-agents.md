# 0008. The sessions guideline counts working agents only

- Status: accepted (PR #9)
- Date: 2026-11-19

## Context

`sessions_guideline` (default: half the machine's RAM in GB) limited the live herdr agents on
the machine. Over it, the dispatcher did not dispatch and asked the user.

## Evidence

Every benchmark run stopped at that question before its first dispatch: the machine had 13
to 15 live agents against a guideline of 12, almost all of them idle or done in other
repositories. The whole run waited for the user's answer.

## Decision

The guideline counts working agents only. Idle and done sessions never block a dispatch and
are no reason to ask; the memory line of the resource board shows what they hold. Working
agents over the guideline are reported, not a stop. Only low memory stops a dispatch.

## Consequences

- Runs start without a question.
- Idle sessions still use memory; when memory runs low, the dispatcher stops and asks as
  before.
