#!/usr/bin/env bash
# Install the herdr-agent-pool workflow into the git repository of the current directory.
#
# Part of herdr-agent-pool (ported from claude-code-multi-agent 0.1.0's install.sh).
#
# Usage (from inside the target repository):
#   curl -fsSL https://raw.githubusercontent.com/R0drig0V1/herdr-agent-pool/main/install.sh | bash
#   bash /path/to/herdr-agent-pool/install.sh [--dry-run] [--force] [--no-plugin]
#
# What it does:
# - Copies the project-owned files of template/ (CLAUDE.md, scripts/check.sh,
#   scripts/integrator.sh, scripts/coordinator.sh, .claude/prompts/{integrator,coordinator}.md,
#   .claude/herdr-agent-pool.json, docs/ indexes) into the repository.
#   Existing files are kept and listed, unless --force.
# - Enables the plugin for the project in .claude/settings.json: copied when absent, merged
#   with jq when present (the snippet is printed when jq is missing). An enabled old
#   multi-agent@claude-code-multi-agent plugin, which this one replaces, is set to false there:
#   both plugins' guards would run otherwise. So is multi-agent-herdr@claude-code-herdr, the
#   separate two-level plugin (also this plugin's id before the 2026-11 rename).
# - Appends the missing .gitignore lines.
# - Installs the plugin for the project with the claude CLI, when `claude` is on PATH and the
#   plugin is not installed yet (--no-plugin skips it; the commands are printed otherwise).
#   When this machine already knows this repository as a marketplace with another name (a
#   machine set up before the rename), the CLI cannot add it again under the new name: the
#   installer asks before removing the old entry, and prints the commands when it may not.
# - Checks what the workflow needs on this machine (jq, python3, gh, herdr and herdr's Claude
#   integration) and reports what is missing. It never installs herdr. When herdr is present
#   without its Claude integration, it asks before running `herdr integration install claude`.
# Questions are read from the terminal, so they also work piped from curl; without a
# terminal, and in a dry run, nothing is asked and the commands are only printed.
# It never writes through a symbolic link or outside the repository: such files are reported
# and left alone.
# The plugin itself (skills, agents, hooks, worktree and verify scripts) is not copied: Claude
# Code installs it from the marketplace the settings point at, and updates it from there.
#
# Needs git and bash; jq to merge an existing settings.json.
set -euo pipefail

REPO_URL="https://github.com/R0drig0V1/herdr-agent-pool.git"
MARKETPLACE="herdr-agent-pool"
MARKETPLACE_REPO="R0drig0V1/herdr-agent-pool"
PLUGIN="herdr-agent-pool@${MARKETPLACE}"
OLD_PLUGINS=(
    "multi-agent@claude-code-multi-agent"   # the plugin this one replaces
    "multi-agent-herdr@claude-code-herdr"   # the two-level plugin: never both in one project
)

dry_run=false
force=false
install_plugin=true
tty=${HERDR_AGENT_POOL_TTY:-/dev/tty}   # where questions are asked (the tests point it at a file)
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force) force=true ;;
        --no-plugin) install_plugin=false ;;
        -h|--help)  # the header comment, up to the first line that is not a comment
            sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

target=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "error: run this inside the git repository to set up" >&2; exit 1; }

# Source of the template: this script's own checkout, or a fresh shallow clone when piped.
src=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # Only this repository's checkout: a project may have a template/ directory of its own.
    [[ -f "$here/template/CLAUDE.md" && -f "$here/plugin/skills/setup/SKILL.md" ]] && src="$here"
fi
if [[ -z "$src" ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    git clone --quiet --depth 1 "$REPO_URL" "$tmp/src"
    src="$tmp/src"
fi

# An existing .claude/settings.json must be a JSON object before anything is copied: the merge
# below would otherwise abort halfway, after the template files were written.
settings="$target/.claude/settings.json"
if [[ -e "$settings" ]] && command -v jq >/dev/null 2>&1 \
    && ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    echo "error: $settings is not a JSON object; fix it and rerun (nothing was written)" >&2
    exit 1
fi

# Never write through a symbolic link or outside the repository: a tracked link (CLAUDE.md ->
# somewhere else, scripts/ -> another directory) would send the files there.
target_real=$(cd "$target" && pwd -P)
refused=()
safe() {  # safe <relative path>: succeeds when writing $target/<path> stays inside the repository
    local rel="$1" dir real
    dir=$(dirname "$target/$rel")
    while [[ ! -d "$dir" ]]; do dir=$(dirname "$dir"); done
    real=$(cd "$dir" && pwd -P)
    if [[ -L "$target/$rel" ]] || [[ "$real" != "$target_real" && "$real" != "$target_real"/* ]]; then
        refused+=("$rel"); return 1
    fi
}

ask() {  # ask <question>: succeeds on a yes typed at the terminal. Never asks in a dry run.
    local answer=""
    $dry_run && return 1
    [[ -r "$tty" ]] || return 1
    [[ -t 1 || -n "${HERDR_AGENT_POOL_TTY:-}" ]] || return 1
    printf '%s [y/N] ' "$1" >&2
    read -r answer < "$tty" || answer=""
    [[ "$answer" == [yY]* ]]
}

copied=() skipped=()
do_copy() {  # do_copy <relative path>
    local rel="$1" dest="$target/$1"
    safe "$rel" || return 0
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
# old plugins off. "Enabled" means enabledPlugins maps the plugin id to true (a `false` entry
# is merged to true). An old plugin is set to false, not removed, so the file records the
# switch; a rerun finds it false and changes nothing.
settings_note=""
if [[ ! -e "$settings" && ! -L "$settings" ]]; then
    do_copy ".claude/settings.json"
elif ! safe ".claude/settings.json"; then
    settings_note="NOT changed (symbolic link or outside the repository): add the keys below by hand"
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
    safe ".gitignore" || break
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

# The plugin itself, through the claude CLI. "Installed" is a user-scope install (enabled for
# this project by .claude/settings.json) or a project-scope install of this repository; a
# project-scope install of another repository does not count.
#
# The marketplace must be registered under the name $MARKETPLACE: the plugin id carries it.
# A machine that knows this GitHub repository under another name (set up before the rename,
# or declared so in the user's settings) makes `claude plugin marketplace add` answer
# "already on disk" and add nothing, and the install then fails with "plugin not found".
# Only removing the old entry fixes that (checked with the CLI: the removal also drops the
# entry from the user's settings, and the add then registers the new name). Removing a
# marketplace also uninstalls the plugins installed from it, so it is done only after a yes.
plugin_note="" stale=""
have_jq=false
command -v jq >/dev/null 2>&1 && have_jq=true
if ! $install_plugin; then
    plugin_note="skipped (--no-plugin)"
elif ! command -v claude >/dev/null 2>&1; then
    plugin_note="NOT installed: claude is not on PATH"
elif $have_jq && claude plugin list --json 2>/dev/null \
    | jq -e --arg id "$PLUGIN" --arg t "$target" --arg tr "$target_real" \
        'any(.[]; .id == $id and ((.projectPath // $t) as $p | $p == $t or $p == $tr))' >/dev/null 2>&1; then
    plugin_note="already installed"
else
    have_marketplace=false
    if $have_jq; then
        markets=$(claude plugin marketplace list --json 2>/dev/null || true)
        jq -e --arg n "$MARKETPLACE" 'any(.[]; .name == $n)' <<<"$markets" >/dev/null 2>&1 \
            && have_marketplace=true
        $have_marketplace || stale=$(jq -r --arg n "$MARKETPLACE" --arg r "$MARKETPLACE_REPO" '
            ($r | ascii_downcase) as $r
            | .[] | select(.name != $n)
            | select(((.repo // "") | ascii_downcase) == $r
                     or ((.url // "") | ascii_downcase | test("github\\.com[:/]" + $r + "(\\.git)?/?$")))
            | .name' <<<"$markets" 2>/dev/null || true)
    fi
    if [[ -n "$stale" ]]; then
        stale_list=$(tr '\n' ' ' <<<"$stale")
        stale_list=${stale_list% }
        plugin_note="NOT installed: this machine knows $MARKETPLACE_REPO as marketplace \"$stale_list\", not \"$MARKETPLACE\""
        if ask "This machine knows $MARKETPLACE_REPO as marketplace \"$stale_list\", so the claude CLI cannot add it as \"$MARKETPLACE\".
Removing \"$stale_list\" also uninstalls, on this machine, the plugins installed from it.
Remove it now?"; then
            removed=true
            while IFS= read -r name; do
                (cd "$target" && claude plugin marketplace remove "$name") >/dev/null 2>&1 || removed=false
            done <<<"$stale"
            if $removed; then
                stale="" plugin_note=""
            else
                plugin_note="NOT installed: the claude CLI could not remove marketplace \"$stale_list\""
            fi
        fi
    fi
    if [[ -n "$stale" ]]; then
        :   # reported in plugin_note; the commands are printed in the next steps
    elif $dry_run; then
        plugin_note="would be installed with the claude CLI (project scope)"
    else
        if ! $have_marketplace; then
            (cd "$target" && claude plugin marketplace add "$MARKETPLACE_REPO") >/dev/null 2>&1 || true
        fi
        if cli_out=$(cd "$target" && claude plugin install "$PLUGIN" --scope project 2>&1); then
            plugin_note="installed (project scope)"
        else
            cli_out=$(tr -d '\033' <<<"$cli_out" | grep -v '^[[:space:]]*$' | tail -n 1 || true)
            plugin_note="NOT installed: the claude CLI refused${cli_out:+ ($cli_out)}"
        fi
    fi
fi

# What the workflow needs on this machine. Nothing here is installed without asking.
missing=()
for tool in jq python3 gh; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
herdr_note="" integration_cmd=""
if ! command -v herdr >/dev/null 2>&1; then
    herdr_note="NOT installed: curl -fsSL https://herdr.dev/install.sh | sh   (https://herdr.dev/tui/docs/install/), then: herdr integration install claude"
else
    herdr_note=$(herdr --version 2>/dev/null | head -n 1 || true)
    integration=$(herdr integration status 2>/dev/null | sed -n 's/^claude: //p' | head -n 1 || true)
    case "$integration" in
        current*) herdr_note+=", Claude integration current" ;;
        *)
            integration_cmd="herdr integration install claude"
            herdr_note+=", Claude integration ${integration:-unknown}"
            if ask "herdr has no current Claude integration (it writes a hook under ~/.claude/hooks/).
Run \"$integration_cmd\" now?" && herdr integration install claude >/dev/null 2>&1; then
                herdr_note+=" -> installed"
                integration_cmd=""
            fi ;;
    esac
fi

$dry_run && echo "dry run: nothing was written" && echo
echo "herdr-agent-pool workflow -> $target"
for f in ${copied[@]+"${copied[@]}"}; do echo "  + $f"; done
for f in ${skipped[@]+"${skipped[@]}"}; do echo "  = $f (exists, kept; --force to overwrite)"; done
[[ -n "$settings_note" ]] && echo "  ~ .claude/settings.json: $settings_note"
for l in ${added[@]+"${added[@]}"}; do echo "  + .gitignore: $l"; done
for f in ${refused[@]+"${refused[@]}"}; do
    echo "  ! $f: NOT written (symbolic link or outside the repository)"
done
if [[ "$settings_note" == NOT* ]]; then
    echo
    cat "$src/template/.claude/settings.json"
fi
echo
echo "This machine:"
echo "  plugin $PLUGIN: $plugin_note"
echo "  herdr: $herdr_note"
if [[ ${#missing[@]} -gt 0 ]]; then echo "  missing tools: ${missing[*]}"; fi

echo
echo "Next steps:"
n=1
step() { echo "  $n. $1"; n=$((n + 1)); }
if [[ "$herdr_note" == NOT* ]]; then step "Install herdr: see the herdr line above."
elif [[ -n "$integration_cmd" ]]; then step "Run: $integration_cmd"; fi
if [[ ${#missing[@]} -gt 0 ]]; then step "Install: ${missing[*]}"; fi
case "$plugin_note" in
    NOT*|skipped*|would*)
        commands=""
        if [[ -n "$stale" ]]; then
            while IFS= read -r name; do
                commands+="
       claude plugin marketplace remove $name    # also uninstalls the plugins installed from it"
            done <<<"$stale"
        fi
        step "Install the plugin (or open Claude Code in the repository and accept its offer):$commands
       claude plugin marketplace add $MARKETPLACE_REPO
       claude plugin install $PLUGIN --scope project" ;;
esac
step "Fill in the TODOs of CLAUDE.md, put your lint/type/test commands in scripts/check.sh,
     and commit these files on the base branch."
step "Inside herdr, launch the integrator with scripts/integrator.sh and start development
     agents from it with /herdr-agent-pool:dispatch <type>/<name> <task>.
     Many agents: add an \"integrators\" object to .claude/herdr-agent-pool.json and launch
     scripts/coordinator.sh instead (pool mode, docs/multi-integrator.md); set this
     machine's limits in ~/.config/herdr-agent-pool/resources.json."
echo
echo "Rerun this installer, or run /herdr-agent-pool:setup, to check the setup again later."
for old in "${OLD_PLUGINS[@]}"; do
    if [[ "$settings_note" == *"disabled $old"* ]]; then
        echo "This plugin must not run next to $old: uninstall it if you no longer use it elsewhere."
    fi
done
