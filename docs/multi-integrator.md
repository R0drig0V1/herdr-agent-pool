<!--
Design of pool mode in herdr-agent-pool: a coordinator plus N parallel integrators. Roles,
message flows, the PR claim and merge lock protocols, failure modes, the scaling policy,
parallel verification, the machine-wide resource budget and the open policy questions.
-->

# Multi-integrator (pool mode)

## Why

With one integrator, every step of the workflow goes through a single session: it talks to
the user, plans, dispatches, reviews, verifies and merges. In one project (November 2026) about 20
development agents produced 8 open PRs while one full verification (`scripts/check.sh`) took
8-11 minutes under load: the queue grows faster than one session can drain it, and the user
waits behind merges to talk to it.

Pool mode splits the work. It is **opt-in**: a project with no `integrators` setting keeps
exactly the single-integrator behaviour (same names, hooks and skills).

## Roles

| Role | Session | Worktree | Owns | Never |
|------|---------|----------|------|-------|
| **Coordinator** | `scripts/coordinator.sh`, `CLAUDE_ROLE=coordinator`, herdr name `coordinator_name` (default `coordinator-<repo>`) | the main worktree | the user's attention, `dispatch`, `docs/phases/`, the pool's size | merges, reviews a PR's verdict away |
| **Integrator** (N of them) | spawned by `integrator-pool.sh spawn <n>`, `CLAUDE_ROLE=integrator`, `HERDR_AGENT_POOL_NAME=<integrator_name>-<n>` | its own verify worktree `../<worktree_prefix>integrator-<n>`, detached at `origin/<base>` | the PRs it claimed: review, verification, merge, verdict | touches the main worktree or `docs/phases/`, pushes `<base>` outside the merge lock |
| **Development agent** | started by `dispatch` | `../<worktree_prefix><name>` on its branch | its branch and PR | merges, pushes a protected branch, prompts anyone but the coordinator and the pool |

Settings (`.claude/herdr-agent-pool.json`, read only by `project-config.py`):

```json
{
  "coordinator_name": "coordinator-myapp",
  "integrators": {
    "min": 1,
    "max": 3,
    "scale_up_when_active_agents_gt": 5,
    "scale_down_idle_minutes": 30,
    "claim_ttl_minutes": 60,
    "max_reverify": 3,
    "reverify_exempt_paths": ["docs/phases/*.md"],
    "locked_reverify_minutes": 60,
    "nudge_after_minutes": 5
  },
  "numbered_files": {
    "adr": "docs/decisions/(\\d{4})-.*\\.md",
    "migration": "src/app/migrations/(\\d{4})_.*\\.sql"
  }
}
```

The `integrators` object turns pool mode on; every key in it is optional (the values above
are the defaults). `numbered_files` (default `{}`, both modes) names the numbered files that
`integrate-pr.sh` renumbers at merge when parallel branches took the same number; see
"Numbered files" below.

A `verify` object, in either mode, shapes the merge verification: `check_env` adds variables
to `scripts/check.sh`'s environment on every merge verification (for example
`{"PROJECT_CHECK_SCOPE": "fast"}`: a fast lane for merges while promotions run the full
check), and `docs_only_env` is added on top when every path the merge changes matches
`docs_only_paths` (a docs-only lane; off while that list is empty). A variable the caller
already exported wins over both (export `PROJECT_CHECK_SCOPE=full` before `integrate-pr.sh`
for a full-scope merge verification). Identity variables
(`CLAUDE_*`, `HERDR_*`, `HERDR_AGENT_POOL_*`) are refused. `project-config.py` derives `mode` (`single`/`pool`) and `integrator_pool`
(`<integrator_name>-1` .. `-max`, each cut to herdr's 32 characters).

## Message flows

The chain of command is short: nothing hops through the coordinator that does not need it.

```mermaid
sequenceDiagram
    actor User
    participant C as coordinator-repo
    participant D as dev agent (feat/x)
    participant I1 as integrator-repo-1
    participant I2 as integrator-repo-2
    participant GH as GitHub (queue)
    participant S as pool state (git common dir)

    User->>C: "build X"
    C->>C: resource-board.sh show (room for one more?)
    C->>D: dispatch (worktree, workspace, brief)
    D-->>C: question (herdr prompt)
    C-->>D: answer (or the user's decision)
    D->>C: RESOURCE REQUEST: dev server + e2e, ~3 GB, ~20 min
    C-->>D: RESOURCE WAIT: 2 verifications running; ask again after PR #12 lands
    D->>GH: gh pr create
    D->>I1: "PR #12 ready" (integrator-pool.sh route: first idle member)
    I1->>S: claim 12 (mkdir, atomic)
    I2->>S: claim 12
    S-->>I2: exit 3 (held): next PR
    I1->>I1: review, integrate-pr.sh: merge + verify in its own worktree
    I1->>S: lock run (flock) + origin/base unchanged?
    I1->>GH: git push origin HEAD:main (fast-forward only)
    I1->>S: report add 12, release 12
    I1->>GH: PR comment (durable verdict)
    I1->>D: "PR #12 merged as abc123" (direct)
    I1->>C: "PR #12 merged; plan tasks: ..."
    C->>C: tick docs/phases, commit
    C->>S: lock run -- git push (plan commit)
    C->>S: report done 12
```

| Message | From | To | How |
|---------|------|----|-----|
| PR announcement | development agent | one pool member | `pr` -> `integrator-pool.sh route` (first `idle`/`done` member, else the first `working` one; never a `blocked` one) |
| Question, blocked state | development agent | coordinator | `herdr agent prompt <coordinator_name>` |
| Verdict | the integrator that handled the PR | the author | PR comment + `herdr agent prompt` (resolved with `agents-in-repo.py --branch`) |
| Merge report | integrator | coordinator | `pool-state.py report add` (durable) + `herdr agent prompt` (wake-up) |
| Kickoff, nudge | coordinator | pool member | `integrator-pool.sh spawn`, or a prompt when PRs wait and every member is idle |
| `RESOURCE REQUEST` / `GO` / `WAIT` / `YIELD`, `SAVE MODE ON/OFF` | any agent <-> coordinator | negotiated against the resource board (see "Resources") |
| Load, priority for a push | pool member <-> coordinator | the coordinator asks before scaling; a member that lost the race for the base (exit 7) asks for priority |

The announcement is only a wake-up: GitHub's open PRs are the queue, and every member reads
it (`pool-state.py queue`) and claims before working, so announcing to one member is enough
and a lost announcement only delays a PR until the next member looks.

## PR claims

State lives in the repository's git common dir, `<common>/herdr-agent-pool/`: every
integrator runs on the same machine (herdr is local), so a directory there is shared by all
of them and by nobody else.

- **Claim** = `mkdir claims/pr-<N>` (atomic on any POSIX file system: exactly one of several
  concurrent `mkdir`s succeeds), then `owner.json` (`owner`, `head`, `since`, `heartbeat`),
  written to a temporary file and renamed in place.
- **Heartbeat**: `integrate-pr.sh` refreshes it at the start and every 2 minutes during a
  verification.
- **Stale** = the heartbeat is older than `claim_ttl_minutes`, or the owner has been missing
  from `herdr agent list` for a grace period (`$HERDR_AGENT_POOL_MISSING_GRACE`, 180 s by
  default). The first listing that misses the owner only records `missing_since`, so one
  glitchy listing cannot hand a live claim over. When herdr cannot be asked, only the age
  counts. A claim directory without `owner.json` is "being created" for 60 s, then stale.
- **The claims lock.** Every read-decide-write of the claims holds `claims/.lock`, a kernel
  `flock`: claim, release, heartbeat, bounce, and the queue's staleness checks. Without it,
  two integrators that both judged a claim stale could each move the other's fresh claim
  aside, and both would own the PR. (Found in review; covered by a test where eight
  integrators race for one stale claim.)
- **Re-claim** of a stale claim: under the lock, `rename` the directory aside, then `mkdir`
  it again.
- **Release** = rename aside and delete, under the lock. Only the owner can release.
- **Re-checked before the push.** `integrate-pr.sh` heartbeats its claim again under the
  merge lock, right before pushing. If the claim changed hands meanwhile, it pushes nothing
  (exit 10).
- **Bounce record**: `bounced/pr-<N>.json` keeps the bounced head SHA. `queue` skips the PR
  until its head changes (the author pushed a fix), so a bounced PR is not re-verified in a
  loop by the next free integrator.

Alternatives considered: a GitHub label or assignee is not atomic (two integrators can both
add it; GitHub has no compare-and-swap on labels), costs API calls and needs write
permissions; a `flock` on a per-PR file would release the claim whenever the Bash command
holding it ends, while a claim must outlive many commands (review, then merge).

## Merge lock and the base-moved policy

Each integrator verifies in its own worktree, so verifications run in parallel; only the
**push to `<base>`** is serialized, by a short merge lock: `pool-state.py lock run --owner
<me> -- <command>` holds a kernel `flock` on `lock/merge.lock` while the command runs and
records the holder in `lock/merge.owner.json`. The kernel releases the lock when the holder
dies, so a crashed integrator cannot wedge the pool.

**Correctness does not depend on the lock.** The plugin never force-pushes, so a push whose
merge commit does not have the current `origin/<base>` as its first parent is rejected by the
remote as a non-fast-forward. Only a tree that was verified can land. The lock adds ordering
and a clear "base moved" signal, and keeps two integrators from re-merging at the same time.

`integrate-pr.sh` under the lock:

1. `git fetch origin <base>`; if `origin/<base>` is still the commit the verification started
   from, push the verified merge commit. Done.
2. Otherwise merge the PR head again onto the new `origin/<base>`. A conflict now is a
   bounce (the author rebases).
3. Compare the new merged tree with the verified one (`git diff --name-only`). When every
   difference matches `reverify_exempt_paths` (default `docs/phases/*.md`, compared with `--no-renames`: the coordinator's
   plan commits, which cannot change the result of the checks), commit and push at once.
   Likewise when the project has a `scripts/reverify-needed.sh` and it says the change cannot
   affect this PR's checks (below).
4. Otherwise release the lock and verify the new tree, then go back to 1; after
   `max_reverify` re-verifications, give the PR back to the queue (claim released, no
   bounce; exit 7). The **last** of those re-verifications runs inside the merge lock
   (`locked_reverify_minutes`, default 60, then it is killed; 0 turns this off): the base
   cannot move under it, so a long verification cannot starve. Other integrators wait for the
   lock meanwhile (up to 900 s, then their PR goes back to the queue without a bounce).

**`scripts/reverify-needed.sh`** (optional, the project's): `reverify-needed.sh <verified
base> <new base> <PR head>`, with the paths that differ between the verified tree and the new
merged tree on stdin, one per line. Only exit 0 with `no-reverify` as the last line of its
output means the new base cannot affect this PR's checks: push without verifying again.
Anything else (another line, another exit code, a crash, no answer within 120 s) verifies
again, so a broken hook fails closed. Its last output lines go to the integrator's log. It
runs under the merge lock in the verify worktree (the new merged tree is checked out), and it
is read from the **new base** commit, so a PR cannot change the rule for its own merge. Keep it
fast and conservative: a wrong "1" lets a semantic conflict land. A project that selects its
tests by path (a check scope) can answer from the intersection of the changed paths with the
PR's scope.

This is the merge-queue rule ("the tree that lands is the tree that was tested"), applied
per PR. Trade-offs of the policies considered:

| Policy when the base moved | Cost | Risk |
|----------------------------|------|------|
| **Re-verify** (chosen, except for exempt paths) | one more full check per collision (8-11 min in one project) | starvation under heavy merge traffic, bounded by `max_reverify` |
| Rebase/re-merge and push without verifying | none | a semantic conflict (both PRs green alone, red together) lands on `<base>` |
| Re-merge, re-verify only when the PRs touch the same files | small | the same semantic-conflict risk, through imports and shared fixtures |
| Exempt paths only (part of the chosen policy) | none | only as large as the exempt patterns: keep them to files no check reads |

Starvation: with N integrators finishing at similar times, the last one to push re-verifies
up to N-1 times. With 3 integrators and 10-minute checks the expected extra cost is small;
`max_reverify` caps the worst case and an exit 7 is visible to the coordinator.

### Speculative batching (evaluated, not implemented)

A merge queue can verify "A", "A+B" and "A+B+C" in parallel and land the longest green
prefix. That needs a shared ordering (the batch), a way to cancel the speculative runs that
depend on a failed one, and N times the machine resources at once. On one laptop the
resource budget, not the integrator count, is the limit (see below), so speculative runs
would mostly wait for heavy slots. Per-PR verification with re-verification on collision is
simpler and fails more legibly. Revisit on a machine with spare capacity: open question 3.

## Numbered files

Two parallel branches that each add "the next" migration or ADR pick the same number. With
`numbered_files` set (`{kind: regex}`; the regex matches a whole path and captures the number
in its one group), numbers are given **at merge time**:

1. The author takes the next free number on its own base (the highest of that kind on
   `origin/<base>`, plus one), so its local check passes. Two parallel branches may take the
   same number.
2. `integrate-pr.sh` runs `renumber.py` after `git merge --no-ff --no-commit` and before
   `verify-merge.sh`. The files of the kind that the PR adds (relative to the base it merges
   onto; renames do not count), in ascending order, keep their number when it is the next
   free one (one above every other file of the kind in the merged tree) and are otherwise
   moved with `git mv` to it, keeping the rest of the name and the zero padding. In the files
   the PR changed, and nowhere else, the old name without its extension becomes the new one;
   the bare old number is replaced only in lines the PR adds that also contain the file's
   slug, are table rows (`|`) of an index file (a non-numbered file in the numbered file's
   directory or its parent), are a heading of the renamed file itself, or name the number by
   its kind (`ADR 0001`, `adr_0001`: the kind's name, any case, then one space, `-`, `_` or
   `#`). A numbered table
   that was sorted is sorted again. One `RENUMBERED <kind> <old> -> <new>` line per rename
   is printed and added to the merge commit message.
3. The verification runs on the renumbered tree, so a bad rewrite fails the check instead of
   landing. A re-merge onto a moved base (under the merge lock) renumbers again.

With `--union-rows`, the index rows of two PRs that took the same number are kept (the
renumbered one is rewritten right after); any other duplicate key still bounces.

Before, the dispatcher reserved each number at dispatch (`pool-state.py reserve`). That made
finished work wait for unfinished work: a branch holding 0002 could not pass a "contiguous
from 0001" check while 0001 was still in progress, and the agent stopped to ask the user.
`reserve`, `reservations` and `unreserve` still work for setups that call them, and a merge
still ends its branch's reservations, but dispatch no longer uses them.

## Lost announcements: the pool watcher

An announcement goes to one member (`route`: the first idle one). Authors that announce to a
busy member by name, or a message lost while a member was blocked, leave PRs unclaimed while
another member idles. `integrator-pool.sh watch` (started by the coordinator in the
background; no Claude tokens) runs `nudge` every minute: when an open PR has waited unclaimed
for `integrators.nudge_after_minutes` (default 5; 0 turns it off), it prompts idle members that
hold no claim, one per waiting PR, each at most once per that interval. A PR still unclaimed
after 3 nudges is left to the coordinator, told once (a member may be declining it for a
reason the watcher cannot see). Each pass also asks agents stopped by an API error to
continue (`retry-stalled.py`, decision 0012) and compacts the development agents that wait
for a verdict with a large context (`compact-waiting.py`, decision 0014). A second `watch` for
the same repository exits at once (a kernel `flock`), so the coordinator restarts it safely.

## The base is red

When `origin/<base>` itself fails a test (a merge left a stale entry, a fast check scope did not
select the test), every PR's verification fails on it, and every author fixes the same line in
their own branch: wasted fixes and conflicting PRs. The pool turns that into **one owner**:

1. **Detect.** An integrator whose verification fails on tests unrelated to the PR runs only
   those tests on `origin/<base>` (inside a heavy slot). When they fail there too, it records
   `pool-state.py base-red report --tests "<ids>" --suspect <PR> --owner <me>` (`base-red.json`
   in the pool state; several reports merge their tests), holds the PR (below) and tells the
   coordinator `BASE RED: ...`. A coordinator whose promotion check fails on the base reports
   it the same way.
2. **One owner.** The coordinator names it: `pool-state.py base-red assign <agent> --branch
   <its branch>` (coordinator only), dispatching a fix task when nobody is on it.
3. **Everyone else waits.** `pool-state.py base-red show` prints the banner `BASE <base> IS RED
   since <time>: <tests>; suspect PR #<S>; fix assigned to <owner>. Do NOT fix it in your
   branch: rebase after the fix lands.` The `commit` and `pr` skills show it and do not stop on
   those tests; `verify-merge.sh` prints it and hands the tests to `scripts/check.sh` as
   `$HERDR_AGENT_POOL_BASE_RED_TESTS` (space-separated; a project may leave them out, which is
   the explicit exemption). While the base is red, a failed merge verification is
   `integrate-pr.sh` exit 14 instead of a bounce, with the claim kept: when only the red tests
   failed the integrator runs `pool-state.py hold <N> --head <sha>` (the claim is released, a
   bounce of that head is undone, and `queue` skips the PR while the base is red); otherwise it
   bounces as usual.
4. **Clear.** Merging the assigned fix's branch clears the entry (`integrate-pr.sh` runs
   `base-red clear --if-branch <B>`), or the coordinator clears it after a green base check.
   Held PRs return to the queue; the cleared period is appended to `base-red.log`.

`report`, `clear` and `hold` are for pool members (and the coordinator), `assign` for the
coordinator only; `show` is for everyone. The state is files, like the rest of the pool's.

## Who owns the plan

The coordinator owns `docs/phases/`. Integrators never write it: after a merge,
`integrate-pr.sh` records a **plan report** (`reports/pr-<N>.json`: the merge sha and the PR
body's "Plan tasks completed" section) and the integrator prompts the coordinator. The
coordinator ticks the tasks in the main worktree, commits `docs(plan): ...`, rebases onto
`origin/<base>`, pushes under the merge lock, and marks the reports done
(`reports/done/`). Because plan commits only touch `docs/phases/`, they never cost an
integrator a re-verification. Reports survive a coordinator that is down; on restart it
also compares recently merged PRs with the known reports (`pool-state.py report known`).

## Guards

| Action | Development agent | Pool integrator | Coordinator | Single-mode integrator |
|--------|-------------------|-----------------|-------------|------------------------|
| Edit/commit in the main worktree | blocked | blocked | allowed | allowed |
| `git push` to a protected branch | blocked | only via `pool-state.py lock run --` (and `integrate-pr.sh`) | only via `pool-state.py lock run --` | allowed |
| `git push --all/--mirror`, `gh pr merge` | blocked | blocked | blocked | allowed |
| `git push --force`/`--delete`, `+` or `:` refspec on a protected branch | blocked | blocked, even under the lock | blocked, even under the lock | allowed |
| `integrate-pr.sh`; `pool-state.py` claim, release, heartbeat, bounce, lock run, report add/done | blocked | allowed | allowed | allowed |
| `integrator-pool.sh` spawn/stop, `cleanup-worktree.sh <branch>`, `integrator-watch.sh` (single mode only), `retry-stalled.py`, `compact-waiting.py` | blocked | blocked | allowed | allowed |
| Setting `CLAUDE_ROLE`, `HERDR_AGENT_POOL_NAME`, `HERDR_AGENT_POOL_SLOT` or `HERDR_ENV` in a command (`VAR=x cmd`, `env`, `export`) | blocked | blocked | blocked | allowed |
| herdr input commands (`pane run`, `send-keys`...) | blocked | allowed* | allowed* | allowed* |
| `herdr agent prompt` | only the coordinator and the pool (single mode: the integrator) | anyone | anyone | anyone |
| Anything above, while `.claude/herdr-agent-pool.json` is invalid | blocked | blocked | blocked | blocked (fail closed; the file itself may be edited) |

\* Allowed by the guard because these roles start and message agents; the rule "never answer
another agent's dialog" stays a rule of their skills and prompts.

The roles come from environment variables, which any session can set, so the real boundary
is herdr's own record of who runs in which pane.

1. **The boundary.** Who calls is decided by herdr and the process tree, not by variables.
   `pool-state.py whoami` takes the pane in `$HERDR_PANE_ID`, but believes it only when that
   pane's shell (`herdr pane process-info`) is an ancestor of the calling process. A forged
   id points at a pane whose shell is not an ancestor, and a missing id gives no answer: no
   fallback to the focused pane. herdr calls time out after 10 s.

   In pool mode, `pool-state.py` refuses (exit 4) claim, release, heartbeat, bounce,
   `lock run` and the plan reports unless the herdr agent of the calling pane is a member of
   `integrator_pool` (or the coordinator, for `lock run` and `report done`), and `--owner` is
   that agent. When herdr cannot answer, it refuses (fail closed). `integrate-pr.sh` requires
   the same membership before it touches anything.
2. **The guard** blocks commands that set an identity variable. It parses the command prefix
   the way the shell does, so `env -u NAME`, `env -C DIR`, `env -S 'STRING'`, `exec -a` and
   `time -o` cannot hide an assignment.
3. **The guard** blocks the role-only scripts for sessions without the role, also when they
   run through an interpreter (`bash script.sh`, `python3 [-I] script.py`).

The guards stay guardrails, not a sandbox (README, Limitations): a script file of the
agent's own is not inspected.

## Failure modes

| Failure | What happens | Recovery |
|---------|--------------|----------|
| An integrator crashes **before or during the verification** | its claim stops heartbeating; its herdr agent disappears, so the claim is stale at once | another integrator re-claims the PR from the queue (`stale`); when the member is respawned, `integrate-pr.sh` aborts the merge left in its own worktree |
| A merged agent's worktree is never cleaned up (the dispatcher was down, the agent stayed busy) | its session keeps memory; the branch stays | `cleanup-worktree.sh --list` on the next pass finds it `ready` or tells why not |
| An integrator crashes **holding the merge lock** | the kernel releases the `flock` with the process | the next `lock run` proceeds; the push either happened (atomic on the remote) or not |
| An integrator crashes **after the push, before its verdict/report** | the PR is merged on GitHub (the head is in `<base>`), the claim goes stale, no plan report | the PR leaves the open queue by itself; the coordinator's catch-up step finds the merged PR without a report and ticks it; the author sees the merge on GitHub (no herdr verdict) |
| Two integrators claim the same PR | exactly one `mkdir` succeeds | the loser gets exit 3 and takes the next PR |
| A second `integrate-pr.sh` starts in a worktree where one is running | the per-worktree lock (a `flock` in the worktree's git dir) refuses it with exit 2, before it touches the merge in progress | the integrator waits for the first run's `RESULT`; a lock left by a dead run's leftover process is taken over |
| Two integrators push at once | the lock serializes them; without it, the remote would reject the second as a non-fast-forward | the second one re-merges (and re-verifies unless only exempt paths moved) |
| `<base>` moves during a verification | detected under the lock | re-merge, push or re-verify (policy above); exit 7 after `max_reverify` |
| The head branch moves during a verification | the verified head is merged; the branch is **kept** (deleted only when PR head = remote head = merged head, with a lease on that commit) | the PR stays open with the new commits and comes back to the queue |
| The coordinator is down | integrators keep merging; reports accumulate; development agents' questions get no answer (the `pr` skill tells the user when the coordinator is not live) | on restart, `coordinate` reads pending reports and catches up merged PRs |
| Every integrator is down | `route` exits 1; announcements are not sent | the PRs wait in GitHub's queue; the coordinator's scale check spawns `min` members |
| herdr cannot be asked | claims are judged by age only; `route` finds nobody | nothing is merged twice: claims still hold until their TTL |
| One herdr listing misses a live integrator | its claim is marked `missing_since`, not taken | the next listing that shows it clears the mark (its heartbeat rewrites the claim) |
| A claim changes hands anyway during a long verification | the first integrator re-checks its claim under the merge lock | it pushes nothing (exit 10) and leaves the PR to the new owner |
| A verification's wait for a slot is interrupted (someone stopped the waiting `resource-budget.py`) | `verify-merge.sh` exits 120: nothing was checked | `integrate-pr.sh` resets, releases the claim and exits 13: back to the queue, no bounce |
| An integrator resumes after an outage, sleep or a long dialog | its picture of the PRs, claims and base is old (one tried to merge a PR merged 7 h earlier) | the `integrate` skill refreshes claims, open PRs and the base before acting |
| A PR needs a decision the integrator cannot make | before, it waited at a dialog (6 h one night: half the pool) | it looks for a recorded decision (`docs/phases/`, `docs/decisions/`, `CLAUDE.md`); without one it comments the question, bounces the head, tells the coordinator and takes the next PR |
| The push under the merge lock hangs | killed after 600 s (`lock run --max-seconds`) | the claim is released and the PR goes back to the queue (exit 6) |
| `.claude/herdr-agent-pool.json` becomes invalid | every role loses its rights (fail closed) | fix the file (the Edit guard allows that one file); `project-config.py` names the error |
| The machine runs out of memory | every agent loses its turn | prevented by the resource budget below |

## Scaling

Scaling is a decision the coordinator takes in conversation, not a formula the plugin applies.
`integrator-pool.sh scale` changes nothing: it prints the facts (live members, their claims
and inactivity, claimable open PRs, development agents) and a rule of thumb, one integrator
per `scale_up_when_active_agents_gt` development agents within `[min, max]`. Development
agents are the live herdr agents in a linked worktree of this repository that is on a branch
(`agents-in-repo.py --dev-only`), idle ones included, since an agent waiting for a verdict
still means a PR in flight.

The coordinator then weighs:

- what the members say about their load: how long their current PR will take, and whether
  the queue is long;
- what the resource board says about the machine.

An integrator costs one session plus heavy-slot time. With every heavy slot busy, another
integrator only waits.

- **Scaling up** is `spawn <n>`. `max` is the one hard bound.
- **Scaling down** is `stop <n>`:
  - for a member that is idle with an empty queue (`scale` marks the ones inactive for
    `scale_down_idle_minutes`), or whose memory is needed elsewhere;
  - only when the member is `idle`/`done` and holds no claim;
  - only for workspaces `spawn` opened (recorded in `members/<name>.json`).

  The verify worktree is kept, so the next spawn reuses its installed dependencies.

## Parallel verification: what the project must provide

With several integrators, `scripts/check.sh`, `scripts/worktree-setup.sh` and
`scripts/verify-reset.sh` run at the same time in different worktrees. The project must make
them **parallel-safe**:

- No fixed ports: bind port 0, or inject the server instead of binding.
- Every database, container, cache or directory written outside the worktree is private to
  the run (a random name) or shared read-only; nothing one run wipes can be in use by another.
- `verify-reset.sh` resets only the state of its own worktree.
- Shared services (a database server) are started idempotently by name.

**An example that satisfies it** (a Python project with PostgreSQL):

- The Docker Compose project name is fixed, so every worktree's database setup script
  (`docker compose up -d --wait db`) reaches the same PostgreSQL server on one port.
- The test fixtures give each pytest session its own template database `<app>_test_<random>`
  (migrated once) and each test a fresh copy (`CREATE DATABASE ... TEMPLATE`), dropped
  afterwards; databases left by killed runs are dropped only when stamped more than 6 h ago
  **and** unused, so a run in another worktree is never disturbed.
- `tests/conftest.py` points `HOME` and the data directory into `tmp_path`.
- The serve tests inject uvicorn ("no port is bound").
- `scripts/worktree-setup.sh` installs into the worktree (`.venv`, `web/node_modules`).

What remains shared is CPU and memory. The machine-wide resource budget handles that.

## Resources: negotiated, with one hard floor

On 2026-11-09 the user's 24 GB machine ran out of memory, and every agent lost its turn. At
the time it was running about 20 development agents, several integrators, and checks in
parallel. A day later the resource board listed 47 live herdr agents across several projects.
Many were idle or done, and each still held its memory.

Resources are therefore **negotiated**, not computed. The coordinator is the arbiter, the
**resource board** is the shared sheet everyone reads, and only one thing is mechanical.

**The hard floor: heavy slots** (`resource-budget.py run`). At most `heavy_slots` heavy
commands run at once on the machine, across every agent and project.

- `verify-merge.sh` runs `check.sh` through it, and so do the `commit` and `pr` skills.
- Worktree setup (`worktree-setup.sh`, from `verify-merge.sh`, `new-worktree.sh` and
  `integrator-pool.sh spawn`) goes through a separate **light** pool (`light_slots`,
  default 2): a warm-cache install never waits behind a test suite, yet a burst of new
  worktrees cannot all install at once. (In one project, a new-worktree setup once waited 40 min
  for a heavy slot.)
- It stays code because a conversation cannot stop a process that is already allocating
  memory. When memory is scarce, agents answer late or not at all.
- Slots are `flock`ed files in `~/.cache/herdr-agent-pool/resources/`, so a crashed holder
  frees its slot. A nested call (`$HERDR_AGENT_POOL_SLOT` set) runs at once instead of
  deadlocking.
- Waiters **queue**. Each one writes a ticket; a free slot goes to the first ticket in
  priority order, oldest first within a priority: `merge` (an integrator's
  `verify-merge.sh`, honoured only for CLAUDE_ROLE=integrator), then `plan` (the
  coordinator's own checks), then `normal` (everything else). A ticket that waited 20 min
  counts as `merge`, so nothing starves. Before this queue, waiters polled with no order: in
  one project, author checks kept beating merge verifications to the slot, and one PR waited
  40 min while a slot stood free.
- Every retry **re-reads the limits**. Raising `heavy_slots` admits waiters at once; lowering
  it admits nobody new until the holders above the new limit finish (they are never killed,
  and the board lists them). A limits file that is half written when a waiter reads it keeps
  the waiter's last good limit.
- The command gets `$HERDR_AGENT_POOL_SLOT_COUNT` (the pool's limit when it was admitted),
  so a project can size its parallelism, e.g. test workers = cores / slots: two checks with 4
  workers each load a shared test database like one check with 8.
- A waiter stopped by a signal (SIGTERM, SIGINT, SIGHUP) exits 120: its command never ran.
  `verify-merge.sh` passes 120 on, and `integrate-pr.sh` turns it into exit 13 (back to the
  queue, no bounce). Do not stop waiters to make them see a new limit: they see it anyway.
- Its limits:
  - it binds only the commands run through it, not a suite an agent starts by hand;
  - setting `HERDR_AGENT_POOL_SLOT` would skip it, so the guard blocks that;
  - when its state directory cannot be created it warns and runs the command anyway, so the
    floor never makes a verification fail;
  - an invalid `resources.json` makes every wrapped command fail. `resource-budget.py
    limits` shows the error.

**The resource board** (`resource-board.sh`) is a human-readable Markdown sheet, machine-wide,
with one file per agent so nobody overwrites anybody.

- Before an agent starts something heavier or longer-lived than a normal check (a server, a
  container, a watcher, a benchmark, parallel subagents), it writes a note: what it runs, an
  estimated GB figure, and how long it expects to take. It clears the note when the thing
  stops.
- `show` prints:
  - memory, flagged **LOW** below `low_memory_gb`;
  - the live herdr agents, and the working ones against the machine's `sessions_guideline`
    (idle and done sessions do not count: the memory line shows what they hold);
  - who holds each heavy and light slot, and for how long, flagging a holder above a lowered
    limit; and the waiters, in turn order with their priority;
  - every note, flagged **overdue** or **(gone)**;
  - the agents that look idle.
- `prune` drops the notes of agents that are no longer live.

**The protocol.** Every message carries the usual header and goes through the coordinator,
so 20 agents never talk all-to-all:

| Message | From -> to | Meaning |
|---------|------------|---------|
| `RESOURCE REQUEST: <what>, ~<GB> GB, ~<min> min, for <PR or task>` | any agent -> coordinator | "may I start this?" A long heavy-slot wait that blocks something urgent is a request too, never a reason to bypass the wrapper |
| `RESOURCE GO: <what>` | coordinator -> requester | start it, and note it on the board |
| `RESOURCE WAIT: <why>; ask again after <event>` | coordinator -> requester | deferred, with a concrete next step; possibly "run only the targeted tests" |
| `RESOURCE YIELD: <what>, because <why>` | coordinator -> an agent | pause or stop at a safe point and confirm (or explain why not); pool integrators finish the PR in progress and claim no new one |
| `SAVE MODE ON: <why>` / `SAVE MODE OFF` | coordinator -> the repository's agents | nothing new and heavy starts, and idle agents finish up; sent when memory is LOW or sessions are well over the guideline |

**The coordinator's priorities**, in order:

1. what unblocks a merge (an integrator's verification, an author fixing a bounce);
2. what the current phase of the plan needs;
3. everything else, first come first served.

Before each dispatch or spawn, it reads the board. When the board is over the guideline or
LOW, it does not start one more session: it tells the user which agents look idle and lets
them decide. Agents never close another agent's workspace, except a pool member through
`integrator-pool.sh stop`.

**The cost** of negotiating: every message wakes an agent (tokens, and a turn's worth of
memory). That is why the protocol is hub-and-spoke through the coordinator, and why an agent
asks only for what goes beyond a normal check. The normal check just waits for its slot.

Limits are per machine, in `~/.config/herdr-agent-pool/resources.json`, overriding defaults
derived from the RAM. `heavy_slots` and `light_slots` (default 2 on every machine) are
enforced; the other two are guidelines the board shows and the coordinator weighs:

| RAM | `heavy_slots` (enforced) | `sessions_guideline` | `low_memory_gb` |
|-----|--------------------------|----------------------|-----------------|
| 16 GB | 1 | 8 | 1.6 |
| 24 GB | 2 | 12 | 2.4 |
| 32 GB | 3 | 16 | 3.2 |
| 64 GB | 7 | 32 | 6.4 |

The reasoning behind the defaults:

- About 8 GB stay reserved for the system, the editor and the Docker VM.
- Each Claude Code session takes 0.5-1.5 GB with its tools.
- A heavy check needs 3-6 GB at its peak (one project: pytest with PostgreSQL copies, vitest
  with coverage, a Vite build).

So: sessions ≈ RAM / 2 and heavy slots ≈ (RAM − 8) / 8. Measure the project's own check
(peak RSS of `scripts/check.sh`, for example with `/usr/bin/time -l`) and adjust.

## Cleanup

A worktree whose branch was merged has done its job. Left behind, it keeps a Claude session,
that session's memory and its installed dependencies alive, and the branch list only grows.
So the one who dispatched the agent discards it after the merge: the integrator in single
mode (through its watcher, `integrator-watch.sh`), the coordinator in pool mode. That is the one who opened the workspace, so it may
close it. The flow:

1. The merged verdict tells the author its task is done: report to the user in one line,
   clear its resource-board note, and stop.
2. `cleanup-worktree.sh --list` shows every development worktree and its state: `ready`,
   `merged-agent-busy`, `merged-but-dirty` or `not-merged`.
3. `cleanup-worktree.sh <branch>` removes nothing unless every check passes:
   - GitHub has a merged PR from the branch into `<base>`, and the branch tip is contained in
     `origin/<base>`, so nothing was added after the merge. Ancestry alone is not enough: a
     branch dispatched a minute ago, with no commit yet, is also contained in the base.
   - The worktree has no uncommitted or untracked file.
   - Every agent in the worktree is `idle` or `done`.
   - Every pane of the workspace to close is inside the worktree.

   Then it:
   - closes the workspace;
   - runs `git worktree remove` (never `--force`);
   - deletes the local branch;
   - deletes the remote branch, only when it still points at the merged tip (with a lease
     on that commit);
   - clears the agents' board notes.
4. Exit 5 (the agent is still busy) means try again on the next pass. Exit 4 (uncommitted
   work) goes to the author or the user and is never discarded. A `not-merged` branch nobody
   works on is the user's call.

Pool members' verify worktrees are kept across `stop`, so the next spawn reuses their
dependencies. `integrator-pool.sh stop <n> --remove-worktree` discards one when the pool
shrinks for good.

## integrate-pr.sh

The merge itself is a script, not a sequence of commands an agent retypes. Each step is
gated on the previous one's exit code, and the exit code is the verdict (see its header for
the codes). It folds in the lessons of an earlier project-specific integration helper:

- **Stop on any conflict** except rows of an index table given with `--union-rows`
  (`union-rows.py`). The resolver keeps the rows of both sides and refuses two different rows
  with the same key, unless the key is a number the PR's renumbering changes ("Numbered
  files").
- **Abort and reset on a failed verification**: `git merge --abort`, then
  `verify-merge.sh --reset-only`, so the next PR starts clean. A `check.sh` that modifies
  tracked files counts as a failure.
- **No verdict without a check**: when the verification never ran (its wait for a slot was
  interrupted, `verify-merge.sh` exit 120), the PR goes back to the queue without a bounce
  (exit 13). Before, killing a waiter recorded a false bounce.
- **No bounce for a red base**: while `pool-state.py base-red` says the base fails on its own,
  a failed verification is exit 14 (claim kept), and the integrator holds the PR or bounces
  it ("The base is red").
- **Keep the branch when it moved during the verification.** The branch is deleted only when
  the PR's head, the remote branch and the merged head are the same commit and it is in
  `origin/<base>`.

  The delete carries `--force-with-lease=refs/heads/<B>:<head>`, which makes it conditional
  on that commit and closes the window between the check and the delete. It rewrites no
  history.

  Twice, a premature deletion closed a PR whose author had pushed during the verification.

It is used in both modes. In single mode it runs in the main worktree on the base branch.

## Open questions (policy, for the user)

1. **Integrators merge without the coordinator's say.** A green, reviewed PR lands as soon as
   its integrator is done. The coordinator only learns of it afterwards. Should merges that
   touch some areas (migrations, security, `CLAUDE.md`) wait for the coordinator or the user?
2. **The coordinator pushes plan commits to `<base>` directly** (under the merge lock, not
   through a PR). This matches what the single integrator did before. The alternative, a
   plan PR verified by the pool, costs a full verification per tick.
3. **Speculative batching** (verify A+B together) is not implemented, because the machine's
   memory is the bottleneck. Revisit on a bigger machine or with CI-hosted verification.
4. **`reverify_exempt_paths` defaults to `docs/phases/*.md`.** A project whose checks read the
   plan (a docs linter, link checks) must set it to `[]`.
5. **Scaling is the coordinator's judgment.** The rule of thumb counts every live
   development agent, idle ones included. Should a hard minimum or maximum ever be
   automatic, for example spawning `min` when every member died?
6. **Sessions are a guideline, not a limit.** Only heavy slots are enforced. Should the
   plugin refuse to start an agent when memory is LOW, instead of the coordinator asking
   the user?
7. **Hub-and-spoke negotiation through the coordinator** costs one coordinator turn per
   request. Integrators could instead settle push priority between themselves directly, at
   the price of more messages.
8. **Resource limits are defaults from the RAM, not measurements.** Should the board record
   the peak memory each heavy command actually used, to replace the agents' estimates?
