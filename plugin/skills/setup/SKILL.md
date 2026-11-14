---
name: setup
description: Check and, with the user's confirmation, install what the herdr-agent-pool plugin needs - the herdr binary, herdr's Claude integration and the project files - and detect the old multi-agent plugin enabled in the same project. Only when the user runs /herdr-agent-pool:setup.
disable-model-invocation: true
---

<!--
setup skill of the herdr-agent-pool plugin. User-invoked only (disable-model-invocation) and
never run from a hook. It checks first and changes anything only after an explicit
confirmation for each step. Install command from https://herdr.dev/agent-guide.md;
integration commands from `herdr integration` (herdr 0.9.5).
-->

# Setup

Check everything first, report, then ask before each change. Any "no" skips that step.

## 1. herdr binary

```bash
command -v herdr && herdr --version
herdr status          # client vs running server version, read-only
```

If `herdr` is missing, show the official installer and run it only after the user confirms
(offer to print the script for review first: `curl -fsSL https://herdr.dev/install.sh`):

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

Homebrew, mise, Nix and manual downloads: https://herdr.dev/tui/docs/install/. Never stop
or restart a running herdr server (`herdr server stop`) as part of setup.

## 2. Claude integration

```bash
herdr integration status | grep '^claude:'
```

`current` means done. If it says `not installed` or outdated, explain that it writes a hook
under `~/.claude/hooks/` (native session restore for Claude panes) and, after the user
confirms:

```bash
herdr integration install claude
```

## 3. The project (only inside a git repository)

```bash
root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
for f in "$root"/.claude/settings.json "$root"/.claude/settings.local.json; do
  [ -f "$f" ] && jq -r --arg f "$f" '.enabledPlugins // {} | to_entries[]
    | select(.key | test("^(multi-agent(-herdr)?|herdr-agent-pool)@")) | "\($f): \(.key) = \(.value)"' "$f"
done
common=$(git rev-parse --path-format=absolute --git-common-dir)
ls -d "$root"/.claude/multi-agent-herdr.json "$common"/multi-agent-herdr \
      ~/.config/multi-agent-herdr ~/.cache/multi-agent-herdr 2>/dev/null   # names before 2026-11
grep -rln -e '/multi-agent-herdr:' -e 'MULTI_AGENT_HERDR_' "$root"/CLAUDE.md "$root"/.claude/prompts \
      "$root"/scripts 2>/dev/null
ls "$root"/scripts/check.sh "$root"/scripts/integrator.sh "$root"/.claude/prompts/integrator.md \
   "$root"/scripts/coordinator.sh "$root"/.claude/prompts/coordinator.md
"${CLAUDE_PLUGIN_ROOT}/scripts/project-config.py" --root "$root"; echo "exit=$?"
```

- The settings (`.claude/herdr-agent-pool.json`): report `base_branch`,
  `integrator_name` and `mode`. In pool mode (`integrators` set) also report
  `coordinator_name` and the pool's names, and check that `scripts/coordinator.sh` and
  `.claude/prompts/coordinator.md` exist (the installer copies them; an older project needs
  them added, see the plugin's docs/migration-multi-integrator.md). A non-zero exit means the file is invalid: show the error. A project
  whose pull requests do not target `main` (an integration branch such as `dev`) or whose
  integrator has another herdr name needs this file; offer to write it and only write it
  after the user confirms the values.
- **`integrator_name` set to plain `integrator`** (the old default, written explicitly by
  earlier installs): herdr names are unique per server, so a second project with the same name
  cannot dispatch (`claim-integrator.sh` exits 3). Offer to remove the key, which gives the
  per-repository default `integrator-<repository>`, or to set another unique name. Change it
  only after the user confirms, and tell them the running integrator takes the new name the
  next time a session starts (the SessionStart hook) or it runs `dispatch` or `integrate`.

- This plugin not enabled, or project files missing: offer the installer from this plugin's
  repository (`install.sh --dry-run` first, then without it after the user confirms).
- **The old `multi-agent` plugin also enabled**: both plugins' hooks would run, and the old
  ones send sessions to `/multi-agent:worktree` + `EnterWorktree`, which this plugin replaces
  with `dispatch`. Show the user the `enabledPlugins` line to remove (or set to `false`) and
  change it only after they confirm.
- **Names from before 2026-11** (the plugin was `multi-agent-herdr@claude-code-herdr`; README,
  "Renamed from multi-agent-herdr"): the plugin no longer reads them. A project that only has
  `.claude/multi-agent-herdr.json` runs on the defaults (single mode), and old state or limits
  directories are ignored. Report each one found with its move from the README, and make the
  moves only after the user confirms, with every session of the project stopped.
  `multi-agent-herdr@claude-code-herdr` enabled may also be the separate two-level plugin:
  check which repository the `claude-code-herdr` marketplace entry names before changing it.

## 4. herdr config

No herdr configuration is required: agent placement (one workspace per agent) is done by
`dispatch`. Never edit `~/.config/herdr/config.toml` unless the user asks; if they do, show
the exact diff and get confirmation before writing.

## 5. Report

One line each: herdr version (client/server), Claude integration state, project state
(plugin enabled, project files, base branch, mode and the role names, old multi-agent enabled
or not), and what was installed or skipped.
