<!--
Reference of the integrate skill: the rare exit codes of scripts/integrate-pr.sh and what the
script does when the base moves. Read when integrate-pr.sh exits with a code other than 0, 3, 4
or 14 (those are in SKILL.md; 14 is in base-red.md).
-->

# integrate-pr.sh: the other exit codes

Nothing was merged in any of these. No bounce is recorded, so the PR stays in the queue.

| Exit | Outcome | What you do |
|------|---------|-------------|
| 1 | usage, role or settings error | fix the command, or show the user the error |
| 2 | a precondition failed, nothing changed: another `integrate-pr.sh` is running in this worktree, dirty worktree, claim not yours, PR not open, `origin/<B>` not the PR head yet, or this pane's herdr agent is not `<me>` | another run: wait for its `RESULT` line (one run per worktree, never a second); otherwise fix the precondition or tell the user |
| 5, 6 | the commit or the push failed, or the push under the lock hung (killed after 600 s); nothing landed, claim released, worktree reset | tell the user (pool mode: or the coordinator) with the output; do not retry blindly |
| 7 | `<base>` kept moving during the verification (`integrators.max_reverify` times); claim released | pool mode: ask the coordinator for priority (`RESOURCE REQUEST: priority to push PR #<N>, it lost the race <k> times`), then back to step 1 |
| 8 | merge lock not acquired in 900 s; claim released | tell the coordinator or the user who holds it (`pool-state.py lock status`), back to step 1 |
| 9 | nothing to merge: the head is already in `<base>` (also when someone else merged it while you verified); claim released | comment on the PR, step 1 |
| 10 | the claim changed hands during the verification (another integrator took it over); nothing pushed, worktree reset | leave the PR to its new owner, step 1 |
| 11 | herdr stopped confirming that this pane's agent is `<me>` (`pool-state.py` refused, exit 4); nothing pushed | stop and tell the user: the session's identity is in doubt |
| 13 | the verification never ran: its wait for a heavy or light slot was interrupted (someone stopped the waiting `resource-budget.py`); worktree reset, claim released | back to step 1 |

## Slots

The verification takes one of the machine's heavy slots (`resource-budget.py`, shared with
every agent on the computer). Merge verifications go first in that queue; the dependency setup
before them uses the separate light slots. The waiter re-reads the limits by itself, so
stopping it to restart it only gives exit 13.

## When `<base>` moves during a verification

The script merges the PR again onto the new base under the lock. It pushes at once when the
new merged tree differs from the verified one only in `integrators.reverify_exempt_paths`
(default `docs/phases/*.md`, the coordinator's plan commits); otherwise it verifies again, up
to `integrators.max_reverify` times. Only a verified tree can land: pushes are never forced,
and the remote rejects a non-fast-forward.
