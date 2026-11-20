# 0011. Start development agents with a lean tool set

- Status: accepted, to be measured
- Date: 2026-11-19

## Context

About 97% of the tokens are cache reads ([docs/benchmark/](../benchmark/README.md)): every
turn reads the whole context again. A development agent's first turn already carries about
49,500 tokens, and it re-reads them on every turn (21 turns on average), so about 70% of a
development agent's cache reads are fixed start-up context. Most of it is Claude Code's
built-in tool definitions and the user's MCP servers, which the development workflow never
uses: the `commit` and `pr` skills and the brief need only the shell, file tools and skills.

## Evidence

One headless turn in a project checkout (`claude -p "Reply with the single word: ok"
--output-format json`), input and cache tokens of the first request:

| Arguments | Tokens |
|-----------|-------:|
| none (Claude Code's defaults) | 25,600-29,300 |
| `--strict-mcp-config` (no MCP servers) | 25,600 |
| `--tools "Bash,Read,Edit,Write,Glob,Grep,Skill,ToolSearch"` | 16,600 |
| both, with `AskUserQuestion` added to `--tools` | about 16,100 |

Tools are not equally cheap. Adding `TodoWrite` to the list gave 32,000 tokens, more than the
defaults. In a scratch repository (default 28,600, the lean list 15,300), adding `Agent` cost
about 4,300 tokens; `WebFetch` and `Monitor` about 600 each.

## Decision

The dispatcher starts each development agent through `start-agent.sh`, which passes the
project's `agent_args` to `claude`. The default is `--strict-mcp-config --tools
"Bash,Read,Edit,Write,Glob,Grep,Skill,ToolSearch,AskUserQuestion"`. A project changes the
list in `.claude/herdr-agent-pool.json`; `[]` gives Claude Code's defaults. The integrator
and the coordinator keep every tool: they review, use subagents and wait on background
commands.

## Alternatives

- **Claude Code's defaults** (before): every tool and MCP server, paid for on every turn of
  every development agent.
- **Only `--strict-mcp-config`**: saves nothing when the user has no MCP servers, and the
  built-in tools are the larger part.
- **A per-task tool list in the brief**: the brief arrives after the agent started, too late
  for `--tools`.

## Consequences

- A development agent has no `Agent` (no subagents, so no `code-reviewer`), no `WebFetch` or
  `WebSearch`, no `TodoWrite` and no `Monitor`. A project that needs one adds it to
  `agent_args`, after measuring its cost the same way: a tool's cost is not proportional to
  its name, as `TodoWrite` showed.
- Tool names change with Claude Code releases. An unknown name in `--tools` is not reported;
  re-measure after an upgrade.
- To measure: the next benchmark run's tokens per development-agent turn and its cache reads,
  against run 6. If a development agent stalls for a missing tool, the list is too short.
