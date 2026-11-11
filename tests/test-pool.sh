#!/usr/bin/env bash
# Smoke tests for pool mode (docs/multi-integrator.md): project-config.py's pool keys, the
# machine's heavy-slot floor (resource-budget.py) and resource board (resource-board.sh), the
# guards' role rules, claim-integrator.sh and the SessionStart hook for the coordinator and pool
# members, agents-in-repo.py's worktree filters, pool-state.py (claim races, stale claims,
# bounces, the merge lock, plan reports), union-rows.py, integrate-pr.sh end to end, and
# integrator-pool.sh (route, scale, spawn, stop) and cleanup-worktree.sh. Part of herdr-agent-pool.
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
unset CLAUDE_ROLE MULTI_AGENT_HERDR_NAME CLAUDECODE CHECK_COUNT CHECK_HOOK HERDR_ENV MULTI_AGENT_HERDR_SLOT
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
# commands are logged to $FAKE_LOG (one line each). $FAKE_HERDR_DOWN makes every call fail.
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
        [[ "${FAKE_START_RC:-0}" == 0 ]] || { echo '{"error":{"code":"agent_not_ready"}}'; exit 1; } ;;
    "agent prompt") printf 'prompt %s %s\n' "$3" "$(head -1 <<<"$4")" >> "$FAKE_LOG" ;;
    *) exit 2 ;;
esac
FAKE
cat > "$fake/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh: `pr view N [--json ...] [-q EXPR]` reads $FAKE_GH/pr-N.json, `pr list` prints
# $FAKE_GH/list.json, `pr comment` is logged.
case "$1 $2" in
    "pr view") n=$3; shift 3; q=.
        while [[ $# -gt 0 ]]; do case "$1" in -q) q=$2; shift 2 ;; *) shift ;; esac; done
        [[ -f "$FAKE_GH/pr-$n.json" ]] || { echo "no pull requests found" >&2; exit 1; }
        jq -r "$q" "$FAKE_GH/pr-$n.json" ;;
    "pr list") cat "$FAKE_GH/list.json" ;;
    "pr comment") echo "comment $3" >> "$FAKE_GH/log" ;;
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
    local json='[]'
    while [[ $# -ge 4 ]]; do
        json=$(jq -c --arg n "$1" --arg p "$2" --arg s "$3" --arg c "$4" \
            '. + [{pane_id: $p, agent_status: $s, cwd: $c} + (if $n == "-" then {} else {name: $n} end)]' <<<"$json")
        shift 4
    done
    jq -n --argjson a "$json" '{result: {agents: $a}, type: "agent_list"}' > "$FAKE_AGENTS"
}
agents
: > "$FAKE_LOG"
# The resource budget's state and limits, private to the tests (never ~/.cache or ~/.config).
export MULTI_AGENT_HERDR_RESOURCES_DIR="$work/resources" MULTI_AGENT_HERDR_RESOURCES_CONFIG="$work/resources.json"
export MULTI_AGENT_HERDR_MISSING_GRACE=0   # an owner missing from herdr is dead at once (one test sets a grace)
budget() { printf '{"heavy_slots": 1, "sessions_guideline": %s, "low_memory_gb": 0}\n' "$1" > "$MULTI_AGENT_HERDR_RESOURCES_CONFIG"; }
budget 50

# A project in pool mode, with a bare origin --------------------------------------------------
origin="$work/origin.git"; proj="$work/proj"
git init --quiet --bare -b main "$origin"
git init --quiet -b main "$proj"
mkdir -p "$proj/.claude/prompts" "$proj/scripts" "$proj/docs/decisions" "$proj/docs/phases" "$proj/src"
cp "$root/template/.claude/settings.json" "$proj/.claude/settings.json"
cat > "$proj/.claude/multi-agent-herdr.json" <<'JSON'
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
echo '{"integrators": {"max": 12}}' > "$long/.claude/multi-agent-herdr.json"
names=$("$pc" --root "$long" integrator_pool)
check "project-config: long names fit 32 characters" \
    bash -c '[[ $(wc -l <<<"$1") == *12 ]] && ! grep -Evq "^[a-z][a-z0-9_-]{0,31}$" <<<"$1" && [[ "$(tail -1 <<<"$1")" == *-12 ]]' _ "$names"
check "project-config: single mode by default"   [ "$("$pc" --root "$work/nowhere" mode)" == single ]
bad="$work/bad"; git init --quiet -b main "$bad"; mkdir -p "$bad/.claude"
for json in '{"integrators": {"min": 3, "max": 2}}' '{"integrators": {"max": 17}}' '{"integrators": {"maxx": 2}}' \
            '{"integrators": {"max": 0}}' '{"integrators": {"max": true}}' '{"integrators": 3}' '{"mode": "pool"}' \
            '{"integrators": {}, "coordinator_name": "integrator-bad-1"}' '{"coordinator_name": "Coord"}' \
            '{"integrators": {"reverify_exempt_paths": "docs/*"}}'; do
    printf '%s\n' "$json" > "$bad/.claude/multi-agent-herdr.json"
    "$pc" --root "$bad" >/dev/null 2>&1; status=$?
    check "project-config: rejects $json" [ "$status" == 1 ]
done
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
expect 2 "guard: posing as an integrator with a prefix" "$g" "$(bash_cmd "CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME=integrator-proj-1 $ipr 12" "$d1")"
expect 2 "guard: setting the member name through env"   "$g" "$(bash_cmd 'env MULTI_AGENT_HERDR_NAME=integrator-proj-1 ls' "$d1")"
expect 2 "guard: export CLAUDE_ROLE"                    "$g" "$(bash_cmd 'export CLAUDE_ROLE=coordinator' "$d1")"
expect 2 "guard: skipping the heavy-slot floor"         "$g" "$(bash_cmd 'MULTI_AGENT_HERDR_SLOT=1 scripts/check.sh' "$d1")"
expect 0 "guard: other variables are fine"              "$g" "$(bash_cmd 'FOO=1 env BAR=2 ls' "$d1")"
# The re-review's probes: env options that take an argument, wrappers in front, interpreters.
for probe in "env -u FOO CLAUDE_ROLE=integrator $ipr 3" \
             "env -i -u A CLAUDE_ROLE=integrator $ps claim 3 --owner x" \
             "command env -u A CLAUDE_ROLE=integrator $ipr 3" \
             "time env -u A MULTI_AGENT_HERDR_NAME=x $ipr 3" \
             "env -C /tmp CLAUDE_ROLE=integrator $ipr 3" \
             "env -S 'CLAUDE_ROLE=integrator ls'" "env -SCLAUDE_ROLE=x ls" \
             "exec -a x env HERDR_ENV=1 ls" "env -- MULTI_AGENT_HERDR_SLOT=1 ls" \
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
CLAUDE_ROLE=integrator  expect 0 "guard: a pool integrator runs integrate-pr.sh" "$g" "$(bash_cmd "$ipr 12" "$wt1")"
CLAUDE_ROLE=integrator  expect 2 "guard: a pool integrator spawns members"      "$g" "$(bash_cmd "$scripts/integrator-pool.sh spawn 2" "$wt1")"
CLAUDE_ROLE=coordinator expect 0 "guard: the coordinator spawns members"        "$g" "$(bash_cmd "$scripts/integrator-pool.sh spawn 2" "$proj")"
CLAUDE_ROLE=coordinator expect 0 "guard: the coordinator cleans up"             "$g" "$(bash_cmd "$scripts/cleanup-worktree.sh feat/x" "$proj")"
for push in "git push --force origin HEAD:main" "git push origin +HEAD:main" "git push origin --delete main" \
            "git push origin :main" "git push --force-with-lease origin HEAD:main" \
            "git push -uf origin HEAD:main" "git push -fu origin HEAD:main" "git push -ud origin main"; do
    CLAUDE_ROLE=integrator expect 2 "guard: under the lock, no '$push'" "$g" "$(bash_cmd "$ps lock run --owner i -- $push" "$wt1")"
done
badpool="$work/badpool"; git init --quiet -b main "$badpool"; mkdir -p "$badpool/.claude"
cp "$root/template/.claude/settings.json" "$badpool/.claude/settings.json"
printf '{"integrators": {"max": 2}, "typo": 1}\n' > "$badpool/.claude/multi-agent-herdr.json"
git -C "$badpool" add -A && git -C "$badpool" commit --quiet -m init
CLAUDE_ROLE=integrator  expect 2 "fail closed: invalid settings, no single-mode rights" "$g" "$(bash_cmd 'git commit -m x' "$badpool")"
CLAUDE_ROLE=integrator  expect 2 "fail closed: invalid settings, no push to main"     "$g" "$(bash_cmd 'git push origin HEAD:main' "$badpool")"
CLAUDE_ROLE=integrator  expect 2 "fail closed: invalid settings, edits blocked"       "$w" "$(file_op "$badpool/README.md")"
CLAUDE_ROLE=integrator  expect 0 "fail closed: the settings file itself may be fixed" "$w" "$(file_op "$badpool/.claude/multi-agent-herdr.json")"
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
: > "$FAKE_LOG"; claim_in "$wt1" w2:p1 CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME=integrator-proj-1; status=$?
check "claim: pool member takes its name" [ "$status:$(cat "$FAKE_LOG")" == "0:rename w2:p1 integrator-proj-1" ]
claim_in "$wt1" w2:p1 CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME=integrator-proj-9; status=$?
check "claim: a name outside the pool is refused" [ "$status" == 1 ]
claim_in "$proj" w1:p1 CLAUDE_ROLE=integrator; status=$?
check "claim: pool mode has no single integrator" [ "$status" == 1 ]
claim_in "$single" w1:p1 CLAUDE_ROLE=coordinator; status=$?
check "claim: no coordinator in single mode" [ "$status" == 1 ]
agents coordinator-proj w1:p1 idle "$proj"  integrator-proj-1 w2:p1 idle "$wt1"
claim_in "$wt1" w2:p1 CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME=integrator-proj-1; status=$?
check "claim: already named pool member" [ "$status" == 0 ]

ssi="$hooks/session-start-integrator.sh"
ss() {  # ss <cwd> [env...]: the hook's additionalContext
    local dir="$1"; shift
    # A here-string, not a pipe: a hook that exits without reading stdin would SIGPIPE jq.
    env HERDR_ENV=1 "$@" "$ssi" 2>/dev/null \
        <<<"$(jq -nc --arg d "$dir" '{cwd: $d, hook_event_name: "SessionStart", source: "startup"}')" \
        | jq -r '.hookSpecificOutput.additionalContext // empty'
}
out=$(ss "$wt1" CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME=integrator-proj-1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1)
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
echo '{"integrators": {"max": 8}}' > "$psr/.claude/multi-agent-herdr.json"
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
owner_file="$(git -C "$psr" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/claims/pr-42/owner.json"
jq '.heartbeat = 0' "$owner_file" > "$owner_file.new" && mv "$owner_file.new" "$owner_file"
check "pool-state: an expired heartbeat is re-claimed" as_m "$third" claim 42 --owner "$(mem "$third")"
check "pool-state: release by its owner"   as_m "$third" release 42 --owner "$(mem "$third")"
check "pool-state: release of an unclaimed PR" as_m "$third" release 42 --owner "$(mem "$third")"
check "pool-state: no .stale-pr-* left behind" \
    bash -c '! ls -A "$1" | grep -q "^\.stale-"' _ "$(git -C "$psr" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/claims"
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
    exits 3 env MULTI_AGENT_HERDR_MISSING_GRACE=1 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w2:p9 HERDR_PANE_ID=w2:p9 "$2" claim 43 --owner "$3"' _ "$psr" "$ps" "$(mem 2)"
members 1 2   # back: the mark is cleared
psq claims >/dev/null
sleep 1.2; members 2   # missing again, more than the grace after the first glitch
check "pool-state: a second glitch after a reappearance starts a new grace" \
    exits 3 env MULTI_AGENT_HERDR_MISSING_GRACE=1 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w2:p9 HERDR_PANE_ID=w2:p9 "$2" claim 43 --owner "$3"' _ "$psr" "$ps" "$(mem 2)"
sleep 1.2
check "pool-state: an owner missing past the grace loses it" \
    env MULTI_AGENT_HERDR_MISSING_GRACE=1 bash -c 'cd "$1" && HERDR_ENV=1 FAKE_PANE=w2:p9 HERDR_PANE_ID=w2:p9 "$2" claim 43 --owner "$3" >/dev/null' _ "$psr" "$ps" "$(mem 2)"
# Eight members race for one stale claim: exactly one takes it (claims/.lock).
members 1 2 3 4 5 6 7 8
as_m 1 claim 44 --owner "$(mem 1)" >/dev/null
f44="$(git -C "$psr" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/claims/pr-44/owner.json"
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
          state: "OPEN", isCrossRepository: false,
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
    out=$(cd "$wt1" && env CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME="$me" HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 \
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

make_pr 2 feat/fail fail.txt boom
integrate 2
check "integrate-pr: a failed verification bounces (exit 4)" bash -c '[[ $1 == 4 && "$2" == *"fail.txt is present"* && "$2" == *"RESULT verify-failed"* ]]' _ "$rc" "$out"
check "integrate-pr: the worktree is clean after a bounce" clean_wt
check "integrate-pr: nothing landed"                       not on_main fail.txt
check "integrate-pr: the bounce is recorded"              [ "$(jq -r .head "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/bounced/pr-2.json")" == "$(git -C "$origin" rev-parse refs/heads/feat/fail)" ]

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

make_pr 10 feat/ten src/ten.txt ten
out=$(cd "$wt1" && env CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME="$me" HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses a PR it did not claim (exit 2)" bash -c '[[ $1 == 2 && "$2" == *"not claimed"* ]]' _ "$rc" "$out"
out=$(cd "$proj" && env CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME="$me" HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses the main worktree in pool mode (exit 2)" [ "$rc" == 2 ]
out=$(cd "$wt1" && env CLAUDE_ROLE=coordinator "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses the coordinator (exit 1)" [ "$rc" == 1 ]
(cd "$proj" && HERDR_ENV=1 FAKE_PANE=w2:p1 HERDR_PANE_ID=w2:p1 "$ps" claim 10 --owner "$me" >/dev/null)
out=$(cd "$wt1" && env CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME="$me" HERDR_ENV=1 FAKE_PANE=w9:p9 HERDR_PANE_ID=w9:p9 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses a pane whose herdr agent is not \$me (exit 2)" \
    bash -c '[[ $1 == 2 && "$2" == *"herdr agent is"* ]]' _ "$rc" "$out"
agents "$me" w2:p1 idle "$wt1"  foo w8:p1 idle "$wt1"
out=$(cd "$wt1" && env CLAUDE_ROLE=integrator MULTI_AGENT_HERDR_NAME=foo HERDR_ENV=1 FAKE_PANE=w8:p1 HERDR_PANE_ID=w8:p1 "$ipr" 10 2>&1); rc=$?
check "integrate-pr: refuses an agent outside the pool, even named in the env (exit 2)" \
    bash -c '[[ $1 == 2 && "$2" == *"not a member of the integrator pool"* ]]' _ "$rc" "$out"
agents "$me" w2:p1 idle "$wt1"
# The claim changes hands while the PR is verified: nothing is pushed.
cat > "$work/hook-steal.sh" <<HOOK
#!/usr/bin/env bash
f="\$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/claims/pr-10/owner.json"
jq '.owner = "integrator-proj-2"' "\$f" > "\$f.new" && mv "\$f.new" "\$f"
HOOK
chmod +x "$work/hook-steal.sh"; export CHECK_HOOK="$work/hook-steal.sh"
before=$(git -C "$origin" rev-parse main)
integrate 10
check "integrate-pr: a claim lost during the verification stops the push (exit 10)" \
    bash -c '[[ $1 == 10 && "$2" == *"claim-lost"* && "$(git -C "$3" rev-parse main)" == "$4" ]]' _ "$rc" "$out" "$origin" "$before"
check "integrate-pr: a lost claim stays with its new owner" \
    [ "$(cd "$proj" && "$ps" claims | awk -F'\t' '$1 == 10 { print $2 }')" == integrator-proj-2 ]
rm -rf "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/claims/pr-10"   # the test's own takeover
# herdr stops confirming the pane's agent while the PR is verified: nothing is pushed (exit 11).
cat > "$work/hook-identity.sh" <<HOOK
#!/usr/bin/env bash
jq '.result.agents |= map(if .pane_id == "w2:p1" then .name = "intruder" else . end)' "$FAKE_AGENTS" > "$FAKE_AGENTS.new"
mv "$FAKE_AGENTS.new" "$FAKE_AGENTS"
HOOK
chmod +x "$work/hook-identity.sh"; export CHECK_HOOK="$work/hook-identity.sh"
rm -rf "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/claims/pr-10"
before=$(git -C "$origin" rev-parse main)
integrate 10
check "integrate-pr: identity lost under the lock stops the push (exit 11)" \
    bash -c '[[ $1 == 11 && "$2" == *"identity-refused"* && "$(git -C "$3" rev-parse main)" == "$4" ]]' _ "$rc" "$out" "$origin" "$before"
agents "$me" w2:p1 idle "$wt1"
rm -rf "$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr/claims/pr-10"
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
    headRefOid: $h, baseRefName: "main", state: "OPEN", isCrossRepository: false}' > "$FAKE_GH/pr-1.json"
out=$(cd "$single" && env CLAUDE_ROLE=integrator "$ipr" 1 2>&1); rc=$?
check "integrate-pr: single mode merges in the main worktree" \
    bash -c '[[ $1 == 0 ]] && git -C "$2" cat-file -e main:s.txt && [[ "$(git -C "$3" rev-parse main)" == "$(git -C "$2" rev-parse main)" ]]' _ "$rc" "$sorigin" "$single"

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
check "resource-board: flags agents over the sessions guideline" bash -c '[[ "$1" == *"Live herdr agents: 3 (guideline for this machine: 2) - **over the guideline**"* ]]' _ "$sheet"
check "resource-board: marks the note of an agent that is gone" bash -c '[[ "$1" == *"| ghost (gone) |"* ]]' _ "$sheet"
check "resource-board: lists idle and done agents as candidates to close" \
    bash -c '[[ "$1" == *"- a2 - idle"* && "$1" == *"- a3 - done"* && "$1" != *"- a1 - working"* ]]' _ "$sheet"
"$board" prune >/dev/null
check "resource-board: prune drops gone agents, keeps live ones and humans' lines" \
    bash -c '[[ ! -e "$1/board/ghost.json" && -e "$1/board/a1.json" && -e "$1/board/me-shell.json" ]]' _ "$MULTI_AGENT_HERDR_RESOURCES_DIR"
"$board" clear --as a1 >/dev/null
check "resource-board: clear removes your own line" not test -e "$MULTI_AGENT_HERDR_RESOURCES_DIR/board/a1.json"
check "resource-board: refuses a name that is not a file name" exits 1 "$board" note x --as "../etc"
check "resource-board: refuses a non-numeric estimate" exits 1 "$board" note x --gb lots --as a2
budget 4
check "resource-board: within the guideline, no flag" bash -c '[[ "$("$1" show)" != *"over the guideline"* ]]' _ "$board"
echo '{"heavy_slots": 0}' > "$MULTI_AGENT_HERDR_RESOURCES_CONFIG"
check "resource-budget: rejects an invalid limit" exits 1 "$rb" limits
echo '{"heavy_slot": 2}' > "$MULTI_AGENT_HERDR_RESOURCES_CONFIG"
check "resource-budget: rejects an unknown key" exits 1 "$rb" limits

# The queue: limits re-read on every retry, priority order, lowered limits, interruptions.
slots() { printf '{"heavy_slots": %s, "light_slots": 1, "sessions_guideline": 50, "low_memory_gb": 0}\n' "$1" > "$MULTI_AGENT_HERDR_RESOURCES_CONFIG"; }
until_true() { for _ in $(seq 1 100); do "$@" && return 0; sleep 0.1; done; return 1; }
queued() { [[ $(ls "$MULTI_AGENT_HERDR_RESOURCES_DIR/queue-heavy" 2>/dev/null | wc -l) -ge $1 ]]; }
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
    bash -c '[[ "$("$1" run --pool light -- sh -c "echo \$MULTI_AGENT_HERDR_SLOT_COUNT")" == 1 ]]' _ "$rb"
"$rb" run --label w2 -- true 2>/dev/null & waiter=$!
until_true queued 1
echo '{"heavy_slots": ' > "$MULTI_AGENT_HERDR_RESOURCES_CONFIG"   # half written
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
echo '{"verify": {"check_env": {"SCOPE": "fast"}, "docs_only_paths": ["docs/*"], "docs_only_env": {"DOCS": "1"}}}' > "$vm/.claude/multi-agent-herdr.json"
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
echo '{"verify": {"check_env": {"CLAUDE_ROLE": "integrator"}}}' > "$vm/.claude/multi-agent-herdr.json"
check "project-config: refuses an identity variable in verify.check_env" exits 1 "$scripts/project-config.py" --root "$vm"
echo '{"verify": {"check_env": {"SCOPE": 1}}}' > "$vm/.claude/multi-agent-herdr.json"
check "project-config: refuses a non-string check variable" exits 1 "$scripts/project-config.py" --root "$vm"
echo '{}' > "$vm/.claude/multi-agent-herdr.json"
hold h5; until_true held 1
(cd "$vm" && env VM_OUT="$work/vm-out" "$scripts/verify-merge.sh" >/dev/null 2>&1) & vmpid=$!
until_true queued 1
kill -TERM "$(jq -r .pid "$MULTI_AGENT_HERDR_RESOURCES_DIR"/queue-heavy/*.json)"; wait "$vmpid"; rc=$?
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
out=$(cd "$proj" && env CLAUDECODE=1 CLAUDE_ROLE=coordinator HERDR_ENV=1 MULTI_AGENT_HERDR_NAME=coordinator-proj "$pool" spawn 2 2>&1); status=$?
log=$(cat "$FAKE_LOG")
check "pool spawn: exit 0"                                  [ "$status" == 0 ]
check "pool spawn: a detached verify worktree at origin/main" \
    bash -c '! git -C "$1" symbolic-ref -q HEAD && [[ "$(git -C "$1" rev-parse HEAD)" == "$(git -C "$2" rev-parse main)" ]]' _ "$wt2" "$origin"
check "pool spawn: its own workspace with the role in its env" \
    bash -c '[[ "$1" == *"workspace-create --cwd $2 --label integrator-proj-2"*"CLAUDE_ROLE=integrator"*"MULTI_AGENT_HERDR_NAME=integrator-proj-2"* ]]' _ "$log" "$wt2"
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
check "cleanup: clears the agent's resource-board note" not test -e "$MULTI_AGENT_HERDR_RESOURCES_DIR/board/donea.json"
check "cleanup: refuses a branch without a merged PR, even one with no commits yet (exit 3)" exits 3 cwi feat/dev1
# A branch name reused after its PR merged: the merged PR's head is not this tip.
jq '.[0].headRefName = "feat/dev2" | .[0].headRefOid = "0000000000000000000000000000000000000000"' "$FAKE_GH/list.json" > "$FAKE_GH/list.new" \
    && mv "$FAKE_GH/list.new" "$FAKE_GH/list.json"
check "cleanup: a reused branch name is not 'merged' (exit 3)" exits 3 cwi feat/dev2
check "cleanup: refuses a protected branch (exit 1)" exits 1 cwi main
check "cleanup: refuses a Claude session that is not the dispatcher (exit 1)" \
    exits 1 env CLAUDECODE=1 CLAUDE_ROLE= bash -c 'cd "$1" && "$2" --list' _ "$proj" "$cw"
unset FAKE_PANES; echo '[]' > "$FAKE_GH/list.json"

echo
echo "$fails failure(s)"
exit "$fails"
