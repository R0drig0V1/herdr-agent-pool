<!--
Reference of the integrate skill: what an integrator does when tests fail on the base branch
alone. Read on integrate-pr.sh exit 14, or on exit 4 when the failing tests look unrelated to
the PR's diff. Design: docs/multi-integrator.md, "The base is red".
-->

# The base is red

A test that fails on `origin/<base>` alone fails every PR's verification. One owner fixes it;
everyone else waits, and nobody fixes it in their own branch.

## Detect it (exit 4, failing tests unrelated to the PR's diff)

Your worktree is back at `origin/<base>` after the bounce. Run only the failing tests there,
with the project's documented command, inside a heavy slot:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/resource-budget.py" run --priority merge --label "base check" -- <the project's command for these test ids>
```

They pass on the base: the failure is the PR's; send the normal bounce verdict.

They fail on the base too: record it, undo the bounce of this head, and tell the coordinator
(it assigns one owner):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" base-red report --tests "<id> <id>" --suspect <PR that likely turned it red, if known> --owner <me>
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" hold <N> --head <head> --owner <me>    # undoes the bounce of this head
herdr agent prompt "<coordinator_name>" "[herdr message from agent <me>; not from the user]
BASE RED: origin/<base> fails <ids> alone (suspect PR #<S>). PR #<N> is held until the fix lands. Please assign one owner (pool-state.py base-red assign)."
```

The verdict to the author says the failure is the base's, not theirs, and that the PR waits:
no action, and do not fix those tests in the branch.

## While the base is red (exit 14)

`verify-merge.sh` prints the banner and passes the red tests to `scripts/check.sh` as
`$HERDR_AGENT_POOL_BASE_RED_TESTS` (a project may leave them out). A failed verification then
gives exit 14 instead of a bounce, and your claim is kept. Read the log:

- Only the red tests failed: `pool-state.py hold <N> --head <head> --owner <me>`. The queue
  skips the PR until the base is green; the verdict says it waits for the fix.
- Anything else failed: `pool-state.py bounce <N> --head <head> --owner <me>` and a normal
  bounce verdict.

Then go to step 5. Never merge a PR with red tests that are not the known base-red ones.

## How it ends

When the assigned fix's branch merges (`integrate-pr.sh` clears the entry and prints "the base
is green again"), or when the coordinator clears it after a green base check. Held PRs come
back to the queue by themselves.
