<!--
Reference of the coordinate skill: details of the integrator pool that the normal loop does not
need. Read when an integrator asks for priority to push, when open PRs wait while every member
is idle, or to know exactly what the watcher, `scale` and `spawn` do.
-->

# The pool: details

## An integrator asks for priority

A member whose merge kept losing the race for the base (`integrate-pr.sh` exit 7) may ask for
priority. Tell the others to hold their next push until it has landed (they hold off by not
starting the next PR), and tell them when it is done.

## PRs wait while every member is idle

A lost announcement. Check with `gh pr list --base <base> --state open`, then nudge the first
idle member:

```bash
herdr agent prompt "<member>" "[herdr message from agent <me>; not from the user]
The queue has unclaimed PRs: run /herdr-agent-pool:integrate."
```

## What the commands do

- **`watch`** spends no Claude tokens. Every minute it prompts an idle member (without a
  claim) when an open PR has waited unclaimed for `integrators.nudge_after_minutes`, each
  member at most once per that interval. It covers lost announcements and authors that
  announce to a busy member. A second `watch` exits at once, so restarting it is safe.
- **`list`** prints one line per member: `n  name  status  worktree  claims  idle-seconds`
  (`status` is the herdr status, or `down`).
- **`scale`** changes nothing. It prints the facts (live members and their claims, claimable
  open PRs, development agents) and a rule-of-thumb suggestion: one integrator per
  `integrators.scale_up_when_active_agents_gt` development agents. An integrator costs one
  session plus heavy-slot time.
- **`spawn <n>`** creates the verify worktree `../<worktree_prefix>integrator-<n>` the first
  time (detached at `origin/<base>`, with `.env` and `scripts/worktree-setup.sh`), opens its
  own herdr workspace, starts Claude there as `<integrator_name>-<n>` with
  `CLAUDE_ROLE=integrator`, and sends it the kickoff (`/herdr-agent-pool:integrate`).
  `integrators.max` is the one hard bound on `<n>`.
- **`stop <n> --remove-worktree`** also discards the member's verify worktree.
