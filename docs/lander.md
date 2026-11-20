<!-- The lander (plugin/scripts/land.py): the deterministic workflow that merges queued pull
     requests in the GitHub Actions design, phase 1 of the migration. What it checks, how to
     set it up, shadow mode, security, limitations and how it is tested. -->

# The lander

The lander merges pull requests that are already approved. It replaces `integrate-pr.sh` and
the merge lock: a GitHub Actions workflow runs `plugin/scripts/land.py` in one concurrency
group per base branch, so it is the only thing that writes the base, one PR after another.
It makes no judgement. The reviewer, or you for `risk:high`, already decided; the lander
checks the gates, verifies the exact merge and pushes exactly what it verified.

It is phase 1 of the move to coordination through GitHub state (the design keeps the Claude
roles for planning, coding and review, and makes routing, ordering and merging deterministic
workflows). During phase 1 the integrators keep reviewing and, instead of running
`integrate-pr.sh`, add the `queue` label to a PR they approve.

## Contents

- [What one run does](#what-one-run-does)
- [Gates](#gates)
- [Outcomes](#outcomes)
- [Running it in a terminal](#running-it-in-a-terminal)
- [Setting it up as a workflow](#setting-it-up-as-a-workflow)
- [Shadow mode](#shadow-mode)
- [Security](#security)
- [Limitations](#limitations)
- [Testing](#testing)

## What one run does

One run drains the queue: the open PRs against the base that carry the `queue` label, oldest
first (by creation time). For each one it reads the PR from GitHub, checks the gates, and, if
they pass:

1. Fetches the base and `refs/pull/<N>/head`, which must still be the head the gates saw.
2. Checks out the base detached and merges the head with `--no-ff`. The merge commit's message
   carries the PR body's closing lines (`Closes #12`).
3. Runs the check command on that merge: `scripts/check.sh` by default, the full check, with
   `HERDR_AGENT_POOL_LAND=1` and `HERDR_AGENT_POOL_LAND_PR=<N>` in its environment. It must
   pass and must leave tracked files unchanged.
4. Pushes the merge commit to the base, never forced. If the base moved meanwhile, the push
   is rejected, and the PR is merged and checked again on the new base, up to `--attempts`
   times (3).
5. Deletes the head branch, with a lease on the merged head, so a later push keeps it.
6. When the base is not the repository's default branch, closes the issues the PR body
   names with a closing keyword (`Fixes #12`), because GitHub does not do it there.

Because each run drains the whole queue, it does not matter that a concurrency group keeps
only one pending run and discards the others.

## Gates

| Gate | Fails how | Then |
|------|-----------|------|
| Not a draft, still against the base | draft or retargeted | leaves the queue, with a comment |
| Base green | an open issue labelled `base-red`, and the PR is not labelled `fixes-base-red` | waits in the queue |
| CI on the head commit | a check or status still running | waits in the queue |
| | a check or status failed | leaves the queue, with a comment |
| Not from a fork | the head is in another repository (its code would run with the lander's rights) | leaves the queue, with a comment |
| Approval | someone's latest review requests changes | leaves the queue, with a comment |
| Approval, `--approval review` only | no approving review of the head commit; for `risk:high`, none from a person (`OWNER`, `MEMBER` or `COLLABORATOR`, not a `--bot` login) | leaves the queue, with a comment |

**The queue label is the approval** by default (`--approval label`): whoever added it reviewed
the PR. That fits a project where every agent acts as one GitHub account, because GitHub does
not let an account approve its own pull requests. `--approval review` also asks for an
approving review of the head commit; use it when reviewers have their own identity (a
reviewer GitHub App, other people).

Leaving the queue at a gate is not a bounce: it does not count toward the limit below.

## Outcomes

Each PR prints one line, `LAND #<N> <outcome> <detail>`:

| Outcome | Meaning |
|---------|---------|
| `merged` | pushed to the base; the detail has the merge commit and the attempt |
| `wait` | a gate says "not yet"; it stays queued for the next run |
| `unqueued` | a gate failed, or the head was already in the base |
| `bounced` | a conflict, or the full check failed on the merge: comment with the reason and the end of the check's output, `queue` removed |
| `needs-human` | the bounce that went over `--max-rounds` (2): also labelled `needs-human`; the cycle stops retrying it |
| `retry-later` | the head moved after the gates were read, or the base moved `--attempts` times; it stays queued |
| `would-land` | `--dry-run` only |

Bounces are counted by a hidden marker in the lander's comments, so the count survives
across runs and needs no state outside GitHub.

## Running it in a terminal

The lander needs only `git` and `gh`, so it runs without GitHub Actions. In a clean checkout
of the repository (its own worktree, not one an agent works in):

```bash
python3 /path/to/herdr-agent-pool/plugin/scripts/land.py --watch 30
```

It drains the queue every 30 seconds until interrupted, and prints only when something was
queued. One lander per base branch: two at once are safe (the push is never forced) but
waste checks.

## Setting it up as a workflow

The lander needs the phase 0 pieces first:

1. **A runner** with the `ci` label (runner-host's `ci` profile), so the full check costs no
   GitHub minutes.
2. **A GitHub App for the lander**, installed on the repository with contents and pull
   requests write and issues read. Store its id as the variable `LANDER_APP_ID` and its key
   as the secret `LANDER_PRIVATE_KEY`.
3. **A ruleset on the base** that lets only the lander App push (bypass list) and forbids
   force pushes for everyone.
4. **Labels**: `queue`, `risk:high`, `needs-human`, `base-red`, `fixes-base-red`.
5. **The files**: copy [workflows/land.yml](workflows/land.yml) to
   `.github/workflows/land.yml` and `plugin/scripts/land.py` to `.github/lander/land.py`, and
   adapt the base branch, the concurrency group and the CI workflow name. The workflow runs
   the base's own copy of `land.py`, so a queued PR cannot change the lander that judges it.
   If the reviewer is an App, set the variable `REVIEWER_BOT_LOGIN` to its login.

Options of `land.py`: `--base` (default: the project's `base_branch`), `--remote` (`origin`),
`--check` (`scripts/check.sh`), `--check-timeout` (60 minutes), `--attempts` (3),
`--max-rounds` (2), `--approval label|review` (`label`), `--bot LOGIN` (repeatable),
`--watch SECONDS` (keep running), `--pr N` (repeatable: also consider PR N,
even before the label search lists it), `--dry-run`.

## Shadow mode

`land.py --dry-run` reads GitHub and prints what it would do, without merging, commenting
or labelling, and without running the check. Run it beside today's integrators before
switching: every PR an integrator merges should first have shown `would-land`, and every PR
an integrator bounced should show a failed gate or turn into a bounce when it lands for real.

## Security

The lander runs code from pull requests: the check runs on the merge, with a token that can
push the base in the same job. That is acceptable only because:

- it lands only PRs that passed review (and a person's review for `risk:high`), on the exact
  head that was reviewed;
- the repository is private, so only collaborators and your own Apps open PRs;
- runner-host's runners are ephemeral containers, discarded after each job;
- the App token lasts an hour and is limited to this repository and the permissions above.

A stronger setup runs the check in a job without the token and pushes in a second job that
only compares tree hashes. It is not done yet (see Limitations).

## Limitations

- **Order** is by PR creation time, not by when `queue` was added.
- **Checked in the sandbox** (2026-11-14, a private throwaway repository): a merge pushed
  to the base marks the PR merged and, with "automatically delete head branches" on, deletes
  its branch, on the default branch and on `develop` alike. Closing keywords close issues only
  on the default branch, hence step 6. The `queue` label filter goes through GitHub's search
  index and showed a new label 1 to 7 s late, so the run a `labeled` event starts could miss
  its own PR: the workflow passes that PR with `--pr`, read through `gh pr view`.
- **Not yet checked**: whether an App's approval counts in a ruleset's required approvals,
  and the ruleset bypass for the lander App. GitHub does not let a PR's author approve it, so
  real merges in the sandbox need a second identity (the reviewer App).
- **No scope-aware re-check yet**: when the base moves, the PR is checked again in full;
  `reverify-needed.sh` is not consulted.
- **No rounds to the author**: a bounce is a comment and a label. Re-dispatching the agent
  (`rebase`, `fix-ci`) is phase 3, and today the herdr agent reads the comment.
- **Check and push share a job** (see Security).

## Testing

`tests/test-lander.sh` runs `land.py` against a throwaway repository with a bare `origin` and
a stateful fake `gh`: gates, landing order, conflicts, red checks up to `needs-human`, a check
that edits files, a base that moves during the check, a head that moves after the gates, a
red base, dry runs and a dirty tree. CI runs it on Ubuntu and macOS.
