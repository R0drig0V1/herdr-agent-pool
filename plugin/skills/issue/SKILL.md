---
name: issue
description: Write a GitHub issue for work that is left for later - a bug, debt, a follow-up or an open question found while developing that is outside the current task or cannot be solved yet - with evidence, acceptance criteria, scope, risk and size, after checking for duplicates; and link it from the code or docs where the gap lives. Use when the user asks to "crea un issue", "abre un issue", "anótalo para después", "deja un issue", or when you find something out of your task's scope that should not be lost.
---

<!--
issue skill of the herdr-agent-pool plugin. Every role may use it. The body format is the one
a planner or a dispatcher can act on later: verifiable acceptance criteria, scope, risk, size
and "Depends on".
-->

# Issue

Turn something you cannot or should not solve now into an issue that someone (an agent, the
coordinator or the user) can pick up later without asking you anything.

## 0. Is it an issue?

| The finding | Do |
|-------------|----|
| Inside your task's scope and small | Fix it now; no issue. |
| Outside your scope, or blocked (a decision, another task, an external fix) | An issue. |
| A known limitation of what you are shipping | An issue, and a note in the docs that links it (step 5). |
| A policy question (money, privacy, scope, a new rule) | An issue labelled `needs-decision`; the user decides. |
| A security vulnerability | Step 1 first: a public repository never gets it as an issue. |
| Something the user already decided not to do | Nothing. |

One issue per distinct problem. Several tiny related items (e.g. typos across one page) go
into one issue as a checklist.

## 1. Check the repository and look for duplicates

```bash
gh repo view --json nameWithOwner,visibility -q '.nameWithOwner + " " + .visibility'
gh issue list --state all --limit 20 --search "<2-4 key terms> in:title,body" \
    --json number,title,state,url -q '.[] | "#\(.number) \(.state) \(.title)"'
gh label list --limit 200 --json name -q '.[].name'
```

- If `gh` is missing or not logged in, tell the user (`brew install gh && gh auth login`) and
  give them the title and body ready to paste.
- **An open issue already covers it**: add your new evidence as a comment
  (`gh issue comment <N> --body-file - <<'BODY' ... BODY`) instead of opening another one.
- **A closed one covers it** and the problem came back: open a new issue that says
  "Regression of #<N>".
- **A vulnerability in a PUBLIC repository**: do not open an issue. Tell the user, and follow
  the repository's SECURITY.md (private advisory). In a private repository, an issue labelled
  `security` is fine.

## 2. Gather the evidence

Collect what lets a stranger reproduce and verify it, from the work in front of you:

- file and line (`path/to/file.py:123`), the commit (`git rev-parse --short HEAD`) and branch;
- the command you ran and the relevant lines of its output, at most about 30 lines;
- what happens versus what should happen;
- the PR or task where it came up.

Never put secrets, tokens, personal data or customer data in an issue: redact them from logs.

## 3. Write it

**Title**: imperative and specific, at most about 70 characters, naming the thing:
"Retry the base fetch in new-worktree.sh when DNS fails", not "Bug in worktree script".
No `[bug]` prefixes: labels carry the kind.

**Language**: the language of the repository's existing issues (look at the last few); English
when there are none.

**Body**:

```markdown
## Context
<Where this came up (task, branch, PR) and why it is not done now: out of scope, blocked by X,
needs a decision.>

## Problem
<What is wrong or missing, in 2-5 sentences. Observed behaviour versus expected.>

## Evidence
- `path/to/file.py:123`: <what is there>
- `<command>` → <trimmed output>
- Seen at <commit> on <branch>

## Proposal
<Optional: the approach you would take, the alternatives, the open questions.>

## Acceptance criteria
- [ ] <A verifiable outcome, e.g. "check.sh passes with a test for X that fails today">
- [ ] <Docs: the page that must say it>

## Scope
Likely touches: <paths>. Out of scope: <what must not change>.

Depends on: <#N, #M, or none>
Risk: <low|high>: <one line why>
Size: <S|M|L>
```

- **Acceptance criteria** are checks, not wishes. "Improve error handling" is not one;
  "`new-worktree.sh` retries once and prints the fetch error" is.
- **Risk high**: migrations and data, security, privacy, new dependencies, CI and workflows,
  anything public-facing. Everything else is low.
- **Size**: S fits one short session, M fits one session, L needs splitting; say how in the
  Proposal.
- **Depends on** keeps exactly that form (`Depends on: #12, #15`), so tools can read it.

## 4. Create it

Use only labels that already exist (the list from step 1): `bug`, `enhancement`, `tech-debt`,
`docs`, `question`, `flaky-test`, `security`, `follow-up`, `risk:low`/`risk:high`,
`size:S`/`size:M`/`size:L` and `needs-decision` when the project has them. A missing label
makes `gh issue create` fail: leave it out and mention it in your report.

```bash
gh issue create --title "<title>" --label "<label>,<label>" --body-file - <<'BODY'
<body from step 3>
BODY
```

- **Never add `agent:ready`** or any other label that starts work: whether and when this is
  worked on is the coordinator's or the user's call.
- **Never create labels** yourself. If the project lacks the set above and the user agrees,
  create them once:
  ```bash
  for l in bug enhancement tech-debt docs question flaky-test security follow-up \
           risk:low risk:high size:S size:M size:L needs-decision; do
      gh label create "$l" 2>/dev/null || true
  done
  ```

## 5. Link it where the gap lives

The issue number goes wherever someone would otherwise rediscover the problem:

- **Code**: one line at the exact spot: `# TODO(#<N>): <what is missing>`. Never a TODO
  without an issue number.
- **Docs**: a known limitation or an open question goes in the page that documents that area
  (a "Limitations" or "Open questions" section), one or two lines with the link. The issue
  holds the details; the doc says the limitation exists.
- **Your PR**: list it under "Follow-ups" in the PR body (`/herdr-agent-pool:pr`).

Commit those links with your work (`/herdr-agent-pool:commit`).

## 6. Report

Give the user the issue URL and one line on why it was left for later. In pool mode do not
send a herdr message only to announce an issue: the coordinator reads new issues in its own
pass, and the PR body lists them. An issue labelled `needs-decision` that blocks your current
task is a blocker: ask the user (or, in pool mode, the coordinator) as your brief says.
