<!--
Reference of the dispatch skill: numbered files (migrations, ADRs) in a brief. Read at step 5
when the task will add a file of a `numbered_files` kind (project settings). Design:
docs/multi-integrator.md, "Numbered files".
-->

# Numbered files

Numbers are given at merge time, not at dispatch: reserve nothing. Add this line to the brief:

```text
Numbered files: give a new <kind> file the next free number on your base (the highest one on
origin/<base>, plus one), so your checks pass. Another branch may take the same number: the
integrator renumbers yours at merge when needed (file, index row, links and mentions such as
"<KIND> 0001" in your lines), and the merge verifies the result.
```

`pool-state.py reserve` still works for older setups, but dispatch no longer uses it.
