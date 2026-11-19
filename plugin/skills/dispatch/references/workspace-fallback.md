<!--
Reference of the dispatch skill: open the worktree as a plain workspace. Read at step 3 when
`herdr worktree open` fails (an older herdr, a repository it does not support).
-->

# `herdr worktree open` failed

Fall back to a plain workspace, then go on with step 3 (take the pane from the JSON):

```bash
OUT=$(herdr workspace create --cwd "$WT" --label "$NAME" --no-focus); echo "exit=$?"; echo "$OUT"
```

It is still the agent's own workspace: never a pane split or a tab in yours. Do not add
`--trust-repository` on your own; if herdr asks for repository trust, ask the user.
