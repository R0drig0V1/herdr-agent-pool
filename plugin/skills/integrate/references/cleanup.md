<!--
Reference of the integrate, coordinate and dispatch skills: what scripts/cleanup-worktree.sh
does and what each non-zero exit code means. Read when a cleanup does not exit 0, or when
--list shows a branch that is not "ready". Design: docs/multi-integrator.md, "Cleanup".
-->

# cleanup-worktree.sh

Whoever dispatched an agent cleans up after its branch merged: in single mode the integrator's
watcher (`integrator-watch.sh` runs it for every `ready` branch), in pool mode the coordinator.
The merged verdict tells the author to wrap up and stop.

`--list` prints every development worktree with its state; `ready` means merged, clean and its
agent idle. `cleanup-worktree.sh <branch>` closes the agent's workspace, removes the worktree
(never `--force`) and deletes the local branch (and the remote one when it is still the merged
head). It removes nothing unless the branch is contained in `origin/<base>`, the worktree has
no uncommitted work and every agent there is idle. `--dry-run` says what it would do.

| Exit | Meaning | What you do |
|------|---------|-------------|
| 1 | usage, wrong role, or a protected branch | fix the command |
| 2 | no such branch | check the name with `--list` |
| 3 | not merged (also `not-merged` in the list for a branch nobody works on any more) | an abandoned branch is the user's call |
| 4 | uncommitted work after the merge | ask the author what it is, or the user; never discard it |
| 5 | the agent is still working or blocked at a dialog, or herdr cannot be asked | try again later; do not wait in a loop |
| 6 | the workspace holds panes outside the worktree | ask the user |
| 7 | git failed | show the user the output |

Discarding finished worktrees also gives the machine memory back: each one keeps a Claude
session alive until its workspace is closed. The pool's verify worktrees are not handled here:
`integrator-pool.sh stop <n> --remove-worktree`.
