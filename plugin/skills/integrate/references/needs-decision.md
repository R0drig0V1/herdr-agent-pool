<!--
Reference of the integrate skill: a PR needs a decision the integrator cannot make (policy,
scope, a privacy or security rule, an exception the PR asks for). Read from step 2 (Review).
-->

# A PR needs a decision that is not yours

It never leaves you waiting: one integrator blocked at a dialog stops a whole pool member for
hours.

1. Look for a decision already recorded:

   ```bash
   git grep -n -i "<keywords of the question>" origin/<base> -- docs/phases/ docs/decisions/ CLAUDE.md
   ```

   A recorded decision that answers it is your answer: cite it (file and line) in your review
   and go on.

2. If there is none, do not raise a dialog and do not wait for the user, at any hour:

   - Comment the question on the PR:
     `gh pr comment <N> --body "Needs a decision: <question>; see <context>"`.
   - Record the bounce, so the queue skips this head (it also releases a pool claim):
     `"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" bounce <N> --head <head-sha> --owner <me>`.
   - Tell the coordinator (pool mode). In single mode, leave it for the user.
   - Take the next PR.

The PR comes back to the queue when its author pushes a new head after the decision.
