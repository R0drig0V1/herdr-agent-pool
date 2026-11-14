#!/usr/bin/env bash
# Install the herdr-agent-pool workflow into the git repository of the current directory.
#
# Part of herdr-agent-pool (ported from claude-code-multi-agent 0.1.0's install.sh; only the
# repository, plugin id and next steps differ).
#
# Usage (from inside the target repository):
#   curl -fsSL https://raw.githubusercontent.com/R0drig0V1/herdr-agent-pool/main/install.sh | bash
#   bash /path/to/herdr-agent-pool/install.sh [--dry-run] [--force]
#
# What it does:
# - Copies the project-owned files of template/ (CLAUDE.md, scripts/check.sh,
#   scripts/integrator.sh, scripts/coordinator.sh, .claude/prompts/{integrator,coordinator}.md,
#   docs/ indexes) into the repository.
#   Existing files are kept and listed, unless --force.
# - Enables the plugin for the project in .claude/settings.json: copied when absent, merged
#   with jq when present (the snippet is printed when jq is missing). An enabled old
#   multi-agent@claude-code-multi-agent plugin, which this one replaces, is set to false there:
#   both plugins' guards would run otherwise. So is multi-agent-herdr@claude-code-herdr, the
#   separate two-level plugin (also this plugin's id before the 2026-11 rename).
# - Appends the missing .gitignore lines.
# The plugin itself (skills, agents, hooks, worktree and verify scripts) is not copied: Claude
# Code installs it from the marketplace the settings point at, and updates it from there.
#
# Needs git and bash; jq to merge an existing settings.json.
set -euo pipefail

REPO_URL="https://github.com/R0drig0V1/herdr-agent-pool.git"
MARKETPLACE="herdr-agent-pool"
PLUGIN="herdr-agent-pool@${MARKETPLACE}"
OLD_PLUGINS=(
    "multi-agent@claude-code-multi-agent"   # the plugin this one replaces
    "multi-agent-herdr@claude-code-herdr"   # the two-level plugin: never both in one project
)

dry_run=false
force=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force) force=true ;;
        -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

target=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "error: run this inside the git repository to set up" >&2; exit 1; }

# Source of the template: this script's own checkout, or a fresh shallow clone when piped.
src=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    [[ -d "$here/template" ]] && src="$here"
fi
if [[ -z "$src" ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    git clone --quiet --depth 1 "$REPO_URL" "$tmp/src"
    src="$tmp/src"
fi

# An existing .claude/settings.json must be valid JSON before anything is copied: the merge
# below would otherwise abort halfway, after the template files were written.
settings="$target/.claude/settings.json"
if [[ -e "$settings" ]] && command -v jq >/dev/null 2>&1 && ! jq empty "$settings" 2>/dev/null; then
    echo "error: $settings is not valid JSON; fix it and rerun (nothing was written)" >&2
    exit 1
fi

copied=() skipped=()
do_copy() {  # do_copy <relative path>
    local rel="$1" dest="$target/$1"
    if [[ -e "$dest" ]] && ! $force; then
        skipped+=("$rel"); return
    fi
    copied+=("$rel")
    $dry_run && return
    mkdir -p "$(dirname "$dest")"
    cp -p "$src/template/$rel" "$dest"
}

while IFS= read -r rel; do
    [[ "$rel" == ".claude/settings.json" ]] && continue
    do_copy "$rel"
done < <(cd "$src/template" && find . -type f | sed 's|^\./||' | sort)

# .claude/settings.json: enable the marketplace and the plugin for the project, and turn the
# old plugin off. "Enabled" means enabledPlugins maps the plugin id to true (a `false` entry
# is merged to true). The old plugin is set to false, not removed, so the file records the
# switch; a rerun finds it false and changes nothing.
settings_note=""
if [[ ! -e "$settings" ]]; then
    do_copy ".claude/settings.json"
elif command -v jq >/dev/null 2>&1; then
    enabled() { jq -e --arg id "$1" '.enabledPlugins[$id] == true' "$settings" >/dev/null; }
    settings_note="merged the marketplace and plugin into it"
    enabled "$PLUGIN" && settings_note="already enables $PLUGIN"
    for old in "${OLD_PLUGINS[@]}"; do
        if enabled "$old"; then settings_note+="; disabled $old (replaced by $PLUGIN)"; fi
    done
    if ! $dry_run && [[ "$settings_note" != "already enables $PLUGIN" ]]; then
        olds=$(printf '%s\n' "${OLD_PLUGINS[@]}" | jq -R . | jq -s .)
        merged=$(jq -s --argjson olds "$olds" \
            '(.[0] * .[1]) | reduce $olds[] as $old (.;
                if .enabledPlugins[$old] == true then .enabledPlugins[$old] = false else . end)' \
            "$settings" "$src/template/.claude/settings.json")
        printf '%s\n' "$merged" > "$settings"
    fi
else
    settings_note="NOT changed (jq missing): add the keys below by hand"
fi
# settings.local.json is the user's own file: warn, do not edit it.
local_settings="$target/.claude/settings.local.json"
for old in "${OLD_PLUGINS[@]}"; do
    if [[ -f "$local_settings" ]] && command -v jq >/dev/null 2>&1 \
        && jq -e --arg id "$old" '.enabledPlugins[$id] == true' "$local_settings" >/dev/null 2>&1; then
        settings_note+="${settings_note:+; }WARNING: .claude/settings.local.json still enables $old: set it to false"
    fi
done

# .gitignore lines.
gitignore="$target/.gitignore"
added=()
for line in ".claude/settings.local.json" ".env"; do
    if ! grep -qxF "$line" "$gitignore" 2>/dev/null; then
        added+=("$line")
        $dry_run && continue
        # A last line without its newline would be glued to ours ("node_modules.env").
        if [[ -s "$gitignore" && -n "$(tail -c 1 "$gitignore")" ]]; then
            printf '\n' >> "$gitignore"
        fi
        printf '%s\n' "$line" >> "$gitignore"
    fi
done

$dry_run && echo "dry run: nothing was written" && echo
echo "herdr-agent-pool workflow -> $target"
for f in ${copied[@]+"${copied[@]}"}; do echo "  + $f"; done
for f in ${skipped[@]+"${skipped[@]}"}; do echo "  = $f (exists, kept; --force to overwrite)"; done
[[ -n "$settings_note" ]] && echo "  ~ .claude/settings.json: $settings_note"
for l in ${added[@]+"${added[@]}"}; do echo "  + .gitignore: $l"; done
if [[ "$settings_note" == NOT* ]]; then
    echo
    cat "$src/template/.claude/settings.json"
fi

cat <<EOF

Next steps:
  1. Fill in the TODOs of CLAUDE.md and put your lint/type/test commands in scripts/check.sh.
  2. Commit these files on main.
  3. Open Claude Code in the repository and trust the folder: it offers to install the
     plugin. Or install it explicitly:
       claude plugin marketplace add R0drig0V1/herdr-agent-pool
       claude plugin install $PLUGIN --scope project
     This plugin replaces multi-agent@claude-code-multi-agent, and must not run next to the
     two-level multi-agent-herdr@claude-code-herdr: the installer sets both to false in
     .claude/settings.json (by hand when jq is missing).
  4. Inside herdr, run /herdr-agent-pool:setup once, launch the integrator with
     scripts/integrator.sh, and start development agents from it with
     /herdr-agent-pool:dispatch <type>/<name> <task>.
     Many agents: add an "integrators" object to .claude/herdr-agent-pool.json and launch
     scripts/coordinator.sh instead (pool mode, docs/multi-integrator.md); set this
     machine's limits in ~/.config/herdr-agent-pool/resources.json.
EOF
