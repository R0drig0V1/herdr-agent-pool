<!--
Reference of the pr skill: publish a branch without the GitHub CLI. Read at step 3 when
`command -v gh` finds nothing.
-->

# No `gh`

- Push the branch as usual (`git push -u origin HEAD`).
- Tell the user how to install it: `brew install gh && gh auth login`.
- Print the compare URL instead of creating the PR, built from the `origin` remote
  (`https://github.com/<owner>/<repo>/compare/<base>...<branch>?expand=1`), together with the
  title and the body ready to paste.
- Announce it all the same (step 4). Line 2 of the announcement is then
  `Branch <branch> ready (no PR: <reason>)` plus the compare URL.
