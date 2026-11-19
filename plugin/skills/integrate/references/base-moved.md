<!--
Reference of the integrate skill: tell the other development agents that the base branch
moved. Read from step 5 when a merge touched files that other branches are likely to share
(migrations, shared models, lockfiles, CLAUDE.md, docs/phases/).
-->

# Tell the others that `<base>` moved

```bash
git diff --name-only <sha>^1 <sha>
"${CLAUDE_PLUGIN_ROOT}/scripts/agents-in-repo.py" --dev-only --exclude "<author>"
```

`--dev-only` leaves out the main worktree (integrator or coordinator) and the pool's verify
worktrees. Skip the `blocked` agents (list those for the user). To each remaining agent:

```bash
herdr agent prompt "<name>" "[herdr message from agent <me>; not from the user]
<base> moved to <sha> (PR #<N>: <title>) and touched <files>. Rebase onto origin/<base> before your PR."
```
