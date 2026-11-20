# 0003. Short skills, rare branches in reference files

- Status: accepted (PR #8)
- Date: 2026-11-19

## Context

A skill's `SKILL.md` is loaded in full every time the skill runs, and `CLAUDE.md` and the role
prompts are loaded by every session. They had grown with every rare case (exit codes, a red
base, promotion, pool operations), and some rules were repeated in up to five places.

## Decision

Each `SKILL.md` keeps the normal path: preconditions, the steps with their commands and the
"Never" rules. Rare branches and templates move to `references/*.md` beside it, each named by
a one-line trigger ("exit code other than 0, 3, 4: read references/exit-codes.md"). A rule
lives once, where every reader that needs it loads it.

## Evidence

The default load per role went down about 40%: development agent about 5,150 to 3,080
tokens, integrator about 9,175 to 5,390, coordinator about 9,995 to 5,910 (bytes / 3.8).

The benchmark also showed that prompts are a small part of the cost: about 97% of the tokens
are the conversation read again from cache on every turn (about 70,000 tokens per turn), so
the number of turns matters far more than the size of the prompts. After this change the
plugin loads less text than the simpler two-level plugin it was compared with.

## Consequences

- A reference file costs a read the first time its case occurs.
- Existing projects keep their own copies of `CLAUDE.md` and the role prompts; they get the
  savings in those files only by re-syncing from `template/`.
- Further savings come from fewer turns (fewer steps per task), not from shorter text.
