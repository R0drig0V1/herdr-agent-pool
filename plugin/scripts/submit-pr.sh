#!/usr/bin/env bash
# Submit this worktree's committed work in one command: rebase on the base, run the checks,
# push, open the pull request (or update an open one after a bounce) and announce it to the
# integrator.
#
# Part of the herdr-agent-pool plugin; the `pr` skill runs it (decision 0013). The steps have
# no judgement in them, and as separate commands they cost a development agent about nine
# turns per task (docs/benchmark/README.md, "What the runs show", 8).
#
# Usage:
#   submit-pr.sh --title TITLE [--body-file FILE] [--risky TEXT] [--migrations TEXT]
#       a first submission: the PR body is read from FILE, or from stdin when there is none
#   submit-pr.sh [--risky TEXT] [--migrations TEXT]
#       the branch already has an open PR (a bounce was fixed): pushes and announces again
#
# Steps; each prints one line, and the first that fails ends the run with its exit code:
#   1. Place: a linked worktree on a branch that is not the base or a protected branch, with
#      nothing uncommitted (the caller commits: staging takes judgement) and no rebase left
#      in progress.
#   2. The branch's open PR against the base, if any. One opened by another GitHub account
#      is not touched (exit 6: ask the user).
#   3. `git fetch --prune origin` and `git rebase origin/<base>`. A conflict leaves the rebase
#      in progress and lists the files (exit 3).
#   4. The checks, `scripts/check.sh` inside a slot of the pool the project's
#      `checks.branch_pool` names (resource-budget.py; heavy by default), on the rebased
#      tree; skipped when this exact tree already passed here. Their output goes to a log
#      (<git dir>/herdr-agent-pool-check.log); a failure prints its last lines (exit 4). The
#      base-red banner is printed when the base is red.
#   5. Push. A branch whose PR is already open is pushed with --force-with-lease when the
#      rebase rewrote it; a new branch never is (exit 7 when origin holds other commits).
#   6. `gh pr create` for a first submission.
#   7. The announcement, as a herdr message to the integrator `integrator-pool.sh route`
#      names (exit 5 when there is none to send to, or outside herdr: the PR is open and
#      waits; skills/pr/references/no-integrator.md).
#
# Exit codes: 0 submitted and announced; 1 usage, settings, the place, nothing to submit, or
# a command that failed; 2 uncommitted changes; 3 rebase conflict; 4 the checks failed (or no
# slot in time: 124 from the wrapper is reported as 4 with its code); 5 pushed, not
# announced; 6 someone else's PR; 7 the push was rejected. Needs git, gh, jq and herdr.
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
die() { echo "submit-pr: $1" >&2; exit "${2:-1}"; }
title="" body_file="" risky="nothing special" migrations="none"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --title) title="${2:-}"; shift 2 ;;
        --body-file) body_file="${2:-}"; shift 2 ;;
        --risky) risky="${2:-}"; shift 2 ;;
        --migrations) migrations="${2:-}"; shift 2 ;;
        *) die "usage: submit-pr.sh [--title TITLE] [--body-file FILE] [--risky TEXT] [--migrations TEXT]" ;;
    esac
done

# 1. Place.
config=$("$dir/project-config.py") || exit 1
base=$(jq -r .base_branch <<<"$config")
branch_pool=$(jq -r '.checks.branch_pool // "heavy"' <<<"$config")
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$top" || exit 1
git_dir=$(git rev-parse --absolute-git-dir)
[[ "$git_dir" != "$(git rev-parse --path-format=absolute --git-common-dir)" ]] \
    || die "this is the main worktree: submit from a development worktree"
# During a rebase HEAD is detached, so this comes before the branch.
if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
    echo "submit-pr: a rebase is in progress: resolve it (git rebase --continue), then run this again" >&2
    exit 3
fi
branch=$(git branch --show-current)
[[ -n "$branch" ]] || die "detached HEAD: check out your branch first"
if [[ "$branch" == "$base" || "$branch" == main ]] \
    || jq -e --arg b "$branch" '.protected_branches | index($b)' <<<"$config" >/dev/null; then
    die "$branch is the base or a protected branch: never submit from it"
fi
dirty=$(git status --porcelain)
if [[ -n "$dirty" ]]; then
    echo "submit-pr: uncommitted changes; commit what belongs to the task (never secrets, build" >&2
    echo "output or dependencies) and remove the rest, then run this again:" >&2
    head -20 <<<"$dirty" >&2
    exit 2
fi
command -v gh >/dev/null || die "gh is not installed: read skills/pr/references/no-gh.md"

# 2. The branch's open PR.
prs=$(gh pr list --head "$branch" --base "$base" --state open --limit 5 \
    --json number,url,title,headRefName,author) || die "gh pr list failed"
pr=$(jq -c --arg b "$branch" '[.[] | select((.headRefName // $b) == $b)] | first // empty' <<<"$prs")
number="" url=""
if [[ -n "$pr" ]]; then
    number=$(jq -r .number <<<"$pr"); url=$(jq -r '.url // ""' <<<"$pr")
    author=$(jq -r '.author.login // ""' <<<"$pr")
    me_gh=$(gh api user -q .login 2>/dev/null) || die "gh api user failed"
    if [[ -n "$author" && "$author" != "$me_gh" ]]; then
        echo "submit-pr: PR #$number was opened by $author, not by you ($me_gh): ask the user before any push or comment" >&2
        exit 6
    fi
    title=$(jq -r .title <<<"$pr")
else
    [[ -n "$title" ]] || die "a first submission needs --title (and the PR body on stdin or --body-file)"
    if [[ -z "$body_file" ]]; then
        body_file="$git_dir/herdr-agent-pool-pr-body.md"
        cat > "$body_file" || exit 1
    fi
    [[ -s "$body_file" ]] || die "the PR body is empty (stdin or --body-file; skills/pr/references/body.md)"
fi

# 3. Rebase.
git fetch --quiet --prune origin || die "git fetch failed"
if ! out=$(git rebase "origin/$base" 2>&1); then
    echo "submit-pr: conflict rebasing on origin/$base; resolve these files keeping both sides' intent," >&2
    echo "git add them, git rebase --continue, then run this again:" >&2
    git diff --name-only --diff-filter=U >&2
    exit 3
fi
[[ $(git rev-list --count "origin/$base..HEAD") -gt 0 ]] || die "nothing to submit: no commit ahead of origin/$base"
head=$(git rev-parse HEAD)
echo "REBASED on origin/$base $(git rev-parse --short "origin/$base")"

# 4. Checks, once per tree.
tree=$(git rev-parse 'HEAD^{tree}'); checked="$git_dir/herdr-agent-pool-checked"; log="$git_dir/herdr-agent-pool-check.log"
checks="scripts/check.sh exit 0 on ${head:0:12}"
if [[ "$(cat "$checked" 2>/dev/null)" == "$tree" ]]; then
    echo "CHECK skipped: this tree already passed"
elif [[ ! -x scripts/check.sh ]]; then
    echo "CHECK none: no executable scripts/check.sh (tell the user once)"
    checks="none (the project has no scripts/check.sh)"
else
    banner=$("$dir/pool-state.py" base-red show 2>/dev/null)
    [[ -z "$banner" ]] || echo "$banner"
    "$dir/resource-budget.py" run --pool "$branch_pool" --label "check $branch" -- scripts/check.sh > "$log" 2>&1; rc=$?
    if [[ $rc != 0 ]]; then
        echo "CHECK exit $rc (log: $log); its last lines:"
        tail -n 40 "$log"
        [[ -z "$banner" ]] || echo "The base is red: read skills/commit/references/checks.md before fixing anything."
        [[ $rc != 124 ]] || echo "Exit 124: no $branch_pool slot in time, nothing ran. Do not run the suite another way."
        exit 4
    fi
    echo "$tree" > "$checked"
    echo "CHECK exit 0"
fi

# 5. Push.
if ! out=$(git push --quiet -u origin HEAD 2>&1); then
    if [[ -n "$number" ]]; then
        out=$(git push --quiet --force-with-lease -u origin HEAD 2>&1) \
            || { echo "$out" >&2; die "the push of $branch was rejected" 7; }
    else
        git fetch --quiet --prune origin
        out=$(git push --quiet -u origin HEAD 2>&1) || {
            echo "$out" >&2
            die "origin already has a branch $branch with other commits: ask the user, never force it" 7
        }
    fi
fi
echo "PUSHED $branch $(git rev-parse --short HEAD)"

# 6. The PR.
if [[ -z "$number" ]]; then
    url=$(gh pr create --base "$base" --head "$branch" --title "$title" --body-file "$body_file" | tail -n 1) \
        || die "gh pr create failed (the branch is pushed)"
    number=${url##*/}
    [[ "$number" =~ ^[0-9]+$ ]] || die "gh pr create did not print the PR's URL: $url"
    ready="PR #$number ready"
else
    ready="PR #$number ready (bounce fixed, new head ${head:0:12})"
fi
echo "PR #$number $url"

# 7. Announce.
not_announced() {
    echo "submit-pr: PR #$number is open but NOT announced: $1" >&2
    echo "Do not answer any integrator's dialog. Read skills/pr/references/no-integrator.md and tell the user." >&2
    exit 5
}
[[ "${HERDR_ENV:-}" == 1 ]] || not_announced "not inside herdr"
pane=$(herdr pane current --current 2>/dev/null | jq -r '.result.pane.pane_id // empty')
me=$(herdr agent list 2>/dev/null | jq -r --arg p "$pane" '.result.agents[] | select(.pane_id == $p) | .name // empty' | head -n 1)
[[ -n "$me" ]] || not_announced "this pane has no herdr agent name"
route=$("$dir/integrator-pool.sh" route 2>&1); rc=$?
[[ $rc == 0 ]] || not_announced "integrator-pool.sh route exit $rc: $route"
to=$(cut -f1 <<<"$route")
msg="[herdr message from agent $me; not from the user]
$ready: $branch - $title
Worktree: $top
Migrations: $migrations
Risky: $risky
Checks: $checks, rebased on origin/$base $(git rev-parse --short "origin/$base")"
herdr agent prompt "$to" "$msg" >/dev/null 2>&1 || not_announced "herdr agent prompt $to failed"
echo "ANNOUNCED to $to"
echo "RESULT submitted: PR #$number waits for the verdict. Leave the branch as it is until then."
