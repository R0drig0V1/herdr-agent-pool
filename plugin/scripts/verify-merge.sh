#!/usr/bin/env bash
# Verify the working tree of the main worktree (normally a PR merged with --no-commit) before
# the integrator commits the merge; with --here, the worktree of the current directory instead
# (a pool integrator's own verify worktree, docs/multi-integrator.md). Exit code 0 means every check passed; anything else means
# do not merge. Gate the commit on the exit code, never on grepped output:
#
#   if "$CLAUDE_PLUGIN_ROOT"/scripts/verify-merge.sh; then git commit ...; else git merge --abort; fi
#
# Usage:
#   verify-merge.sh [--here]               full verification
#   verify-merge.sh [--here] --reset-only  only reset shared verification state (after
#                                          `git merge --abort`)
#
# With --here, several integrators verify in parallel, so the project's scripts below must be
# parallel-safe: no fixed ports, no shared database or directory that one run wipes under
# another (docs/multi-integrator.md, "Parallel verification").
#
# Steps, stopping at the first failure:
# 1. scripts/verify-reset.sh, if the project has one: recreate shared state (e.g. the
#    integrator's test database) from scratch, so state left by an earlier, aborted
#    verification cannot break (or fake) this one.
# 2. scripts/worktree-setup.sh, if present: install dependencies the PR may have added. It
#    receives the project's base branch (project-config.py base_branch, default main) as $1.
# 3. scripts/check.sh: lint, formatting, types and tests. A project without one only gets a
#    warning, so configure it before trusting a VERIFY OK. It gets the project's
#    `verify.check_env` variables, plus `verify.docs_only_env` when every path the merge
#    changes (against HEAD) matches `verify.docs_only_paths` (project-config.py).
# Step 2 runs in one of the machine's light slots and step 3 in one of its heavy slots, with
# merge priority (resource-budget.py run): they may first wait for other agents' work. Exit
# 120 means a step was interrupted while it waited for its slot: nothing was checked, which
# is not a verdict on the merge (integrate-pr.sh requeues the PR without a bounce).
#
# Part of the herdr-agent-pool plugin (unchanged from multi-agent 0.1.0); the scripts above belong to the project and are resolved
# from the repository of the current directory.
#
# Only for the integrator.
set -euo pipefail

here=false reset_only=false
for arg in "$@"; do
    case "$arg" in
        --here) here=true ;;
        --reset-only) reset_only=true ;;
        *) echo "usage: verify-merge.sh [--here] [--reset-only]" >&2; exit 2 ;;
    esac
done

main_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
if $here; then
    repo_root=$(git rev-parse --show-toplevel)
else
    repo_root=$main_root
    cd "$repo_root"
    [[ "$(git rev-parse --absolute-git-dir)" == "$repo_root/.git" ]] \
        || { echo "run it in the main worktree ($repo_root), or pass --here" >&2; exit 2; }
fi
cd "$repo_root"

step() { echo; echo "==> $*"; }

reset_state() {
    if [[ -x scripts/verify-reset.sh ]]; then
        step "reset verification state"
        scripts/verify-reset.sh
    fi
}

if $reset_only; then
    reset_state
    exit 0
fi

failed_step="setup"
report_failure() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        echo
        echo "VERIFY FAILED at: $failed_step (exit $status)" >&2
    fi
}
trap report_failure EXIT

# The heavy steps hold one of the machine's heavy slots (resource-budget.py): with many
# agents and integrators on one computer, at most `heavy_slots` of them run at once.
rb="$(dirname "$0")/resource-budget.py" pc="$(dirname "$0")/project-config.py"
heavy() { "$rb" run --priority merge --label "verify-merge $repo_root" -- "$@"; }
light() { "$rb" run --pool light --label "verify-merge setup $repo_root" -- "$@"; }
failed_step="reset verification state"; reset_state
if [[ -x scripts/worktree-setup.sh ]]; then
    failed_step="worktree setup"; step "$failed_step"
    light scripts/worktree-setup.sh "$("$pc" --root "$main_root" base_branch)"
fi
failed_step="checks"; step "$failed_step"
# A red base (pool-state.py base-red): say so, and hand the known-red tests to check.sh, which
# may leave them out ($HERDR_AGENT_POOL_BASE_RED_TESTS, space-separated; the project decides).
red=$("$(dirname "$0")/pool-state.py" base-red show 2>/dev/null || true)
if [[ -n "$red" ]]; then
    echo "$red"
    HERDR_AGENT_POOL_BASE_RED_TESTS=$("$(dirname "$0")/pool-state.py" base-red show --tests 2>/dev/null || true)
    export HERDR_AGENT_POOL_BASE_RED_TESTS
fi
# The project's check variables (verify.check_env, plus verify.docs_only_env on a docs-only
# merge), one NAME=value per line. A variable the caller exported wins (for example
# PROJECT_CHECK_SCOPE=full for a full-scope merge verification). An invalid settings file
# stops the verification here.
vcfg=$("$pc" --root "$main_root" verify)
check_env=()
while IFS= read -r line; do
    [[ -n "$line" ]] && check_env+=("$line")
done < <(git diff --no-renames --name-only HEAD | python3 -c 'import fnmatch, json, os, sys
cfg = json.loads(sys.argv[1])
paths = [p for p in sys.stdin.read().splitlines() if p]
pats = cfg["docs_only_paths"]
env = dict(cfg["check_env"])
if pats and paths and all(any(fnmatch.fnmatchcase(p, q) for q in pats) for p in paths):
    print("docs-only merge: adding verify.docs_only_env", file=sys.stderr)
    env.update(cfg["docs_only_env"])
kept = sorted(k for k in env if k in os.environ)
if kept:
    print("exported by the caller, kept: " + " ".join(f"{k}={os.environ[k]}" for k in kept), file=sys.stderr)
print("\n".join(f"{k}={v}" for k, v in env.items() if k not in os.environ))' "$vcfg")
[[ ${#check_env[@]} -eq 0 ]] || echo "check environment: ${check_env[*]}"
if [[ -x scripts/check.sh ]]; then
    heavy env ${check_env[@]+"${check_env[@]}"} scripts/check.sh
else
    echo "warning: scripts/check.sh not found; nothing was checked" >&2
fi

echo
echo "VERIFY OK"
