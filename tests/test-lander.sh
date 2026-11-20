#!/usr/bin/env bash
# Smoke tests for the lander (plugin/scripts/land.py, docs/lander.md): the gates (draft, CI,
# approvals, risk:high, base-red), landing in order, conflicts and red checks as counted
# bounces up to needs-human, a base that moves during the check, a head that moves after the
# gates, dry runs and a dirty tree. Part of herdr-agent-pool.
#
# Usage: tests/test-lander.sh      (exit code = number of failed cases)
#
# Everything runs in a throwaway repository with a bare `origin` and a stateful fake `gh`
# (its state is one JSON file: pull requests, labels, reviews, checks, comments, issues);
# nothing touches GitHub. The project's scripts/check.sh counts its runs ($CHECK_COUNT), runs
# the script $CHECK_HOOK once (then deletes it) and fails when fail.txt exists. Needs git, jq and python3.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
land="$root/plugin/scripts/land.py"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CHECK_COUNT CHECK_HOOK

base="$root/.test-work-lander"
case "$root/" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|"${TMPDIR:-/nonexistent}"*)
        base="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-agent-pool-test-work-lander" ;;
esac
mkdir -p "$base" && work=$(mktemp -d "$base/run.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd -P)
export GIT_CEILING_DIRECTORIES="$work"
fails=0

check() {  # check <description> <command...>: ok when the command succeeds
    local desc="$1"; shift
    if "$@"; then echo "ok    $desc"; else echo "FAIL  $desc"; fails=$((fails + 1)); fi
}
not() { ! "$@"; }

# Fake gh -------------------------------------------------------------------------------------
fake="$work/bin"; mkdir -p "$fake"
export FAKE_GH_STATE="$work/gh-state.json"
cat > "$fake/gh" <<'FAKE'
#!/usr/bin/env python3
"""Fake gh over $FAKE_GH_STATE: pr list/view/comment/edit and issue list."""
import json, os, sys
path = os.environ["FAKE_GH_STATE"]
state = json.load(open(path))
args = sys.argv[1:]
def opt(name, many=False):
    vals = [args[i + 1] for i, a in enumerate(args) if a == name]
    return vals if many else (vals[0] if vals else None)
def names(item):
    return {l["name"] for l in item.get("labels", [])}
cmd = " ".join(args[:2])
if cmd == "pr list":
    out = [{"number": p["number"], "createdAt": p["createdAt"]} for p in state["prs"].values()
           if p["state"] == "OPEN" and p["baseRefName"] == opt("--base") and opt("--label") in names(p)
           and not p.get("hidden")]
    print(json.dumps(out))
elif cmd == "issue list":
    print(json.dumps([{"number": i["number"]} for i in state["issues"] if opt("--label") in names(i)]))
elif cmd == "pr view":
    pr = state["prs"].get(args[2])
    if pr is None:
        sys.exit("no pull requests found")
    print(json.dumps(pr))
elif cmd == "repo view":
    print(state.get("default", "main"))
elif cmd == "issue close":
    state.setdefault("closed", []).append(int(args[2]))
elif cmd == "pr comment":
    state["prs"][args[2]]["comments"].append({"body": sys.stdin.read()})
elif cmd == "pr edit":
    pr = state["prs"][args[2]]
    for name in opt("--add-label", True):
        pr["labels"].append({"name": name})
    for name in opt("--remove-label", True):
        pr["labels"] = [l for l in pr["labels"] if l["name"] != name]
else:
    sys.exit(f"fake gh: unsupported {args}")
json.dump(state, open(path, "w"))
FAKE
chmod +x "$fake/gh"
export PATH="$fake:$PATH"

# Repositories --------------------------------------------------------------------------------
origin="$work/origin.git" proj="$work/proj" dev="$work/dev" pusher="$work/pusher"
git init --quiet --bare -b main "$origin"
git init --quiet -b main "$proj"
mkdir -p "$proj/scripts"
cat > "$proj/scripts/check.sh" <<'CHECK'
#!/usr/bin/env bash
[[ -n "${CHECK_COUNT:-}" ]] && echo run >> "$CHECK_COUNT"
if [[ -n "${CHECK_HOOK:-}" && -f "$CHECK_HOOK" ]]; then bash "$CHECK_HOOK"; rm -f "$CHECK_HOOK"; fi
[[ "${HERDR_AGENT_POOL_LAND:-}" == 1 ]] || { echo "not run by the lander"; exit 9; }
[[ -f mutate.txt ]] && echo changed >> README.md
if [[ -f fail.txt ]]; then echo "FAILED test_fail"; exit 1; fi
echo "all green"
CHECK
chmod +x "$proj/scripts/check.sh"
echo readme > "$proj/README.md"
git -C "$proj" add -A && git -C "$proj" commit --quiet -m init
git -C "$proj" remote add origin "$origin" && git -C "$proj" push --quiet origin main
git clone --quiet "$origin" "$dev"
git clone --quiet "$origin" "$pusher"
echo '{"prs": {}, "issues": []}' > "$FAKE_GH_STATE"

gh_set() {  # gh_set <jq expression>: change the fake GitHub state
    local tmp="$FAKE_GH_STATE.tmp"
    jq "$1" "$FAKE_GH_STATE" > "$tmp" && mv "$tmp" "$FAKE_GH_STATE"
}
gh_get() { jq -r "$1" "$FAKE_GH_STATE"; }

make_pr() {  # make_pr <N> <file> <content> [label...]: branch pr-N from origin/main, queued,
             # CI green and approved on its head by a collaborator
    local n="$1" file="$2" content="$3"; shift 3
    git -C "$dev" fetch --quiet origin && git -C "$dev" checkout --quiet -B "pr-$n" origin/main
    printf '%s\n' "$content" >> "$dev/$file"
    git -C "$dev" add -A && git -C "$dev" commit --quiet -m "change for #$n"
    git -C "$dev" push --quiet origin "pr-$n" "pr-$n:refs/pull/$n/head"
    local head; head=$(git -C "$dev" rev-parse HEAD)
    local labels; labels=$(printf '%s\n' queue "$@" | jq -R '{name: .}' | jq -s .)
    gh_set ".prs[\"$n\"] = {number: $n, title: \"PR $n\", body: \"Summary\n\nCloses #$((n + 100))\n\",
        headRefName: \"pr-$n\", headRefOid: \"$head\", baseRefName: \"main\", state: \"OPEN\",
        isDraft: false, isCrossRepository: false, createdAt: \"2026-11-14T10:$(printf %02d "$n"):00Z\",
        labels: $labels, comments: [],
        statusCheckRollup: [{__typename: \"CheckRun\", name: \"ci\", status: \"COMPLETED\", conclusion: \"SUCCESS\"}],
        reviews: [{author: {login: \"reviewer-app\"}, authorAssociation: \"NONE\", state: \"APPROVED\", commit: {oid: \"$head\"}}]}"
}
human_approves() {  # human_approves <N>
    gh_set ".prs[\"$1\"].reviews += [{author: {login: \"owner\"}, authorAssociation: \"OWNER\",
        state: \"APPROVED\", commit: {oid: .prs[\"$1\"].headRefOid}}]"
}
push_main() {  # push_main <file> <content>: someone else's commit lands on origin/main
    git -C "$pusher" fetch --quiet origin && git -C "$pusher" checkout --quiet -B main origin/main
    printf '%s\n' "$2" >> "$pusher/$1"
    git -C "$pusher" add -A && git -C "$pusher" commit --quiet -m "main: $1" && git -C "$pusher" push --quiet origin main
}
lander() {  # lander [args...]: run land.py in the project; sets out, rc
    export CHECK_COUNT="$work/count"; : > "$CHECK_COUNT"
    out=$(cd "$proj" && python3 "$land" --base main --approval "${APPROVAL:-review}" --bot reviewer-app "$@" 2>&1); rc=$?
    unset CHECK_HOOK
}
runs() { wc -l < "$work/count" | tr -d ' '; }
on_main() { git -C "$origin" cat-file -e "main:$1" 2>/dev/null; }
remote_branch() { git -C "$origin" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
has_label() { [[ $(gh_get "[.prs[\"$1\"].labels[].name] | index(\"$2\") != null") == true ]]; }
said() { [[ "$out" == *"$1"* ]]; }
last_comment() { gh_get ".prs[\"$1\"].comments[-1].body // \"\""; }

# Cases ---------------------------------------------------------------------------------------
make_pr 1 one.txt one
lander
check "merges a green, approved PR (exit 0)"         said "LAND #1 merged"
check "the PR's file is on origin/main"              on_main one.txt
check "the head branch is deleted"                   not remote_branch pr-1
check "the merge commit carries the closing line"    bash -c "git -C '$origin' log -1 --format=%B main | grep -q 'Closes #101'"
check "the merge is a merge commit (--no-ff)"        bash -c "[[ \$(git -C '$origin' log -1 --format=%P main | wc -w) -eq 2 ]]"
check "the check ran once, as the lander"            [ "$(runs)" = 1 ]
gh_set '.prs["1"].state = "MERGED"'

make_pr 3 three.txt three
make_pr 2 two.txt two
lander
check "lands oldest first"                           bash -c "[[ \$(grep -o 'LAND #[0-9]' <<<'$out' | tr -d '\n') == 'LAND #2LAND #3' ]]"
check "both PRs are on main"                         bash -c "git -C '$origin' cat-file -e main:two.txt && git -C '$origin' cat-file -e main:three.txt"
gh_set '.prs["2"].state = "MERGED" | .prs["3"].state = "MERGED"'

make_pr 4 four.txt four
gh_set '.prs["4"].statusCheckRollup[0].status = "IN_PROGRESS" | .prs["4"].statusCheckRollup[0].conclusion = ""'
lander
check "pending CI: waits"                            said "LAND #4 wait CI is still running"
check "pending CI: stays queued"                     has_label 4 queue
check "pending CI: nothing merged"                   not on_main four.txt
gh_set '.prs["4"].statusCheckRollup += [{__typename: "StatusContext", context: "x", state: "FAILURE"}] | .prs["4"].statusCheckRollup[0] |= (.status = "COMPLETED" | .conclusion = "SUCCESS")'
lander
check "red CI: leaves the queue"                     not has_label 4 queue
check "red CI: comment, no bounce count"             bash -c "[[ \"\$1\" == *'CI failed'* && \"\$1\" != *'lander bounce'* ]]" _ "$(last_comment 4)"
gh_set '.prs["4"].state = "CLOSED"'

make_pr 5 five.txt five
gh_set '.prs["5"].reviews[0].commit.oid = "0000000"'
lander
check "approval of an older commit does not count"   said "LAND #5 unqueued no approval of the head commit"
gh_set '.prs["5"].state = "CLOSED"'

make_pr 6 six.txt six
gh_set '.prs["6"].reviews += [{author: {login: "owner"}, authorAssociation: "OWNER", state: "CHANGES_REQUESTED", commit: {oid: .prs["6"].headRefOid}}]'
lander
check "changes requested by anyone blocks"           said "LAND #6 unqueued changes are requested"
gh_set '.prs["6"].state = "CLOSED"'

make_pr 7 seven.txt seven risk:high
lander
check "risk:high with only the bot's approval"       said "LAND #7 unqueued risk:high needs a person"
gh_set '.prs["7"].labels += [{name: "queue"}]'
human_approves 7
lander
check "risk:high with a person's approval lands"     said "LAND #7 merged"
gh_set '.prs["7"].state = "MERGED"'

make_pr 8 eight.txt eight
gh_set '.prs["8"].isDraft = true'
lander
check "a draft leaves the queue"                     said "LAND #8 unqueued the pull request is a draft"
gh_set '.prs["8"].state = "CLOSED"'

# Bounces: conflict, then a red check up to needs-human.
make_pr 9 shared.txt from-pr
push_main shared.txt from-main
lander
check "conflict: bounced"                            said "LAND #9 bounced conflict"
check "conflict: out of the queue"                   not has_label 9 queue
check "conflict: counted comment (1 of 2)"           bash -c "[[ \"\$1\" == *'lander bounce'*'bounce 1 of 2: merge conflict'* ]]" _ "$(last_comment 9)"
check "conflict: the local tree is clean"            bash -c "[[ -z \$(git -C '$proj' status --porcelain --untracked-files=no) ]]"
gh_set '.prs["9"].state = "CLOSED"'

make_pr 10 fail.txt boom
for round in 1 2; do
    gh_set '.prs["10"].labels += [{name: "queue"}]'
    lander
    check "red check, round $round: bounced"          said "LAND #10 bounced red"
done
check "red check: the log tail is in the comment"   bash -c "[[ \"\$1\" == *'FAILED test_fail'* ]]" _ "$(last_comment 10)"
gh_set '.prs["10"].labels += [{name: "queue"}]'
lander
check "third bounce: needs-human"                   said "LAND #10 needs-human red"
check "third bounce: labelled needs-human"          has_label 10 needs-human
check "red check: nothing landed"                   not on_main fail.txt
gh_set '.prs["10"].state = "CLOSED"'

make_pr 11 mutate.txt x
lander
check "a check that edits tracked files: bounced"   said "LAND #11 bounced red"
gh_set '.prs["11"].state = "CLOSED"'

# The base moves while the candidate is checked: merged again on the new base, checked again.
make_pr 12 twelve.txt twelve
export CHECK_HOOK="$work/hook.sh"
echo "cd '$pusher' && git fetch --quiet origin && git checkout --quiet -B main origin/main && echo m >> moved.txt && git add -A && git commit --quiet -m moved && git push --quiet origin main" > "$CHECK_HOOK"
lander
check "base moved: merged on the second attempt"    said "LAND #12 merged"
check "base moved: the check ran twice"             [ "$(runs)" = 2 ]
check "base moved: both changes are on main"        bash -c "git -C '$origin' cat-file -e main:moved.txt && git -C '$origin' cat-file -e main:twelve.txt"
gh_set '.prs["12"].state = "MERGED"'

# The head moves after the gates read it: no landing of an unreviewed commit.
make_pr 13 thirteen.txt thirteen
git -C "$dev" commit --quiet --allow-empty -m later && git -C "$dev" push --quiet -f origin "pr-13:refs/pull/13/head"
lander
check "head moved after the gates: retry later"     said "LAND #13 retry-later"
check "head moved: not merged"                      not on_main thirteen.txt
check "head moved: still queued"                    has_label 13 queue
gh_set '.prs["13"].state = "CLOSED"'

# A red base: only the fix lands.
gh_set '.issues += [{number: 900, labels: [{name: "base-red"}]}]'
make_pr 14 fourteen.txt fourteen
make_pr 15 fifteen.txt fifteen fixes-base-red
lander
check "base red: an ordinary PR waits"              said "LAND #14 wait the base is red"
check "base red: the fix lands"                     said "LAND #15 merged"
gh_set '.issues = [] | .prs["15"].state = "MERGED"'

check "default base: the lander closes no issue"   bash -c "[[ \$(jq '.closed // [] | length' '$FAKE_GH_STATE') == 0 ]]"

lander --dry-run
check "dry run: reports what it would land"         said "LAND #14 would-land"
check "dry run: nothing merged"                     not on_main fourteen.txt
check "dry run: the check never ran"                [ "$(runs)" = 0 ]
lander
check "after the base turns green, #14 lands"       said "LAND #14 merged"

# A base that is not the default branch: GitHub ignores closing keywords there, so the lander
# closes the issues itself.
gh_set '.default = "develop"'
make_pr 16 sixteen.txt sixteen
gh_set '.prs["16"].body = "Fixes #116, see #5, resolves #117\nCloses other/repo#7\n"'
lander
check "non-default base: merged"                    said "LAND #16 merged"
check "non-default base: closes the named issues"   bash -c "[[ \$(jq -c '.closed' '$FAKE_GH_STATE') == '[116,117]' ]]"
gh_set '.default = "main" | .prs["16"].state = "MERGED"'

# GitHub's label search lags: a --pr from the event is considered even when the list misses it.
make_pr 17 seventeen.txt seventeen
gh_set '.prs["17"].hidden = true'
lander --pr 17
check "--pr: lands a PR the label search missed"    said "LAND #17 merged"
make_pr 18 eighteen.txt eighteen
gh_set '.prs["18"].labels = []'
lander --pr 18
check "--pr: skips a PR that is not queued"         said "LAND #18 skip"
check "--pr: nothing merged for it"                 not on_main eighteen.txt
gh_set '.prs["17"].state = "MERGED" | .prs["18"].state = "CLOSED"'

# --approval label (the default): the queue label is the approval; requested changes and forks
# still block.
make_pr 19 nineteen.txt nineteen
gh_set '.prs["19"].reviews = []'
APPROVAL=label lander
check "label mode: lands without a review"          said "LAND #19 merged"
make_pr 20 twenty.txt twenty risk:high
gh_set '.prs["20"].reviews = [{author: {login: "owner"}, authorAssociation: "OWNER", state: "CHANGES_REQUESTED", commit: {oid: .prs["20"].headRefOid}}]'
APPROVAL=label lander
check "label mode: requested changes still block"   said "LAND #20 unqueued changes are requested"
make_pr 21 twentyone.txt twentyone
gh_set '.prs["21"].isCrossRepository = true'
APPROVAL=label lander
check "a PR from a fork leaves the queue"           said "LAND #21 unqueued it comes from a fork"
gh_set '.prs["19"].state = "MERGED" | .prs["20"].state = "CLOSED" | .prs["21"].state = "CLOSED"'

# --watch: keeps draining; a PR queued after the first pass lands in a later one.
make_pr 22 twentytwo.txt twentytwo
gh_set '.prs["22"].labels = []'
(cd "$proj" && exec python3 "$land" --base main --watch 0.3 > "$work/watch.log" 2>&1) &
watcher=$!
sleep 1; gh_set '.prs["22"].labels = [{name: "queue"}]'
for _ in $(seq 1 50); do on_main twentytwo.txt && break; sleep 0.2; done
kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
check "--watch: lands a PR queued while it runs"    on_main twentytwo.txt
check "--watch: quiet while the queue is empty"     bash -c "[[ \$(grep -c 'LANDER done' '$work/watch.log') -le 2 ]]"
gh_set '.prs["22"].state = "MERGED"'
git -C "$proj" checkout --quiet --detach 2>/dev/null; git -C "$proj" reset --quiet --hard

echo dirty >> "$proj/README.md"
lander
check "a dirty working tree: exit 1"                [ "$rc" = 1 ]
git -C "$proj" checkout --quiet -- README.md

echo
if [[ $fails -eq 0 ]]; then echo "all lander tests passed"; else echo "$fails lander test(s) failed"; fi
exit "$fails"
