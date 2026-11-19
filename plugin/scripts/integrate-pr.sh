#!/usr/bin/env bash
# Merge one pull request into the base branch, verified, or stop with the reason.
#
# Part of the herdr-agent-pool plugin (docs/multi-integrator.md, "integrate-pr.sh"); the
# `integrate` skill runs it after reviewing the diff. It folds in the lessons of the first
# multi-integrator runs: stop on any conflict except mechanical index rows, abort and reset on
# a failed verification, and keep the head branch when it moved during the verification (a
# premature deletion closed PRs twice).
#
# Usage: integrate-pr.sh <PR number> [--union-rows PATH]... [--author-ok LOGIN]
#
# A PR opened by another GitHub account than the one `gh` is logged in as (a contributor, a
# bot) is refused (exit 2) until the user says yes to that PR: then pass --author-ok with the
# PR author's login. The yes is asked again for every such PR.
#
# Only for CLAUDE_ROLE=integrator, and inside herdr only for the session whose herdr agent is
# the integrator's name; in pool mode that agent must also be one of `integrator_pool`, and
# the script refuses to run outside herdr. The role and the name come from the environment,
# so the live pane is the proof; pool-state.py checks the same for the claims and the lock,
# and the Bash guard also keeps other sessions from running it.
# Single mode: run it in the main worktree (on the base branch). Pool mode: run it in your own
# verify worktree (detached HEAD), holding the PR's claim (pool-state.py claim; the script
# heartbeats it and releases it on every outcome but a lost claim).
#
# Steps, each gated on the previous one's exit code:
#  1. Preconditions: settings, role, worktree, no other run in this worktree (a per-worktree
#     lock), no merge in progress (a crashed run's merge is aborted), clean tree, the PR open
#     against the base branch from this repository, and origin/<branch> equal to the PR's head.
#  2. Start from origin/<base> (pool: detached checkout; single: fast-forward of <base>), then
#     `git merge --no-ff --no-commit` the PR head. A conflict stops it (exit 3), unless every
#     conflicted file was given with --union-rows and union-rows.py resolves it.
#  3. verify-merge.sh (--here in pool mode), output in a log file; the exit code is the
#     verdict. A failure aborts the merge and resets the verification state (exit 4). check.sh
#     must not change tracked files (that is a failure too).
#  4. Commit the merge, then push it under the merge lock (pool-state.py lock run). Inside the
#     lock, when origin/<base> moved since the verification started, the PR is merged again
#     onto the new base; if the new merged tree differs from the verified one only in
#     `integrators.reverify_exempt_paths` (default docs/phases/*.md; compared with
#     --no-renames, so moving code into an exempt path is a change), or when the project's
#     scripts/reverify-needed.sh (read from the new base) says the change cannot affect this
#     PR's checks, it is pushed at once; otherwise the lock is released and the new tree is
#     verified again, up to `integrators.max_reverify` times (exit 7 after that). The last of
#     those runs holds the merge lock (`integrators.locked_reverify_minutes`, 0: off), so the
#     base cannot move under it and a long verification cannot starve. The push is never forced: a
#     non-fast-forward is rejected by the remote, so only a verified tree can land (a rejected
#     push is merged again and re-verified). Pool mode: the claim is re-checked under the lock
#     right before the push (exit 10 if it changed hands), and the locked part is killed after
#     600 s.
#  5. Delete the head branch only when the PR's head, the remote branch and the merged head
#     are the same commit and it is contained in origin/<base> (the delete itself carries a
#     lease on that commit, so a push that lands meanwhile keeps the branch); else keep it.
#  6. Pool mode: record the plan report for the coordinator (pool-state.py report add, with
#     the PR body's "Plan tasks completed" section) and release the claim. A bounce (exit 3 or
#     4) is recorded in both modes (pool-state.py bounce), so the queue skips that head.
#
# The last line printed is `RESULT <outcome> ...`. Exit codes: 0 merged; 1 usage, role or
# settings; 2 precondition failed (nothing changed); 3 conflict (bounce); 4 verification failed
# (bounce); 5 commit failed; 6 push failed or timed out; 7 the base kept moving; 8 merge lock
# not acquired; 9 nothing to merge (the head is already in the base); 10 the claim changed hands
# (nothing pushed); 11 herdr stopped confirming this pane's identity under the lock (nothing
# pushed); 13 the verification never ran (verify-merge.sh exit 120: its wait for a slot was
# interrupted), which is no verdict; 14 the verification failed while the base is red
# (pool-state.py base-red): no bounce, the claim is kept, the integrator decides between
# `pool-state.py hold` (only the red tests failed) and `pool-state.py bounce`. On 5-10 and 13 the worktree is reset and the PR goes back
# to the queue without a bounce (the claim is released, except on 10). Needs git, gh, jq, python3 and (inside herdr) herdr.
set -uo pipefail

here_dir=$(cd "$(dirname "$0")" && pwd)
pc="$here_dir/project-config.py"
ps="$here_dir/pool-state.py"

# Under the merge lock: re-entered through `pool-state.py lock run -- integrate-pr.sh
# --push-under-lock`, with the state of the outer run in the environment (exported below).
# Every failure has its own exit code (no `set -e`, which would turn them all into 1).
if [[ "${1:-}" == --push-under-lock ]]; then
    fail() { echo "$2"; exit "$1"; }
    remerge_onto() {  # remerge_onto <sha>: the PR merged again, uncommitted, onto <sha>
        printf '%s\n' "$1" > "$IPR_STATE"
        if [[ "$IPR_MODE" == pool ]]; then git checkout --quiet --detach "$1" || fail 6 "cannot check out $1"
        else git reset --quiet --hard "$1" || fail 6 "cannot reset to $1"; fi
        if ! git merge --quiet --no-ff --no-commit "$IPR_HEAD_SHA" >/dev/null 2>&1; then
            git merge --abort 2>/dev/null
            fail 3 "the PR no longer merges cleanly onto $1"
        fi
    }
    # The project's scripts/reverify-needed.sh <verified base> <new base> <PR head>, taken from
    # the new base (a PR cannot change the rule for its own merge), with the changed paths on
    # stdin. Only exit 0 with `no-reverify` as the last line of its output skips the
    # re-verification (fail closed: a crash, any other answer, or none within 120 s verifies).
    reverify_skipped() {  # reverify_skipped <new base> <changed paths>
        local hook rc
        git cat-file -e "$1:scripts/reverify-needed.sh" 2>/dev/null || return 1
        hook=$(mktemp) || return 1
        git show "$1:scripts/reverify-needed.sh" > "$hook" && chmod +x "$hook"
        python3 -c 'import subprocess, sys
try:
    proc = subprocess.run(sys.argv[1:], timeout=120, stdout=subprocess.PIPE, text=True)
except subprocess.TimeoutExpired:
    print("scripts/reverify-needed.sh gave no answer in 120 s: verifying again")
    sys.exit(1)
lines = proc.stdout.strip().splitlines()
sys.stdout.write("".join(f"  reverify-needed.sh: {line}\n" for line in lines[-5:]))
sys.exit(0 if proc.returncode == 0 and lines[-1:] == ["no-reverify"] else 1)' \
            "$hook" "$IPR_BASE_SHA" "$1" "$IPR_HEAD_SHA" <<<"$2"; rc=$?
        rm -f "$hook"
        [[ $rc == 0 ]]
    }
    # The last re-verification, inside the lock: merge onto the current base and verify that.
    # 76: the verification failed; 77: it never ran (its wait for a slot was interrupted).
    verify_locked() {
        echo "verifying under the merge lock on origin/$IPR_BASE ($now): the base cannot move meanwhile"
        remerge_onto "$now"
        local rc
        "$IPR_VERIFY" ${IPR_VERIFY_HERE:+--here} > "$IPR_LOG" 2>&1; rc=$?
        if [[ $rc == 0 ]] && ! git diff --quiet; then
            echo "scripts/check.sh changed tracked files:" >> "$IPR_LOG"; git diff --stat >> "$IPR_LOG"; rc=1
        fi
        [[ $rc == 120 ]] && exit 77
        [[ $rc == 0 ]] || exit 76
        git commit --quiet -F "$IPR_MSG" || fail 5 "git commit of the re-merge failed"
        check_claim   # again: the verification was long, the claim may have changed hands
    }
    # The claim may have changed hands while we verified (a stale-claim takeover): re-check it
    # here, under the lock, right before pushing.
    check_claim() {
        [[ "$IPR_MODE" == pool ]] || return 0
        local hb
        "$IPR_PS" heartbeat "$IPR_N" --owner "$IPR_ME" >/dev/null 2>&1; hb=$?
        [[ $hb != 4 ]] || fail 11 "pool-state.py refused the heartbeat: herdr no longer confirms this pane is $IPR_ME; nothing pushed"
        [[ $hb == 0 ]] || fail 10 "the claim on PR #$IPR_N is no longer $IPR_ME's: nothing pushed"
    }
    check_claim
    git fetch --quiet origin "$IPR_BASE" || fail 6 "git fetch origin $IPR_BASE failed"
    now=$(git rev-parse "origin/$IPR_BASE") || fail 6 "no origin/$IPR_BASE"
    git merge-base --is-ancestor "$IPR_HEAD_SHA" "$now" \
        && fail 9 "the PR head is already in origin/$IPR_BASE ($now): merged by someone else"
    if [[ "${IPR_LOCKED_VERIFY:-}" == 1 ]]; then
        verify_locked
    elif [[ "$now" != "$IPR_BASE_SHA" ]]; then
        echo "origin/$IPR_BASE moved during the verification: $IPR_BASE_SHA -> $now"
        remerge_onto "$now"
        tree=$(git write-tree) || fail 6 "git write-tree failed"
        # --no-renames: a file moved from src/ into an exempt path must count as a change in src/.
        changed=$(git diff --no-renames --name-only "$IPR_VERIFIED_TREE" "$tree")
        if ! python3 -c 'import fnmatch, json, sys
pats = json.loads(sys.argv[1])
paths = [p for p in sys.stdin.read().splitlines() if p]
sys.exit(0 if all(any(fnmatch.fnmatchcase(p, q) for q in pats) for p in paths) else 1)' \
            "$IPR_EXEMPT" <<<"$changed"; then
            echo "the new base changes the verified tree outside the exempt paths:"
            head -n 20 <<<"$changed" | sed 's/^/  /'
            reverify_skipped "$now" "$changed" || exit 75
            echo "scripts/reverify-needed.sh (from origin/$IPR_BASE) says these changes cannot affect this PR's checks; no re-verify"
        else
            echo "only exempt paths changed since the verification (${changed//$'\n'/, }); no re-verify"
        fi
        git commit --quiet -F "$IPR_MSG" || fail 5 "git commit of the re-merge failed"
    fi
    out=$(git push --porcelain origin "HEAD:refs/heads/$IPR_BASE" 2>&1) && exit 0
    if grep -qE 'non-fast-forward|fetch first|\[rejected\]' <<<"$out"; then
        # Someone pushed without the lock: merge again onto what is there and verify again.
        git fetch --quiet origin "$IPR_BASE" || fail 6 "git fetch origin $IPR_BASE failed"
        echo "the push was rejected as a non-fast-forward: re-verifying on the new origin/$IPR_BASE"
        remerge_onto "$(git rev-parse "origin/$IPR_BASE")"
        exit 75
    fi
    fail 6 "git push failed: $out"
fi

usage() { echo "usage: integrate-pr.sh <PR number> [--union-rows PATH]... [--author-ok LOGIN]" >&2; exit 1; }
N="${1:-}"; [[ "$N" =~ ^[0-9]+$ ]] || usage; shift
union=() author_ok=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --union-rows) [[ $# -ge 2 ]] || usage; union+=("$2"); shift 2 ;;
        --author-ok) [[ $# -ge 2 ]] || usage; author_ok="$2"; shift 2 ;;
        *) usage ;;
    esac
done

result() { echo "RESULT $*"; }
[[ "${CLAUDE_ROLE:-}" == integrator ]] || { echo "only the integrator (CLAUDE_ROLE=integrator)" >&2; exit 1; }
config=$("$pc") || exit 1
mode=$(jq -r .mode <<<"$config")
base=$(jq -r .base_branch <<<"$config")
max_reverify=$(jq -r '.integrators.max_reverify // 3' <<<"$config")
exempt=$(jq -c '.integrators.reverify_exempt_paths // ["docs/phases/*.md"]' <<<"$config")
locked_minutes=$(jq -r '.integrators.locked_reverify_minutes // 60' <<<"$config")
if [[ "$mode" == pool ]]; then me="${HERDR_AGENT_POOL_NAME:-}"; else me=$(jq -r .integrator_name <<<"$config"); fi
[[ -n "$me" ]] || { echo "pool mode: HERDR_AGENT_POOL_NAME is not set (spawn integrators with integrator-pool.sh)" >&2; exit 1; }

stop() { echo "STOP: $*" >&2; result precondition "$*"; exit 2; }
# The role and the name come from the environment, so check them against herdr: the agent in
# this pane must be named $me (a session cannot pose as a pool member by setting variables).
if [[ "$mode" == pool || "${HERDR_ENV:-}" == 1 ]]; then
    [[ "${HERDR_ENV:-}" == 1 ]] || stop "pool mode: run it inside herdr, as a pool member"
    # pool-state.py whoami: the agent of the pane in $HERDR_PANE_ID, believed only when that
    # pane's shell is one of our ancestors (a forged id fails); herdr calls time out at 10 s.
    agent=$("$ps" whoami 2>/dev/null) || agent=""
    [[ -n "$agent" && "$agent" == "$me" ]] || stop "this pane's herdr agent is '${agent:-unknown}', not $me"
    if [[ "$mode" == pool ]] && ! jq -e --arg a "$agent" '.integrator_pool | index($a)' <<<"$config" >/dev/null; then
        stop "this pane's herdr agent, $agent, is not a member of the integrator pool ($(jq -r '.integrator_pool | join(", ")' <<<"$config"))"
    fi
fi
top=$(git rev-parse --show-toplevel) || stop "not inside a git repository"
cd "$top" || exit 2
git_dir=$(git rev-parse --absolute-git-dir); common=$(git rev-parse --path-format=absolute --git-common-dir)
# One run per worktree: a second run here would take the first one's merge for a crashed run's
# and abort it. A kernel flock on a file in this worktree's git dir, held on fd 9 for the whole
# run (the kernel frees it when we die). The verification and the push get fd 9 closed, so a
# daemon a check leaves behind cannot hold it; a lock whose recorded run is dead is taken over.
wt_lock="$git_dir/herdr-agent-pool-integrate.lock"
exec 9>>"$wt_lock" || stop "cannot open $wt_lock"
if ! python3 -c 'import fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)'; then
    holder=$(head -n 1 "$wt_lock" 2>/dev/null); hpid=${holder%% *}
    if [[ "$hpid" =~ ^[0-9]+$ ]] && kill -0 "$hpid" 2>/dev/null; then
        stop "another integrate-pr.sh is running in this worktree ($holder): wait for its RESULT, never start a second run here"
    fi
    echo "warning: the integrate lock of this worktree is held by a leftover of a dead run (${holder:-unknown}); taking over" >&2
fi
printf '%s PR #%s %s\n' "$$" "$N" "$(date -u +%FT%TZ)" > "$wt_lock"
if [[ "$mode" == pool ]]; then
    [[ "$git_dir" != "$common" ]] || stop "pool mode: run it in your own verify worktree, not the main worktree (the coordinator's)"
    "$ps" heartbeat "$N" --owner "$me" >/dev/null || stop "PR #$N is not claimed by $me (pool-state.py claim $N --owner $me)"
    verify=("$here_dir/verify-merge.sh" --here)
else
    [[ "$git_dir" == "$common" ]] || stop "single mode: run it in the main worktree"
    verify=("$here_dir/verify-merge.sh")
fi

# A run that crashed mid-merge left MERGE_HEAD behind: abort it (this worktree is ours).
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "aborting a merge left in progress by an earlier run"
    git merge --abort || stop "could not abort the merge in progress"
    "${verify[@]}" --reset-only >/dev/null 2>&1 9>&- || true
fi
[[ -z "$(git status --porcelain)" ]] || { git status --short >&2; stop "the worktree $top is not clean"; }

pr=$(gh pr view "$N" --json number,title,body,headRefName,headRefOid,baseRefName,state,isCrossRepository,author) \
    || stop "gh pr view $N failed"
B=$(jq -r .headRefName <<<"$pr"); head=$(jq -r .headRefOid <<<"$pr"); title=$(jq -r .title <<<"$pr")
[[ "$(jq -r .state <<<"$pr")" == OPEN ]] || stop "PR #$N is not open"
[[ "$(jq -r .baseRefName <<<"$pr")" == "$base" ]] || stop "PR #$N targets $(jq -r .baseRefName <<<"$pr"), not $base"
[[ "$(jq -r .isCrossRepository <<<"$pr")" == false ]] || stop "PR #$N comes from a fork: integrate it by hand"
# Someone else's PR: only with the user's yes for this PR (--author-ok <its author>).
author=$(jq -r '.author.login // ""' <<<"$pr")
self=$(gh api user -q .login 2>/dev/null) || stop "cannot tell which GitHub account gh uses (gh api user failed)"
if [[ "$author" != "$self" && "$author_ok" != "$author" ]]; then
    stop "PR #$N was opened by ${author:-an unknown account}, not by $self: ask the user before working on it, then rerun with --author-ok ${author:-LOGIN}"
fi
git fetch --quiet --prune origin "$base" "refs/heads/$B:refs/remotes/origin/$B" || stop "git fetch failed"
[[ "$(git rev-parse "origin/$B")" == "$head" ]] \
    || stop "origin/$B ($(git rev-parse --short "origin/$B")) is not the PR head (${head:0:12}) yet: retry"

finish_bounce() {  # finish_bounce <outcome> <exit code> <reason>: reset, record, report
    git merge --abort >/dev/null 2>&1 || true
    "${verify[@]}" --reset-only >/dev/null 2>&1 9>&- || true
    if [[ "$mode" == pool ]]; then git checkout --quiet --detach "origin/$base"
    else git reset --quiet --hard "origin/$base"; fi
    "$ps" bounce "$N" --head "$head" --owner "$me" >/dev/null \
        || echo "warning: could not record the bounce of PR #$N (pool-state.py bounce failed)" >&2
    result "$1" "PR #$N" "$3"; exit "$2"
}
requeue() {  # requeue <outcome> <exit code> <reason>: reset, back to the queue, no bounce
    git merge --abort >/dev/null 2>&1 || true
    if [[ "$mode" == pool ]]; then git checkout --quiet --detach "origin/$base"
    else git reset --quiet --hard "origin/$base"; fi
    if [[ "$mode" == pool && "${4:-}" != keep-claim ]]; then
        "$ps" release "$N" --owner "$me" >/dev/null \
            || echo "warning: could not release the claim on PR #$N (pool-state.py release failed)" >&2
    fi
    result "$1" "PR #$N" "$3"; exit "$2"
}

# 2. Start from origin/<base> and merge.
if [[ "$mode" == pool ]]; then
    git checkout --quiet --detach "origin/$base" || stop "cannot check out origin/$base"
else
    git switch --quiet "$base" && git merge --quiet --ff-only "origin/$base" \
        || stop "$base cannot fast-forward to origin/$base"
fi
base_sha=$(git rev-parse HEAD)
if git merge-base --is-ancestor "$head" "$base_sha"; then
    requeue nothing-to-merge 9 "${head:0:12} is already in origin/$base"
fi
if ! git merge --quiet --no-ff --no-commit "$head" >/dev/null 2>&1; then
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        mechanical=false
        for u in ${union[@]+"${union[@]}"}; do [[ "$f" == "$u" ]] && mechanical=true; done
        if $mechanical && "$here_dir/union-rows.py" "$f"; then
            git add -- "$f"; echo "resolved $f mechanically (union of table rows)"
        else
            echo "conflict: $f" >&2
        fi
    done < <(git diff --name-only --diff-filter=U)
    remaining=$(git diff --name-only --diff-filter=U)
    [[ -z "$remaining" ]] || finish_bounce conflict 3 "conflicts with origin/$base in: ${remaining//$'\n'/ }"
    git diff --cached --check >/dev/null 2>&1 || finish_bounce conflict 3 "conflict markers left after resolution"
fi

# 3. Verify, heartbeating the claim meanwhile (a verification can take longer than a TTL).
log="$git_dir/herdr-agent-pool-verify-$N.log"
hb=""
start_heartbeat() {  # pool mode: heartbeat the claim every 2 minutes in the background
    [[ "$mode" == pool ]] || return 0
    # Its own stdio is /dev/null and it kills its own sleep when stopped: a child left
    # holding the caller's stdout would keep `$(integrate-pr.sh ...)` waiting.
    (
        exec </dev/null >/dev/null 2>&1 9>&-
        s=""; trap '[[ -n "$s" ]] && kill "$s"; exit 0' TERM
        while :; do
            sleep 120 & s=$!; wait "$s"
            "$ps" heartbeat "$N" --owner "$me" || exit 0
        done
    ) &
    hb=$!
}
stop_heartbeat() { [[ -z "$hb" ]] || kill "$hb" 2>/dev/null; hb=""; }
run_verify() {
    local rc
    start_heartbeat
    "${verify[@]}" > "$log" 2>&1 9>&-; rc=$?
    stop_heartbeat
    if [[ $rc -eq 0 ]] && ! git diff --quiet; then
        echo "scripts/check.sh changed tracked files:" >> "$log"; git diff --stat >> "$log"; rc=1
    fi
    tail -n 40 "$log"
    echo "(full verification log: $log)"
    return "$rc"
}
verify_failed() {  # verify_failed <reason>: a bounce, or exit 14 while the base is red
    if [[ -n "$("$ps" base-red show 2>/dev/null)" ]]; then
        "${verify[@]}" --reset-only >/dev/null 2>&1 9>&- || true
        requeue base-red 14 "$1; the base is red ($("$ps" base-red show --tests 2>/dev/null)): read the log, then pool-state.py hold (only those tests failed) or bounce" keep-claim
    fi
    finish_bounce verify-failed 4 "$1"
}
verified_or_out() {  # verified_or_out <what was merged>: bounce on a failure, requeue when nothing ran
    run_verify; local rc=$?
    [[ $rc == 0 ]] && return 0
    if [[ $rc == 120 ]]; then
        "${verify[@]}" --reset-only >/dev/null 2>&1 9>&- || true
        requeue not-verified 13 "the verification never ran (its wait for a slot was interrupted); no bounce; log: $log"
    fi
    verify_failed "verify-merge.sh failed on the merge with $1 (${base_sha:0:12}); log: $log"
}
verified_or_out "origin/$base"

msg="$git_dir/herdr-agent-pool-merge-msg-$N"
printf 'Merge pull request #%s from %s\n\n%s\n' "$N" "$B" "$title" > "$msg"
export IPR_BASE="$base" IPR_MODE="$mode" IPR_HEAD_SHA="$head" IPR_EXEMPT="$exempt" IPR_MSG="$msg"
export IPR_PS="$ps" IPR_N="$N" IPR_ME="$me"
export IPR_STATE="$git_dir/herdr-agent-pool-newbase-$N"
export IPR_LOG="$log" IPR_VERIFY="${verify[0]}" IPR_VERIFY_HERE="${verify[1]:-}"

# 4. Commit, then push under the merge lock; re-verify when the base moved under us.
attempt=0; locked=0
while :; do
    export IPR_BASE_SHA="$base_sha" IPR_VERIFIED_TREE; IPR_VERIFIED_TREE=$(git write-tree)
    git commit --quiet -F "$msg" || requeue commit-failed 5 "git commit of the merge failed"
    if [[ $locked == 1 ]]; then
        # The verification runs inside: allow it locked_reverify_minutes, plus the push.
        export IPR_LOCKED_VERIFY=1; start_heartbeat
        "$ps" lock run --owner "$me" --timeout 900 --max-seconds $((locked_minutes * 60 + 600)) \
            -- "$0" --push-under-lock 9>&-; rc=$?
        stop_heartbeat; tail -n 40 "$log"; echo "(full verification log: $log)"
    else
        # --max-seconds: a hung fetch or push must not hold the merge lock for everyone.
        "$ps" lock run --owner "$me" --timeout 900 --max-seconds 600 -- "$0" --push-under-lock 9>&-; rc=$?
    fi
    case $rc in
        0) break ;;
        3) finish_bounce conflict 3 "conflicts with the new origin/$base ($(cat "$IPR_STATE"))" ;;
        9) requeue nothing-to-merge 9 "the head is already in origin/$base: merged by someone else" ;;
        10) requeue claim-lost 10 "the claim changed hands during the verification; nothing pushed" keep-claim ;;
        4|11) requeue identity-refused 11 "herdr no longer confirms this pane's agent (pool-state.py refused); nothing pushed" keep-claim ;;
        75) ;;
        124) requeue lock-timeout 8 "merge lock not acquired in 900 s" ;;
        125) if [[ $locked == 1 ]]; then
                 "${verify[@]}" --reset-only >/dev/null 2>&1 9>&- || true
                 requeue push-failed 6 "the verification under the merge lock ran longer than $locked_minutes min (integrators.locked_reverify_minutes) and was killed; no bounce"
             fi
             requeue push-failed 6 "the push under the merge lock ran longer than 600 s and was killed" ;;
        5) requeue commit-failed 5 "git commit of the re-merge failed" ;;
        76) verify_failed "verify-merge.sh failed under the merge lock on the new origin/$base ($(cat "$IPR_STATE")); log: $log" ;;
        77) "${verify[@]}" --reset-only >/dev/null 2>&1 9>&- || true
            requeue not-verified 13 "the verification under the merge lock never ran (its wait for a slot was interrupted); no bounce; log: $log" ;;
        *) requeue push-failed 6 "the push under the merge lock failed (exit $rc); nothing landed" ;;
    esac
    attempt=$((attempt + 1))
    base_sha=$(cat "$IPR_STATE")
    [[ $attempt -le $max_reverify ]] \
        || requeue base-moving 7 "origin/$base moved $attempt times during verification; back to the queue"
    if [[ $attempt -eq $max_reverify && $locked_minutes -gt 0 ]]; then
        locked=1
        echo "last re-verify ($attempt of $max_reverify): it runs holding the merge lock, so origin/$base cannot move again"
        continue
    fi
    echo "re-verifying on the new origin/$base (${base_sha:0:12}), attempt $attempt of $max_reverify"
    verified_or_out "the new origin/$base"
done
merged=$(git rev-parse HEAD)

# 5. Delete the head branch only when nothing moved; otherwise keep it (and the PR open).
git fetch --quiet --prune origin "$base" "refs/heads/$B:refs/remotes/origin/$B" 2>/dev/null
remote_now=$(git rev-parse -q --verify "origin/$B" || true)
pr_head=$(gh pr view "$N" --json headRefOid -q .headRefOid 2>/dev/null || true)
branch="kept"
if [[ "$remote_now" == "$head" && "$pr_head" == "$head" ]] && git merge-base --is-ancestor "$head" "origin/$base"; then
    # The lease makes the delete conditional on origin/$B still being $head (no history is
    # rewritten; a push that lands in between makes the delete fail and keeps the branch).
    git push --quiet --force-with-lease="refs/heads/$B:$head" origin --delete "$B" 2>/dev/null && branch="deleted"
fi
[[ "$branch" == kept ]] && echo "branch $B KEPT: remote ${remote_now:-?}, PR head ${pr_head:-?}, merged ${head}; the PR stays open if it has new commits"

# The branch's number reservations (pool-state.py reserve) are spent: its files landed.
"$ps" unreserve --owner "$B" >/dev/null 2>&1 || true
# The fix of a red base (pool-state.py base-red assign --branch) just landed: green again.
"$ps" base-red clear --owner "$me" --if-branch "$B" --reason "PR #$N ($B), the assigned fix, merged" 2>/dev/null \
    && echo "the base is green again: PR #$N was the assigned fix"

# 6. Plan report and claim (pool mode).
if [[ "$mode" == pool ]]; then
    tasks=$(jq -r .body <<<"$pr" | awk '/^## /{p = ($0 ~ /^## Plan tasks completed/); next} p' | sed '/^[[:space:]]*$/d')
    "$ps" report add "$N" --sha "$merged" --owner "$me" --tasks "$tasks" >/dev/null
    "$ps" release "$N" --owner "$me" >/dev/null
fi
rm -f "$msg" "$IPR_STATE"
result merged "PR #$N as $merged onto origin/$base; branch $B $branch"
exit 0
