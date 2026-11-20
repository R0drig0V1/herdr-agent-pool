<!--
Reference of the coordinate skill: find merges whose plan report was lost. Read after the
coordinator restarts (an integrator may have died between its push and its report).
-->

# Catch up after a restart

Compare the recently merged PRs with the recorded reports:

```bash
gh pr list --base <base> --state merged --limit 30 --json number,title,mergedAt
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" report known <N>; echo "exit=$?"   # 1: never reported
```

For a merged PR that was never reported, read its "Plan tasks completed" section
(`gh pr view <N> --json body`) and tick it like any other report (step 3 of the skill).

A change limited to `docs/phases/` does not make the integrators verify again
(`integrators.reverify_exempt_paths`), but every push still makes them merge again: batch the
ticks into one commit.
