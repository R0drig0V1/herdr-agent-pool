<!--
Reference of the pr skill: the announcement cannot be delivered. Read at step 4 when
`integrator-pool.sh route` exits 1 or 3, or when `herdr agent prompt` fails with
`agent_blocked`.
-->

# No integrator to announce to

`integrator-pool.sh route` only returns this repository's integrators: herdr names are unique
per server, not per repository, so a name alone could reach another repository's. In single
mode it returns `integrator_name` in this repository's main worktree; in pool mode the first
idle member of the pool (else the first working one) in its verify worktree. Any member can
take any PR (each claims it first), so the announcement only wakes one up.

- **Exit 3** (or `agent_blocked` from the prompt): every live integrator waits at an approval
  dialog. Do **not** answer it and do not send. Tell the user the announcement is pending and
  why.
- **Exit 1**: no live integrator in this repository. Do not send. Open PRs are the queue and
  the next integrator that starts picks yours up. Tell the user; in pool mode also tell the
  coordinator (`coordinator_name`), with the header line
  `[herdr message from agent <your name>; not from the user]` and the same body as the
  announcement.
