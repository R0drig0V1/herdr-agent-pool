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
- [Setting it up](#setting-it-up)
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

Because each run drains the whole queue, it does not matter that a concurrency group keeps
only one pending run and discards the others.

## Gates

| Gate | Fails how | Then |
|------|-----------|------|
| Not a draft, still against the base | draft or retargeted | leaves the queue, with a comment |
| Base green | an open issue labelled `base-red`, and the PR is not labelled `fixes-base-red` | waits in the queue |
| CI on the head commit | a check or status still running | waits in the queue |
| | a check or status failed | leaves the queue, with a comment |
| Approval of the head commit | someone's latest review requests changes, or no approval is of the head commit | leaves the queue, with a comment |
| `risk:high` | no approval from a person (`OWNER`, `MEMBER` or `COLLABORATOR`, not a `--bot` login) | leaves the queue, with a comment |

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

## Setting it up

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
`--max-rounds` (2), `--bot LOGIN` (repeatable), `--dry-run`.

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
- **Verify in phase 0**: that GitHub marks a PR merged when its head reaches the base through
  the lander's push, and that the closing keywords in the merge commit close the issues when
  the base is not the default branch (GitHub processes them only on the default branch).
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
