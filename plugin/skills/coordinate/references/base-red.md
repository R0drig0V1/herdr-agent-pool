<!--
Reference of the coordinate skill: what the coordinator does when tests fail on the base branch
alone. Read when an integrator sends "BASE RED: ...", or when a promotion check fails on the
base alone. Design: docs/multi-integrator.md, "The base is red".
-->

# The base is red

An integrator that finds tests failing on `origin/<base>` alone records it
(`pool-state.py base-red report`) and sends you `BASE RED: ...`.

Name **one** owner of the fix, so nobody else fixes it in their branch: an agent already on
it, or dispatch a fix task (`/herdr-agent-pool:dispatch`). Then:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" base-red show                      # the banner
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" base-red assign <agent> --branch <its branch>
```

Tell that agent it owns the fix. Meanwhile every `commit`, `pr` and merge verification prints
the banner, and integrators hold the PRs that fail only on those tests.

The entry clears by itself when the fix's branch merges. When a full base check (your
promotion check) is green first, clear it yourself; held PRs return to the queue:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/pool-state.py" base-red clear --owner <me> --reason "<check> green on <sha>"
```

A promotion check that fails on the base alone is a red base too: run `base-red report`
yourself with the failing tests.
