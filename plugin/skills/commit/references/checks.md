<!--
Reference of the commit and pr skills: the two rare cases around the project checks. Read when
`pool-state.py base-red show` prints a banner, when the wait for a heavy slot blocks something
urgent, or when the wrapper exits 124.
-->

# The checks: rare cases

## The base is red

`pool-state.py base-red show` prints nothing while `<base>` is green. A `BASE ... IS RED`
banner names failing tests and the one agent that owns their fix.

- Do **not** fix those tests in your branch, unless you are that owner.
- Do not let them stop you: when only those tests fail, go on and say so (`base red: <tests>`)
  in your report and, for a PR, under Test plan. Failures of only the base-red tests are not
  yours.
- Rebase after the fix lands.
- Show the banner to the user.

## Heavy slots

The checks run inside one of the machine's heavy slots (`resource-budget.py run`). Every agent
on this computer shares a small number of them, so a full test suite may first wait ("waiting
for one of N heavy slot(s)").

- Let it wait. Never run the suite outside the wrapper, and never several suites at once.
- `"${CLAUDE_PLUGIN_ROOT}/scripts/resource-board.sh" show` shows who holds each slot.
- A long wait that blocks something urgent (a bounce to fix) is a `RESOURCE REQUEST` to the
  coordinator in pool mode, or a note to the user in single mode. It is not a reason to bypass
  the wrapper.
- With `--timeout S`, exit 124 means no slot was free in time: nothing ran. Say so; do not run
  the suite another way.
