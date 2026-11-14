<!--
Checklist for moving an existing herdr-agent-pool project (the project as the worked example)
from one integrator to pool mode: a coordinator plus N integrators (docs/multi-integrator.md).
-->

# Migrating a project to pool mode (checklist)

Pool mode is opt-in, and upgrading the plugin alone changes nothing: a project without an
`integrators` setting keeps one integrator. The steps below switch a project over. They use
the project as the example. The plugin does not edit the project; the project's own integrator
(or the user) makes these changes on `main`.

## Before you switch

- [ ] **Upgrade the plugin** to 0.2.0 or later (`claude plugin marketplace update
      herdr-agent-pool`, then update `herdr-agent-pool`; a machine that still has the names
      from before 2026-11 moves first: README, "Renamed from multi-agent-herdr"). Restart the sessions that should
      pick up the new hooks: hooks and skills load when a session starts.
- [ ] **Write the machine's resource limits**, a new file in 0.2.0. It is per computer, not
      per project, and shared by every project:
      `~/.config/herdr-agent-pool/resources.json`. The defaults for a 24 GB machine are
      `{"heavy_slots": 2, "sessions_guideline": 12, "low_memory_gb": 2.4}`; only
      `heavy_slots` is enforced. the project's full check took this machine out of memory, so
      start with `{"heavy_slots": 1}` and raise it after measuring the check's peak memory
      (`/usr/bin/time -l scripts/check.sh`). An invalid file makes every verification fail,
      so check it with `resource-budget.py limits`.
      `resource-board.sh show` is the live sheet; on 2026-11-09 it listed 47 live herdr
      agents. Close the panes of agents that are `done` before switching: they still hold
      memory.
- [ ] **Verify that `scripts/check.sh` is parallel-safe**: no fixed ports, and no shared state
      that one run wipes under another (docs/multi-integrator.md, "Parallel verification").
      The design is right: `compose.yaml` fixes `name: the project` (one shared PostgreSQL),
      `tests/plugins/db.py` uses random `the project_test_*` databases per run and per test, and
      the serve tests bind no port. Prove it rather than assume it:
      - start `scripts/ensure-db.sh` from two worktrees at the same moment, with the database
        stopped, and check that both succeed (two concurrent `docker compose up -d --wait db`
        may race to create the container);
      - run two full checks at once in two worktrees (two integrators' verify worktrees) and
        check that both are green, and that generated outputs (the contract export,
        `web/dist`, coverage files) stay inside each worktree.

      the project's fast-checks PR, in progress (a separate tmpfs test server), changes how
      the tests reach PostgreSQL: redo both checks after it lands.
- [ ] **Retire the ad-hoc check lock.** Agents currently run `/usr/bin/lockf -k
      /tmp/the project-check.lock scripts/check.sh` by hand, which allows one check at a time
      on the machine. In 0.2.0, `verify-merge.sh`, `new-worktree.sh` and the `commit` and
      `pr` skills run the heavy scripts through `resource-budget.py run`: at most
      `heavy_slots` at once.

      The two locks are independent. While both are in use, a `lockf` check and
      `heavy_slots` plugin checks can run together. So:
      1. keep the `lockf` rule until every session (agents and integrators) runs 0.2.0;
      2. then remove it from briefs, prompts and `CLAUDE.md`, and replace it with "run the
         full check only through `/herdr-agent-pool:commit` or `:pr`";
      3. set `heavy_slots` to 1 (above) until two checks at once are proven to fit.
- [ ] **Disk**: each integrator gets its own verify worktree (`../the project-integrator-<n>`)
      with its own `.venv` and `web/node_modules`, installed once by `scripts/worktree-setup.sh`
      and kept across stops.
- [ ] **Clean up what is already finished.** Until now nothing removed merged worktrees.
      Run `cleanup-worktree.sh --list` in the project's main worktree. For each `ready` branch,
      run `cleanup-worktree.sh <branch>`, which closes the workspace and removes the
      worktree and branches. Branches marked `merged-but-dirty` and `not-merged` are yours
      to decide. This also gives memory back: each finished worktree keeps a session alive.
- [ ] **Let the current integrator finish** the PR it is merging. Note the open PRs: they
      stay in GitHub's queue, and the pool picks them up.
- [ ] **Stop the single integrator before the config changes.** The hooks read
      `.claude/herdr-agent-pool.json` live from the main worktree. As soon as the
      `integrators` object is there, a still-running single integrator loses its rights in
      the main worktree, in the middle of whatever it is doing. See "Switching over" for the
      order.

## Files in the project

- [ ] `.claude/herdr-agent-pool.json`: add the pool. A starting point for 20 agents:

      ```json
      {
        "$comment": "...",
        "base_branch": "main",
        "protected_branches": [],
        "integrators": {"min": 1, "max": 3, "scale_up_when_active_agents_gt": 5}
      }
      ```

      The names become `coordinator-the project` and `integrator-the project-1` .. `-3`.
      **the project must also set `"reverify_exempt_paths": []`** inside `integrators`:
      `tests/server/test_traceability.py` reads `docs/phases/phase-3-features.md`, so a plan
      commit can change the result of the checks. Every merge after a plan commit then
      verifies again; that is the price of a check that reads the plan.
- [ ] `scripts/integrator.sh`: replace it with the plugin's `template/scripts/integrator.sh`.
      the project's copy predates the SessionStart claim, and the new one refuses to launch in
      pool mode.
- [ ] `scripts/coordinator.sh`: new, from `template/scripts/coordinator.sh`, made executable
      with `chmod +x`.
- [ ] `.claude/prompts/coordinator.md`: new, from `template/.claude/prompts/coordinator.md`.
      Add the project's own rules (privacy rules P1-P6, ADR policy) where the coordinator
      decides scope.
- [ ] `.claude/prompts/integrator.md`: merge in the template's "Pool mode" paragraph and the
      two changed bullets (`docs/phases/` belongs to the coordinator; preconditions in your
      own verify worktree). Keep the project's project-specific attack checklist.
- [ ] `CLAUDE.md`, "Multi-agent workflow", following the template:
  - the main worktree belongs to the coordinator;
  - `docs/phases/` belongs to the coordinator;
  - PRs are announced to the pool;
  - questions go to the coordinator;
  - verdicts come from the integrator that handled the PR;
  - `scripts/check.sh` must stay parallel-safe.

  Add `scripts/coordinator.sh` to "Layout" and "Commands".
- [ ] ADR index conflicts: the pool's integrators resolve rows added to
      `docs/decisions/README.md` with
      `integrate-pr.sh <N> --union-rows docs/decisions/README.md`, the plugin's version of
      the project's `--resolve-adr-index`. Mention it in `.claude/prompts/integrator.md`. Retire
      the scratchpad `integrate-pr.sh`.
- [ ] Optional ADR in `docs/decisions/` recording the switch to pool mode and the chosen
      limits.

## Switching over

1. [ ] Prepare the file changes above on a branch (a development agent and a PR, as usual).
2. [ ] Let the single integrator merge everything else that is green, then stop it: the user
       closes the `integrator-the project` session and its pane. In pool mode that name is not
       used, and the main worktree belongs to the coordinator.
3. [ ] Merge the switch-over PR **by hand**, after the integrator is stopped (from a shell
       outside Claude Code: `git merge` in the main worktree and `git push`, or GitHub's merge
       button followed by `git pull --ff-only` in the main worktree). Doing it this way
       means no running session changes roles mid-command.
4. [ ] In a herdr pane of the main worktree, run `scripts/coordinator.sh`. The SessionStart
       hook names it `coordinator-the project`.
5. [ ] In the coordinator, run `/herdr-agent-pool:coordinate`. It checks the preconditions,
       reads the resource board, looks at `integrator-pool.sh scale` (with 20 development
       agents and the settings above it suggests 3 integrators) and spawns as many as the
       queue and the machine justify, and reads pending reports.
       Answer any folder-trust dialog of a new integrator workspace yourself; agents never
       answer them.
6. [ ] Tell the running development agents about the change. The coordinator sends each one a
       herdr message: "announce PRs with /herdr-agent-pool:pr (it routes to the pool), send
       questions to coordinator-the project, and before anything heavier than the normal check
       note it on the resource board and send a RESOURCE REQUEST to coordinator-the project". The guard blocks prompts to the old name
       `integrator-the project` in pool mode, so an agent that still uses it fails safely and is
       told why.
7. [ ] Watch the first merges: `integrator-pool.sh list` (members, claims, idleness),
       `pool-state.py claims`, `pool-state.py lock status`, `resource-board.sh show`.

## Rolling back

1. [ ] Stop the pool members: `integrator-pool.sh stop <n>` for each idle member. It refuses
       members that are working or hold a claim. Wait for them to finish.
2. [ ] Remove `integrators` (and `coordinator_name`) from `.claude/herdr-agent-pool.json` on
       `main`.
3. [ ] Stop the coordinator and launch `scripts/integrator.sh` in the main worktree. The
       verify worktrees can stay (`git worktree remove ../the project-integrator-<n>` when no
       longer wanted).
