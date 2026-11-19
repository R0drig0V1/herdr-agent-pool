#!/usr/bin/env bash
# Single mode's token-free watcher: wake the idle integrator with what changed, compact it when
# its context is large, and clean up merged worktrees.
#
# Part of the herdr-agent-pool plugin (docs/reference.md, "What changes in single mode";
# decision 0010). Pool mode has its own watcher (integrator-pool.sh watch). The `integrate`
# skill starts this one in the background once; it spends no Claude tokens.
#
# Usage:
#   integrator-watch.sh [SECONDS]   a pass every SECONDS (default 60, at least 10) until
#                                   stopped; one watcher per repository (a second one exits 0
#                                   at once; the pid is in <git common dir>/herdr-agent-pool/
#                                   integrator-watch.pid)
#   integrator-watch.sh once        one pass
#
# A pass:
#   1. Cleanup: every branch `cleanup-worktree.sh --list` reports `ready` (merged, clean, its
#      agent idle) on passes at least $HERDR_AGENT_POOL_CLEAN_GRACE seconds apart (default
#      180, so the merged verdict reaches its author first) is removed with
#      `cleanup-worktree.sh <branch>`, whose own checks still apply. Nothing else is touched.
#   2. News, from one `gh pr list` of the open PRs against the base:
#      - a PR waits for a verdict: not a draft, not labelled `queue` or `needs-human`, and its
#        head neither bounced nor held (pool-state.py records both in single mode too), seen
#        at the same head on an earlier pass (an announcement right before a pass is not news);
#      - the lander (docs/lander.md): a PR labelled `queue` on the last pass that is now merged,
#        closed, or open with a lander comment (it left the queue).
#   3. Wake-up: when there is news and the integrator (`integrator_name`, in the main
#      worktree) is `idle` or `done`, one `herdr agent prompt` lists it; never while it is
#      `working` or `blocked` (the news waits). Each item is told once: a PR again only at a
#      new head.
#   4. Compaction (before the wake-up): when the integrator is `idle` or `done` and its context
#      (context-tokens.py: the last turn's prompt size in its Claude Code transcript) is above
#      `integrator_compact_tokens` (default 120000; 0 turns it off), one `herdr agent prompt`
#      types `/compact <what to keep>` into it: at most once per idle period (until it is seen
#      `working` or `blocked` again) and once every $HERDR_AGENT_POOL_COMPACT_COOLDOWN seconds
#      (default 600). Never while it works or is blocked; a pass that compacts leaves the news
#      for the next one. A transcript it cannot read means no compaction, said once on stderr.
# One line on stdout per action (cleaned, refused, woke, COMPACT <name> <tokens>).
#
# Inside Claude Code only the integrator (CLAUDE_ROLE=integrator) runs it; the user may run it
# from a herdr pane. Exit codes: 0 ok; 1 usage, settings, pool mode or role. Needs git, gh,
# jq, python3 and herdr.
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
die() { echo "integrator-watch: $1" >&2; exit 1; }
config=$("$dir/project-config.py") || exit 1
cfg() { jq -r "$1" <<<"$config"; }
[[ "$(cfg .mode)" == single ]] || die "pool mode: the coordinator runs integrator-pool.sh watch"
[[ "${CLAUDECODE:-}" != 1 || "${CLAUDE_ROLE:-}" == integrator ]] \
    || die "only the integrator (CLAUDE_ROLE=integrator) runs the watcher from Claude Code"
[[ "${HERDR_ENV:-}" == 1 ]] || die "not inside herdr (HERDR_ENV != 1)"
name=$(cfg .integrator_name); base=$(cfg .base_branch)
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)") || exit 1
pstate="$(git rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool"; ws="$pstate/integrator-watch"
mkdir -p "$ws" || exit 1
grace="${HERDR_AGENT_POOL_CLEAN_GRACE:-180}"
compact_tokens=$(cfg .integrator_compact_tokens); cooldown="${HERDR_AGENT_POOL_COMPACT_COOLDOWN:-600}"
compact_text="/compact Keep: every open PR and its state (claimed, bounced, held, waiting for a verdict, \
queued for the lander), the verdicts not yet sent to their authors, the plan progress (phase, tasks \
done, next tasks) and everything the user asked or decided. Drop: old tool output, diffs and logs \
already acted on; GitHub, pool-state.py and docs/phases/ hold the rest."
cd "$main" || exit 1

clean_pass() {
    local branch state now rc out
    now=$(date +%s)
    while IFS=$'\t' read -r branch state _; do
        [[ -n "$branch" ]] || continue
        local f="$ws/ready-${branch//\//%}"
        if [[ "$state" != ready ]]; then rm -f "$f"; continue; fi
        [[ -f "$f" ]] || { echo "$now" > "$f"; continue; }
        (( now - $(cat "$f") >= grace )) || continue
        out=$("$dir/cleanup-worktree.sh" "$branch" 2>&1); rc=$?
        rm -f "$f"
        if [[ $rc == 0 ]]; then echo "cleaned $branch"
        else echo "cleanup of $branch refused (exit $rc): $(tail -n 1 <<<"$out")"; fi
    done < <("$dir/cleanup-worktree.sh" --list 2>/dev/null)
}

# The open PRs: "<number> <head> <labels,> <draft>" per line.
open_prs() {
    gh pr list --base "$base" --state open --limit 200 --json number,headRefOid,isDraft,labels \
        | jq -r '.[] | "\(.number) \(.headRefOid) ,\([.labels[]?.name] | join(",")), \(.isDraft)"'
}
recorded_head() { jq -r '.head // empty' "$pstate/$1/pr-$2.json" 2>/dev/null; }

# News items, "<key>\t<text>" per line: $ws/news-prs is rebuilt every pass (a PR decided
# meanwhile is no news); $ws/news-lander accumulates until told.
news_pass() {
    local prs n head labels draft queued="" text
    prs=$(open_prs) || { echo "gh pr list failed: no news this pass" >&2; return 1; }
    : > "$ws/news-prs"
    while read -r n head labels draft; do
        [[ -n "$n" && "$draft" == false ]] || continue
        if [[ "$labels" == *,queue,* ]]; then queued+="$n "; continue; fi
        [[ "$labels" != *,needs-human,* ]] || continue
        [[ "$(recorded_head bounced "$n")" != "$head" && "$(recorded_head held "$n")" != "$head" ]] || continue
        if [[ "$(cat "$ws/seen-$n" 2>/dev/null)" != "$head" ]]; then echo "$head" > "$ws/seen-$n"; continue; fi
        [[ "$(cat "$ws/told-$n" 2>/dev/null)" != "$head" ]] || continue
        printf 'pr %s %s\tPR #%s waits for a verdict (head %s)\n' "$n" "$head" "$n" "${head:0:12}" >> "$ws/news-prs"
    done <<<"$prs"
    for n in $(cat "$ws/queued" 2>/dev/null); do
        [[ " $queued " != *" $n "* ]] || continue
        text=$(lander_outcome "$n") && printf 'lander %s\tPR #%s %s\n' "$n" "$n" "$text" >> "$ws/news-lander"
    done
    echo "$queued" > "$ws/queued"
    for f in "$ws"/seen-* "$ws"/told-*; do   # PRs no longer open forget their state
        [[ -e "$f" ]] || continue
        n=${f##*-}; grep -q "^$n " <<<"$prs" || rm -f "$f"
    done
}
lander_outcome() {  # lander_outcome <N>: what happened to a PR that left the queue (exit 1: nothing to say)
    local pr state
    pr=$(gh pr view "$1" --json state,comments 2>/dev/null) || return 1
    state=$(jq -r .state <<<"$pr")
    case "$state" in
        MERGED) echo "merged (it was queued for the lander)" ;;
        CLOSED) echo "was closed (it was queued for the lander)" ;;
        *) jq -er '[.comments[]? | .body // "" | select(startswith("Lander:") or contains("herdr-agent-pool:lander bounce"))]
                   | last | select(.) | split("\n") | map(select(length > 0 and (startswith("<!--") | not))) | first
                   | "left the queue: " + .[0:160]' <<<"$pr" ;;
    esac
}

integrator_status() { "$dir/agents-in-repo.py" --name "$name" --main-worktree 2>/dev/null | head -n 1 | cut -f3; }

# compact_pass <status>: one /compact when the idle integrator's context is over the threshold.
# Exit 0 only when it sent one. $ws/compact-idle marks an idle period that had its compaction.
compact_pass() {
    local tokens now last
    case "$1" in
        working|blocked) rm -f "$ws/compact-idle"; return 1 ;;
        idle|done) ;;
        *) return 1 ;;
    esac
    [[ "$compact_tokens" -gt 0 && ! -e "$ws/compact-idle" ]] || return 1
    now=$(date +%s); last=$(cat "$ws/compact-last" 2>/dev/null || echo 0)
    (( now - last >= cooldown )) || return 1
    if ! tokens=$("$dir/context-tokens.py" "$name" 2>"$ws/compact-error"); then
        [[ -e "$ws/compact-unreadable" ]] \
            || echo "integrator-watch: no compaction, cannot read $name's context: $(tail -n 1 "$ws/compact-error")" >&2
        touch "$ws/compact-unreadable"; return 1
    fi
    rm -f "$ws/compact-unreadable"
    (( tokens > compact_tokens )) || return 1
    herdr agent prompt "$name" "$compact_text" >/dev/null 2>&1 \
        || { echo "the /compact prompt to $name failed; next pass retries" >&2; return 1; }
    echo "$now" > "$ws/compact-last"; touch "$ws/compact-idle"
    echo "COMPACT $name $tokens"
}

wake_pass() {  # wake_pass <status>: tells the integrator the pending news when it is idle or done
    local text news
    news=$(cat "$ws/news-lander" "$ws/news-prs" 2>/dev/null)
    [[ -n "$news" ]] || return 0
    [[ "$1" == idle || "$1" == "done" ]] || return 0
    text="[herdr message from the integrator watcher (integrator-watch.sh); not from the user]
Since your last pass:
$(cut -f2 <<<"$news" | sed 's/^/- /')
Run /herdr-agent-pool:integrate now: refresh the queue."
    herdr agent prompt "$name" "$text" >/dev/null 2>&1 || { echo "the prompt to $name failed; next pass retries" >&2; return 0; }
    echo "woke $name: $(cut -f2 <<<"$news" | paste -sd ';' -)"
    while read -r kind n head; do
        [[ "$kind" != pr ]] || echo "$head" > "$ws/told-$n"
    done < <(cut -f1 <<<"$news")
    rm -f "$ws/news-lander" "$ws/news-prs"
}

one_pass() {
    local news=0 status
    clean_pass
    news_pass || news=1
    status=$(integrator_status)
    compact_pass "$status" && return 0   # the news waits for the next pass
    (( news == 0 )) && wake_pass "$status"
}

case "${1:-60}" in
    once) one_pass ;;
    *[!0-9]*|"") die "usage: integrator-watch.sh [SECONDS] | once" ;;
    *)
        interval="$1"
        [[ "$interval" -ge 10 ]] || die "the interval must be at least 10 seconds"
        # One watcher per repository: a kernel flock on fd 8 for the loop's lifetime.
        exec 8>>"$pstate/integrator-watch.lock" || exit 1
        if ! python3 -c 'import fcntl, sys
try:
    fcntl.flock(8, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)'; then
            echo "an integrator watcher already runs for this repository (pid $(cat "$pstate/integrator-watch.pid" 2>/dev/null || echo '?'))"
            exit 0
        fi
        echo "$$" > "$pstate/integrator-watch.pid"
        echo "integrator watcher $$: a pass every ${interval}s (stop it with kill $$)"
        while :; do
            ( one_pass ) 8>&- || echo "integrator-watch: pass failed; next one in ${interval}s" >&2
            sleep "$interval" 8>&-
        done ;;
esac
