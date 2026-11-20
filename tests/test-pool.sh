#!/usr/bin/env bash
# Smoke tests for pool mode (docs/multi-integrator.md): project-config.py's pool keys, the
# machine's heavy-slot floor (resource-budget.py) and resource board (resource-board.sh), the
# guards' role rules, claim-integrator.sh and the SessionStart hook for the coordinator and pool
# members, agents-in-repo.py's worktree filters, pool-state.py (claim races, stale claims,
# bounces, the merge lock, plan reports), union-rows.py, integrate-pr.sh end to end (with
# renumber.py: numbered files renumbered at merge; plan-tick.py: plan ticks in the merge in
# single mode), integrator-pool.sh (route, scale, spawn, stop), cleanup-worktree.sh and
# integrator-watch.sh (single mode's watcher). Part of herdr-agent-pool.
#
# Usage: tests/test-pool.sh        (exit code = number of failed cases)
#
# Everything runs in throwaway repositories with a bare `origin`, a fake `herdr` and a fake
# `gh` on PATH; nothing touches GitHub or a real herdr server. The project's scripts/check.sh
# in the test repository counts its runs ($CHECK_COUNT), runs a hook once ($CHECK_HOOK: push to
# the PR branch or to main *during* a verification) and fails when fail.txt exists.
# Needs git, jq and python3.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hooks="$root/plugin/hooks"
scripts="$root/plugin/scripts"
export CLAUDE_PLUGIN_ROOT="$root/plugin"
export HERDR_AGENT_POOL_NO_WATCH=1   # the SessionStart hook starts no watcher in the tests
unset CLAUDE_ROLE HERDR_AGENT_POOL_NAME CLAUDECODE CHECK_COUNT CHECK_HOOK HERDR_ENV HERDR_AGENT_POOL_SLOT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Not under a temporary directory: the Bash guard allows writes there on purpose. Each run
# gets its own directory, so two runs at once cannot delete each other's repositories.
base="$root/.test-work-pool"
case "$root/" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|"${TMPDIR:-/nonexistent}"*)
        base="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-agent-pool-test-work-pool" ;;
esac
mkdir -p "$base" && work=$(mktemp -d "$base/run.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd -P)   # agents-in-repo.py compares realpaths
# The scratch repositories live inside this checkout: git must never walk up from one of
# them into the checkout itself (a missing scratch repository would otherwise make the
# tests commit, switch branches and push in the real repository).
export GIT_CEILING_DIRECTORIES="$work"
fails=0

check() {  # check <description> <command...>: ok when the command succeeds
    local desc="$1"; shift
    if "$@"; then echo "ok    $desc"; else echo "FAIL  $desc"; fails=$((fails + 1)); fi
}
expect() {  # expect <code> <description> <hook> <json>
    local want="$1" desc="$2" hook="$3" json="$4" got
    printf '%s' "$json" | "$hook" >/dev/null 2>&1; got=$?
    if [[ "$got" == "$want" ]]; then echo "ok    $desc"
    else echo "FAIL  $desc (exit $got, want $want)"; fails=$((fails + 1)); fi
}
not() { ! "$@"; }
exits() {  # exits <code> <command...>: ok when the command exits with <code> (else shows why)
    local want="$1" got out; shift
    out=$("$@" 2>&1); got=$?
    [[ $got == "$want" ]] || { echo "      (exit $got, want $want: $(tail -2 <<<"$out" | tr '\n' ' '))"; return 1; }
}
bash_cmd() { jq -nc --arg c "$1" --arg d "$2" '{tool_input: {command: $c}, cwd: $d}'; }
file_op() { jq -nc --arg f "$1" '{tool_input: {file_path: $f}}'; }

# Fakes -------------------------------------------------------------------------------------
fake="$work/bin"; mkdir -p "$fake"
cat > "$fake/herdr" <<'FAKE'
#!/usr/bin/env bash
# Fake herdr: `agent list` prints $FAKE_AGENTS; `pane current` reports $FAKE_PANE; mutating
# commands are logged to $FAKE_LOG (one line each; `agent prompt` also writes its whole message
# to $FAKE_PROMPT_FILE when that is set). $FAKE_HERDR_DOWN makes every call fail.
# `agent start` also writes its arguments to $FAKE_ARGV, one per line, when it is set.
[[ -z "${FAKE_HERDR_DOWN:-}" ]] || { echo "herdr: no server" >&2; exit 1; }
case "$1 $2" in
    "agent list") cat "$FAKE_AGENTS" ;;
    "pane current") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$FAKE_PANE" ;;
    "pane list") if [[ -n "${FAKE_PANES:-}" ]]; then cat "$FAKE_PANES"; else echo '{"result":{"panes":[]}}'; fi ;;
    "pane process-info") printf '{"result":{"process_info":{"pane_id":"%s","shell_pid":%s}}}\n' "$4" "${FAKE_SHELL_PID:-0}" ;;
    "agent rename") echo "rename $3 $4" >> "$FAKE_LOG"; echo '{"result":{}}' ;;
    "workspace create") shift 2; echo "workspace-create $*" >> "$FAKE_LOG"
        echo '{"result":{"workspace":{"workspace_id":"w9"},"root_pane":{"pane_id":"w9:p1"}}}' ;;
    "workspace close") echo "workspace-close $3" >> "$FAKE_LOG"; echo '{"result":{}}' ;;
    "agent start") shift 2; echo "agent-start $*" >> "$FAKE_LOG"
        [[ -z "${FAKE_ARGV:-}" ]] || printf '%s\n' "$@" > "$FAKE_ARGV"
        [[ "${FAKE_START_RC:-0}" == 0 ]] || { echo '{"error":{"code":"agent_not_ready"}}'; exit 1; } ;;
    "agent prompt") printf 'prompt %s %s\n' "$3" "$(head -1 <<<"$4")" >> "$FAKE_LOG"
        [[ -z "${FAKE_PROMPT_FILE:-}" ]] || printf '%s\n' "$4" > "$FAKE_PROMPT_FILE" ;;
    *) exit 2 ;;
esac
FAKE
cat > "$fake/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh: `pr view N [--json ...] [-q EXPR]` reads $FAKE_GH/pr-N.json, `pr list` prints
# $FAKE_GH/list-<state>.json for `--state <state>` when it exists, else $FAKE_GH/list.json,
# `pr comment` is logged, `api user` prints the account (tester).
case "$1 $2" in
    "pr view") n=$3; shift 3; q=.
        while [[ $# -gt 0 ]]; do case "$1" in -q) q=$2; shift 2 ;; *) shift ;; esac; done
        [[ -f "$FAKE_GH/pr-$n.json" ]] || { echo "no pull requests found" >&2; exit 1; }
        jq -r "$q" "$FAKE_GH/pr-$n.json" ;;
    "pr list") state=""; while [[ $# -gt 0 ]]; do [[ "$1" == --state ]] && state=$2; shift; done
        if [[ -n "$state" && -f "$FAKE_GH/list-$state.json" ]]; then cat "$FAKE_GH/list-$state.json"
        else cat "$FAKE_GH/list.json"; fi ;;
    "api user") echo "${FAKE_GH_USER:-tester}" ;;
    "pr comment") echo "comment $3" >> "$FAKE_GH/log" ;;
    "pr create") shift 2; echo "create $*" >> "$FAKE_GH/log"; echo "https://github.com/o/r/pull/${FAKE_GH_NEW_PR:-77}" ;;
    *) exit 2 ;;
esac
FAKE
chmod +x "$fake/herdr" "$fake/gh"
export PATH="$fake:$PATH" FAKE_AGENTS="$work/agents.json" FAKE_LOG="$work/herdr.log" FAKE_PANE="w1:p1"
# Every fake pane's shell is this test's shell: an ancestor of each command the tests run, which
# is what pool-state.py's caller_name requires before it believes $HERDR_PANE_ID.
export FAKE_SHELL_PID=$$
export FAKE_GH="$work/gh"; mkdir -p "$FAKE_GH"; echo '[]' > "$FAKE_GH/list.json"
agents() {  # agents <name|-> <pane> <status> <cwd> ...: write the fake `herdr agent list`
    local json='[]'   # a named agent's Claude Code session id is sess-<name>
    while [[ $# -ge 4 ]]; do
        json=$(jq -c --arg n "$1" --arg p "$2" --arg s "$3" --arg c "$4" \
            '. + [{pane_id: $p, agent_status: $s, cwd: $c}
                  + (if $n == "-" then {} else {name: $n, agent_session: {kind: "id", value: ("sess-" + $n)}} end)]' <<<"$json")
        shift 4
    done
    jq -n --argjson a "$json" '{result: {agents: $a}, type: "agent_list"}' > "$FAKE_AGENTS"
}
agents
: > "$FAKE_LOG"
# The resource budget's state and limits, private to the tests (never ~/.cache or ~/.config).
export HERDR_AGENT_POOL_RESOURCES_DIR="$work/resources" HERDR_AGENT_POOL_RESOURCES_CONFIG="$work/resources.json"
export HERDR_AGENT_POOL_MISSING_GRACE=0   # an owner missing from herdr is dead at once (one test sets a grace)
budget() { printf '{"heavy_slots": 1, "sessions_guideline": %s, "low_memory_gb": 0}\n' "$1" > "$HERDR_AGENT_POOL_RESOURCES_CONFIG"; }
budget 50

# A project in pool mode, with a bare origin --------------------------------------------------
origin="$work/origin.git"; proj="$work/proj"
git init --quiet --bare -b main "$origin"
git init --quiet -b main "$proj"
mkdir -p "$proj/.claude/prompts" "$proj/scripts" "$proj/docs/decisions" "$proj/docs/phases" "$proj/src"
cp "$root/template/.claude/settings.json" "$proj/.claude/settings.json"
cat > "$proj/.claude/herdr-agent-pool.json" <<'JSON'
{"integrators": {"max": 2, "scale_up_when_active_agents_gt": 2}}
JSON
echo "stance" > "$proj/.claude/prompts/integrator.md"
cat > "$proj/scripts/check.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ -z "${CHECK_COUNT:-}" ]] || echo run >> "$CHECK_COUNT"
if [[ -n "${CHECK_HOOK:-}" && ! -e "$CHECK_HOOK.done" ]]; then touch "$CHECK_HOOK.done"; "$CHECK_HOOK"; fi
[[ ! -e fail.txt ]] || { echo "fail.txt is present"; exit 1; }
i=0   # ADR numbers unique and contiguous from 0001, each one linked from the index
for f in docs/adr/[0-9][0-9][0-9][0-9]-*.md; do
    [[ -e "$f" ]] || continue
    i=$((i + 1)); n=$(basename "$f")
    [[ "${n:0:4}" == "$(printf %04d "$i")" ]] || { echo "ADR numbers not contiguous at $n"; exit 1; }
    grep -qF "]($n)" docs/adr/README.md || { echo "$n is not in the ADR index"; exit 1; }
done
echo "checks ok"
SH
chmod +x "$proj/scripts/check.sh"
printf '| ADR | Title |\n|---|---|\n| [0001](0001-a.md) | First |\n' > "$proj/docs/decisions/README.md"
printf '# Plan\n- [ ] task\n' > "$proj/docs/phases/plan.md"
printf 'line one\n' > "$proj/src/a.txt"
git -C "$proj" add -A && git -C "$proj" commit --quiet -m init
git -C "$proj" remote add origin "$origin" && git -C "$proj" push --quiet -u origin main
dev="$work/dev"; git clone --quiet "$origin" "$dev"
pusher="$work/pusher"; git clone --quiet "$origin" "$pusher"
wt1="$work/proj-integrator-1"
git -C "$proj" worktree add --quiet --detach "$wt1" origin/main
for repo in "$proj" "$dev" "$pusher" "$wt1"; do   # every scratch repository is its own
    [[ "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" == "$repo" ]] \
        || { echo "ABORT: $repo is not an isolated test repository"; exit 99; }
done
[[ "$(git -C "$dev" remote get-url origin)" == "$origin" ]] || { echo "ABORT: $dev does not push to the test origin"; exit 99; }

pc="$scripts/project-config.py"
ps="$scripts/pool-state.py"
ipr="$scripts/integrate-pr.sh"
pool="$scripts/integrator-pool.sh"

# project-config.py ---------------------------------------------------------------------------
check "project-config: pool mode"                [ "$(cd "$proj" && "$pc" mode)" == pool ]
check "project-config: pool names"               [ "$(cd "$proj" && "$pc" integrator_pool | tr '\n' ' ')" == "integrator-proj-1 integrator-proj-2 " ]
check "project-config: coordinator default name" [ "$(cd "$proj" && "$pc" coordinator_name)" == coordinator-proj ]
check "project-config: dotted key and defaults"  [ "$(cd "$proj" && "$pc" integrators.claim_ttl_minutes)" == 60 ]
long="$work/a-very-long-repository-name-that-overflows"; git init --quiet -b main "$long"; mkdir -p "$long/.claude"
echo '{"integrators": {"max": 12}}' > "$long/.claude/herdr-agent-pool.json"
names=$("$pc" --root "$long" integrator_pool)
check "project-config: long names fit 32 characters" \
    bash -c '[[ $(wc -l <<<"$1") == *12 ]] && ! grep -Evq "^[a-z][a-z0-9_-]{0,31}$" <<<"$1" && [[ "$(tail -1 <<<"$1")" == *-12 ]]' _ "$names"
check "project-config: single mode by default"   [ "$("$pc" --root "$work/nowhere" mode)" == single ]
bad="$work/bad"; git init --quiet -b main "$bad"; mkdir -p "$bad/.claude"
for json in '{"integrators": {"min": 3, "max": 2}}' '{"integrators": {"max": 17}}' '{"integrators": {"maxx": 2}}' \
            '{"integrators": {"max": 0}}' '{"integrators": {"max": true}}' '{"integrators": 3}' '{"mode": "pool"}' \
            '{"integrators": {}, "coordinator_name": "integrator-bad-1"}' '{"coordinator_name": "Coord"}' \
            '{"integrators": {"reverify_exempt_paths": "docs/*"}}' '{"integrators": {"max_reverify": 0}}' \
            '{"integrators": {"nudge_after_minutes": -1}}' '{"numbered_files": {"adr": "docs/(a)(b)"}}' \
            '{"numbered_files": {"ADR": "docs/(1)"}}' '{"numbered_files": {"adr": "docs/("}}' '{"numbered_files": []}' \
            '{"plan_ticks_in_merge": "no"}' '{"plan_ticks_in_merge": 0}' '{"integrator_compact_tokens": -1}' \
            '{"integrator_compact_tokens": "120000"}' '{"integrator_compact_tokens": true}' '{"integrator_compact_tokens": 1.5}'; do
    printf '%s\n' "$json" > "$bad/.claude/herdr-agent-pool.json"
    "$pc" --root "$bad" >/dev/null 2>&1; status=$?
    check "project-config: rejects $json" [ "$status" == 1 ]
done
printf '%s\n' '{"integrators": {"locked_reverify_minutes": 0, "nudge_after_minutes": 0}}' > "$bad/.claude/herdr-agent-pool.json"
check "project-config: 0 turns the locked re-verify and the nudges off" \
    [ "$("$pc" --root "$bad" integrators.locked_reverify_minutes)$("$pc" --root "$bad" integrators.nudge_after_minutes)" == 00 ]
check "project-config: plan ticks in the merge by default" [ "$("$pc" --root "$work/nowhere" plan_ticks_in_merge)" == true ]
check "project-config: compacts the integrator above 120000 tokens by default" \
    [ "$("$pc" --root "$work/nowhere" integrator_compact_tokens)" == 120000 ]
printf '%s\n' '{"integrator_compact_tokens": 0}' > "$bad/.claude/herdr-agent-pool.json"
check "project-config: integrator_compact_tokens 0 (off) is valid" [ "$("$pc" --root "$bad" integrator_compact_tokens)" == 0 ]
# The template's coordinator.sh repeats the default name rule.
mkdir -p "$work/names/Data Lab"; git init --quiet -b main "$work/names/Data Lab"
mkdir -p "$work/names/Data Lab/scripts" && cp "$root/template/scripts/coordinator.sh" "$work/names/Data Lab/scripts/"
check "coordinator.sh: default name agrees with project-config.py" \
    [ "$("$work/names/Data Lab/scripts/coordinator.sh" --print-name)" == "$("$pc" --root "$work/names/Data Lab" coordinator_name)" ]
check "coordinator.sh: refuses to launch in single mode" \
    bash -c '! HERDR_ENV=1 "$1" >/dev/null 2>&1' _ "$work/names/Data Lab/scripts/coordinator.sh"
cp "$root/template/scripts/integrator.sh" "$wt1/integrator.sh"   # any path inside the repository works
check "integrator.sh: refuses to launch in pool mode" \
    bash -c 'out=$(HERDR_ENV=1 "$1" 2>&1); [[ $? == 1 && "$out" == *coordinator.sh* ]]' _ "$wt1/integrator.sh"
rm -f "$wt1/integrator.sh"

# Guards in pool mode -------------------------------------------------------------------------
g="$hooks/guard-main-bash.py"; w="$hooks/guard-main-worktree.sh"
git -C "$proj" worktree add --quiet -b feat/dev1 "$work/proj-dev1" origin/main
d1="$work/proj-dev1"
expect 0 "pool guard: developer prompts the coordinator"   "$g" "$(bash_cmd 'herdr agent prompt coordinator-proj "question"' "$d1")"
expect 0 "pool guard: developer prompts a pool member"     "$g" "$(bash_cmd 'herdr agent prompt integrator-proj-2 "PR #1 ready"' "$d1")"
expect 2 "pool guard: developer prompts the bare prefix"   "$g" "$(bash_cmd 'herdr agent prompt integrator-proj "PR #1 ready"' "$d1")"
expect 2 "pool guard: developer pushes main under the lock" "$g" "$(bash_cmd "$ps lock run --owner x -- git push origin HEAD:main" "$d1")"
CLAUDE_ROLE=integrator expect 2 "pool guard: integrator commits in the main worktree" "$g" "$(bash_cmd 'git commit -m x' "$proj")"
CLAUDE_ROLE=integrator expect 2 "pool guard: integrator writes into the main worktree" "$g" "$(bash_cmd 'echo x > notes.md' "$proj")"
CLAUDE_ROLE=integrator expect 2 "pool guard: integrator pushes main directly"  "$g" "$(bash_cmd 'git push origin HEAD:main' "$wt1")"
CLAUDE_ROLE=integrator expect 0 "pool guard: integrator pushes main under the lock" "$g" "$(bash_cmd "$ps lock run --owner integrator-proj-1 -- git push origin HEAD:main" "$wt1")"
CLAUDE_ROLE=integrator expect 2 "pool guard: integrator --all under the lock"  "$g" "$(bash_cmd "$ps lock run --owner i -- git push --all origin" "$wt1")"
CLAUDE_ROLE=integrator expect 2 "pool guard: integrator gh pr merge"           "$g" "$(bash_cmd 'gh pr merge 3' "$wt1")"
CLAUDE_ROLE=integrator expect 0 "pool guard: integrator merges in its worktree" "$g" "$(bash_cmd 'git merge --no-ff --no-commit origin/feat/x' "$wt1")"
CLAUDE_ROLE=integrator expect 0 "pool guard: integrator prompts an author"    "$g" "$(bash_cmd 'herdr agent prompt dev1 "verdict"' "$wt1")"
CLAUDE_ROLE=coordinator expect 0 "pool guard: coordinator commits in the main worktree" "$g" "$(bash_cmd 'git commit -m "docs(plan): tick"' "$proj")"
CLAUDE_ROLE=coordinator expect 2 "pool guard: coordinator pushes main directly" "$g" "$(bash_cmd 'git push origin HEAD:main' "$proj")"
CLAUDE_ROLE=coordinator expect 0 "pool guard: coordinator pushes main under the lock" "$g" "$(bash_cmd "$ps lock run --owner coordinator-proj -- git push origin HEAD:main" "$proj")"
CLAUDE_ROLE=coordinator expect 2 "pool guard: coordinator gh pr merge"          "$g" "$(bash_cmd 'gh pr merge 3' "$proj")"
CLAUDE_ROLE=coordinator expect 0 "pool guard: coordinator starts agents"        "$g" "$(bash_cmd 'herdr agent start x --kind claude --pane w2:p1' "$proj")"
CLAUDE_ROLE=coordinator expect 0 "edit guard: coordinator edits the plan"       "$w" "$(file_op "$proj/docs/phases/plan.md")"
CLAUDE_ROLE=integrator  expect 2 "edit guard: pool integrator edits the main worktree" "$w" "$(file_op "$proj/docs/phases/plan.md")"
CLAUDE_ROLE=integrator  expect 0 "edit guard: pool integrator edits its worktree" "$w" "$(file_op "$wt1/x.md")"
single="$work/single"; git init --quiet -b main "$single"; mkdir -p "$single/.claude"
cp "$root/template/.claude/settings.json" "$single/.claude/settings.json"
git -C "$single" add -A && git -C "$single" commit --quiet -m init
CLAUDE_ROLE=coordinator expect 2 "single guard: a coordinator is just a session" "$g" "$(bash_cmd 'git commit -m x' "$single")"
CLAUDE_ROLE=coordinator expect 2 "single edit guard: a coordinator is just a session" "$w" "$(file_op "$single/x.md")"
CLAUDE_ROLE=integrator  expect 0 "single guard: the integrator may do everything" "$g" "$(bash_cmd 'git push origin HEAD:main && gh pr merge 3' "$single")"
CLAUDE_ROLE=integrator  expect 0 "single edit guard: the integrator edits"     "$w" "$(file_op "$single/x.md")"
CLAUDE_ROLE=integrator  expect 0 "single guard: the integrator runs its watcher"  "$g" "$(bash_cmd "$scripts/integrator-watch.sh" "$single")"
expect 2 "guard: posing as an integrator with a prefix" "$g" "$(bash_cmd "CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME=integrator-proj-1 $ipr 12" "$d1")"
expect 2 "guard: setting the member name through env"   "$g" "$(bash_cmd 'env HERDR_AGENT_POOL_NAME=integrator-proj-1 ls' "$d1")"
expect 2 "guard: export CLAUDE_ROLE"                    "$g" "$(bash_cmd 'export CLAUDE_ROLE=coordinator' "$d1")"
expect 2 "guard: skipping the heavy-slot floor"         "$g" "$(bash_cmd 'HERDR_AGENT_POOL_SLOT=1 scripts/check.sh' "$d1")"
expect 0 "guard: other variables are fine"              "$g" "$(bash_cmd 'FOO=1 env BAR=2 ls' "$d1")"
# The re-review's probes: env options that take an argument, wrappers in front, interpreters.
for probe in "env -u FOO CLAUDE_ROLE=integrator $ipr 3" \
             "env -i -u A CLAUDE_ROLE=integrator $ps claim 3 --owner x" \
             "command env -u A CLAUDE_ROLE=integrator $ipr 3" \
             "time env -u A HERDR_AGENT_POOL_NAME=x $ipr 3" \
             "env -C /tmp CLAUDE_ROLE=integrator $ipr 3" \
             "env -S 'CLAUDE_ROLE=integrator ls'" "env -SCLAUDE_ROLE=x ls" \
             "exec -a x env HERDR_ENV=1 ls" "env -- HERDR_AGENT_POOL_SLOT=1 ls" \
             "bash $ipr 3" "sh $scripts/cleanup-worktree.sh feat/x" \
             "python3 $ps claim 3 --owner x" "python3 -I $ps lock run --owner x -- true" \
             "env -u A python3 $ps bounce 3 --head h --owner x"; do
    expect 2 "guard: blocks '$probe'" "$g" "$(bash_cmd "$probe" "$d1")"
done
expect 0 "guard: env -u alone is fine"                  "$g" "$(bash_cmd 'env -u FOO ls' "$d1")"
for probe in "HERDR_PANE_ID=w1:p1 $ps claim 3 --owner x" "env HERDR_TAB_ID=w1:t1 ls" \
             "export HERDR_WORKSPACE_ID=w1" "env -u A HERDR_SOCKET_PATH=/tmp/s ls" "HERDR_BIN_PATH=/x ls"; do
    expect 2 "guard: blocks '$probe'" "$g" "$(bash_cmd "$probe" "$d1")"
done
expect 0 "guard: bash running an ordinary script"       "$g" "$(bash_cmd 'bash scripts/check.sh' "$d1")"
expect 0 "guard: python3 -c"                            "$g" "$(bash_cmd "python3 -c 'print(1)'" "$d1")"
expect 2 "guard: a developer runs integrate-pr.sh"      "$g" "$(bash_cmd "$ipr 12" "$d1")"
expect 2 "guard: a developer claims a PR"               "$g" "$(bash_cmd "$ps claim 12 --owner integrator-proj-1" "$d1")"
expect 0 "guard: a developer reads the queue"           "$g" "$(bash_cmd "$ps queue --base main" "$d1")"
expect 2 "guard: a developer cleans up a branch"        "$g" "$(bash_cmd "$scripts/cleanup-worktree.sh feat/x" "$d1")"
expect 0 "guard: a developer lists the cleanup state"   "$g" "$(bash_cmd "$scripts/cleanup-worktree.sh --list" "$d1")"
expect 2 "guard: a developer runs the integrator watcher" "$g" "$(bash_cmd "$scripts/integrator-watch.sh once" "$d1")"
CLAUDE_ROLE=integrator  expect 0 "guard: a pool integrator runs integrate-pr.sh" "$g" "$(bash_cmd "$ipr 12" "$wt1")"
CLAUDE_ROLE=integrator  expect 2 "guard: a pool integrator spawns members"      "$g" "$(bash_cmd "$scripts/integrator-pool.sh spawn 2" "$wt1")"
CLAUDE_ROLE=integrator  expect 2 "guard: a pool integrator runs the pool watcher" "$g" "$(bash_cmd "$scripts/integrator-pool.sh watch" "$wt1")"
expect 0 "guard: a developer reserves a number"     "$g" "$(bash_cmd "$ps reserve adr --owner feat/x" "$d1")"
expect 2 "guard: a developer reports a red base"   "$g" "$(bash_cmd "$ps base-red report --tests t --owner x" "$d1")"
expect 0 "guard: a developer reads the red-base banner" "$g" "$(bash_cmd "$ps base-red show" "$d1")"
expect 2 "guard: a developer holds a PR"          "$g" "$(bash_cmd "$ps hold 3 --head x --owner x" "$d1")"
CLAUDE_ROLE=coordinator expect 0 "guard: the coordinator spawns members"        "$g" "$(bash_cmd "$scripts/integrator-pool.sh spawn 2" "$proj")"
CLAUDE_ROLE=coordinator expect 0 "guard: the coordinator cleans up"             "$g" "$(bash_cmd "$scripts/cleanup-worktree.sh feat/x" "$proj")"
for push in "git push --force origin HEAD:main" "git push origin +HEAD:main" "git push origin --delete main" \
            "git push origin :main" "git push --force-with-lease origin HEAD:main" \
            "git push -uf origin HEAD:main" "git push -fu origin HEAD:main" "git push -ud origin main"; do
    CLAUDE_ROLE=integrator expect 2 "guard: under the lock, no '$push'" "$g" "$(bash_cmd "$ps lock run --owner i -- $push" "$wt1")"
done
badpool="$work/badpool"; git init --quiet -b main "$badpool"; mkdir -p "$badpool/.claude"
cp "$root/template/.claude/settings.json" "$badpool/.claude/settings.json"
printf '{"integrators": {"max": 2}, "typo": 1}\n' > "$badpool/.claude/herdr-agent-pool.json"
git -C "$badpool" add -A && git -C "$badpool" commit --quiet -m init
CLAUDE_ROLE=integrator  expect 2 "fail closed: invalid settings, no single-mode rights" "$g" "$(bash_cmd 'git commit -m x' "$badpool")"
CLAUDE_ROLE=integrator  expect 2 "fail closed: invalid settings, no push to main"     "$g" "$(bash_cmd 'git push origin HEAD:main' "$badpool")"
CLAUDE_ROLE=integrator  expect 2 "fail closed: invalid settings, edits blocked"       "$w" "$(file_op "$badpool/README.md")"
CLAUDE_ROLE=integrator  expect 0 "fail closed: the settings file itself may be fixed" "$w" "$(file_op "$badpool/.claude/herdr-agent-pool.json")"
CLAUDE_ROLE=coordinator expect 2 "fail closed: the coordinator too"                   "$w" "$(file_op "$badpool/README.md")"

# claim-integrator.sh and the SessionStart hook for the new roles -------------------------------
claim="$scripts/claim-integrator.sh"
claim_in() {  # claim_in <dir> <pane> [env...]: exit code of claim-integrator.sh
    local dir="$1" pane="$2"; shift 2
    (cd "$dir" && env HERDR_ENV=1 FAKE_PANE="$pane" HERDR_PANE_ID="$pane" "$@" "$claim" >/dev/null 2>&1)
}
agents - w1:p1 idle "$proj"  - w2:p1 idle "$wt1"
: > "$FAKE_LOG"; claim_in "$proj" w1:p1 CLAUDE_ROLE=coordinator; status=$?
check "claim: coordinator takes coordinator_name" [ "$status:$(cat "$FAKE_LOG")" == "0:rename w1:p1 coordinator-proj" ]
: > "$FAKE_LOG"; claim_in "$wt1" w2:p1 CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME=integrator-proj-1; status=$?
check "claim: pool member takes its name" [ "$status:$(cat "$FAKE_LOG")" == "0:rename w2:p1 integrator-proj-1" ]
claim_in "$wt1" w2:p1 CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME=integrator-proj-9; status=$?
check "claim: a name outside the pool is refused" [ "$status" == 1 ]
claim_in "$proj" w1:p1 CLAUDE_ROLE=integrator; status=$?
check "claim: pool mode has no single integrator" [ "$status" == 1 ]
claim_in "$single" w1:p1 CLAUDE_ROLE=coordinator; status=$?
check "claim: no coordinator in single mode" [ "$status" == 1 ]
agents coordinator-proj w1:p1 idle "$proj"  integrator-proj-1 w2:p1 idle "$wt1"
claim_in "$wt1" w2:p1 CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME=integrator-proj-1; status=$?
check "claim: already named pool member" [ "$status" == 0 ]

ssi="$hooks/session-start-integrator.sh"
ss() {  # ss <cwd> [env...]: the hook's additionalContext
    local dir="$1"; shift
    # A here-string, not a pipe: a hook that exits without reading stdin would SIGPIPE jq.
    env HERDR_ENV=1 "$@" "$ssi" 2>/dev/null \
        <<<"$(jq -nc --arg d "$dir" '{cwd: $d, hook_event_name: "SessionStart", source: "startup"}')" \
        | jq -r '.hookSpecificOutput.additionalContext // empty'
}
out=$(ss "$wt1" CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME=integrator-proj-1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1)
check "session-start: pool member in its verify worktree" bash -c '[[ "$1" == *"herdr agent integrator-proj-1"*"integrator pool"* ]]' _ "$out"
out=$(ss "$proj" CLAUDE_ROLE=coordinator FAKE_PANE=w1:p1 HERDR_PANE_ID=w1:p1)
check "session-start: coordinator in the main worktree" bash -c '[[ "$1" == *"herdr agent coordinator-proj (the coordinator)"* ]]' _ "$out"
out=$(ss "$d1" CLAUDE_ROLE=integrator FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1)
check "session-start: no claim in a linked worktree without a pool name" [ -z "$out" ]
out=$(jq -nc --arg d "$proj" '{cwd: $d}' | CLAUDE_ROLE=coordinator "$hooks/session-start-worktree.sh")
check "session-start-worktree: silent for the coordinator" [ -z "$out" ]

# agents-in-repo.py filters -------------------------------------------------------------------
agents coordinator-proj w1:p1 idle "$proj"  integrator-proj-1 w2:p1 working "$wt1"  dev1 w3:p1 idle "$d1/sub"
mkdir -p "$d1/sub"
air() { (cd "$proj" && "$scripts/agents-in-repo.py" "$@" | cut -f1 | tr '\n' ' '); }
check "agents-in-repo: --dev-only"  [ "$(air --dev-only)" == "dev1 " ]
check "agents-in-repo: --detached"  [ "$(air --detached)" == "integrator-proj-1 " ]
check "agents-in-repo: --main-worktree" [ "$(air --main-worktree)" == "coordinator-proj " ]

# pool-state.py -------------------------------------------------------------------------------
# A pool of eight in its own repository. In pool mode pool-state.py checks who calls: the herdr
# agent of the calling pane (FAKE_PANE) must be a pool member and match --owner. Member i is
# integrator-psr-i in pane wi:p9; the coordinator is coordinator-psr in pane wc:p9.
psr="$work/psr"; git init --quiet -b main "$psr"; mkdir -p "$psr/.claude"
cp "$root/template/.claude/settings.json" "$psr/.claude/settings.json"
echo '{"integrators": {"max": 8}}' > "$psr/.claude/herdr-agent-pool.json"
git -C "$psr" add -A && git -C "$psr" commit --quiet -m init
git -C "$psr" remote add origin "$origin" && git -C "$psr" fetch --quiet origin
mem() { echo "integrator-psr-$1"; }
as_m() { local i="$1"; shift; (cd "$psr" && HERDR_ENV=1 FAKE_PANE="w$i:p9" HERDR_PANE_ID="w$i:p9" "$ps" "$@"); }   # as member i
as_c() { (cd "$psr" && HERDR_ENV=1 FAKE_PANE="wc:p9" HERDR_PANE_ID="wc:p9" "$ps" "$@"); }                       # as the coordinator
psq() { (cd "$psr" && "$ps" "$@"); }                                                       # read-only
members() {  # members <i>...: the live agents are these members and the coordinator
    local list=(coordinator-psr wc:p9 idle "$psr") i
    for i in "$@"; do list+=("$(mem "$i")" "w$i:p9" idle "$psr"); done
    agents "${list[@]}"
}
members 1 2 3 4 5 6 7 8
for i in 1 2 3 4 5 6 7 8; do
    ( as_m "$i" claim 42 --owner "$(mem "$i")" >/dev/null 2>&1; echo $? > "$work/race.$i" ) &
done
wait
winners=$(grep -lx 0 "$work"/race.* | wc -l | tr -d ' '); held=$(grep -lx 3 "$work"/race.* | wc -l | tr -d ' ')
check "pool-state: 8 racing claims, exactly one wins" [ "$winners:$held" == "1:7" ]
winner=$(psq claims | awk -F'\t' '$1 == 42 { print $2 }'); wi=${winner##*-}
check "pool-state: the owner re-claims its own PR"     as_m "$wi" claim 42 --owner "$winner"
other=$(( wi % 8 + 1 ))
check "pool-state: another member cannot release it"  exits 3 as_m "$other" release 42 --owner "$(mem "$other")"
members "$other"   # the winner is gone
out=$(as_m "$other" claim 42 --owner "$(mem "$other")" 2>&1); status=$?
check "pool-state: a dead owner's claim is re-claimed" bash -c '[[ $1 == 0 && "$2" == *"re-claimed from"* ]]' _ "$status" "$out"
third=$(( other % 8 + 1 )); members "$other" "$third"
check "pool-state: a live owner's claim holds" exits 3 as_m "$third" claim 42 --owner "$(mem "$third")"
owner_file="$(git -C "$psr" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/claims/pr-42/owner.json"
jq '.heartbeat = 0' "$owner_file" > "$owner_file.new" && mv "$owner_file.new" "$owner_file"
check "pool-state: an expired heartbeat is re-claimed" as_m "$third" claim 42 --owner "$(mem "$third")"
check "pool-state: release by its owner"   as_m "$third" release 42 --owner "$(mem "$third")"
check "pool-state: release of an unclaimed PR" as_m "$third" release 42 --owner "$(mem "$third")"
check "pool-state: no .stale-pr-* left behind" \
    bash -c '! ls -A "$1" | grep -q "^\.stale-"' _ "$(git -C "$psr" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/claims"
# Who may call (pool mode): a member, as itself, inside herdr.
check "pool-state: refused outside herdr (exit 4)"     exits 4 psq claim 50 --owner "$(mem 1)"
agents foo w0:p9 idle "$psr"  "$(mem 1)" w1:p9 idle "$psr"
check "pool-state: refused to an agent outside the pool (exit 4)" \
    exits 4 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w0:p9 HERDR_PANE_ID=w0:p9 "$2" claim 50 --owner foo' _ "$psr" "$ps"
check "pool-state: refused when --owner is another agent (exit 4)" exits 4 as_m 1 claim 50 --owner "$(mem 2)"
check "pool-state: refused when herdr does not answer (exit 4)" \
    exits 4 env FAKE_HERDR_DOWN=1 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w1:p9 HERDR_PANE_ID=w1:p9 "$2" claim 50 --owner "$3"' _ "$psr" "$ps" "$(mem 1)"
members 1 2
check "pool-state: the coordinator may take the merge lock" as_c lock run --owner coordinator-psr -- true
check "pool-state: a member may not mark a plan report done (exit 4)" exits 4 as_m 1 report "done" 3
check "pool-state: read-only commands need no identity" psq claims
check "pool-state: whoami names the calling pane's agent" [ "$(as_m 1 whoami)" == "$(mem 1)" ]
check "pool-state: no \$HERDR_PANE_ID, no identity (no fallback to the focused pane)" \
    exits 4 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w1:p9 "$2" claim 50 --owner "$3"' _ "$psr" "$ps" "$(mem 1)"
sleep 30 & stranger=$!
check "pool-state: a forged \$HERDR_PANE_ID is refused (the pane's shell is not an ancestor)" \
    exits 4 env FAKE_SHELL_PID="$stranger" bash -c 'cd "$1" && HERDR_ENV=1 HERDR_PANE_ID=w1:p9 "$2" claim 50 --owner "$3"' _ "$psr" "$ps" "$(mem 1)"
kill "$stranger" 2>/dev/null; wait "$stranger" 2>/dev/null
# One glitchy herdr listing does not hand a live claim over; a later glitch starts a new grace.
as_m 1 claim 43 --owner "$(mem 1)" >/dev/null
members 2   # member 1 is missing from this listing
check "pool-state: an owner missing once keeps its claim (grace)" \
    exits 3 env HERDR_AGENT_POOL_MISSING_GRACE=1 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w2:p9 HERDR_PANE_ID=w2:p9 "$2" claim 43 --owner "$3"' _ "$psr" "$ps" "$(mem 2)"
members 1 2   # back: the mark is cleared
psq claims >/dev/null
sleep 1.2; members 2   # missing again, more than the grace after the first glitch
check "pool-state: a second glitch after a reappearance starts a new grace" \
    exits 3 env HERDR_AGENT_POOL_MISSING_GRACE=1 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w2:p9 HERDR_PANE_ID=w2:p9 "$2" claim 43 --owner "$3"' _ "$psr" "$ps" "$(mem 2)"
sleep 1.2
check "pool-state: an owner missing past the grace loses it" \
    env HERDR_AGENT_POOL_MISSING_GRACE=1 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w2:p9 HERDR_PANE_ID=w2:p9 "$2" claim 43 --owner "$3" >/dev/null' _ "$psr" "$ps" "$(mem 2)"
# Eight members race for one stale claim: exactly one takes it (claims/.lock).
members 1 2 3 4 5 6 7 8
as_m 1 claim 44 --owner "$(mem 1)" >/dev/null
f44="$(git -C "$psr" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/claims/pr-44/owner.json"
jq '.heartbeat = 0' "$f44" > "$f44.new" && mv "$f44.new" "$f44"
for i in 2 3 4 5 6 7 8 1; do
    ( as_m "$i" claim 44 --owner "$(mem "$i")" >/dev/null 2>&1; echo $? > "$work/stale-race.$i" ) &
done
wait
check "pool-state: 8 racing takeovers of a stale claim, exactly one wins" \
    [ "$(grep -lx 0 "$work"/stale-race.* | wc -l | tr -d ' ')" == 1 ]

printf '[{"number": 7, "title": "seven", "headRefName": "feat/s", "headRefOid": "aaa", "isDraft": false, "createdAt": "2026-01-02"},
 {"number": 6, "title": "six", "headRefName": "feat/x", "headRefOid": "bbb", "isDraft": false, "createdAt": "2026-01-01"},
 {"number": 8, "title": "draft", "headRefName": "feat/d", "headRefOid": "ccc", "isDraft": true, "createdAt": "2026-01-01"},
 {"number": 9, "title": "nine", "headRefName": "feat/n", "headRefOid": "ddd", "isDraft": false, "createdAt": "2026-01-03"}]\n' \
    > "$FAKE_GH/list.json"
members 1 2
as_m 2 claim 9 --owner "$(mem 2)" >/dev/null
as_m 1 bounce 7 --head aaa --owner "$(mem 1)" >/dev/null
check "pool-state: queue is oldest first, skips drafts, live claims and bounced heads" \
    [ "$(psq queue --base main --owner "$(mem 1)" | cut -f1,4 | tr '\t\n' ':,')" == "6:free," ]
check "pool-state: the claimer sees its own PR as mine" \
    [ "$(psq queue --base main --owner "$(mem 2)" | cut -f1,4 | tr '\t\n' ':,')" == "6:free,9:mine," ]
sed -i.bak 's/"aaa"/"aab"/' "$FAKE_GH/list.json" && rm -f "$FAKE_GH/list.json.bak"
check "pool-state: a new head after a bounce is back in the queue" \
    [ "$(psq queue --base main --owner "$(mem 1)" | cut -f1 | tr '\n' ,)" == "6,7," ]
as_m 2 release 9 --owner "$(mem 2)" >/dev/null; echo '[]' > "$FAKE_GH/list.json"

lockf="$work/lock-order"; : > "$lockf"
for i in 1 2; do
    as_m "$i" lock run --owner "$(mem "$i")" -- sh -c "echo start >> '$lockf'; sleep 1; echo end >> '$lockf'" >/dev/null &
done
held_status=0   # poll: each lock run first checks its caller's identity, slower on a busy runner
for _ in $(seq 1 50); do psq lock status >/dev/null; held_status=$?; [[ $held_status == 1 ]] && break; sleep 0.1; done
wait
check "pool-state: lock status while held" [ "$held_status" == 1 ]
check "pool-state: the merge lock serialises its holders" [ "$(tr '\n' ' ' < "$lockf")" == "start end start end " ]
check "pool-state: lock status when free" psq lock status
as_m 1 lock run --owner "$(mem 1)" --expect-base 0000000000000000000000000000000000000000 --base main -- true >/dev/null 2>&1; status=$?
check "pool-state: --expect-base exits 75 when the base moved" [ "$status" == 75 ]
as_m 1 lock run --owner "$(mem 1)" --expect-base "$(git -C "$psr" rev-parse origin/main)" --base main -- sh -c 'exit 5' >/dev/null 2>&1; status=$?
check "pool-state: --expect-base runs the command when the base is unchanged" [ "$status" == 5 ]
pidf="$work/lock-child.pid"
as_m 1 lock run --owner "$(mem 1)" --max-seconds 1 -- sh -c "sleep 30 & echo \$! > '$pidf'; wait" >/dev/null 2>&1; status=$?
check "pool-state: a command over --max-seconds is killed with its children (exit 125)" \
    bash -c '[[ $1 == 125 ]] && ! kill -0 "$(cat "$2")" 2>/dev/null' _ "$status" "$pidf"
as_m 1 report add 3 --sha abc --owner "$(mem 1)" --tasks "- task three" >/dev/null
check "pool-state: report list"      [ "$(psq report list | cut -f1,3,4 | tr '\t' ' ')" == "3 $(mem 1) - task three" ]
check "pool-state: the coordinator marks a report done" as_c report "done" 3
check "pool-state: report known after done" psq report known 3
check "pool-state: report unknown"   not psq report known 4

# union-rows.py -------------------------------------------------------------------------------
ur="$scripts/union-rows.py"
printf '| ADR | T |\n|---|---|\n| [0001](a) | A |\n<<<<<<< HEAD\n| [0003](c) | C |\n=======\n| [0002](b) | B |\n>>>>>>> feat\n' > "$work/idx.md"
check "union-rows: both rows, sorted" bash -c '"$1" "$2" && [[ "$(tail -2 "$2" | cut -c4-7 | tr "\n" ,)" == "0002,0003," ]] && ! grep -q "<<<" "$2"' _ "$ur" "$work/idx.md"
printf '<<<<<<< HEAD\n| [0002](c) | C |\n=======\n| [0002](b) | B |\n>>>>>>> feat\n' > "$work/clash.md"
check "union-rows: refuses two rows with one key" bash -c '! "$1" "$2" 2>/dev/null && grep -q "<<<" "$2"' _ "$ur" "$work/clash.md"
check "union-rows: keeps them with --allow-key (a number renumber.py changes next)" \
    bash -c '"$1" --allow-key 0002 "$2" && [[ $(grep -c "^| \[0002\]" "$2") == 2 ]]' _ "$ur" "$work/clash.md"
printf '<<<<<<< HEAD\nsome prose\n=======\n| [0002](b) | B |\n>>>>>>> feat\n' > "$work/prose.md"
check "union-rows: refuses prose" bash -c '! "$1" "$2" 2>/dev/null' _ "$ur" "$work/prose.md"

# integrate-pr.sh end to end (pool member integrator-proj-1 in $wt1) ----------------------------
me=integrator-proj-1
agents "$me" w2:p1 idle "$wt1"
make_pr() {  # make_pr <N> <branch> <file> <content>: push a branch from $dev and describe it
    local n="$1" b="$2"
    git -C "$dev" fetch --quiet origin && git -C "$dev" checkout --quiet -B "$b" origin/main
    mkdir -p "$(dirname "$dev/$3")" && printf '%s\n' "$4" >> "$dev/$3"
    git -C "$dev" add -A && git -C "$dev" commit --quiet -m "change for #$n" && git -C "$dev" push --quiet origin "$b"
    pr_json "$n" "$b"
}
pr_json() {  # pr_json <N> <branch>: the fake GitHub view of PR N at origin/<branch>'s head
    jq -n --argjson n "$1" --arg b "$2" --arg h "$(git -C "$origin" rev-parse "refs/heads/$2")" \
        '{number: $n, title: "PR \($n)", headRefName: $b, headRefOid: $h, baseRefName: "main",
          state: "OPEN", isCrossRepository: false, author: {login: "tester"},
          body: "## Summary\nx\n\n## Plan tasks completed\n- task \($n)\n\n## Docs\nnone\n"}' > "$FAKE_GH/pr-$1.json"
}
push_main() {  # push_main <file> <content>: someone else's commit lands on origin/main
    git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main
    mkdir -p "$(dirname "$pusher/$1")" && printf '%s\n' "$2" >> "$pusher/$1"
    git -C "$pusher" add -A && git -C "$pusher" commit --quiet -m "main: $1" && git -C "$pusher" push --quiet origin main
}
on_main() { git -C "$origin" cat-file -e "main:$1" 2>/dev/null; }
remote_branch() { git -C "$origin" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
integrate() {  # integrate <N> [args...]: claim as $me and run integrate-pr.sh; sets out, rc
    local n="$1"; shift
    (cd "$proj" && HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ps" claim "$n" --owner "$me" >/dev/null)
    export CHECK_COUNT="$work/count-$n"; : > "$CHECK_COUNT"
    out=$(cd "$wt1" && env CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME="$me" HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 \
        "$ipr" "$n" "$@" 2>&1); rc=$?
    unset CHECK_COUNT CHECK_HOOK
}
runs() { wc -l < "$work/count-$1" | tr -d ' '; }
clean_wt() { [[ -z "$(git -C "$wt1" status --porcelain)" ]] && ! git -C "$wt1" rev-parse -q --verify MERGE_HEAD >/dev/null; }

make_pr 1 feat/one src/one.txt one
integrate 1
check "integrate-pr: merges a green PR (exit 0)" bash -c '[[ $1 == 0 && "$2" == *"RESULT merged"*"deleted"* ]]' _ "$rc" "$out"
check "integrate-pr: the PR's file is on origin/main" on_main src/one.txt
check "integrate-pr: the head branch is deleted"      not remote_branch feat/one

check "integrate-pr: the claim is released"           [ -z "$(cd "$proj" && "$ps" claims | awk -F'\t' '$1 == 1')" ]
check "integrate-pr: a plan report waits for the coordinator" \
    [ "$(cd "$proj" && "$ps" report list | cut -f1,4 | tr '\t' ' ')" == "1 - task 1" ]
check "integrate-pr: one verification" [ "$(runs 1)" == 1 ]
# Pool mode ticks nothing in the merge: the coordinator ticks from the report.
push_main docs/phases/plan.md '- [ ] T5.1 a pool task'
make_pr 41 feat/pool-plan src/pool-plan.txt x
jq '.body = "## Plan tasks completed\n- T5.1\n"' "$FAKE_GH/pr-41.json" > "$FAKE_GH/pr-41.new" && mv "$FAKE_GH/pr-41.new" "$FAKE_GH/pr-41.json"
integrate 41
check "integrate-pr: pool mode merges without ticking the plan" \
    bash -c '[[ $1 == 0 && "$2" != *PLAN-TICKED* ]] && git -C "$3" show main:docs/phases/plan.md | grep -qxF -- "- [ ] T5.1 a pool task"' _ "$rc" "$out" "$origin"
check "integrate-pr: pool mode reports the task to the coordinator" \
    bash -c '[[ "$(cd "$1" && "$2" report list)" == *T5.1* ]]' _ "$proj" "$ps"

# Someone else's PR (another GitHub account opened it): only with the user's yes, per PR.
make_pr 90 feat/foreign src/foreign.txt foreign
jq '.author.login = "contributor"' "$FAKE_GH/pr-90.json" > "$FAKE_GH/pr-90.tmp" && mv "$FAKE_GH/pr-90.tmp" "$FAKE_GH/pr-90.json"
integrate 90
check "integrate-pr: refuses another account's PR (exit 2)" bash -c '[[ $1 == 2 && "$2" == *"opened by contributor"*"--author-ok contributor"* ]]' _ "$rc" "$out"
check "integrate-pr: nothing of it is on origin/main"       not on_main src/foreign.txt
integrate 90 --author-ok someone-else
check "integrate-pr: a yes for another author does not count" [ "$rc" = 2 ]
integrate 90 --author-ok contributor
check "integrate-pr: merges it with --author-ok <author>"   bash -c '[[ $1 == 0 && "$2" == *"RESULT merged"* ]]' _ "$rc" "$out"

make_pr 2 feat/fail fail.txt boom
integrate 2
check "integrate-pr: a failed verification bounces (exit 4)" bash -c '[[ $1 == 4 && "$2" == *"fail.txt is present"* && "$2" == *"RESULT verify-failed"* ]]' _ "$rc" "$out"
check "integrate-pr: the worktree is clean after a bounce" clean_wt
check "integrate-pr: nothing landed"                       not on_main fail.txt
check "integrate-pr: the bounce is recorded"              [ "$(jq -r .head "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/bounced/pr-2.json")" == "$(git -C "$origin" rev-parse refs/heads/feat/fail)" ]

make_pr 3 feat/conflict src/a.txt "from the PR"
push_main src/a.txt "from main"
integrate 3
check "integrate-pr: a conflict bounces (exit 3)" bash -c '[[ $1 == 3 && "$2" == *"RESULT conflict"*"src/a.txt"* ]]' _ "$rc" "$out"
check "integrate-pr: the worktree is clean after a conflict" clean_wt

make_pr 4 feat/adr docs/decisions/README.md "| [0002](0002-b.md) | Second |"
push_main docs/decisions/README.md "| [0003](0003-c.md) | Third |"
integrate 4 --union-rows docs/decisions/README.md
check "integrate-pr: index rows are resolved mechanically" \
    bash -c '[[ $1 == 0 ]] && [[ "$(git -C "$2" show main:docs/decisions/README.md | grep -c "^| \[000")" == 3 ]]' _ "$rc" "$origin"

# merge=union (template/.gitattributes): two PRs appending at the same spot of an append-only
# file merge without a conflict.
push_main .gitattributes "CHANGELOG.md merge=union"
make_pr 41 feat/log-a CHANGELOG.md "- added a"
make_pr 42 feat/log-b CHANGELOG.md "- added b"
integrate 41
integrate 42
check "integrate-pr: merge=union keeps both appended lines" \
    bash -c '[[ $1 == 0 ]] && git -C "$2" show main:CHANGELOG.md | grep -q "added a" && git -C "$2" show main:CHANGELOG.md | grep -q "added b"' _ "$rc" "$origin"

make_pr 5 feat/moved src/five.txt five
cat > "$work/hook-moved.sh" <<HOOK
#!/usr/bin/env bash
git -C "$dev" checkout --quiet feat/moved && echo more >> "$dev/src/five.txt"
git -C "$dev" commit --quiet -am "more" && git -C "$dev" push --quiet origin feat/moved
jq --arg h "\$(git -C "$origin" rev-parse refs/heads/feat/moved)" '.headRefOid = \$h' "$FAKE_GH/pr-5.json" > "$FAKE_GH/pr-5.new"
mv "$FAKE_GH/pr-5.new" "$FAKE_GH/pr-5.json"
HOOK
chmod +x "$work/hook-moved.sh"; export CHECK_HOOK="$work/hook-moved.sh"
integrate 5
check "integrate-pr: a branch that moved during the verification is kept" \
    bash -c '[[ $1 == 0 && "$2" == *"KEPT"* && "$2" == *"branch feat/moved kept"* ]]' _ "$rc" "$out"
check "integrate-pr: the kept branch still exists" remote_branch feat/moved

make_pr 6 feat/six src/six.txt six
printf '#!/usr/bin/env bash\n"%s" docs/phases/plan.md "- [x] ticked"\n' "$work/push-main.sh" > "$work/hook-plan.sh"
cat > "$work/push-main.sh" <<HOOK
#!/usr/bin/env bash
git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main
printf '%s\n' "\$2" >> "$pusher/\$1"
git -C "$pusher" add -A && git -C "$pusher" commit --quiet -m "main: \$1" && git -C "$pusher" push --quiet origin main
HOOK
chmod +x "$work/hook-plan.sh" "$work/push-main.sh"; export CHECK_HOOK="$work/hook-plan.sh"
integrate 6
check "integrate-pr: base moved by exempt paths only: re-merged, not re-verified" \
    bash -c '[[ $1 == 0 && "$2" == *"only exempt paths changed"* && $3 == 1 ]]' _ "$rc" "$out" "$(runs 6)"
check "integrate-pr: both the plan commit and the PR are on main" \
    bash -c 'git -C "$1" show main:docs/phases/plan.md | grep -q ticked && git -C "$1" cat-file -e main:src/six.txt' _ "$origin"

make_pr 7 feat/seven src/seven.txt seven
printf '#!/usr/bin/env bash\n"%s" src/other.txt other\n' "$work/push-main.sh" > "$work/hook-code.sh"
chmod +x "$work/hook-code.sh"; export CHECK_HOOK="$work/hook-code.sh"
integrate 7
check "integrate-pr: base moved by code: verified again, then merged" \
    bash -c '[[ $1 == 0 && "$2" == *"re-verifying"* && $3 == 2 ]]' _ "$rc" "$out" "$(runs 7)"
check "integrate-pr: main has both changes" bash -c 'on() { git -C "$1" cat-file -e "main:$2"; }; on "$1" src/other.txt && on "$1" src/seven.txt' _ "$origin"

# One run per worktree: a second integrate-pr.sh started mid-check is refused (exit 2) and the
# first one still lands; a lock left held by a dead run's leftover is taken over.
make_pr 8 feat/eight src/eight.txt eight
make_pr 9 feat/nine src/nine.txt nine
printf '#!/usr/bin/env bash\n(cd "%s" && "%s" claim 9 --owner "%s" >/dev/null)\n"%s" 9 > "%s/second.out" 2>&1; echo $? > "%s/second.rc"\n' \
    "$proj" "$ps" "$me" "$ipr" "$work" "$work" > "$work/hook-second.sh"
chmod +x "$work/hook-second.sh"; export CHECK_HOOK="$work/hook-second.sh"
integrate 8
check "integrate-pr: a second run in the same worktree is refused (exit 2)" \
    bash -c '[[ $(cat "$1/second.rc") == 2 ]] && grep -q "another integrate-pr.sh is running" "$1/second.out"' _ "$work"
check "integrate-pr: the first run still merges" bash -c '[[ $1 == 0 ]]' _ "$rc"
check "integrate-pr: the first run's PR is on main" on_main src/eight.txt
wt_lock="$(git -C "$wt1" rev-parse --absolute-git-dir)/herdr-agent-pool-integrate.lock"
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); f.seek(0); f.truncate(); f.write("999999 PR #0\n"); f.flush(); time.sleep(60)' "$wt_lock" &
leftover=$!; for _ in $(seq 1 100); do grep -q 999999 "$wt_lock" 2>/dev/null && break; sleep 0.1; done
integrate 9
kill "$leftover" 2>/dev/null; wait "$leftover" 2>/dev/null
check "integrate-pr: a lock held by a dead run's leftover is taken over" \
    bash -c '[[ $1 == 0 && "$2" == *"taking over"* ]]' _ "$rc" "$out"

# Number reservations (pool-state.py reserve, project setting numbered_files) --------------------
cfg_json="$proj/.claude/herdr-agent-pool.json"; cfg_saved=$(cat "$cfg_json")
cat > "$cfg_json" <<'JSON'
{"integrators": {"max": 2, "scale_up_when_active_agents_gt": 2}, "numbered_files": {"adr": "docs/decisions/(\\d{4})-.*\\.md"}}
JSON
"$work/push-main.sh" docs/decisions/0007-seven.md seven
git -C "$dev" fetch --quiet origin && git -C "$dev" checkout --quiet -B feat/adr9 origin/main
echo nine > "$dev/docs/decisions/0009-nine.md" && git -C "$dev" add -A && git -C "$dev" commit --quiet -m adr9 \
    && git -C "$dev" push --quiet origin feat/adr9
echo '[{"number": 40, "headRefName": "feat/adr9", "isCrossRepository": false},
       {"number": 41, "headRefName": "feat/deleted", "isCrossRepository": false}]' > "$FAKE_GH/list.json"
rsv() { (cd "$proj" && "$ps" reserve adr --owner "$1" 2>"$work/rsv.err"); }
reserved() { (cd "$proj" && "$ps" reservations | cut -f2,3 | tr '\t\n' '  '); }
check "reserve: above main (0007) and the open PRs (0009; a deleted head is skipped)" [ "$(rsv feat/a)" == 0010 ]
check "reserve: above the numbers already reserved"        [ "$(rsv feat/b)" == 0011 ]
(cd "$proj" && "$ps" unreserve --owner feat/b >/dev/null)
check "unreserve: gives the branch's number back" [ "$(reserved)" == "10 feat/a " ]
"$work/push-main.sh" docs/decisions/0010-ten.md ten
check "reserve: a number that landed ends its reservation" \
    bash -c '[[ $1 == 0011 && "$3" == "11 feat/c " ]] && grep -q "adr 10 landed" "$2"' _ "$(rsv feat/c)" "$work/rsv.err" "$(reserved)"
check "reserve: an unknown kind is refused (exit 1)" exits 1 bash -c 'cd "$1" && "$2" reserve nope --owner x' _ "$proj" "$ps"
mv "$FAKE_GH/list.json" "$FAKE_GH/list.away"
check "reserve: fails closed when the open PRs cannot be listed (exit 1)" exits 1 bash -c 'cd "$1" && "$2" reserve adr --owner x' _ "$proj" "$ps"
mv "$FAKE_GH/list.away" "$FAKE_GH/list.json"
check "reserve: fails closed when the base cannot be fetched (exit 1)" \
    exits 1 bash -c 'cd "$1" && "$2" reserve adr --owner x --base nosuch' _ "$proj" "$ps"
echo '[]' > "$FAKE_GH/list.json"

# Re-verify scope: the project's scripts/reverify-needed.sh, read from the new base -------------
git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main && mkdir -p "$pusher/scripts"
cat > "$pusher/scripts/reverify-needed.sh" <<'SH'
#!/usr/bin/env bash
# Verify again unless every changed path is a docs/notes-* file.
while read -r p; do [[ -z "$p" || "$p" == docs/notes-* ]] || { echo "code changed: $p"; exit 0; }; done
echo no-reverify
SH
chmod +x "$pusher/scripts/reverify-needed.sh"
git -C "$pusher" add -A && git -C "$pusher" commit --quiet -m "reverify hook" && git -C "$pusher" push --quiet origin main
make_pr 21 feat/twentyone src/twentyone.txt x
(cd "$proj" && "$ps" reserve adr --owner feat/twentyone >/dev/null 2>&1)
printf '#!/usr/bin/env bash\n"%s" docs/notes-x.txt x\n' "$work/push-main.sh" > "$work/hook-other.sh"
chmod +x "$work/hook-other.sh"; export CHECK_HOOK="$work/hook-other.sh"
integrate 21
check "integrate-pr: reverify-needed.sh says the new base cannot matter: merged, not re-verified" \
    bash -c '[[ $1 == 0 && "$2" == *"reverify-needed.sh"*"no re-verify"* && $3 == 1 ]]' _ "$rc" "$out" "$(runs 21)"
check "integrate-pr: the merged branch's number reservations end" bash -c '[[ "$1" != *feat/twentyone* ]]' _ "$(reserved)"
make_pr 22 feat/twentytwo src/twentytwo.txt x
printf '#!/usr/bin/env bash\n"%s" src/y.txt y\n' "$work/push-main.sh" > "$work/hook-src.sh"
chmod +x "$work/hook-src.sh"; export CHECK_HOOK="$work/hook-src.sh"
integrate 22
check "integrate-pr: reverify-needed.sh asks for it: verified again" \
    bash -c '[[ $1 == 0 && "$2" == *"re-verifying"* && $3 == 2 ]]' _ "$rc" "$out" "$(runs 22)"

# The last re-verification holds the merge lock (max_reverify 1 here) ---------------------------
cat > "$cfg_json" <<'JSON'
{"integrators": {"max": 2, "scale_up_when_active_agents_gt": 2, "max_reverify": 1}}
JSON
make_pr 23 feat/twentythree src/twentythree.txt x
cat > "$work/hook-locked.sh" <<HOOK
#!/usr/bin/env bash
n=\$(( \$(cat "$work/locked.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$work/locked.n"
if [[ \$n == 1 ]]; then rm -f "\$0.done"; "$work/push-main.sh" src/locked.txt z
else (cd "$proj" && "$ps" lock status) > "$work/locked.status" 2>&1 || true; fi
HOOK
chmod +x "$work/hook-locked.sh"; export CHECK_HOOK="$work/hook-locked.sh"
integrate 23
check "integrate-pr: the last re-verify runs under the merge lock and merges" \
    bash -c '[[ $1 == 0 && "$2" == *"holding the merge lock"* && $3 == 2 ]]' _ "$rc" "$out" "$(runs 23)"
check "integrate-pr: the merge lock is held during that verification" grep -q "held by" "$work/locked.status"
check "integrate-pr: both changes are on main" bash -c 'git -C "$1" cat-file -e main:src/locked.txt && git -C "$1" cat-file -e main:src/twentythree.txt' _ "$origin"
printf '%s\n' "$cfg_saved" > "$cfg_json"

# The base is red (pool-state.py base-red, hold; integrate-pr.sh exit 14) -----------------------
as_me() { (cd "$proj" && HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ps" "$@"); }
as_coord() { (cd "$proj" && HERDR_ENV=1 FAKE_PANE=w1:p1 HERDR_PANE_ID=w1:p1 "$ps" "$@"); }
red_banner() { (cd "$proj" && "$ps" base-red show); }
agents "$me" w2:p1 idle "$wt1"  coordinator-proj w1:p1 idle "$proj"
check "base-red: nothing while the base is green" [ -z "$(red_banner)" ]
as_me base-red report --tests "tests/test_a.py::t1" --suspect 21 --owner "$me" >/dev/null
as_me base-red report --tests "tests/test_b.py::t2 tests/test_a.py::t1" --owner "$me" >/dev/null
check "base-red: the banner merges the tests, names the suspect, no owner yet" \
    bash -c '[[ "$1" == "BASE main IS RED since "*": tests/test_a.py::t1 tests/test_b.py::t2; suspect PR #21; fix assigned to nobody yet"* ]]' _ "$(red_banner)"
check "base-red: a pool member may not assign the fix (exit 4)" exits 4 as_me base-red assign "$me"
as_coord base-red assign dev-fix --branch feat/fixred >/dev/null
check "base-red: the coordinator assigns one owner" bash -c '[[ "$1" == *"fix assigned to dev-fix."* ]]' _ "$(red_banner)"
check "base-red: clear --if-branch of another branch clears nothing (exit 3)" \
    exits 3 as_me base-red clear --owner "$me" --reason x --if-branch feat/other
make_pr 24 feat/red24 fail.txt red
printf '#!/usr/bin/env bash\necho "${HERDR_AGENT_POOL_BASE_RED_TESTS:-}" > "%s/red-env"\n' "$work" > "$work/hook-red.sh"
chmod +x "$work/hook-red.sh"; export CHECK_HOOK="$work/hook-red.sh"
integrate 24
head24=$(git -C "$origin" rev-parse refs/heads/feat/red24)
check "integrate-pr: a failure while the base is red is exit 14, not a bounce" \
    bash -c '[[ $1 == 14 && "$2" == *"BASE main IS RED"* && "$2" == *"RESULT base-red"* && ! -e "$3/bounced/pr-24.json" ]]' \
    _ "$rc" "$out" "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool"
check "integrate-pr: the claim is kept after exit 14" bash -c '[[ "$1" == *"24	$2"* ]]' _ "$(cd "$proj" && "$ps" claims)" "$me"
check "verify-merge: check.sh gets the red tests" [ "$(cat "$work/red-env")" == "tests/test_a.py::t1 tests/test_b.py::t2" ]
jq -n --arg h "$head24" '[{number: 24, title: "PR 24", headRefName: "feat/red24", headRefOid: $h, isDraft: false, createdAt: "2026-01-01T00:00:00Z"}]' > "$FAKE_GH/list.json"
as_me hold 24 --head "$head24" --owner "$me" >/dev/null
check "hold: the claim is released and the queue skips the held PR" \
    bash -c '[[ -z "$1" && "$2" != *"24	"* ]]' _ "$(cd "$proj" && "$ps" claims)" "$(cd "$proj" && "$ps" queue --base main)"
make_pr 25 feat/fixred src/fixred.txt fix
integrate 25
check "integrate-pr: merging the assigned fix clears the red base" \
    bash -c '[[ $1 == 0 && "$2" == *"the base is green again"* && -z "$3" ]]' _ "$rc" "$out" "$(red_banner)"
check "base-red: the held PR is back in the queue" bash -c '[[ "$1" == "24	"* ]]' _ "$(cd "$proj" && "$ps" queue --base main)"
check "hold: refused while the base is green (exit 1)" exits 1 as_me hold 24 --head "$head24" --owner "$me"
echo '[]' > "$FAKE_GH/list.json"; agents "$me" w2:p1 idle "$wt1"

# Number at merge (renumber.py, project setting numbered_files) ---------------------------------
# The test check.sh wants the ADRs in docs/adr numbered 0001, 0002, ... and each one in the index.
cat > "$cfg_json" <<'JSON'
{"integrators": {"max": 2, "scale_up_when_active_agents_gt": 2}, "numbered_files": {"adr": "docs/adr/(\\d{4})-.*\\.md"}}
JSON
git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main && mkdir -p "$pusher/docs/adr"
printf '| ADR | Title |\n|---|---|\n' > "$pusher/docs/adr/README.md"
git -C "$pusher" add -A && git -C "$pusher" commit --quiet -m "adr index" && git -C "$pusher" push --quiet origin main
adr_pr() {  # adr_pr <N> <branch> <number> <slug>: an ADR, its index row and a guide linking it
    local n="$1" b="$2" name="$3-$4.md"
    git -C "$dev" fetch --quiet origin && git -C "$dev" checkout --quiet -B "$b" origin/main
    printf '# %s. %s\n\nSee also %s.\n' "$3" "$4" "$3-$4" > "$dev/docs/adr/$name"
    printf '| [%s](%s) | %s |\n' "$3" "$name" "$4" >> "$dev/docs/adr/README.md"
    printf 'Read [ADR %s](adr/%s).\n' "$3" "$name" > "$dev/docs/guide-$4.md"
    git -C "$dev" add -A && git -C "$dev" commit --quiet -m "ADR $3" && git -C "$dev" push --quiet origin "$b"
    pr_json "$n" "$b"
}
main_show() { git -C "$origin" show "main:$1"; }
adr_pr 30 feat/adr-first 0001 first
adr_pr 31 feat/adr-second 0001 second   # both took 0001 on the same base
integrate 30 --union-rows docs/adr/README.md
check "renumber: the first PR keeps 0001" \
    bash -c '[[ $1 == 0 && "$2" != *RENUMBERED* ]]' _ "$rc" "$out"
integrate 31 --union-rows docs/adr/README.md
check "renumber: the second PR's 0001 becomes 0002, verified (contiguous) and merged" \
    bash -c '[[ $1 == 0 && "$2" == *"RENUMBERED adr docs/adr/0001-second.md -> docs/adr/0002-second.md"* && "$2" == *"RESULT merged"* ]]' _ "$rc" "$out"
check "renumber: the file is renamed on main" on_main docs/adr/0002-second.md
check "renumber: the old name is gone"        not on_main docs/adr/0001-second.md
check "renumber: the index row is rewritten" \
    [ "$(main_show docs/adr/README.md | tail -2)" == "$(printf '| [0001](0001-first.md) | first |\n| [0002](0002-second.md) | second |')" ]
check "renumber: the link in a changed file is rewritten" \
    [ "$(main_show docs/guide-second.md)" == "Read [ADR 0002](adr/0002-second.md)." ]
check "renumber: the heading and the name inside the ADR are rewritten" \
    [ "$(main_show docs/adr/0002-second.md)" == "$(printf '# 0002. second\n\nSee also 0002-second.')" ]
check "renumber: the merge commit message lists the rename" \
    bash -c 'git -C "$1" log -1 --format=%B main | grep -qx "RENUMBERED adr docs/adr/0001-second.md -> docs/adr/0002-second.md"' _ "$origin"
adr_pr 32 feat/adr-third 0003 third
integrate 32 --union-rows docs/adr/README.md
check "renumber: a PR that took the next free number is untouched" \
    bash -c '[[ $1 == 0 && "$2" != *RENUMBERED* ]]' _ "$rc" "$out"
check "renumber: its file is on main as it was" on_main docs/adr/0003-third.md
adr_pr 33 feat/adr-fourth 0004 fourth
cat > "$work/hook-adr.sh" <<HOOK
#!/usr/bin/env bash
git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main
printf '# 0004. other\n' > "$pusher/docs/adr/0004-other.md"
printf '| [0004](0004-other.md) | other |\n' >> "$pusher/docs/adr/README.md"
git -C "$pusher" add -A && git -C "$pusher" commit --quiet -m "adr 0004" && git -C "$pusher" push --quiet origin main
HOOK
chmod +x "$work/hook-adr.sh"; export CHECK_HOOK="$work/hook-adr.sh"
integrate 33 --union-rows docs/adr/README.md
check "renumber: a re-merge onto a moved base renumbers again (0004 -> 0005) and re-verifies" \
    bash -c '[[ $1 == 0 && "$2" == *"RENUMBERED adr docs/adr/0004-fourth.md -> docs/adr/0005-fourth.md"* && $3 == 2 && "$4" == "$5" ]]' \
    _ "$rc" "$out" "$(runs 33)" "$(main_show docs/adr/README.md | tail -2)" \
    "$(printf '| [0004](0004-other.md) | other |\n| [0005](0005-fourth.md) | fourth |')"
check "renumber: both 0004 and 0005 are on main" bash -c '[[ -n "$1" && -n "$2" ]]' _ \
    "$(main_show docs/adr/0004-other.md)" "$(main_show docs/adr/0005-fourth.md)"
adr_pr 35 feat/adr-bad 0001 bad
echo boom > "$dev/fail.txt" && git -C "$dev" add -A && git -C "$dev" commit --quiet -m boom \
    && git -C "$dev" push --quiet origin feat/adr-bad && pr_json 35 feat/adr-bad
integrate 35 --union-rows docs/adr/README.md
check "renumber: a renumbered PR whose check fails bounces (exit 4)" \
    bash -c '[[ $1 == 4 && "$2" == *"RENUMBERED adr docs/adr/0001-bad.md -> docs/adr/0006-bad.md"* ]]' _ "$rc" "$out"
check "renumber: the worktree is clean after it (renamed files included)" clean_wt
adr_pr 36 feat/adr-kindref 0001 kindref   # main has 0001-0005: becomes 0006
mkdir -p "$dev/src" && printf 'See ADR 0001.\nADR_0001_CASES = 1\nadrs-0001 too\nRow 0001 stays.\nMADR 0001 stays.\n' > "$dev/src/kindref.txt"
printf -- '- kindref (ADR 0001)\n' > "$dev/CHANGES.md"
git -C "$dev" add -A && git -C "$dev" commit --quiet -m "kindref refs" \
    && git -C "$dev" push --quiet origin feat/adr-kindref && pr_json 36 feat/adr-kindref
integrate 36 --union-rows docs/adr/README.md
check "renumber: a PR whose lines name the ADR by its kind merges as 0006" \
    bash -c '[[ $1 == 0 && "$2" == *"RENUMBERED adr docs/adr/0001-kindref.md -> docs/adr/0006-kindref.md"* ]]' _ "$rc" "$out"
check "renumber: ADR 0001, ADR_0001 and adrs-0001 in its lines become 0006; other 0001s stay" \
    [ "$(main_show src/kindref.txt)" == "$(printf 'See ADR 0006.\nADR_0006_CASES = 1\nadrs-0006 too\nRow 0001 stays.\nMADR 0001 stays.')" ]
check "renumber: the kind reference in another changed file is rewritten" \
    [ "$(main_show CHANGES.md)" == "- kindref (ADR 0006)" ]
printf '%s\n' "$cfg_saved" > "$cfg_json"
adr_pr 34 feat/adr-dup 0001 dup
integrate 34
check "renumber: without numbered_files nothing is renumbered (the check catches the duplicate)" \
    bash -c '[[ $1 == 4 && "$2" != *RENUMBERED* && "$2" == *"not contiguous"* ]]' _ "$rc" "$out"
check "renumber: the worktree is clean after that bounce" clean_wt

make_pr 10 feat/ten src/ten.txt ten
out=$(cd "$wt1" && env CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME="$me" HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses a PR it did not claim (exit 2)" bash -c '[[ $1 == 2 && "$2" == *"not claimed"* ]]' _ "$rc" "$out"
out=$(cd "$proj" && env CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME="$me" HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses the main worktree in pool mode (exit 2)" [ "$rc" == 2 ]
out=$(cd "$wt1" && env CLAUDE_ROLE=coordinator "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses the coordinator (exit 1)" [ "$rc" == 1 ]
(cd "$proj" && HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ps" claim 10 --owner "$me" >/dev/null)
out=$(cd "$wt1" && env CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME="$me" HERDR_ENV=1 FAKE_PANE=w9:p9 HERDR_PANE_ID=w9:p9 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses a pane whose herdr agent is not \$me (exit 2)" \
    bash -c '[[ $1 == 2 && "$2" == *"herdr agent is"* ]]' _ "$rc" "$out"
agents "$me" w2:p1 idle "$wt1"  foo w8:p1 idle "$wt1"
out=$(cd "$wt1" && env CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NAME=foo HERDR_ENV=1 FAKE_PANE=w8:p1 HERDR_PANE_ID=w8:p1 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses an agent outside the pool, even named in the env (exit 2)" \
    bash -c '[[ $1 == 2 && "$2" == *"not a member of the integrator pool"* ]]' _ "$rc" "$out"
agents "$me" w2:p1 idle "$wt1"
# The claim changes hands while the PR is verified: nothing is pushed.
cat > "$work/hook-steal.sh" <<HOOK
#!/usr/bin/env bash
f="\$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/claims/pr-10/owner.json"
jq '.owner = "integrator-proj-2"' "\$f" > "\$f.new" && mv "\$f.new" "\$f"
HOOK
chmod +x "$work/hook-steal.sh"; export CHECK_HOOK="$work/hook-steal.sh"
before=$(git -C "$origin" rev-parse main)
integrate 10
check "integrate-pr: a claim lost during the verification stops the push (exit 10)" \
    bash -c '[[ $1 == 10 && "$2" == *"claim-lost"* && "$(git -C "$3" rev-parse main)" == "$4" ]]' _ "$rc" "$out" "$origin" "$before"
check "integrate-pr: a lost claim stays with its new owner" \
    [ "$(cd "$proj" && "$ps" claims | awk -F'\t' '$1 == 10 { print $2 }')" == integrator-proj-2 ]
rm -rf "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/claims/pr-10"   # the test's own takeover
# herdr stops confirming the pane's agent while the PR is verified: nothing is pushed (exit 11).
cat > "$work/hook-identity.sh" <<HOOK
#!/usr/bin/env bash
jq '.result.agents |= map(if .pane_id == "w2:p1" then .name = "intruder" else . end)' "$FAKE_AGENTS" > "$FAKE_AGENTS.new"
mv "$FAKE_AGENTS.new" "$FAKE_AGENTS"
HOOK
chmod +x "$work/hook-identity.sh"; export CHECK_HOOK="$work/hook-identity.sh"
rm -rf "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/claims/pr-10"
before=$(git -C "$origin" rev-parse main)
integrate 10
check "integrate-pr: identity lost under the lock stops the push (exit 11)" \
    bash -c '[[ $1 == 11 && "$2" == *"identity-refused"* && "$(git -C "$3" rev-parse main)" == "$4" ]]' _ "$rc" "$out" "$origin" "$before"
agents "$me" w2:p1 idle "$wt1"
rm -rf "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool/claims/pr-10"
# Code renamed into an exempt path on main: --no-renames sees the source change, so re-verify.
make_pr 11 feat/eleven src/eleven.txt eleven
cat > "$work/hook-rename.sh" <<HOOK
#!/usr/bin/env bash
git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main
git -C "$pusher" mv src/one.txt docs/phases/one.md && git -C "$pusher" commit --quiet -m "move one"
git -C "$pusher" push --quiet origin main
HOOK
chmod +x "$work/hook-rename.sh"; export CHECK_HOOK="$work/hook-rename.sh"
integrate 11
check "integrate-pr: code moved into an exempt path still re-verifies" \
    bash -c '[[ $1 == 0 && "$2" == *"re-verifying"* && $3 == 2 ]]' _ "$rc" "$out" "$(runs 11)"

# Single mode: the integrator in the main worktree.
sorigin="$work/single-origin.git"; git init --quiet --bare -b main "$sorigin"
git -C "$single" remote add origin "$sorigin" && git -C "$single" push --quiet -u origin main
sdev="$work/single-dev"; git clone --quiet "$sorigin" "$sdev"
git -C "$sdev" checkout --quiet -b feat/s && echo s > "$sdev/s.txt" && git -C "$sdev" add -A \
    && git -C "$sdev" commit --quiet -m s && git -C "$sdev" push --quiet origin feat/s
jq -n --arg h "$(git -C "$sorigin" rev-parse refs/heads/feat/s)" '{number: 1, title: "s", body: "", headRefName: "feat/s",
    headRefOid: $h, baseRefName: "main", state: "OPEN", isCrossRepository: false, author: {login: "tester"}}' > "$FAKE_GH/pr-1.json"
out=$(cd "$single" && env CLAUDE_ROLE=integrator "$ipr" 1 2>&1); rc=$?
check "integrate-pr: single mode merges in the main worktree" \
    bash -c '[[ $1 == 0 ]] && git -C "$2" cat-file -e main:s.txt && [[ "$(git -C "$3" rev-parse main)" == "$(git -C "$2" rev-parse main)" ]]' _ "$rc" "$sorigin" "$single"

# Single mode ticks the PR's plan tasks inside the merge (plan-tick.py), before the check.
sdev_main() {  # sdev_main <message>: commit what is staged in $sdev onto origin/main
    git -C "$sdev" commit --quiet -m "$1" && git -C "$sdev" push --quiet origin HEAD:main
}
git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B main origin/main
mkdir -p "$sdev/docs/phases" "$sdev/scripts"
printf '# Phase 1\n- [ ] **T1.1 `one`**: first\n- [ ] **T1.10 `ten`**: needs T1.1\n- [ ] T1.2 two\n- [ ] T1.3 three\n' > "$sdev/docs/phases/1-core.md"
cat > "$sdev/scripts/check.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ -z "${CHECK_SEEN:-}" ]] || cat docs/phases/*.md > "$CHECK_SEEN"
[[ -z "${CHECK_COUNT:-}" ]] || echo run >> "$CHECK_COUNT"
if [[ -n "${CHECK_HOOK:-}" && ! -e "$CHECK_HOOK.done" ]]; then touch "$CHECK_HOOK.done"; "$CHECK_HOOK"; fi
echo "checks ok"
SH
chmod +x "$sdev/scripts/check.sh"; git -C "$sdev" add -A && sdev_main "plan and check"
spr() {  # spr <N> <branch> <plan section>: a PR from $sdev whose body lists plan tasks
    git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B "$2" origin/main
    echo "$1" > "$sdev/s$1.txt" && git -C "$sdev" add -A && git -C "$sdev" commit --quiet -m "s$1" && git -C "$sdev" push --quiet origin "$2"
    jq -n --argjson n "$1" --arg b "$2" --arg h "$(git -C "$sorigin" rev-parse "refs/heads/$2")" --arg t "$3" \
        '{number: $n, title: "s\($n)", headRefName: $b, headRefOid: $h, baseRefName: "main", state: "OPEN",
          isCrossRepository: false, author: {login: "tester"},
          body: "## Summary\nT1.3\n\n## Plan tasks completed\n\($t)\n\n## Docs\nT1.2\n"}' > "$FAKE_GH/pr-$1.json"
}
sint() {  # sint <N>: integrate-pr.sh in the single main worktree; sets out, rc
    export CHECK_SEEN="$work/seen-$1" CHECK_COUNT="$work/count-$1"; : > "$CHECK_COUNT"
    out=$(cd "$single" && env CLAUDE_ROLE=integrator "$ipr" "$1" 2>&1); rc=$?
    unset CHECK_SEEN CHECK_COUNT CHECK_HOOK
}
splan() { git -C "$sorigin" show main:docs/phases/1-core.md; }
spr 61 feat/s61 '- `docs/phases/1-core.md`: T1.1 and T9.9'
sint 61
check "plan ticks: the listed task is ticked in the merge (PLAN-TICKED)" \
    bash -c '[[ $1 == 0 && "$2" == *"PLAN-TICKED T1.1 docs/phases/1-core.md"* ]] && grep -qF -- "- [x] **T1.1" <<<"$3"' _ "$rc" "$out" "$(splan)"
check "plan ticks: T1.10 and the ids outside the section stay open" \
    bash -c 'grep -qF -- "- [ ] **T1.10" <<<"$1" && grep -qxF -- "- [ ] T1.2 two" <<<"$1" && grep -qxF -- "- [ ] T1.3 three" <<<"$1"' _ "$(splan)"
check "plan ticks: an id it cannot find is reported (PLAN-UNTICKED)" \
    bash -c '[[ "$1" == *"PLAN-UNTICKED T9.9 (no such task in docs/phases)"* ]]' _ "$out"
check "plan ticks: the verification ran on the ticked tree" grep -qF -- "- [x] **T1.1" "$work/seen-61"
check "plan ticks: one merge commit carries the tick and says so" \
    bash -c '[[ "$(git -C "$1" log -1 --format=%P main | wc -w | tr -d " ")" == 2 ]] && git -C "$1" log -1 --format=%B main | grep -qx "PLAN-TICKED T1.1 docs/phases/1-core.md" \
             && [[ -n "$(git -C "$1" diff main^1 main -- docs/phases/1-core.md)" ]]' _ "$sorigin"
check "plan ticks: the main worktree is clean afterwards" [ -z "$(git -C "$single" status --porcelain)" ]
spr 62 feat/s62 '- T1.1'
sint 62
check "plan ticks: an already ticked task is reported, not ticked twice" \
    bash -c '[[ $1 == 0 && "$2" == *"PLAN-UNTICKED T1.1 (already ticked)"* && "$2" != *PLAN-TICKED* ]]' _ "$rc" "$out"
# The base moves during the verification (a plan edit, an exempt path): re-merged, ticked again.
spr 63 feat/s63 '- T1.2'
cat > "$work/hook-splan.sh" <<HOOK
#!/usr/bin/env bash
git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B main origin/main
echo '- [ ] T1.4 four' >> "$sdev/docs/phases/1-core.md"
git -C "$sdev" add -A && git -C "$sdev" commit --quiet -m "plan: T1.4" && git -C "$sdev" push --quiet origin HEAD:main
HOOK
chmod +x "$work/hook-splan.sh"; export CHECK_HOOK="$work/hook-splan.sh"
sint 63
check "plan ticks: a re-merge onto a moved base ticks again" \
    bash -c '[[ $1 == 0 && "$2" == *"moved during the verification"* ]] && grep -qxF -- "- [x] T1.2 two" <<<"$3" && grep -qxF -- "- [ ] T1.4 four" <<<"$3" \
             && git -C "$4" log -1 --format=%B main | grep -qx "PLAN-TICKED T1.2 docs/phases/1-core.md"' _ "$rc" "$out" "$(splan)" "$sorigin"
git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B main origin/main
echo '{"plan_ticks_in_merge": false}' > "$sdev/.claude/herdr-agent-pool.json"; git -C "$sdev" add -A && sdev_main "plan ticks off"
git -C "$single" fetch --quiet origin && git -C "$single" merge --quiet --ff-only origin/main   # the settings are read from the worktree
spr 64 feat/s64 '- T1.3'
sint 64
check "plan ticks: plan_ticks_in_merge false leaves the plan alone" \
    bash -c '[[ $1 == 0 && "$2" != *PLAN-* ]] && grep -qxF -- "- [ ] T1.3 three" <<<"$3"' _ "$rc" "$out" "$(splan)"
git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B main origin/main
git -C "$sdev" rm --quiet .claude/herdr-agent-pool.json && sdev_main "plan ticks on"
git -C "$single" fetch --quiet origin && git -C "$single" merge --quiet --ff-only origin/main

# plan-tick.py alone: whole tokens, leading ids, ambiguity.
ptick="$scripts/plan-tick.py"; ptd="$work/plan-tick"; mkdir -p "$ptd/docs/phases"
printf '%s\n' '- [ ] **T1.10 `ten`**: needs T1.1 and T1.1.2' '- [ ] T1.1.2 sub' '  - [ ] note: see T3.1' \
    '- [ ] T2.1 a' '- [ ] T2.1 b' '- [x] T4.1 done' > "$ptd/docs/phases/p.md"
ptout=$(cd "$ptd" && printf '## Plan tasks completed\nT1.1, `T1.1.2`, T2.1, T3.1, T4.1\n## Docs\nT1.10\n' | "$ptick"); ptrc=$?
check "plan-tick: T1.1 is not ticked in a line that leads with T1.10 (only mentions it there)" \
    bash -c '[[ "$1" == *"PLAN-UNTICKED T1.1 "* ]] && grep -qF -- "- [ ] **T1.10" "$2"' _ "$ptout" "$ptd/docs/phases/p.md"
check "plan-tick: T1.1.2 ticks its own line, not the one that mentions it" \
    bash -c '[[ $1 == 0 && "$2" == *"PLAN-TICKED T1.1.2 "* ]] && grep -qxF -- "- [x] T1.1.2 sub" "$3"' _ "$ptrc" "$ptout" "$ptd/docs/phases/p.md"
check "plan-tick: an id mentioned by one open task only ticks it (indented too)" \
    grep -qxF -- "  - [x] note: see T3.1" "$ptd/docs/phases/p.md"
check "plan-tick: two open tasks with one id are ambiguous: neither is ticked" \
    bash -c '[[ "$1" == *"PLAN-UNTICKED T2.1 (ambiguous"* ]] && [[ $(grep -c -- "- \[ \] T2.1" "$2") == 2 ]]' _ "$ptout" "$ptd/docs/phases/p.md"
check "plan-tick: ids outside the section are ignored" bash -c '[[ "$1" != *T1.10* ]]' _ "$ptout"
check "plan-tick: a ticked task is reported as such" bash -c '[[ "$1" == *"PLAN-UNTICKED T4.1 (already ticked)"* ]]' _ "$ptout"
check "plan-tick: no section, no output and nothing changed" \
    bash -c 'before=$(cat "$2"); out=$(cd "$1" && printf "## Summary\nT2.1\n" | "$3"); [[ $? == 0 && -z "$out" && "$(cat "$2")" == "$before" ]]' _ "$ptd" "$ptd/docs/phases/p.md" "$ptick"

# resource-budget.py (the hard floor) and resource-board.sh (the negotiated sheet) -------------
rb="$scripts/resource-budget.py"; board="$scripts/resource-board.sh"
order="$work/heavy-order"; : > "$order"
for i in 1 2; do
    "$rb" run --label "t$i" -- sh -c "echo start >> '$order'; sleep 0.6; echo end >> '$order'" 2>/dev/null &
done
holder=""
for _ in $(seq 1 50); do holder=$("$board" show | grep "slot 0: t") && break; sleep 0.1; done
wait
check "resource-budget: one heavy slot serialises two checks" [ "$(tr '\n' ' ' < "$order")" == "start end start end " ]
check "resource-board: shows the heavy slot's holder" bash -c '[[ "$1" == *"slot 0: t"* ]]' _ "$holder"
check "resource-budget: a nested run does not wait for its own slot" "$rb" run -- "$rb" run --timeout 5 -- true
check "resource-budget: the command's exit code comes back" exits 7 "$rb" run -- sh -c 'exit 7'
"$rb" run -- sleep 60 & holder_pid=$!   # holds the only slot until killed
for _ in $(seq 1 100); do grep -q "slot 0: sleep" <<<"$("$board" show)" && break; sleep 0.2; done
check "resource-budget: --timeout gives up with 124" exits 124 "$rb" run --timeout 0.5 -- true
kill "$holder_pid"; wait "$holder_pid" 2>/dev/null
check "resource-budget: a killed holder frees its slot" "$rb" run --timeout 10 -- true
agents a1 w1:p1 working /x  a2 w2:p1 idle /y  a3 w3:p1 "done" /z
budget 2
"$board" note "dev server + e2e" --gb 3 --minutes 20 --as a1 >/dev/null
"$board" note "old benchmark" --as ghost >/dev/null
"$board" note "my notebook" --as me-shell >/dev/null
sheet=$("$board" show)
check "resource-board: a note shows what, GB and time left" \
    bash -c '[[ "$1" == *"| a1 | dev server + e2e | 3 | 0 min | "*" min left |"* ]]' _ "$sheet"
check "resource-board: idle and done agents do not count toward the guideline" \
    bash -c '[[ "$1" == *"Live herdr agents: 3, 1 working (guideline for this machine: 2 working)"* && "$1" != *"over the guideline"* ]]' _ "$sheet"
check "resource-board: marks the note of an agent that is gone" bash -c '[[ "$1" == *"| ghost (gone) |"* ]]' _ "$sheet"
check "resource-board: lists idle and done agents as candidates to close" \
    bash -c '[[ "$1" == *"- a2 - idle"* && "$1" == *"- a3 - done"* && "$1" != *"- a1 - working"* ]]' _ "$sheet"
"$board" prune >/dev/null
check "resource-board: prune drops gone agents, keeps live ones and humans' lines" \
    bash -c '[[ ! -e "$1/board/ghost.json" && -e "$1/board/a1.json" && -e "$1/board/me-shell.json" ]]' _ "$HERDR_AGENT_POOL_RESOURCES_DIR"
"$board" clear --as a1 >/dev/null
check "resource-board: clear removes your own line" not test -e "$HERDR_AGENT_POOL_RESOURCES_DIR/board/a1.json"
check "resource-board: refuses a name that is not a file name" exits 1 "$board" note x --as "../etc"
check "resource-board: refuses a non-numeric estimate" exits 1 "$board" note x --gb lots --as a2
agents a1 w1:p1 working /x  a2 w2:p1 working /y  a3 w3:p1 working /z
check "resource-board: flags working agents over the guideline" \
    bash -c '[[ "$("$1" show)" == *"3 working (guideline for this machine: 2 working) - **over the guideline**"* ]]' _ "$board"
budget 4
check "resource-board: within the guideline, no flag" bash -c '[[ "$("$1" show)" != *"over the guideline"* ]]' _ "$board"
echo '{"heavy_slots": 0}' > "$HERDR_AGENT_POOL_RESOURCES_CONFIG"
check "resource-budget: rejects an invalid limit" exits 1 "$rb" limits
echo '{"heavy_slot": 2}' > "$HERDR_AGENT_POOL_RESOURCES_CONFIG"
check "resource-budget: rejects an unknown key" exits 1 "$rb" limits

# The queue: limits re-read on every retry, priority order, lowered limits, interruptions.
slots() { printf '{"heavy_slots": %s, "light_slots": 1, "sessions_guideline": 50, "low_memory_gb": 0}\n' "$1" > "$HERDR_AGENT_POOL_RESOURCES_CONFIG"; }
until_true() { for _ in $(seq 1 100); do "$@" && return 0; sleep 0.1; done; return 1; }
queued() { [[ $(ls "$HERDR_AGENT_POOL_RESOURCES_DIR/queue-heavy" 2>/dev/null | wc -l) -ge $1 ]]; }
held() { "$rb" status --json | jq -e --argjson n "$1" '.heavy.holders | length == $n' >/dev/null; }
release_file="$work/release"; rm -f "$release_file"
hold() { "$rb" run --label "$1" -- sh -c "until [ -e '$release_file.$1' ]; do sleep 0.1; done" 2>/dev/null & }
slots 1
hold h1; until_true held 1
"$rb" run --label w1 -- true 2>/dev/null & waiter=$!
until_true queued 1
slots 2
check "resource-budget: a raised limit admits a waiter that is already waiting" until_true not kill -0 "$waiter"
touch "$release_file.h1"; wait
rm -f "$release_file".*; : > "$order"
slots 1
hold h2; until_true held 1
"$rb" run --label normal -- sh -c "echo normal >> '$order'" 2>/dev/null &
until_true queued 1
env CLAUDE_ROLE=integrator "$rb" run --priority merge --label merge -- sh -c "echo merge >> '$order'" 2>/dev/null &
until_true queued 2
check "resource-board: lists the waiters in turn order" \
    bash -c '[[ "$("$1" show)" == *"waiting #1: merge"*"waiting #2: normal"* ]]' _ "$board"
touch "$release_file.h2"; wait
check "resource-budget: a merge verification goes before an earlier normal check" [ "$(tr '\n' ' ' < "$order")" == "merge normal " ]
out=$(env CLAUDE_ROLE= "$rb" run --priority merge -- true 2>&1)
check "resource-budget: merge priority outside an integrator is queued as normal" bash -c '[[ "$1" == *"queued as normal"* ]]' _ "$out"
rm -f "$release_file".*
slots 2
hold h3; until_true held 1; hold h4; until_true held 2
slots 1
touch "$release_file.h3"; until_true held 1
check "resource-budget: a lowered limit counts the holder above it (no new admission)" exits 124 "$rb" run --timeout 1 -- true
check "resource-board: flags a holder above the lowered limit" \
    bash -c '[[ "$("$1" show)" == *"slot 1: h4"*"above the current limit"* ]]' _ "$board"
check "resource-budget: the light pool does not wait behind heavy holders" "$rb" run --pool light --timeout 2 -- true
check "resource-budget: the command learns the pool's limit" \
    bash -c '[[ "$("$1" run --pool light -- sh -c "echo \$HERDR_AGENT_POOL_SLOT_COUNT")" == 1 ]]' _ "$rb"
"$rb" run --label w2 -- true 2>/dev/null & waiter=$!
until_true queued 1
echo '{"heavy_slots": ' > "$HERDR_AGENT_POOL_RESOURCES_CONFIG"   # half written
sleep 2.5
check "resource-budget: a half-written limits file keeps the waiter waiting" kill -0 "$waiter"
kill -TERM "$waiter"; wait "$waiter"; rc=$?
check "resource-budget: a waiter stopped by SIGTERM exits 120 (the command never ran)" [ "$rc" == 120 ]
check "resource-budget: the stopped waiter's ticket is gone" not queued 1
slots 1; touch "$release_file.h4"; wait; rm -f "$release_file".*

# verify-merge.sh: the project's check variables, and exit 120 when the check never ran.
vm="$work/vm"; git init --quiet -b main "$vm"; mkdir -p "$vm/.claude" "$vm/scripts" "$vm/docs" "$vm/src"
cat > "$vm/scripts/check.sh" <<'SH'
#!/usr/bin/env bash
echo "scope=${SCOPE:-} docs=${DOCS:-}" > "$VM_OUT"
SH
chmod +x "$vm/scripts/check.sh"
echo '{"verify": {"check_env": {"SCOPE": "fast"}, "docs_only_paths": ["docs/*"], "docs_only_env": {"DOCS": "1"}}}' > "$vm/.claude/herdr-agent-pool.json"
echo a > "$vm/docs/a.md"; echo a > "$vm/src/a.py"
git -C "$vm" add -A && git -C "$vm" commit --quiet -m init
vmrun() { (cd "$vm" && env VM_OUT="$work/vm-out" "$scripts/verify-merge.sh" >/dev/null 2>&1); }
echo b >> "$vm/docs/a.md"; git -C "$vm" add -A
vmrun
check "verify-merge: check_env plus docs_only_env on a docs-only change" [ "$(cat "$work/vm-out")" == "scope=fast docs=1" ]
echo b >> "$vm/src/a.py"; git -C "$vm" add -A
vmrun
check "verify-merge: only check_env when code changed too" [ "$(cat "$work/vm-out")" == "scope=fast docs=" ]
(cd "$vm" && env VM_OUT="$work/vm-out" SCOPE=full "$scripts/verify-merge.sh" >/dev/null 2>&1)
check "verify-merge: a variable the caller exported wins over check_env" [ "$(cat "$work/vm-out")" == "scope=full docs=" ]
echo '{"verify": {"check_env": {"CLAUDE_ROLE": "integrator"}}}' > "$vm/.claude/herdr-agent-pool.json"
check "project-config: refuses an identity variable in verify.check_env" exits 1 "$scripts/project-config.py" --root "$vm"
echo '{"verify": {"check_env": {"SCOPE": 1}}}' > "$vm/.claude/herdr-agent-pool.json"
check "project-config: refuses a non-string check variable" exits 1 "$scripts/project-config.py" --root "$vm"
echo '{}' > "$vm/.claude/herdr-agent-pool.json"
hold h5; until_true held 1
(cd "$vm" && env VM_OUT="$work/vm-out" "$scripts/verify-merge.sh" >/dev/null 2>&1) & vmpid=$!
until_true queued 1
kill -TERM "$(jq -r .pid "$HERDR_AGENT_POOL_RESOURCES_DIR"/queue-heavy/*.json)"; wait "$vmpid"; rc=$?
check "verify-merge: exit 120 when its wait for a slot is interrupted" [ "$rc" == 120 ]
touch "$release_file.h5"; wait; rm -f "$release_file".*
budget 50

# integrator-pool.sh ---------------------------------------------------------------------------
route() { (cd "$d1" && "$pool" route 2>/dev/null); }
agents dev1 w3:p1 idle "$d1"
route >/dev/null; status=$?
check "pool route: no live integrator (exit 1)" [ "$status" == 1 ]
git -C "$proj" worktree add --quiet --detach "$work/proj-integrator-2" origin/main
wt2="$work/proj-integrator-2"
agents dev1 w3:p1 idle "$d1"  integrator-proj-1 w2:p1 working "$wt1"  integrator-proj-2 w4:p1 idle "$wt2"
check "pool route: the idle member first" [ "$(route | cut -f1)" == integrator-proj-2 ]
agents integrator-proj-1 w2:p1 working "$wt1"  integrator-proj-2 w4:p1 blocked "$wt2"
check "pool route: else a working one"    [ "$(route | cut -f1)" == integrator-proj-1 ]
agents integrator-proj-1 w2:p1 blocked "$wt1"  integrator-proj-2 w4:p1 blocked "$wt2"
route >/dev/null; status=$?
check "pool route: every member blocked (exit 3)" [ "$status" == 3 ]
agents integrator-proj-1 w2:p1 idle "$single"
route >/dev/null; status=$?
check "pool route: a pool name outside this repository does not count" [ "$status" == 1 ]
agents integrator-single w1:p1 idle "$single"
check "pool route: single mode routes to integrator_name" [ "$(cd "$single" && "$pool" route | cut -f1)" == integrator-single ]

# integrator-pool.sh nudge / watch: idle members hear about PRs that wait unclaimed -------------
st="$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool"
jq -n '[{number: 31, title: "PR 31", headRefName: "feat/x31", headRefOid: "abc", isDraft: false, createdAt: "2026-01-01T00:00:00Z"}]' \
    > "$FAKE_GH/list.json"
agents integrator-proj-1 w2:p1 working "$wt1"  integrator-proj-2 w4:p1 idle "$wt2"
nudge() { (cd "$proj" && env HERDR_ENV=1 "$pool" nudge 2>&1); }
: > "$FAKE_LOG"; out=$(nudge)
check "pool nudge: a PR just seen unclaimed waits (no prompt yet)" bash -c '[[ "$1" == *"no PR to nudge about"* && ! -s "$2" ]]' _ "$out" "$FAKE_LOG"
echo $(( $(date +%s) - 400 )) > "$st/watch/pr-31"
nudge >/dev/null
check "pool nudge: after nudge_after_minutes the idle member is prompted" \
    grep -q "prompt integrator-proj-2 \[herdr message from the pool watcher" "$FAKE_LOG"
check "pool nudge: the working member is left alone" not grep -q "prompt integrator-proj-1" "$FAKE_LOG"
: > "$FAKE_LOG"; nudge >/dev/null
check "pool nudge: a member is nudged at most once per interval" [ ! -s "$FAKE_LOG" ]
(cd "$proj" && env CLAUDECODE=1 CLAUDE_ROLE=integrator HERDR_ENV=1 "$pool" nudge >/dev/null 2>&1); status=$?
check "pool nudge: refused to a Claude session that is not the coordinator" [ "$status" == 1 ]
echo 3 > "$st/watch/pr-31.nudges"; rm -f "$st/watch/nudged-"*; : > "$FAKE_LOG"; nudge >/dev/null
check "pool nudge: after 3 nudges the coordinator is told, not the members" \
    bash -c 'grep -q "prompt coordinator-proj \[herdr message from the pool watcher" "$1" && ! grep -q "prompt integrator" "$1"' _ "$FAKE_LOG"
: > "$FAKE_LOG"; nudge >/dev/null
check "pool nudge: the coordinator is told once" [ ! -s "$FAKE_LOG" ]
(cd "$proj" && exec env HERDR_ENV=1 "$pool" watch 10 > "$work/watch.out" 2>&1) & watcher=$!
until_true test -s "$st/watch.pid"
out=$(cd "$proj" && env HERDR_ENV=1 "$pool" watch 10 2>&1); status=$?
check "pool watch: a second watcher exits 0 at once" bash -c '[[ $1 == 0 && "$2" == *"already runs"* ]]' _ "$status" "$out"
kill "$(cat "$st/watch.pid")" 2>/dev/null; wait "$watcher" 2>/dev/null
echo '[]' > "$FAKE_GH/list.json"

for i in 2 3; do git -C "$proj" worktree add --quiet -b "feat/dev$i" "$work/proj-dev$i" origin/main; done
agents dev1 w3:p1 working "$d1"  dev2 w5:p1 idle "$work/proj-dev2"  dev3 w6:p1 working "$work/proj-dev3" \
       integrator-proj-1 w2:p1 idle "$wt1"  coordinator-proj w1:p1 idle "$proj"
check "pool desired: 3 development agents, one integrator per 2 -> 2" \
    [ "$(cd "$proj" && "$pool" desired)" == "desired=2 development_agents=3 live=1" ]
out=$(cd "$proj" && "$pool" scale); live_before=$(cd "$proj" && "$pool" list | grep -c down)
check "pool scale: facts and a suggestion, nothing changed" \
    bash -c '[[ "$1" == *"facts: 1 live member(s)"*"3 development agent(s)"*"integrator-proj-1: idle"*"suggestion: 2 member(s)"* && $2 == 1 ]]' _ "$out" "$live_before"

(cd "$proj" && env CLAUDECODE=1 CLAUDE_ROLE= HERDR_ENV=1 "$pool" spawn 2 >/dev/null 2>&1); status=$?
check "pool spawn: refused to a Claude session that is not the coordinator" [ "$status" == 1 ]
git -C "$proj" worktree remove "$wt2"
: > "$FAKE_LOG"
out=$(cd "$proj" && env CLAUDECODE=1 CLAUDE_ROLE=coordinator HERDR_ENV=1 HERDR_AGENT_POOL_NAME=coordinator-proj "$pool" spawn 2 2>&1); status=$?
log=$(cat "$FAKE_LOG")
check "pool spawn: exit 0"                                  [ "$status" == 0 ]
check "pool spawn: a detached verify worktree at origin/main" \
    bash -c '! git -C "$1" symbolic-ref -q HEAD && [[ "$(git -C "$1" rev-parse HEAD)" == "$(git -C "$2" rev-parse main)" ]]' _ "$wt2" "$origin"
check "pool spawn: its own workspace with the role in its env" \
    bash -c '[[ "$1" == *"workspace-create --cwd $2 --label integrator-proj-2"*"CLAUDE_ROLE=integrator"*"HERDR_AGENT_POOL_NAME=integrator-proj-2"* ]]' _ "$log" "$wt2"
check "pool spawn: agent started with its name and the integrator prompt" \
    bash -c '[[ "$1" == *"agent-start integrator-proj-2 --kind claude --pane w9:p1 -- --name integrator-proj-2 --append-system-prompt-file"*"prompts/integrator.md"* ]]' _ "$log"
check "pool spawn: the kickoff carries the header" \
    bash -c '[[ "$1" == *"prompt integrator-proj-2 [herdr message from agent coordinator-proj; not from the user]"* ]]' _ "$log"
agents integrator-proj-2 w9:p1 idle "$wt2"   # member 1 is down
: > "$FAKE_LOG"
(cd "$proj" && env HERDR_ENV=1 FAKE_START_RC=1 "$pool" spawn 1 >/dev/null 2>&1); status=$?
check "pool spawn: a startup dialog is escalated (exit 4), never answered" \
    bash -c '[[ $1 == 4 ]] && ! grep -q "send-keys" "$2"' _ "$status" "$FAKE_LOG"

agents integrator-proj-2 w9:p1 idle "$wt2"  integrator-proj-1 w2:p1 idle "$wt1"
(cd "$proj" && HERDR_ENV=1 FAKE_PANE=w9:p1 HERDR_PANE_ID=w9:p1 "$ps" claim 77 --owner integrator-proj-2 >/dev/null)
(cd "$proj" && env HERDR_ENV=1 "$pool" stop 2 >/dev/null 2>&1); status=$?
check "pool stop: refused while the member holds a claim (exit 5)" [ "$status" == 5 ]
(cd "$proj" && HERDR_ENV=1 FAKE_PANE=w9:p1 HERDR_PANE_ID=w9:p1 "$ps" release 77 --owner integrator-proj-2 >/dev/null)
agents integrator-proj-2 w9:p1 working "$wt2"
(cd "$proj" && env HERDR_ENV=1 "$pool" stop 2 >/dev/null 2>&1); status=$?
check "pool stop: refused while the member works (exit 5)" [ "$status" == 5 ]
agents integrator-proj-2 w9:p1 idle "$wt2"
: > "$FAKE_LOG"
(cd "$proj" && env HERDR_ENV=1 "$pool" stop 2 >/dev/null 2>&1); status=$?
check "pool stop: closes the idle member's own workspace" bash -c '[[ $1 == 0 && "$(cat "$2")" == "workspace-close w9" ]]' _ "$status" "$FAKE_LOG"
(cd "$proj" && env HERDR_ENV=1 "$pool" stop 2 >/dev/null 2>&1); status=$?
check "pool stop: refuses a member it has no record of (exit 5)" [ "$status" == 5 ]
agents   # member 2 is down: spawn it again, then stop it for good
(cd "$proj" && env HERDR_ENV=1 "$pool" spawn 2 >/dev/null 2>&1)
agents integrator-proj-2 w9:p1 idle "$wt2"
(cd "$proj" && env HERDR_ENV=1 "$pool" stop 2 --remove-worktree >/dev/null 2>&1); status=$?
check "pool stop --remove-worktree: discards the verify worktree" bash -c '[[ $1 == 0 && ! -d "$2" ]] && ! git -C "$3" worktree list | grep -q integrator-2' _ "$status" "$wt2" "$proj"

# start-agent.sh: the dispatch skill's `herdr agent start`, with agent_args after `--` --------
sa="$scripts/start-agent.sh"; sa_repo="$work/start-agent"; argv="$work/start-agent.argv"
git init --quiet -b main "$sa_repo"; mkdir -p "$sa_repo/.claude"
start_agent() {  # start_agent <agent_args JSON|->: run start-agent.sh (- = no file), print its exit code
    local json="$1"
    if [[ "$json" == - ]]; then rm -f "$sa_repo/.claude/herdr-agent-pool.json"
    else printf '{"agent_args": %s}\n' "$json" > "$sa_repo/.claude/herdr-agent-pool.json"; fi
    rm -f "$argv"
    (cd "$sa_repo" && FAKE_ARGV="$argv" "$sa" dev1 w4:p1 >/dev/null 2>&1); echo $?
}
started_with() {  # started_with <exit code> <arg...>: exit 0 and `herdr agent start` got exactly these
    local status="$1"; shift
    [[ $status == 0 && "$(cat "$argv" 2>/dev/null)" == "$(printf '%s\n' "$@")" ]]
}
status=$(start_agent -)
check "start-agent: the default lean arguments after --" started_with "$status" \
    dev1 --kind claude --pane w4:p1 -- --strict-mcp-config --tools \
    "Bash,Read,Edit,Write,Glob,Grep,Skill,ToolSearch,AskUserQuestion"
status=$(start_agent '["--append-system-prompt", "be brief, then stop", "--tools", "Bash,Read"]')
check "start-agent: a custom list, spaces and commas kept in one argument each" \
    started_with "$status" \
    dev1 --kind claude --pane w4:p1 -- --append-system-prompt "be brief, then stop" --tools Bash,Read
status=$(start_agent '[]')
check "start-agent: [] starts claude with its defaults (no --)" started_with "$status" \
    dev1 --kind claude --pane w4:p1
status=$(start_agent '["a\nb"]')
check "start-agent: invalid settings exit 1 and start nothing" bash -c '[[ $1 == 1 && ! -e "$2" ]]' _ "$status" "$argv"
out=$(cd "$sa_repo" && rm -f .claude/herdr-agent-pool.json && FAKE_START_RC=1 "$sa" dev1 w4:p1 2>&1); status=$?
check "start-agent: herdr's exit code and agent_not_ready passed through" \
    bash -c '[[ $1 == 1 && "$2" == *agent_not_ready* ]]' _ "$status" "$out"
check "start-agent: usage (exit 2)" exits 2 "$sa" dev1

# cleanup-worktree.sh: discard a merged branch's workspace, worktree and branches -----------------
cw="$scripts/cleanup-worktree.sh"
git -C "$dev" fetch --quiet origin && git -C "$dev" checkout --quiet -B feat/done origin/main
echo finished > "$dev/src/done.txt" && git -C "$dev" add -A && git -C "$dev" commit --quiet -m "feat: done" \
    && git -C "$dev" push --quiet origin feat/done
git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main \
    && git -C "$pusher" merge --quiet --no-ff -m "Merge feat/done" origin/feat/done && git -C "$pusher" push --quiet origin main
git -C "$proj" fetch --quiet origin
git -C "$proj" branch --quiet feat/done origin/feat/done
git -C "$proj" worktree add --quiet "$work/proj-done" feat/done
done_wt="$work/proj-done"
jq -n --arg h "$(git -C "$proj" rev-parse feat/done)" \
    '[{number: 30, headRefName: "feat/done", headRefOid: $h, state: "MERGED"}]' > "$FAKE_GH/list.json"   # GitHub: PR #30 merged
export FAKE_PANES="$work/panes.json"
panes() {  # panes <workspace> <pane> <cwd> ...: the fake `herdr pane list`
    local json='[]'
    while [[ $# -ge 3 ]]; do
        json=$(jq -c --arg w "$1" --arg p "$2" --arg c "$3" '. + [{workspace_id: $w, pane_id: $p, cwd: $c}]' <<<"$json"); shift 3
    done
    jq -n --argjson p "$json" '{result: {panes: $p}}' > "$FAKE_PANES"
}
cwi() { (cd "$proj" && "$cw" "$@"); }
agents donea w7:p1 working "$done_wt"  dev1 w3:p1 idle "$d1"
panes w7 w7:p1 "$done_wt"
check "cleanup --list: merged but its agent still works; others not merged" \
    bash -c '[[ "$1" == *"feat/done"$'"'"'\t'"'"'"merged-agent-busy"* && "$1" == *"feat/dev1"$'"'"'\t'"'"'"not-merged"* ]]' _ "$(cwi --list)"
check "cleanup: refuses while the agent works (exit 5)" exits 5 cwi feat/done
agents donea w7:p1 idle "$done_wt"
echo scratch > "$done_wt/notes.txt"
check "cleanup: refuses uncommitted work (exit 4)" exits 4 cwi feat/done
rm "$done_wt/notes.txt"
panes w7 w7:p1 "$done_wt"  w7 w7:p2 "$proj"
check "cleanup: refuses a workspace that also holds another pane (exit 6)" exits 6 cwi feat/done
panes w7 w7:p1 "$done_wt"
: > "$FAKE_LOG"
out=$(cwi feat/done --dry-run)
check "cleanup --dry-run: says what it would do, changes nothing" \
    bash -c '[[ "$1" == *"would close workspace w7"*"would remove the worktree"*"would delete origin/feat/done"* && -d "$2" && ! -s "$3" ]]' _ "$out" "$done_wt" "$FAKE_LOG"
"$scripts/resource-board.sh" note "e2e server" --as donea >/dev/null
check "cleanup --list: ready when merged, clean and idle" bash -c '[[ "$1" == *"feat/done"$'"'"'\t'"'"'"ready"* ]]' _ "$(cwi --list)"
cwi feat/done >/dev/null 2>&1; status=$?
check "cleanup: closes the workspace, removes the worktree and both branches" \
    bash -c '[[ $1 == 0 && "$(cat "$2")" == "workspace-close w7" && ! -d "$3" ]] \
             && ! git -C "$4" rev-parse -q --verify refs/heads/feat/done >/dev/null \
             && ! git -C "$5" rev-parse -q --verify refs/heads/feat/done >/dev/null' _ "$status" "$FAKE_LOG" "$done_wt" "$proj" "$origin"
check "cleanup: clears the agent's resource-board note" not test -e "$HERDR_AGENT_POOL_RESOURCES_DIR/board/donea.json"
check "cleanup: refuses a branch without a merged PR, even one with no commits yet (exit 3)" exits 3 cwi feat/dev1
# A branch name reused after its PR merged: the merged PR's head is not this tip.
jq '.[0].headRefName = "feat/dev2" | .[0].headRefOid = "0000000000000000000000000000000000000000"' "$FAKE_GH/list.json" > "$FAKE_GH/list.new" \
    && mv "$FAKE_GH/list.new" "$FAKE_GH/list.json"
check "cleanup: a reused branch name is not 'merged' (exit 3)" exits 3 cwi feat/dev2
check "cleanup: refuses a protected branch (exit 1)" exits 1 cwi main
check "cleanup: refuses a Claude session that is not the dispatcher (exit 1)" \
    exits 1 env CLAUDECODE=1 CLAUDE_ROLE= bash -c 'cd "$1" && "$2" --list' _ "$proj" "$cw"
unset FAKE_PANES; echo '[]' > "$FAKE_GH/list.json"

# integrator-watch.sh: single mode's watcher wakes the idle integrator and cleans up -----------
iw="$scripts/integrator-watch.sh"
sst="$(git -C "$single" rev-parse --path-format=absolute --git-common-dir)/herdr-agent-pool"
wpass() { (cd "$single" && env HERDR_ENV=1 HERDR_AGENT_POOL_CLEAN_GRACE=0 "$iw" once 2>&1); }
# The integrator's Claude Code transcript (context-tokens.py): its cwd with every character
# outside [A-Za-z0-9] as "-", under a private projects directory.
export HERDR_AGENT_POOL_CLAUDE_PROJECTS="$work/claude-projects"
itx="$HERDR_AGENT_POOL_CLAUDE_PROJECTS/${single//[^A-Za-z0-9]/-}/sess-integrator-single.jsonl"
transcript() {  # transcript <context tokens>: the integrator's last turn sent that many tokens
    mkdir -p "$(dirname "$itx")"
    jq -nc '{type: "user", message: {role: "user", content: "x"}}' > "$itx"
    jq -nc --argjson t "$1" '{type: "assistant", message: {model: "m", usage: {input_tokens: 2,
        cache_creation_input_tokens: 1000, cache_read_input_tokens: ($t - 1002), output_tokens: 50}}}' >> "$itx"
}
transcript 30000
compacts() { grep -c "^prompt integrator-single /compact Keep: every open PR" "$FAKE_LOG"; }
prompts() { grep -c "^prompt integrator-single \[herdr message from the integrator watcher" "$FAKE_LOG"; }
open_list() {  # open_list <N:head[:label]> ...: the fake open PRs
    local json='[]' n h l
    for item in "$@"; do
        IFS=: read -r n h l <<<"$item"
        json=$(jq -c --argjson n "$n" --arg h "$h" --arg l "$l" \
            '. + [{number: $n, headRefOid: $h, isDraft: false, labels: (if $l == "" then [] else [{name: $l}] end)}]' <<<"$json")
    done
    printf '%s\n' "$json" > "$FAKE_GH/list-open.json"
}
echo '[]' > "$FAKE_GH/list-merged.json"
check "watch: refuses pool mode (exit 1)" exits 1 bash -c 'cd "$1" && HERDR_ENV=1 "$2" once' _ "$proj" "$iw"
agents integrator-single w1:p1 idle "$single"
open_list 50:h50a
: > "$FAKE_LOG"; out=$(wpass)
check "watch: a PR first seen is not news yet (an announcement may be on its way)" bash -c '[[ -z "$1" && $2 == 0 ]]' _ "$out" "$(prompts)"
out=$(wpass)
check "watch: an undecided PR wakes the idle integrator" \
    bash -c '[[ "$1" == *"woke integrator-single: PR #50 waits for a verdict"* && $2 == 1 ]]' _ "$out" "$(prompts)"
out=$(wpass)
check "watch: the same news is never told twice" bash -c '[[ -z "$1" && $2 == 1 ]]' _ "$out" "$(prompts)"
open_list 50:h50b; wpass >/dev/null; out=$(wpass)
check "watch: a new head is news again" bash -c '[[ "$1" == *"PR #50 waits"* && $2 == 2 ]]' _ "$out" "$(prompts)"
agents integrator-single w1:p1 working "$single"
open_list 50:h50b 51:h51; wpass >/dev/null; out=$(wpass)
check "watch: a working integrator is not prompted" bash -c '[[ -z "$1" && $2 == 2 ]]' _ "$out" "$(prompts)"
agents integrator-single w1:p1 blocked "$single"; out=$(wpass)
check "watch: a blocked integrator is not prompted" bash -c '[[ -z "$1" && $2 == 2 ]]' _ "$out" "$(prompts)"
agents integrator-single w1:p1 "done" "$single"; out=$(wpass)
check "watch: the news waited and is told once the integrator is done" \
    bash -c '[[ "$1" == *"PR #51 waits"* && "$1" != *"PR #50"* && $2 == 3 ]]' _ "$out" "$(prompts)"
mkdir -p "$sst/bounced" && echo '{"head": "h52"}' > "$sst/bounced/pr-52.json"
open_list 50:h50b 51:h51 52:h52 53:h53:queue 54:h54:queue 55:h55:draft
jq '.[5].isDraft = true' "$FAKE_GH/list-open.json" > "$FAKE_GH/l.new" && mv "$FAKE_GH/l.new" "$FAKE_GH/list-open.json"
wpass >/dev/null; out=$(wpass)
check "watch: bounced heads, queued and draft PRs are no news" bash -c '[[ -z "$1" && $2 == 3 ]]' _ "$out" "$(prompts)"
# The lander merges #53 and bounces #54 out of the queue.
open_list 50:h50b 51:h51 52:h52 54:h54
jq -n '{number: 53, state: "MERGED", comments: []}' > "$FAKE_GH/pr-53.json"
jq -n '{number: 54, state: "OPEN", comments: [{body: "Looks good."}, {body: "<!-- herdr-agent-pool:lander bounce -->\n\nLander bounce 1 of 2: merge conflict onto `main`."}]}' > "$FAKE_GH/pr-54.json"
out=$(wpass)
check "watch: the lander's merge and bounce wake the integrator, in one message" \
    bash -c '[[ "$1" == *"PR #53 merged"*"PR #54 left the queue: Lander bounce 1 of 2: merge conflict"* && $2 == 4 ]]' _ "$out" "$(prompts)"
out=$(wpass); out2=$(wpass)
check "watch: lander news is told once (the bounced PR then waits like any other)" \
    bash -c '[[ "$1$2" != *"PR #53"* && "$1$2" != *"left the queue"* ]]' _ "$out" "$out2"
open_list; wpass >/dev/null
# Compaction: an idle integrator whose context is over integrator_compact_tokens (120000).
check "context-tokens: the last turn's prompt (input + cache creation + cache read)" \
    [ "$("$scripts/context-tokens.py" integrator-single)" == 30000 ]
cp "$itx" "$work/itx.saved"
jq -nc '{type: "system", subtype: "compact_boundary", compactMetadata: {preTokens: 30000, postTokens: 4000}}' >> "$itx"
check "context-tokens: a compaction after the last turn counts its summary" \
    [ "$("$scripts/context-tokens.py" integrator-single)" == 4000 ]
mv "$work/itx.saved" "$itx"
check "context-tokens: an agent without a session exits 2" exits 2 "$scripts/context-tokens.py" nobody
: > "$FAKE_LOG"; out=$(wpass)
check "watch: an idle integrator under the threshold is not compacted" bash -c '[[ -z "$1" && $2 == 0 ]]' _ "$out" "$(compacts)"
transcript 130000; agents integrator-single w1:p1 working "$single"; out=$(wpass)
check "watch: a working integrator over the threshold is not compacted" bash -c '[[ -z "$1" && $2 == 0 ]]' _ "$out" "$(compacts)"
agents integrator-single w1:p1 blocked "$single"; out=$(wpass)
check "watch: a blocked integrator is not compacted" bash -c '[[ -z "$1" && $2 == 0 ]]' _ "$out" "$(compacts)"
agents integrator-single w1:p1 idle "$single"; open_list 56:h56; out=$(wpass)
check "watch: compacts the idle integrator over the threshold, once (COMPACT line)" \
    bash -c '[[ "$1" == "COMPACT integrator-single 130000" && $2 == 1 ]]' _ "$out" "$(compacts)"
out=$(wpass)
check "watch: not twice in the same idle period (the news goes out instead)" \
    bash -c '[[ "$1" == *"woke integrator-single: PR #56 waits"* && "$1" != *COMPACT* && $2 == 1 ]]' _ "$out" "$(compacts)"
open_list
agents integrator-single w1:p1 working "$single"; wpass >/dev/null
agents integrator-single w1:p1 "done" "$single"; out=$(wpass)
check "watch: not again within 10 minutes" bash -c '[[ -z "$1" && $2 == 1 ]]' _ "$out" "$(compacts)"
agents integrator-single w1:p1 working "$single"; wpass >/dev/null
agents integrator-single w1:p1 "done" "$single"; out=$(HERDR_AGENT_POOL_COMPACT_COOLDOWN=0 wpass)
check "watch: a new idle period after the cooldown compacts again" \
    bash -c '[[ "$1" == "COMPACT integrator-single 130000" && $2 == 2 ]]' _ "$out" "$(compacts)"
agents integrator-single w1:p1 working "$single"; wpass >/dev/null; agents integrator-single w1:p1 idle "$single"
echo '{"integrator_compact_tokens": 0}' > "$single/.claude/herdr-agent-pool.json"
out=$(HERDR_AGENT_POOL_COMPACT_COOLDOWN=0 wpass); rm -f "$single/.claude/herdr-agent-pool.json"
check "watch: integrator_compact_tokens 0 turns the compaction off" bash -c '[[ -z "$1" && $2 == 2 ]]' _ "$out" "$(compacts)"
rm -f "$itx"; out=$(HERDR_AGENT_POOL_COMPACT_COOLDOWN=0 wpass); out2=$(HERDR_AGENT_POOL_COMPACT_COOLDOWN=0 wpass)
check "watch: an unreadable transcript is said once, and nothing is prompted" \
    bash -c '[[ "$1" == *"no compaction, cannot read integrator-single'"'"'s context"* && -z "$2" && $3 == 2 ]]' _ "$out" "$out2" "$(compacts)"
transcript 30000
# Cleanup: a ready worktree goes, a dirty one stays.
for b in w-done w-dirty; do
    git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B "feat/$b" origin/main
    echo "$b" > "$sdev/$b.txt" && git -C "$sdev" add -A && git -C "$sdev" commit --quiet -m "$b" && git -C "$sdev" push --quiet origin "feat/$b"
    git -C "$sdev" checkout --quiet -B main origin/main && git -C "$sdev" merge --quiet --no-ff -m "Merge feat/$b" "feat/$b" \
        && git -C "$sdev" push --quiet origin main
    git -C "$single" fetch --quiet origin && git -C "$single" branch --quiet "feat/$b" "origin/feat/$b"
    git -C "$single" worktree add --quiet "$work/single-$b" "feat/$b"
done
git -C "$single" merge --quiet --ff-only origin/main
echo scratch > "$work/single-w-dirty/notes.txt"
jq -n --arg a "$(git -C "$single" rev-parse feat/w-done)" --arg b "$(git -C "$single" rev-parse feat/w-dirty)" \
    '[{headRefName: "feat/w-done", headRefOid: $a}, {headRefName: "feat/w-dirty", headRefOid: $b}]' > "$FAKE_GH/list-merged.json"
agents integrator-single w1:p1 working "$single"  wdone w8:p1 idle "$work/single-w-done"  wdirty w9:p1 idle "$work/single-w-dirty"
export FAKE_PANES="$work/panes.json"; panes w8 w8:p1 "$work/single-w-done"  w9 w9:p1 "$work/single-w-dirty"
: > "$FAKE_LOG"; out=$(wpass)
check "watch: a worktree just ready is left for a grace period" bash -c '[[ -z "$1" && -d "$2" ]]' _ "$out" "$work/single-w-done"
out=$(wpass)
check "watch: cleans up the ready worktree (cleanup-worktree.sh)" \
    bash -c '[[ "$1" == *"cleaned feat/w-done"* && ! -d "$2" ]] && grep -q "workspace-close w8" "$3"' _ "$out" "$work/single-w-done" "$FAKE_LOG"
check "watch: leaves the dirty one alone" \
    bash -c '[[ "$1" != *w-dirty* && -f "$2/notes.txt" ]] && ! grep -q "workspace-close w9" "$3"' _ "$out" "$work/single-w-dirty" "$FAKE_LOG"
# retry-stalled.py: an agent whose last turn stopped on an API error is asked to continue.
rs="$scripts/retry-stalled.py"
rpass() { (cd "$single" && env HERDR_ENV=1 "$@" "$rs" 2>&1); }
dpath="$work/single-w-dirty"
dtx="$HERDR_AGENT_POOL_CLAUDE_PROJECTS/${dpath//[^A-Za-z0-9]/-}/sess-wdirty.jsonl"
api_error() {  # api_error <transcript> <text> [kind]: its last turn becomes an API error
    mkdir -p "$(dirname "$1")"
    jq -nc '{type: "user", message: {role: "user", content: "x"}}' >> "$1"
    jq -nc --arg t "$2" --arg k "${3:-server_error}" '{type: "assistant", isApiErrorMessage: true, error: $k,
        message: {model: "<synthetic>", content: [{type: "text", text: $t}]}}' >> "$1"
    jq -nc '{type: "cost-state"}' >> "$1"
}
answered() { jq -nc '{type: "assistant", message: {model: "m", content: [{type: "text", text: "ok"}]}}' >> "$1"; }
retries() { grep -c "^prompt $1 \[herdr message from the watcher (retry-stalled.py)" "$FAKE_LOG"; }
agents integrator-single w1:p1 working "$single"  wdirty w9:p1 idle "$dpath"
: > "$FAKE_LOG"; out=$(rpass)
check "retry: an agent without a transcript is left alone" bash -c '[[ -z "$1" && $2 == 0 ]]' _ "$out" "$(retries wdirty)"
api_error "$dtx" "API Error: Connection lost mid-response."; out=$(rpass)
check "retry: an idle agent stopped by an API error is asked to continue (RETRY line)" \
    bash -c '[[ "$1" == "RETRY wdirty 1/20 API Error: Connection lost mid-response." && $2 == 1 ]]' _ "$out" "$(retries wdirty)"
out=$(rpass)
check "retry: not again before the backoff (60 s)" bash -c '[[ -z "$1" && $2 == 1 ]]' _ "$out" "$(retries wdirty)"
out=$(rpass HERDR_AGENT_POOL_RETRY_BASE=0)
check "retry: again after the backoff" bash -c '[[ "$1" == "RETRY wdirty 2/20 "* && $2 == 2 ]]' _ "$out" "$(retries wdirty)"
agents integrator-single w1:p1 working "$single"  wdirty w9:p1 working "$dpath"
out=$(rpass HERDR_AGENT_POOL_RETRY_BASE=0)
check "retry: a working agent is left alone" bash -c '[[ -z "$1" && $2 == 2 ]]' _ "$out" "$(retries wdirty)"
agents integrator-single w1:p1 working "$single"  wdirty w9:p1 "done" "$dpath"
out=$(rpass HERDR_AGENT_POOL_RETRY_BASE=0 HERDR_AGENT_POOL_RETRY_MAX=2); out2=$(rpass HERDR_AGENT_POOL_RETRY_BASE=0 HERDR_AGENT_POOL_RETRY_MAX=2)
check "retry: gives up after the maximum, said once" \
    bash -c '[[ "$1" == "GAVE-UP wdirty after 2 retries: "* && -z "$2" && $3 == 2 ]]' _ "$out" "$out2" "$(retries wdirty)"
answered "$dtx"; out=$(rpass)
check "retry: a turn that ended well forgets the count" \
    bash -c '[[ -z "$1" && ! -e "$2/retry-stalled/wdirty.json" ]]' _ "$out" "$sst"
api_error "$dtx" "API Error: Invalid API key" authentication_failed; out=$(rpass); out2=$(rpass)
check "retry: an error a retry cannot fix is not retried, said once" \
    bash -c '[[ "$1" == "NO-RETRY wdirty: "*"Invalid API key" && -z "$2" && $3 == 2 ]]' _ "$out" "$out2" "$(retries wdirty)"
check "retry: a development agent may not run it (exit 1)" \
    exits 1 env CLAUDECODE=1 CLAUDE_ROLE= bash -c 'cd "$1" && "$2"' _ "$single" "$rs"
rm -f "$dtx"
# The watcher runs it first; the integrator it retried gets nothing else in that pass.
open_list 57:h57; wpass >/dev/null
api_error "$itx" "API Error: Can't reach the API server"
agents integrator-single w1:p1 idle "$single"
: > "$FAKE_LOG"; out=$(wpass)
check "watch: retries the integrator stopped by an API error, and sends nothing else in that pass" \
    bash -c '[[ "$1" == "RETRY integrator-single 1/20 "* && "$1" != *woke* && $2 == 1 && $3 == 0 ]]' _ "$out" "$(retries integrator-single)" "$(prompts)"
out=$(wpass)
check "watch: the news goes out on the next pass" \
    bash -c '[[ "$1" == *"woke integrator-single: PR #57 waits"* && "$1" != *RETRY* ]]' _ "$out"
open_list; transcript 30000
(cd "$single" && exec env HERDR_ENV=1 "$iw" 10 > "$work/iwatch.out" 2>&1) & iwatcher=$!
until_true test -s "$sst/integrator-watch.pid"
out=$(cd "$single" && env HERDR_ENV=1 "$iw" 10 2>&1); status=$?
check "watch: a second watcher exits 0 at once" bash -c '[[ $1 == 0 && "$2" == *"already runs"* ]]' _ "$status" "$out"
kill "$(cat "$sst/integrator-watch.pid")" 2>/dev/null; wait "$iwatcher" 2>/dev/null
agents wdirty w9:p1 idle "$dpath"
out=$(cd "$single" && env HERDR_ENV=1 HERDR_AGENT_POOL_GONE_PASSES=1 "$iw" 10 2>&1); status=$?
out2=$(cd "$single" && env HERDR_ENV=1 HERDR_AGENT_POOL_GONE_PASSES=1 "$iw" 2>&1); status2=$?
check "watch: runs without an argument, as the SessionStart hook starts it (60 s)" \
    bash -c '[[ $1 == 0 && "$2" == *"a pass every 60s"* && "$2" != *unbound* ]]' _ "$status2" "$out2"
check "watch: the loop ends once the integrator is gone from herdr" \
    bash -c '[[ $1 == 0 && "$2" == *"integrator-single is gone from herdr; stopping"* ]]' _ "$status" "$out"
# The real SessionStart hook starts the real watcher (the agent in the pane stays unnamed in
# the fake list, so the watcher sees no integrator and ends after its first pass).
agents - w1:p1 idle "$single"; rm -f "$sst/integrator-watch.log"
ss "$single" CLAUDE_ROLE=integrator HERDR_AGENT_POOL_NO_WATCH= HERDR_AGENT_POOL_GONE_PASSES=1 FAKE_PANE=w1:p1 >/dev/null
until_true grep -q "is gone from herdr; stopping" "$sst/integrator-watch.log" 2>/dev/null
check "session-start: the hook's watcher starts and runs its passes (integrator-watch.log)" \
    grep -q "integrator watcher .*: a pass every 60s" "$sst/integrator-watch.log"
unset FAKE_PANES; rm -f "$FAKE_GH/list-open.json" "$FAKE_GH/list-merged.json"

# submit-pr.sh: one command from committed work to an announced PR ----------------------------
sp="$scripts/submit-pr.sh"
swt="$work/single-submit"
git -C "$single" fetch --quiet origin && git -C "$single" merge --quiet --ff-only origin/main
git -C "$single" worktree add --quiet -b feat/sub "$swt" origin/main
export FAKE_PROMPT_FILE="$work/last-prompt.txt"
submit() { (cd "$swt" && env HERDR_ENV=1 FAKE_PANE=w7:p1 CHECK_HOOK= "$sp" "$@" 2>&1); }
announces() { grep -c "^prompt integrator-single \[herdr message from agent subber; not from the user\]" "$FAKE_LOG"; }
agents integrator-single w1:p1 idle "$single"  subber w7:p1 working "$swt"
echo '[]' > "$FAKE_GH/list-open.json"; : > "$FAKE_GH/log"; : > "$FAKE_LOG"
check "submit: refuses the main worktree (exit 1)" exits 1 bash -c 'cd "$1" && HERDR_ENV=1 "$2" --title t </dev/null' _ "$single" "$sp"
echo one > "$swt/one.txt"
out=$(submit --title "feat: one" <<<"body"); rc=$?
check "submit: uncommitted changes stop it (exit 2), listed" bash -c '[[ $1 == 2 && "$2" == *"one.txt"* ]]' _ "$rc" "$out"
git -C "$swt" add one.txt && git -C "$swt" commit --quiet -m "feat: one"
out=$(submit <<<"body"); rc=$?
check "submit: a first submission needs a title (exit 1)" bash -c '[[ $1 == 1 && "$2" == *"--title"* ]]' _ "$rc" "$out"
# The base moves meanwhile (another PR merged): the submission rebases onto it.
git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B main origin/main \
    && echo moved > "$sdev/moved.txt" && git -C "$sdev" add -A && git -C "$sdev" commit --quiet -m moved && git -C "$sdev" push --quiet origin main
out=$(submit --title "feat: one" <<<"## Summary"); rc=$?
check "submit: rebases, checks, pushes, opens the PR and announces it (exit 0)" \
    bash -c '[[ $1 == 0 && "$2" == *"REBASED on origin/main"*"CHECK exit 0"*"PUSHED feat/sub"*"PR #77 https://github.com/o/r/pull/77"*"ANNOUNCED to integrator-single"*"RESULT submitted"* ]]' _ "$rc" "$out"
check "submit: the pushed branch holds the commit on top of the moved base" \
    bash -c 'git -C "$1" cat-file -e refs/heads/feat/sub:one.txt && git -C "$1" cat-file -e refs/heads/feat/sub:moved.txt' _ "$sorigin"
check "submit: gh pr create got the base, the title and the body" \
    bash -c 'grep -q "^create --base main --head feat/sub --title feat: one --body-file " "$1" && [[ "$(cat "$2")" == "## Summary" ]]' \
    _ "$FAKE_GH/log" "$(git -C "$swt" rev-parse --absolute-git-dir)/herdr-agent-pool-pr-body.md"
check "submit: one announcement, from the agent's herdr name" [ "$(announces)" == 1 ]
# A bounce: the PR is open, the base moved onto the same file, the fix is submitted again.
subhead=$(git -C "$sorigin" rev-parse refs/heads/feat/sub)
jq -n --arg h "$subhead" '[{number: 77, url: "https://github.com/o/r/pull/77", title: "feat: one", headRefName: "feat/sub", headRefOid: $h, isDraft: false, labels: [], author: {login: "tester"}}]' > "$FAKE_GH/list-open.json"
git -C "$sdev" fetch --quiet origin && git -C "$sdev" checkout --quiet -B main origin/main \
    && echo theirs > "$sdev/one.txt" && git -C "$sdev" add -A && git -C "$sdev" commit --quiet -m "their one" && git -C "$sdev" push --quiet origin main
out=$(submit); rc=$?
check "submit: a rebase conflict stops it (exit 3) and names the file" bash -c '[[ $1 == 3 && "$2" == *"one.txt"* ]]' _ "$rc" "$out"
out=$(submit); rc=$?
check "submit: a rebase in progress stops it (exit 3)" bash -c '[[ $1 == 3 && "$2" == *"rebase is in progress"* ]]' _ "$rc" "$out"
echo both > "$swt/one.txt" && git -C "$swt" add one.txt && GIT_EDITOR=true git -C "$swt" rebase --continue >/dev/null 2>&1
: > "$FAKE_GH/log"; out=$(submit --risky "the merge of one.txt"); rc=$?
check "submit: a fixed bounce is force-pushed with a lease and announced again, without a new PR" \
    bash -c '[[ $1 == 0 && "$2" == *"PR #77"*"ANNOUNCED to integrator-single"* && ! -s "$3" && $4 == 2 ]] && [[ "$(git -C "$5" show refs/heads/feat/sub:one.txt)" == both ]]' \
    _ "$rc" "$out" "$FAKE_GH/log" "$(announces)" "$sorigin"
check "submit: the second announcement says the bounce was fixed and what is risky" \
    bash -c 'grep -q "^PR #77 ready (bounce fixed, new head " "$1" && grep -qx "Risky: the merge of one.txt" "$1" && grep -q "^Checks: scripts/check.sh exit 0 on " "$1"' _ "$FAKE_PROMPT_FILE"
out=$(submit); rc=$?
check "submit: a tree that already passed is not checked again" bash -c '[[ $1 == 0 && "$2" == *"CHECK skipped"* ]]' _ "$rc" "$out"
jq '.[0].author.login = "someone-else"' "$FAKE_GH/list-open.json" > "$FAKE_GH/l.new" && mv "$FAKE_GH/l.new" "$FAKE_GH/list-open.json"
out=$(submit); rc=$?
check "submit: a PR opened by another account is not touched (exit 6)" bash -c '[[ $1 == 6 && "$2" == *"ask the user"* ]]' _ "$rc" "$out"
jq '.[0].author.login = "tester"' "$FAKE_GH/list-open.json" > "$FAKE_GH/l.new" && mv "$FAKE_GH/l.new" "$FAKE_GH/list-open.json"
agents subber w7:p1 working "$swt"
out=$(submit); rc=$?
check "submit: no live integrator: the PR stays open, not announced (exit 5)" bash -c '[[ $1 == 5 && "$2" == *"NOT announced"* ]]' _ "$rc" "$out"
agents integrator-single w1:p1 idle "$single"  subber w7:p1 working "$swt"
printf '#!/bin/sh\necho "boom: 1 test failed"\nexit 1\n' > "$swt/scripts/check.sh"
git -C "$swt" add -A && git -C "$swt" commit --quiet -m "break the check"
n=$(announces); out=$(submit); rc=$?
check "submit: a red check stops before the push (exit 4) and shows its last lines" \
    bash -c '[[ $1 == 4 && "$2" == *"CHECK exit 1"*"boom: 1 test failed"* && "$2" != *PUSHED* && $3 == "$4" ]]' _ "$rc" "$out" "$(announces)" "$n"
rm -f "$FAKE_GH/list-open.json"; unset FAKE_PROMPT_FILE

echo
echo "$fails failure(s)"
exit "$fails"
