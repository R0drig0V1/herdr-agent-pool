<!-- Recommendations for a project's own CI workflows (GitHub Actions) when many agents push
     to it through this plugin: test each change once, cancel superseded runs, split by
     toolchain and spend fewer billed minutes. Read by people and by the setup skill. -->

# CI workflows for a multi-agent project

With many agents, a project's CI runs far more often than with a few people: every agent
pushes its branch, every bounce pushes again, and the integrators push merges to the base
branch all day. A setup that is fine for a small team becomes the largest cost and a queue.
In one project (about 15 agents, 3 integrators) the workflows were triggered about 1,600
times in six days. That is about 7,000 to 9,000 billed minutes, or USD 200 to 270 a month on
GitHub-hosted Linux runners at USD 0.006 per minute. Almost half of it went to jobs shorter
than a minute.

These are recommendations for the project's own `.github/workflows/`. The plugin never
edits them. `/multi-agent-herdr:setup` reviews them against this page and reports what it
finds.

## Contents

- [Rule 1: test each change once, where the gate is](#rule-1-test-each-change-once-where-the-gate-is)
- [Rule 2: a newer run cancels an older one](#rule-2-a-newer-run-cancels-an-older-one)
- [Rule 3: split by toolchain and run only what a change touches](#rule-3-split-by-toolchain-and-run-only-what-a-change-touches)
- [Rule 4: spend fewer billed minutes](#rule-4-spend-fewer-billed-minutes)
- [Reference workflows](#reference-workflows)
- [Measure first](#measure-first)
- [Checklist](#checklist)

## Rule 1: test each change once, where the gate is

A change should run the test suite once, at the step that decides whether it lands. Running
it on the pull request and again when it merges pays twice for the same answer.

**Why the push run repeats the PR run.** The plugin's integrator runs `verify-merge.sh` on
the exact merge result: the PR merged onto the current base. Then it pushes that result to
the base. A workflow on `push` to the base tests the same tree a second time. The
`pull_request` event tests `refs/pull/<N>/merge`, which is the PR merged with the base as it
was when the run started. So with the plugin's local verify, a PR run is also a second
answer, and an older one.

Pick one gate and arrange the triggers around it:

| Gate | Where the suite runs | `pull_request` | `push` to the base | Promotion to `main` |
|------|----------------------|----------------|--------------------|---------------------|
| **Local** (the plugin's default) | `verify-merge.sh` in an integrator slot, on your machine | cheap checks the local run lacks (other OS by label, secret scan, dependency audit when a lockfile changes); the full suite optional | none (deploy only) | none when promotion fast-forwards: `main` gets commits that were already verified |
| **CI** (GitHub merge queue, or a future `verify.backend: ci`) | the `merge_group` run (or a candidate branch) | lint and fast tests only, as early feedback | none (deploy only) | none, as above |

What never pays:

- `push` on every branch **and** `pull_request`. Each push to a PR branch then runs twice.
  Limit `push` to branches that deploy, or drop it.
- The full suite on the base after each merge "to be sure". If you want a safety net, run it
  once a night on the base with `schedule`, not once per merge.
- A promotion that makes a new merge commit (`develop` into `main` with `--no-ff`) when a
  fast-forward would do. The new commit has a new SHA, so it looks untested and gets tested
  again.

## Rule 2: a newer run cancels an older one

When a branch gets a new push, the run for the old commit is wasted. When the base moves, the
deploy of the old tip is wasted too. Use `concurrency` everywhere.

**Checks: one group per PR, cancel the older run.**

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

**Deploys: the newer deploy kills the running one.** At most one run and one pending run
exist per group. A new run replaces the pending one, and with `cancel-in-progress: true` it
also cancels the running one. Whether the running deploy may die at any step depends on the
deploy:

- **The deploy can stop at any step safely** (it builds, then switches an image or a symlink
  in one atomic step; running it again finishes what it started): cancel the whole run, at
  the workflow level.
- **A step must not stop halfway** (database migrations, a release to a store): give the
  build and the release separate groups, at the job level. A newer push cancels the older
  build. The older release finishes if it already started, and the newer one then waits for
  it. Before releasing, check that the commit is still the branch tip; if it is not, skip,
  because a newer run releases it. See [Reference workflows](#reference-workflows).

Never put a deploy and the checks in one group, or a merge to the base would cancel the
checks of an open PR.

## Rule 3: split by toolchain and run only what a change touches

Separate jobs or workflows by what they depend on: Python, web (Node), Rust, containers,
infrastructure. Then a change that touches only `web/` does not install Python or build Rust.

How to skip what a change does not touch:

- **Workflow-level `paths:` filters** cost nothing, because the workflow does not start. Use
  them for workflows that are not required checks, such as dependency audits:
  `paths: [uv.lock, web/package-lock.json, desktop/Cargo.lock]`.
- **For required checks, use job-level `if:`.** A workflow skipped by `paths:` never reports.
  A required check from it then stays "Expected — waiting" and blocks the PR. A job skipped
  by `if:` reports success.
- **A `changes` job** computes what changed with `git diff --name-only`, and the other jobs
  read its outputs. Plain `git diff` needs no third-party action. This job bills a minute of
  its own. It pays off when it skips jobs longer than about a minute. For a few short checks,
  use `if:` on steps inside one job instead.
- **Docs-only changes** need no test suite: skip it on `docs/**` and `**/*.md`. This is the
  same idea as the plugin's `verify.docs_only_paths`.

## Rule 4: spend fewer billed minutes

GitHub rounds **each job** up to a whole minute, so a 7-second job costs a full minute.
Windows minutes cost 2x and macOS 10x.

- **Merge short jobs into one job with several steps.** Four audits of 7 to 46 seconds cost
  4 minutes as four jobs and 1 minute as one job. Keep a separate job only for long work
  (several minutes), another OS, or a toolchain the others do not install.
- **Audits and scans** (dependency audit, secret scan, workflow lint) run when their inputs
  change (`paths:`) and on a weekly `schedule`, not on every push.
- **Skip draft PRs**, and add `ready_for_review` to the PR types so the run starts when the PR
  is ready:

  ```yaml
  on:
    pull_request:
      types: [opened, synchronize, reopened, ready_for_review]
  jobs:
    check:
      if: github.event.pull_request.draft != true
  ```

- **Other OSes on demand**: by a PR label, manually (`workflow_dispatch`) or nightly, never
  on every push.
- **Cache dependencies**: `setup-uv` with `enable-cache`, `setup-node` with `cache`, and a
  Cargo cache. Cold Rust builds are usually the longest step.
- **Group Dependabot updates** (`groups:` in `dependabot.yml`) and run it weekly. Every
  Dependabot PR is a full CI run.
- **Set `timeout-minutes` on every job.** A hung test should not bill the default 6 hours.
- **Fail fast inside a job**: run lint and type checks before the tests, in the same job, so
  a typo fails in seconds.
- **Self-hosted runners** on your own machine cost no Actions minutes. GitHub postponed its
  proposed per-minute fee for self-hosted runners. Choose the runner through a variable
  (`runs-on: ${{ vars.CHECK_RUNNER || 'ubuntu-latest' }}`) so a project can switch without
  editing workflows. Use them only for **private** repositories: on a public one, a fork's PR
  would run code on your machine.

## Reference workflows

The action SHAs are examples. Pin the versions you use, and keep `permissions` minimal.

**Checks** (`ci.yml`): pull requests only, one run per PR, short checks in one job, and the
long suite only when code changed.

```yaml
name: CI
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:

permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  check:
    if: github.event.pull_request.draft != true
    runs-on: ${{ vars.CHECK_RUNNER || 'ubuntu-latest' }}
    timeout-minutes: 30
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: What changed
        id: changes
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
        run: |
          if [ -z "$BASE_SHA" ]; then echo "code=true" >> "$GITHUB_OUTPUT"; exit 0; fi
          files=$(git diff --name-only "$BASE_SHA"...HEAD)
          if grep -qvE '^docs/|\.md$' <<<"$files"; then code=true; else code=false; fi
          echo "code=$code" >> "$GITHUB_OUTPUT"
      - uses: astral-sh/setup-uv@68559e99cc807c1eb7e9238fd43a15bba460eec2 # v10.3.3
        if: steps.changes.outputs.code == 'true'
        with:
          enable-cache: true
      - name: Lint, types, tests
        if: steps.changes.outputs.code == 'true'
        run: scripts/check.sh
```

**Audits** (`quality.yml`): one job, run only when its inputs change, plus weekly.

```yaml
name: Quality
on:
  pull_request:
    paths: [uv.lock, web/package-lock.json, .github/workflows/**]
  schedule:
    - cron: "17 6 * * 1"
  workflow_dispatch:

permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  audits:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: astral-sh/setup-uv@68559e99cc807c1eb7e9238fd43a15bba460eec2 # v10.3.3
      - name: Python dependencies
        run: uvx pip-audit
      - name: Web dependencies
        working-directory: web
        run: npm audit --audit-level=high
      - name: Workflows
        run: uvx zizmor .github/workflows
```

**Deploy** (`deploy.yml`): a newer push cancels the older build. A release that already
started finishes, and a release of a commit that is no longer the tip is skipped.

```yaml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    concurrency:
      group: deploy-build-${{ github.ref }}
      cancel-in-progress: true
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Build
        run: scripts/build.sh

  release:
    needs: build
    runs-on: ubuntu-latest
    timeout-minutes: 20
    environment: production
    concurrency:
      group: deploy-release-${{ github.ref }}
      cancel-in-progress: false
    permissions:
      contents: read
    steps:
      - name: Still the tip?
        id: tip
        env:
          GH_TOKEN: ${{ github.token }}
          BRANCH: ${{ github.ref_name }}
        run: |
          tip=$(gh api "repos/$GITHUB_REPOSITORY/commits/$BRANCH" --jq .sha)
          if [ "$tip" = "$GITHUB_SHA" ]; then echo "current=true" >> "$GITHUB_OUTPUT"
          else echo "current=false" >> "$GITHUB_OUTPUT"; echo "superseded by $tip: skipping"; fi
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        if: steps.tip.outputs.current == 'true'
        with:
          persist-credentials: false
      - name: Release
        if: steps.tip.outputs.current == 'true'
        run: scripts/release.sh
```

If the whole deploy may stop at any step, a workflow-level `concurrency` with
`cancel-in-progress: true` is simpler and also kills a running release.

## Measure first

Billed minutes per workflow over the last 7 days. Each job is rounded up, the way GitHub
bills it. Jobs that never started (no steps) are left out.

```bash
since=$(date -u -v-7d +%F 2>/dev/null || date -u -d '7 days ago' +%F)
gh run list --limit 1000 --created ">=$since" --json databaseId,workflowName \
    --jq '.[] | "\(.databaseId)\t\(.workflowName)"' |
while IFS=$'\t' read -r id wf; do
    gh api "repos/{owner}/{repo}/actions/runs/$id/jobs" --jq '.jobs[]
        | select(.started_at != null and .completed_at != null and (.steps | length) > 0)
        | (((.completed_at | fromdate) - (.started_at | fromdate)) / 60 | ceil)' |
        awk -v wf="$wf" '{ m += $1 } END { printf "%s\t%d\n", wf, m }'
done | awk -F'\t' '{ m[$1] += $2; n[$1]++ } END { for (w in m) printf "%6d min  %4d runs  %s\n", m[w], n[w], w }' |
    sort -rn
```

A run that fails in seconds with "The job was not started because recent account payments
have failed or your spending limit needs to be increased" means the account ran out of
minutes. Nothing was tested.

## Checklist

1. No workflow runs the test suite both on `pull_request` and on `push` to the base.
2. `push` is limited to branches that deploy; no `push` on every branch next to `pull_request`.
3. Every workflow has `concurrency` with `cancel-in-progress: true`. Deploys use a group of
   their own, at the job level when a step must not stop halfway.
4. Jobs shorter than a minute are steps of one job.
5. Audits and scans run on `paths:` of their inputs plus a weekly `schedule`.
6. Required checks skip with job- or step-level `if:`, never with workflow-level `paths:`.
7. Draft PRs are skipped, and the types include `ready_for_review`.
8. Windows and macOS run by label, manually or nightly.
9. Every job has `timeout-minutes` and caches its dependencies.
10. Promotion to `main` fast-forwards, so it triggers no new test run.
11. `runs-on` reads a variable, so the project can move to its own runners without editing.
