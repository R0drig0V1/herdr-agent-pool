<!--
Reference of the pr skill: the pull request body. Read once per session, at step 3, before
`gh pr create`. scripts/integrate-pr.sh reads the "Plan tasks completed" section by its
heading, so keep the headings as they are.
-->

# Body template (English)

```markdown
## Summary
<1-3 sentences: what and why>

## Changes
- <area>: <change>

## Migrations / data
<"None" or: what it does, whether it is reversible, and how it was tried>

## Test plan
- [ ] `scripts/check.sh`
- [ ] <manual check: command run and what it showed>

## Docs
<which docs/ pages were updated>

## Plan tasks completed
<one line per task, its id first, e.g. `- T1.2 Add login endpoint (docs/phases/1-auth.md)`:
the ids tick the plan at merge. Do not tick them yourself: docs/phases/ is the integrator's.>

## Follow-ups
<"None", or the issues opened for work left out of this PR (/herdr-agent-pool:issue):
#N: one line each.>
```

End the body with the PR attribution line this environment specifies, if any. When the base is
red and only its tests fail, say so under Test plan (`base red: <tests>`).
