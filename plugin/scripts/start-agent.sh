#!/usr/bin/env bash
# Start a development agent: `herdr agent start <name> --kind claude --pane <pane>`, with the
# project's `agent_args` passed on to `claude` after `--`.
#
# Usage: start-agent.sh <name> <pane>     e.g. start-agent.sh user-login w3:p1
#
# Part of the herdr-agent-pool plugin; step 4 of the dispatch skill runs it. `agent_args`
# (.claude/herdr-agent-pool.json, scripts/project-config.py) defaults to no MCP servers and a
# short `--tools` list: every turn re-reads the start-up context, so tools an agent never uses
# cost tokens on every turn (docs/decisions/0011-lean-agent-start.md). `[]` starts `claude`
# with its own defaults (no `--`). It is a script, not shell code in SKILL.md, so that each
# setting reaches `claude` as one argument (spaces and commas included) and the skill carries
# no positional tokens (tests/check-skill-substitutions.py).
#
# The integrator and the coordinator are not started here: they keep every tool.
# Exit codes: 2 usage; 1 invalid settings; otherwise `herdr agent start`'s own (its output,
# e.g. `agent_not_ready`, is passed through unchanged). Runs under bash 3.2 (no mapfile).
set -euo pipefail

name="${1:-}" pane="${2:-}"
[[ -n "$name" && -n "$pane" && $# -eq 2 ]] || { echo "usage: start-agent.sh <name> <pane>" >&2; exit 2; }
dir=$(cd "$(dirname "$0")" && pwd)
# One argument per line; validation guarantees non-empty one-line items, so no output is [].
out=$("$dir/project-config.py" agent_args) || exit 1

args=()
if [[ -n "$out" ]]; then
    while IFS= read -r line; do args+=("$line"); done <<<"$out"
fi
if [[ ${#args[@]} -eq 0 ]]; then
    exec herdr agent start "$name" --kind claude --pane "$pane"
fi
exec herdr agent start "$name" --kind claude --pane "$pane" -- "${args[@]}"
