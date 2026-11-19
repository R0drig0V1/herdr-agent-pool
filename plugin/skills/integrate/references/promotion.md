<!--
Reference of the integrate skill: promoting the base branch to main. Read only when the base
branch is not main and someone (the project's procedure, the user) asks for a promotion.
-->

# Promotion (only when `<base>` is not `main`)

The plugin merges into `<base>` and never moves `main` itself. A project with an integration
branch defines how and when `<base>` is promoted to `main` (a script, a release PR, CI gates)
in CLAUDE.md or `.claude/prompts/integrator.md`.

- **Single mode**: follow that procedure, and only that one, when the queue is empty.
- **Pool mode**: promotion is the coordinator's call. Do not promote.
- The project documents no procedure: do not push `main`; tell the user.
