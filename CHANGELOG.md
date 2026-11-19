<!-- Release history of herdr-agent-pool, in Keep a Changelog format. -->

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Lessons from a project's first night in pool mode (3 integrators, about 15 agents).

### Changed
- The README is short: what the plugin does, the diagram, install, the skills, the core rules
  and a documentation index. Every detail it held moved to the new `docs/reference.md`.
- Fewer conflicts and interruptions, from a measured benchmark (docs/benchmark/):
  - the template's `.gitattributes` marks `CHANGELOG.md` and the docs indexes `merge=union`,
    so parallel PRs that append at the same spot no longer bounce (README, "Fewer conflicts");
  - the dispatcher runs `/herdr-agent-pool:improve-plan` before a phase's first dispatch when
    the phase has no review;
  - the `sessions_guideline` counts working agents only: idle and done sessions (often of
    other repositories) no longer block a dispatch or make the dispatcher ask the user, and
    working agents over the guideline are reported, not a stop; only low memory stops it;
  - the `pr` skill fetches with `--prune` before rebasing and after a rejected push of a new
    branch, so a stale `origin/<branch>` is not mistaken for someone else's branch.
- Numbered files (`numbered_files`: migrations, ADRs) are numbered at merge time, not at
  dispatch. Authors take the next free number on their own base, so their checks pass, and
  `integrate-pr.sh` (new `renumber.py`) moves a PR's new files to the next free numbers on
  the base it merges onto, rewrites their names, index rows and links in the PR's files,
  prints one `RENUMBERED` line per rename (also in the merge commit message) and verifies
  the renumbered tree; re-merges onto a moved base renumber again. `union-rows.py` keeps two
  index rows with a number being renumbered (`--allow-key`). The `dispatch` skill no longer
  reserves numbers; `pool-state.py reserve` still works but is not used by it. In a measured
  run, a reserved 0002 failed a "contiguous from 0001" check while 0001 was unfinished, and
  the agent stopped to ask the user.
- A slimmer single-mode integrator (decision 0010): its mechanical steps moved into scripts
  that spend no tokens.
  - `integrate-pr.sh` ticks the plan tasks the PR body lists by id (`T1.2`) under "Plan tasks
    completed" in `docs/phases/*.md` inside the merge commit, before the verification (new
    `plan-tick.py`; one `PLAN-TICKED` or `PLAN-UNTICKED` line each, also in the commit
    message); re-merges tick again. No separate `docs(plan)` commit per PR. The new setting
    `plan_ticks_in_merge` (default `true`) turns it off; pool mode is unchanged.
  - New `integrator-watch.sh`, started by the `integrate` skill in the background: every
    minute it cleans up the worktrees `cleanup-worktree.sh --list` reports `ready`, and wakes
    the integrator, only when it is idle or done, once per item, about open PRs that wait for
    a verdict and queued PRs the lander merged or took out of the queue. In a measured run
    the integrator sat idle 14 minutes after lander merges nothing told it about.
  - The `pr` skill's body template lists each completed task by its id.
- `install.sh` is now the whole per-repository setup, one command instead of three steps. It
  installs the plugin for the project with the `claude` CLI when it is not installed yet
  (`--no-plugin` skips it), checks `jq`, `python3`, `gh`, herdr and herdr's Claude
  integration, asks before running `herdr integration install claude`, and ends with a
  report of the machine and only the steps that are left. `/herdr-agent-pool:setup` is no
  longer a required step. herdr itself is never installed by it.
- `install.sh` refuses to write through a symbolic link or outside the repository, and stops
  before copying when `.claude/settings.json` is valid JSON but not an object.
- The integrator no longer tells the other agents that the base moved after a merge, and an
  author no longer rebases or force-pushes a branch it has announced unless it bounced. Every
  PR is already verified merged onto the current base. In a measured run (1 integrator, 3
  agents, 6 tasks) those messages were a third of all messages, some reached agents that had
  finished, and one made an author rewrite a branch under verification, which left its PR
  closed instead of merged.
- **Renamed to `herdr-agent-pool`**, so it no longer shares its names with the separate
  two-level plugin in claude-code-herdr: marketplace `herdr-agent-pool`, plugin id
  `herdr-agent-pool@herdr-agent-pool`, skills `/herdr-agent-pool:<skill>`, settings
  `.claude/herdr-agent-pool.json`, state `<git common dir>/herdr-agent-pool/`, machine files
  under `~/.config/herdr-agent-pool/` and `~/.cache/herdr-agent-pool/`, variables
  `HERDR_AGENT_POOL_*`. The old names are not read: README, "Renamed from multi-agent-herdr",
  lists the moves; `setup` reports the old names a project still has. The installer also
  turns off `multi-agent-herdr@claude-code-herdr` in a project it sets up.
- **Shorter prompts** (about 40% fewer tokens loaded per role, no rule or behaviour changed).
  `commit`, `pr`, `integrate`, `coordinate` and `dispatch` keep the normal path in `SKILL.md`;
  rare branches and message templates moved to `skills/<skill>/references/*.md`, read only
  when the skill says so (the rare `integrate-pr.sh` exit codes, a red base, a PR that needs a
  decision, cleanup failures, promotion, the dispatch brief, the PR body, no `gh`, no live
  integrator). `template/CLAUDE.md` and the role prompts state each rule once and point to the
  skill that details it. Projects already set up keep their own copies of those three files;
  compare them with `template/` to take the shorter text. `tests/test-hooks.sh` now also
  checks the message header in `references/*.md`.

### Added
- `docs/decisions/`: the plugin's own design decisions (0001-0009), each with its context,
  alternatives and evidence; `docs/benchmark/`: the method and the four first runs of the
  benchmark (five agents, an 18-task backlog in the public `textkit-sandbox`), with
  `benchmark/measure.py` (turns, messages, tokens from session transcripts) and
  `benchmark/pr-stats.py` (PR timings, bounces, force pushes from GitHub).
- `install.sh` detects a machine that knows this GitHub repository as a marketplace with
  another name (set up before the rename, or declared so in the user's settings). There,
  `claude plugin marketplace add` answers "already on disk", adds nothing, and the plugin is
  then "not found in marketplace". The installer names the other marketplace and asks before
  removing it (that also uninstalls the plugins installed from it); without a terminal, on
  "no" and in a dry run it prints the commands instead. README, Install, and the `setup`
  skill describe the same fix by hand.
- `install.sh` reports the `claude` CLI's own reason when it refuses to install the plugin,
  and does not take a project-scope install of another repository for this one's.
- Rule: ask the user before working on a pull request that another GitHub account opened,
  every time (README, "Rules"; the project template's CLAUDE.md; the `integrate` and `pr`
  skills). `integrate-pr.sh` refuses such a PR (exit 2) unless it gets
  `--author-ok <the PR's author>`.
- `land.py`, the lander (docs/lander.md): phase 1 of coordination through GitHub state. One
  run, in a per-base concurrency group, drains the PRs labelled `queue` oldest first; gates
  on draft, CI of the head commit, approval of the head commit (a person's for `risk:high`)
  and an open `base-red` issue; merges `--no-ff`, runs the full check on the merge and
  pushes it unforced, merging again when the base moved. Conflicts and red checks bounce
  with a counted comment, and the one over `--max-rounds` adds `needs-human`. The queue label
  is the approval by default (`--approval review` also asks for an approving review, and a
  person's for `risk:high`); PRs from forks are not landed. `--watch SECONDS` keeps it
  running in a terminal, without GitHub Actions. `--dry-run` is
  a shadow mode. Reference workflow in docs/workflows/land.yml; tests in
  tests/test-lander.sh, run by CI.
- `issue` skill: any role writes a GitHub issue for work left for later (out of scope, blocked,
  a known limitation or an open question), after a duplicate search: evidence, verifiable
  acceptance criteria, scope, risk, size and `Depends on`, using only existing labels and
  never a label that starts work. It links the issue from the code (`TODO(#N)`), the docs and
  the PR. The `pr` body gains a "Follow-ups" section; `document` files an issue for each known
  limitation it documents.
- `docs/field-evidence.md`: what one project's first week in pool mode showed, with numbers and
  sources: checks 7.5 times slower under load, the slot queue as the merge rate, 204 messages a
  day to the coordinator (about 85% mechanical), lost announcements, claims that lapse while
  their holder is alive, and CI unavailable while each change was tested twice.
- Guideline "move work forward proactively", in the `dispatch` and `coordinate` skills, the
  coordinator and integrator prompts, the template `CLAUDE.md` and the README. The dispatcher
  starts agents for every task that can start now, without waiting to be asked, and always
  starts writing code early. It does not force work: no agents for undecided designs, for
  collisions with branches in flight, or for work a pending decision would make us amend.
- `docs/ci-workflows.md`: recommendations for a project's own CI under many agents. Test each
  change once, where the gate is (never on `pull_request` and again on `push` to the base);
  a newer run cancels an older one, also for deploys; split by toolchain; merge short jobs,
  because each job bills at least a minute. It has reference workflows (checked with
  actionlint and zizmor), a measurement snippet and a checklist.
- `setup` skill, step 5: reviews `.github/workflows/` against that checklist and reports
  what fails, read-only.
- `resource-budget.py`: a **priority queue** for slots. Waiters write tickets; a free slot goes
  to `merge` (an integrator's `verify-merge.sh`), then `plan` (the coordinator's checks),
  then `normal`, oldest first; a ticket waiting 20 min counts as `merge`. `--priority` is
  honoured only for the matching `CLAUDE_ROLE`.
- `resource-budget.py`: a **light pool** (`light_slots`, default 2) for worktree setup
  (`new-worktree.sh`, `verify-merge.sh`, `integrator-pool.sh spawn`), so setup no longer waits
  behind test suites.
- `resource-budget.py status [--json]`: every holder of both pools (also those above a lowered
  limit) and the waiters in turn order; `resource-board.sh show` prints it.
- `$HERDR_AGENT_POOL_SLOT_COUNT` for the command in a slot (the pool's limit at admission).
- Project setting `verify` (`check_env`, `docs_only_paths`, `docs_only_env`): variables for
  `scripts/check.sh` on merge verifications, e.g. a fast lane, and a docs-only lane. A variable
  the caller exported wins over both.
- `integrate-pr.sh` exit 13: the verification never ran (its wait for a slot was interrupted),
  back to the queue without a bounce.
- `integrate-pr.sh` takes a per-worktree lock: a second run in the same verify worktree is
  refused (exit 2) instead of aborting the first run's merge.
- Optional project hook `scripts/reverify-needed.sh` (read from the new base): when the base
  moved during a verification, it decides whether the change can affect the PR's checks; when
  it answers `no-reverify` (exit 0), the PR lands without a re-verification. Anything else
  verifies again.
- The last re-verification (`max_reverify`) runs holding the merge lock, so a long verification
  cannot starve (`integrators.locked_reverify_minutes`, default 60; 0 turns it off).
- `integrator-pool.sh nudge` / `watch`: a token-free watcher prompts idle members when an open PR
  has waited unclaimed for `integrators.nudge_after_minutes` (default 5); the coordinator starts
  it. After 3 nudges about a PR it tells the coordinator once. The `pr` skill re-announces
  through `route` only.
- Project setting `numbered_files` and `pool-state.py reserve` / `unreserve` / `reservations`:
  migration and ADR numbers handed out per branch, so parallel branches never pick the same one;
  the `dispatch` skill reserves them and writes them in the brief.
- "Base is red" notice: `pool-state.py base-red report|assign|clear|show` and `hold`. One owner
  fixes a base that fails on its own; `commit`, `pr` and `verify-merge.sh` print the banner
  (`$HERDR_AGENT_POOL_BASE_RED_TESTS` for `scripts/check.sh`); `integrate-pr.sh` exit 14
  instead of a bounce while red; merging the assigned fix clears it.
- `integrate` skill: refresh claims, open PRs and the base after any pause; look for a recorded
  decision before asking, and never wait at a dialog holding a PR (comment, bounce, tell the
  coordinator, move on).

### Fixed
- `resource-budget.py run` read `heavy_slots` once: raising it never admitted a waiter (one PR
  waited 40 min with a slot free) and lowering it never held new ones back. Every retry now
  re-reads the limits, keeping the last good value when the file is half written.
- `resource-board.sh show` listed only the slots below the current limit, hiding holders above
  a lowered one.
- `new-worktree.sh` retries the fetch of the base branch once (DNS hiccups).
- Owner files and tickets are written atomically.

## [0.2.0] - 2026-11-09

This release moved to its own repository,
[herdr-agent-pool](https://github.com/R0drig0V1/herdr-agent-pool), which carries the full
history of [claude-code-herdr](https://github.com/R0drig0V1/claude-code-herdr). That one keeps
the original single-integrator plugin unchanged. The URLs in the README, `install.sh`,
`plugin.json`, the template settings and SECURITY.md point here; the marketplace name and the
plugin id are still `claude-code-herdr` and `multi-agent-herdr@claude-code-herdr`.

### Added
- **Pool mode** (opt-in, docs/multi-integrator.md): an `integrators` object in
  `.claude/multi-agent-herdr.json` splits the single integrator into a **coordinator** (the
  session the user talks to: dispatch, `docs/phases/`, scaling; it never merges) and N
  **integrators** `<integrator_name>-<n>` that claim, verify and merge PRs in parallel, each in
  its own verify worktree detached at `origin/<base>`. Announcements go straight to the pool,
  verdicts straight from the integrator to the author, questions to the coordinator.
- `scripts/integrate-pr.sh`: one PR merged step by step, each step gated on the previous exit
  code: merge, `verify-merge.sh`, commit, push under the merge lock. When `<base>` moved during
  the verification it re-merges, pushes at once if only `reverify_exempt_paths` changed (the
  plan), and otherwise re-verifies, up to `max_reverify` times. A conflict stops it unless it
  is index-table rows (`--union-rows`, `union-rows.py`). A failed verification aborts and
  resets. The head branch is deleted only when the PR head, the remote head and the merged
  head agree, with a lease on that commit; otherwise it is kept. Used in both modes.
- `scripts/pool-state.py`: pool state in the git common dir. It holds atomic PR claims
  (`mkdir`), stale-claim takeover (dead owner or expired heartbeat, moved aside with an atomic
  `rename`), bounced heads (the queue skips a head until it changes), the merge lock (`lock
  run`, a kernel `flock` with `--expect-base`) and plan reports for the coordinator.
- `scripts/integrator-pool.sh`: `list`, `route` (the integrator the `pr` skill announces to,
  in both modes), `scale` (the facts and a rule-of-thumb suggestion; the coordinator decides
  after asking the members), `spawn <n>` (verify worktree, own workspace with
  `CLAUDE_ROLE=integrator`, `herdr agent start`, kickoff) and `stop <n>` (only idle members
  without claims, only workspaces it opened).
- **Resources, negotiated with one hard floor**, after an out-of-memory crash with about 20
  agents on a 24 GB machine:
  - `scripts/resource-budget.py run`: at most `heavy_slots` heavy commands at once, across all
    agents and projects (`verify-merge.sh`, `new-worktree.sh`, and the `commit` and `pr`
    skills run the project's scripts through it);
  - `scripts/resource-board.sh`: the shared, machine-wide resource sheet where agents note
    what they run, and `show` prints memory, slot holders, notes and idle agents;
  - a conversational protocol through the coordinator: `RESOURCE REQUEST` / `GO` / `WAIT` /
    `YIELD` and `SAVE MODE ON/OFF`, with the coordinator's priorities.

  Limits go in `~/.config/multi-agent-herdr/resources.json`, with defaults from the RAM. Only
  `heavy_slots` is enforced; `sessions_guideline` and `low_memory_gb` are guidelines.
- `scripts/cleanup-worktree.sh`: after a merge, the dispatcher (the integrator in single mode,
  the coordinator in pool mode) discards the agent's herdr workspace, worktree and local
  branch, and the remote branch when it is still the merged head. It acts only when the branch
  has a merged PR and its tip is in the base, the worktree is clean and its agent is idle.
  `--list` shows every development worktree's state. `integrator-pool.sh stop
  --remove-worktree` discards a pool member's verify worktree. The merged verdict tells the
  author to wrap up and stop.
- README: a "How it works" diagram of the whole flow (`docs/assets/how-it-works.svg`, light and dark).
- Skill `coordinate`; template `scripts/coordinator.sh` and `.claude/prompts/coordinator.md`.
- `project-config.py`: keys `coordinator_name` and `integrators`, derived `mode` and
  `integrator_pool`, dotted keys (`integrators.max`).
- `verify-merge.sh --here` (verify the current worktree); `agents-in-repo.py --detached` and
  `--dev-only`.
- `tests/test-pool.sh` (also in CI); docs/multi-integrator.md (design, failure modes, open
  questions) and docs/migration-multi-integrator.md (switching a project).
- SessionStart hook `session-start-integrator.sh`: an integrator session (`CLAUDE_ROLE=integrator`,
  inside herdr, in the main worktree of a repository that enables the plugin) takes its herdr
  name with `scripts/claim-integrator.sh` as it starts, relaunches and resumed sessions
  included. Before, a relaunched integrator stayed an unnamed herdr agent until
  `/multi-agent-herdr:integrate` or `dispatch` ran, and development agents' PR announcements
  to `integrator_name` were lost meanwhile. herdr already lists the Claude agent at
  SessionStart (checked live with herdr 0.9.5), so the first claim normally succeeds; a
  detached worker retries "agent not detected" every 2 s for up to 60 s, and the hook waits at
  most about 0.8 s, so it never holds session start. The session gets one line naming its
  herdr agent, a note to ask the user when another live agent holds the name (exit 3), or a
  short warning on any other failure. `dispatch` and `integrate` keep the claim as a fallback;
  `template/scripts/integrator.sh` and `claim-integrator.sh` document the hook.

### Changed
- After review (PR #7):
  - claims are read, decided and written under a `flock` (`claims/.lock`), so two integrators
    can no longer both take over one stale claim;
  - an owner missing from one herdr listing keeps its claim for a grace period
    (`$MULTI_AGENT_HERDR_MISSING_GRACE`, 180 s);
  - `integrate-pr.sh`:
    - re-checks its claim under the merge lock before pushing (exit 10 if it changed hands);
    - exits 9 when someone else already merged the head;
    - re-verifies after a non-fast-forward rejection;
    - releases the claim and resets the worktree on every non-merge exit;
    - kills a push hung under the lock after 600 s;
    - compares the exempt paths with `--no-renames`, now defaulting to `docs/phases/*.md`;
    - checks that its pane's herdr agent is the integrator;
  - the Bash guard blocks commands that set `CLAUDE_ROLE`, `MULTI_AGENT_HERDR_NAME`,
    `MULTI_AGENT_HERDR_SLOT` or `HERDR_ENV`, and the role-only scripts for sessions without
    the role;
  - the guard blocks `--force`, `--delete`, `+` and `:` refspecs on a protected branch even
    under the merge lock;
  - an invalid `.claude/multi-agent-herdr.json` fails closed (no role keeps its rights;
    the file itself may be edited);
  - `cleanup-worktree.sh` matches a merged PR by its head commit, not only by its name.
- After the second review (PR #3):
  - the identity boundary is now herdr itself: in pool mode, `pool-state.py` (claim,
    release, heartbeat, bounce, lock run, report add/done) and `integrate-pr.sh` require
    the calling pane's herdr agent to be a pool member (the coordinator may also
    `lock run` and `report done`), and `--owner` to be that agent; they refuse when herdr
    cannot answer;
  - the guard parses `env`/`exec`/`time` options that take arguments (`-u`, `-C`,
    `-S 'STRING'`, `-a`, `-o`), and resolves `bash script.sh` and `python3 script.py` to
    the script;
  - combined short flags (`-uf`, `-fu`, `-ud`) count as force or delete on a protected
    branch;
  - `lock run --max-seconds` kills the command's whole process group;
  - `missing_since` is cleared when the owner is listed again;
  - `herdr agent list` has a 10 s timeout;
  - stale claims moved aside are deleted, and `claims/.lock` is mode 0600.
- After the third review: the caller's identity no longer trusts `$HERDR_PANE_ID` alone.
  `pool-state.py whoami` believes that pane only when its shell (`herdr pane
  process-info`) is an ancestor of the caller, and there is no fallback to the focused pane.
  `integrate-pr.sh` uses it too, and exits 11 when the identity is refused under the lock.
  The guard also protects `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`,
  `HERDR_SOCKET_PATH` and `HERDR_BIN_PATH`.
- Single mode: `verify-merge.sh`, `new-worktree.sh` and the `commit`/`pr` skills go through
  `resource-budget.py` (an invalid `resources.json` fails them), and `integrate` cleans up
  merged worktrees.
- `integrate` no longer leaves the author's worktree behind: in single mode it cleans up merged
  branches with `cleanup-worktree.sh`.
- `integrate` merges with `integrate-pr.sh` in both modes and rebuilds the queue with
  `pool-state.py queue`. It records bounces, so a bounced head is not verified again. In pool
  mode it claims first, never touches the main worktree or `docs/phases/`, and reports merges
  to the coordinator.
- `dispatch` belongs to the coordinator in pool mode, reads the resource board first, and its
  brief routes questions and resource requests to the dispatcher. `pr` announces through `integrator-pool.sh route`.
- Guards: in pool mode the coordinator owns the main worktree. Integrators are held to the
  main-worktree rules. Both push a protected branch only through `pool-state.py lock run --`.
  `gh pr merge` stays blocked for both. Development agents may prompt the coordinator and the
  pool members. Single mode is unchanged.
- `claim-integrator.sh` and the SessionStart hooks handle the coordinator and pool members.
  `template/scripts/integrator.sh` refuses to launch in pool mode.
- `guard-main-bash.py`: `check_segment` split into `check_git`, `check_push`, `check_locked`
  and `check_writers` (it stays under the lizard ceilings).
- `integrator_name` defaults to `integrator-<repository>` (the main worktree's directory name,
  lower case, runs outside `[a-z0-9_-]` replaced by `-`, cut to 32 characters) instead of
  `integrator`. herdr agent names are unique per server, so with the old default a second
  project on the same server could not dispatch (`claim-integrator.sh` exit 3).
  `project-config.py` computes it (`default_integrator_name`), `template/scripts/integrator.sh`
  repeats the rule and gains `--print-name`, and the template settings file no longer writes
  the key. Existing projects with `"integrator_name": "integrator"` keep it;
  `/multi-agent-herdr:setup` offers to remove it, and `claim-integrator.sh` explains the fix
  when the name is taken.

## [0.1.0]

### Added
- `multi-agent-herdr` Claude Code plugin, published through the `claude-code-herdr`
  marketplace in this repository. Replaces `multi-agent` 0.1.0 (claude-code-multi-agent
  commit 88c8ad4), ported and made herdr native.
- Skills: `dispatch` (one worktree and one herdr workspace per development agent), `setup`,
  and the ported `commit`, `pr`, `integrate`, `document`, `improve-plan`. `pr` announces to the
  herdr agent `integrator`; `integrate` sends verdicts to the agent that owns the branch.
- `scripts/agents-in-repo.py`: read-only branch -> worktree -> live herdr agent resolver.
- Every herdr message starts with `[herdr message from agent <name>; not from the user]`, and
  agent messages are documented as data, never user approval.
- Agents `plan-adversary` and `code-reviewer`, guard hooks, `notify.sh`, `new-worktree.sh`,
  `verify-merge.sh`, `install.sh`, `template/`, smoke tests and CI, ported from multi-agent.

- The Bash guard blocks herdr commands that type into another pane (`agent
  send-keys|attach|rename`, `pane run|send-keys|send-text`, `terminal attach|session`, and
  `agent prompt` to anyone but `integrator`) for development agents, also after a `cd` out
  of the repository, behind `$HERDR_BIN_PATH` / other `$VAR` programs, behind the `command`,
  `exec`, `builtin`, `nohup` and `time` prefixes, and inside `sh|bash|zsh -c` / `eval`
  strings (which also brings the other Bash rules to those strings).
- `scripts/claim-integrator.sh`, run by `dispatch` and `integrate`, gives the integrator the
  herdr name `integrator`; `pr` only announces to the `integrator` in its own repository's
  main worktree (`agents-in-repo.py --name integrator --main-worktree`).

- `.claude/multi-agent-herdr.json` (optional, project-owned) and `scripts/project-config.py`,
  its only reader: `base_branch` (default `main`) for projects whose PRs target an
  integration branch such as `dev`, `integrator_name` (default `integrator`),
  `protected_branches` (extra push-protected patterns) and `worktree_prefix` (default
  `<repo>-`). Used by `new-worktree.sh`, `verify-merge.sh`, `claim-integrator.sh`, the Bash
  guard, `scripts/integrator.sh` and the `pr`, `integrate`, `dispatch`, `document` and `setup`
  skills. `integrate` never moves `main` when the base is another branch; it follows the
  project's documented promotion. An invalid file stops scripts and skills; the guard falls
  back to the defaults.

- Automated quality and security checks (docs/code-quality.md): `quality.yml` (ruff
  check/format with mccabe <= 15, lizard complexity ceilings, zizmor, actionlint, gitleaks),
  `codeql.yml` (CodeQL for Python and Actions), `scorecard.yml` (OpenSSF Scorecard) and
  Dependabot version updates for actions and the uv-locked dev tools (`pyproject.toml`,
  `uv.lock`). `ci.yml` now runs with `contents: read`, pins `actions/checkout` by SHA and
  does not persist credentials. `SECURITY.md`: private vulnerability reporting.

### Fixed
- `install.sh` sets an enabled `multi-agent@claude-code-multi-agent` (the plugin this one
  replaces) to `false` in `.claude/settings.json` and reports `disabled ...`; before, it added
  `multi-agent-herdr` next to it and both plugins' guards ran. Idempotent: a rerun finds it
  `false` and writes nothing. A `.claude/settings.local.json` that still enables it gets a
  warning, not an edit.
- `dispatch` found the new worktree with an inline `awk '... substr($0,10) ... $0==b ...'`.
  Claude Code substitutes `$N` (shorthand for `$ARGUMENTS[N]`), `$ARGUMENTS[N]`, `$ARGUMENTS`
  and declared `$name` arguments in a skill's content
  ([Available string substitutions](https://code.claude.com/docs/en/skills#available-string-substitutions),
  [Pass arguments to skills](https://code.claude.com/docs/en/skills#pass-arguments-to-skills)),
  so the integrator received the dispatch arguments in place of `$0` and a broken command.
  The lookup moved to `plugin/scripts/worktree-of.sh <branch>`. An audit of every SKILL.md and
  agent found no other such token; the two `$ARGUMENTS` uses (`dispatch`, `improve-plan`) are
  prose meant for substitution.
- `tests/check-skill-substitutions.py`, run by `tests/test-hooks.sh` in CI, fails on a
  positional token (`$N`, `${N}`, `$ARGUMENTS[N]`) anywhere in a SKILL.md, on `$ARGUMENTS` in
  a fenced code block, and on a declared `arguments` name used in a code block.

### Fixed (compared with multi-agent)
- Hooks and `install.sh` read `enabledPlugins` as JSON: a `false` entry no longer enables the
  guards, and `settings.local.json` overrides `settings.json`.
- `install.sh` adds a newline before appending to a `.gitignore` that lacks one, and stops
  before copying anything when `.claude/settings.json` is not valid JSON.
- `new-worktree.sh`, `verify-merge.sh` and `integrator.sh` work in paths with spaces.

### Removed (compared with multi-agent)
- The `worktree` skill and `EnterWorktree`: development agents start inside their worktree
  through `dispatch`. `SendMessage`/`ListAgents` fallbacks: this plugin is herdr only.
