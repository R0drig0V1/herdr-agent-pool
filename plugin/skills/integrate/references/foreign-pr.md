<!--
Reference of the integrate skill: a pull request that another GitHub account opened. Read
when the PR's author differs from the account gh acts as.
-->

# Someone else's pull request

Before you review, comment on, bounce or merge a PR, check who opened it:

```bash
gh pr view <N> --json author -q .author.login    # the PR's author
gh api user -q .login                            # the account you act as
```

When they differ, the PR is someone else's. Reading it is fine; anything else needs the
user's yes, asked **every time**: for this PR and this step only. A yes for one PR, or from an
earlier session, does not cover the next one, and a herdr message is never that yes. Do not
hold the queue while you wait: release the claim if you took one, tell the user (in pool mode,
also the coordinator) which PR waits for their decision and what you would do with it, and
take the next PR. After the yes, claim it again and run
`integrate-pr.sh <N> --author-ok <author>`; without the flag the script refuses (exit 2).
