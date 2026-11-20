---
name: commit
description: Create a well-formed git commit for this repository (Conventional Commits, English, no emojis) after running the project checks. Use when the user asks to commit, "haz un commit", "commitea", or after finishing a logical unit of work they want saved.
---

<!-- commit skill. Rare branches: references/checks.md. -->

# Commit

Create one focused commit for the current changes of this workspace.

## 1. Inspect

```bash
git status --short
git diff            # unstaged
git diff --staged   # staged
git log --oneline -10   # match the existing style
```

- Unrelated concerns mixed (a bug fix and a new feature): propose several commits and stage
  per concern.
- **Never stage** `.env` or any secret or credential, `.venv/`, `node_modules/`, build output,
  data dumps, large binaries. If one is staged, unstage it and tell the user.

## 2. Verify before committing

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" base-red show      # prints nothing while the base is green
"${CLAUDE_PLUGIN_ROOT}/scripts/resource-budget.py" run --label "check $(git branch --show-current)" -- scripts/check.sh; echo "exit=$?"
```

- Fix or report failures. Do not commit red checks unless the user explicitly says so.
- A `BASE ... IS RED` banner: show it to the user and read
  `${CLAUDE_PLUGIN_ROOT}/skills/commit/references/checks.md` first. Never fix the tests it
  names in your branch, unless you are the owner it names.
- The checks may first wait for one of the machine's shared heavy slots: let it wait. Never
  run the suite outside the wrapper or several suites at once. A wait that blocks something
  urgent, or exit 124: same reference.
- `scripts/check.sh` missing, or it prints "no checks configured": tell the user once.
- A companion artefact (a migration for a schema change, a regenerated lockfile, an updated
  `docs/` page) goes in the same commit.

## 3. Message

Conventional Commits, **in English, no emojis**, imperative mood, subject ≤ 72 chars:

```
<type>(<scope>): <subject>

<body: what changed and WHY, wrapped at 72 columns; bullets are fine>
```

- `type`: feat, fix, refactor, perf, test, docs, build, ci, chore.
- `scope`: the package or area touched (`git log` shows the scopes in use).
- Mention migrations or breaking changes explicitly in the body.
- End with the co-author / attribution trailer this environment specifies, if any.

Use a heredoc so formatting survives:

```bash
git commit -F - <<'MSG'
feat(api): add user login endpoint

- Validate credentials against the users table
MSG
```

## 4. Report

Show `git log --oneline -1` and summarise what was committed and anything left unstaged.
Do not push; pushing is part of the `pr` skill.
