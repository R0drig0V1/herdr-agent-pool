<!--
Reference of the dispatch skill: reserve a number for a branch before its agent starts. Read at
step 5 when the task will add a file of a `numbered_files` kind (project settings), such as a
migration or an ADR. Design: docs/multi-integrator.md, "Numbered files".
-->

# Numbered files

Reserve the number for the branch first, so two parallel branches never pick the same one,
and put it in the brief ("Numbers reserved for this branch: ..."):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/project-config.py" numbered_files    # the kinds, {} when none
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" reserve <kind> --owner <BRANCH>; echo "exit=$?"
```

It prints the number, zero-padded: above every number on `origin/<base>`, in an open PR and
already reserved. The reservation ends when the file lands, or with
`pool-state.py unreserve --owner <BRANCH>` if the task is dropped.
