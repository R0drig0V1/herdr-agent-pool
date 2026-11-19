#!/usr/bin/env python3
"""The machine's hard floor for heavy commands: at most `heavy_slots` of them at once.

Part of the herdr-agent-pool plugin (docs/multi-integrator.md, "Resources"). Resources are
mostly negotiated: agents note what they run on the resource board (resource-board.sh) and
ask the coordinator for a turn. This script is the one thing that is not negotiated, because a
conversation cannot stop a process that is already eating memory: however the negotiation
goes, no more than `heavy_slots` heavy commands (a full test suite, a build) run at once on
this computer, across every agent and project of the user.

`verify-merge.sh` runs the project's `scripts/check.sh` through `run`, and the `commit` and
`pr` skills run the checks the same way. Worktree setup (`scripts/worktree-setup.sh`, from
`new-worktree.sh`, `verify-merge.sh` and `integrator-pool.sh spawn`) uses the separate
`light` pool (`light_slots`), so a warm-cache install never waits behind a test suite.

Slots are `flock`ed files, so the kernel frees the slot of a crashed holder. A command started
inside a heavy slot (`$HERDR_AGENT_POOL_SLOT` set) runs at once, so a nested call cannot
deadlock.

Waiters queue. Each waiter writes a ticket; under a queue lock, a free slot goes to the first
ticket in priority order, oldest first within a priority:

* `merge`: an integrator's merge verification (`verify-merge.sh`; only honoured for
  CLAUDE_ROLE=integrator);
* `plan`: the coordinator's own checks (the default for CLAUDE_ROLE=coordinator);
* `normal`: everything else (the default), e.g. a development agent's checks.

A ticket that has waited `AGING_MINUTES` counts as `merge`, so nothing starves. Every retry
re-reads the limits: raising `heavy_slots` admits waiters at once, lowering it admits nobody
new until the holders above the new limit finish (they are never killed). Tickets of dead
processes are dropped. A waiter from an older version of this script has no ticket and simply
polls the slots.

Limits, machine-wide, from `~/.config/herdr-agent-pool/resources.json` (or the file in
`$HERDR_AGENT_POOL_RESOURCES_CONFIG`), each key optional:

    {"heavy_slots": 2, "light_slots": 2, "sessions_guideline": 12, "low_memory_gb": 2.4}

`heavy_slots` and `light_slots` are enforced; the other two are the guidelines the resource
board shows and the coordinator weighs (working sessions for this RAM; idle and done ones do
not count; the free memory below which
it declares save mode). Defaults from the machine's RAM (R GB): heavy_slots =
max(1, (R - 8) // 8), light_slots = 2, sessions_guideline = max(2, R // 2), low_memory_gb =
R / 10; a 24 GB machine gets 2, 2, 12 and 2.4. `$HERDR_AGENT_POOL_HEAVY_SLOTS` overrides
heavy_slots. A limits file that cannot be read while a waiter retries (for example, half
written) keeps the waiter's last good limit.

Slot state lives in `~/.cache/herdr-agent-pool/resources` (or
`$HERDR_AGENT_POOL_RESOURCES_DIR`), not in a temporary directory: a sandboxed session may get
its own `$TMPDIR`. Each held slot has an owner file (`slot-<i>.json` for heavy,
`light-<i>.json` for light: label, cwd, agent, pid, since, priority) and each waiter a ticket
in `queue-<pool>/`; `status` and resource-board.sh show both.

The command gets `$HERDR_AGENT_POOL_SLOT_COUNT`, the pool's limit when it was admitted, so a
project can size its parallelism (e.g. test workers = cores / slots).

Usage:

    resource-budget.py run [--pool heavy|light] [--priority merge|plan|normal]
                           [--label TEXT] [--timeout S] -- CMD [ARG...]
    resource-budget.py limits                   effective limits as JSON
    resource-budget.py status [--json]          holders and waiters of both pools

Exit codes: 0 ok; 1 usage or invalid config; 120 `run` was interrupted (SIGTERM, SIGINT or
SIGHUP) while waiting: CMD never ran; 124 `run` got no slot within --timeout (CMD never ran);
otherwise CMD's own exit code. Python 3.9 compatible, no dependencies.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import functools
import glob
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
from collections.abc import Iterator
from typing import Any

GB = 1024**3
EXIT_INTERRUPTED = 120
EXIT_TIMEOUT = 124
KEYS = ("heavy_slots", "light_slots", "sessions_guideline", "low_memory_gb")
POOLS = {"heavy": ("slot", "heavy_slots"), "light": ("light", "light_slots")}  # file prefix, key
PRIORITIES = {"merge": 0, "plan": 1, "normal": 2}
ROLE_PRIORITY = {"merge": "integrator", "plan": "coordinator"}  # who may ask for it
AGING_MINUTES = 20
POLL_SECONDS = 2.0


class Interrupted(Exception):
    """A signal arrived while waiting for a slot."""


@functools.lru_cache(maxsize=1)
def total_gb() -> float:
    """Physical memory in GB (8 when it cannot be read)."""
    try:
        if platform.system() == "Darwin":
            out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True)
            return int(out.stdout.strip()) / GB
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024 / GB
    except (OSError, ValueError):
        pass
    return 8.0


def config_path() -> str:
    home = os.path.expanduser("~")
    default = os.path.join(home, ".config", "herdr-agent-pool", "resources.json")
    return os.environ.get("HERDR_AGENT_POOL_RESOURCES_CONFIG", default)


def limits() -> dict[str, Any]:
    """Effective limits: the config file over the RAM-based defaults (raises ValueError)."""
    ram = total_gb()
    result: dict[str, Any] = {
        "heavy_slots": max(1, int((ram - 8) // 8)),
        "light_slots": 2,
        "sessions_guideline": max(2, int(ram // 2)),
        "low_memory_gb": round(ram / 10, 1),
        "ram_gb": round(ram, 1),
        "source": f"defaults for {ram:.0f} GB of RAM",
    }
    path = config_path()
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: must be a JSON object")
    for key, value in data.items():
        if key.startswith("$"):
            continue
        if key not in KEYS:
            raise ValueError(f"{path}: unknown key {key!r} (known: {', '.join(KEYS)})")
        floor = 0 if key == "low_memory_gb" else 1
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < floor:
            raise ValueError(f"{path}: {key} must be a number >= {floor}, got {value!r}")
        result[key] = value if key == "low_memory_gb" else int(value)
        result["source"] = path
    env = os.environ.get("HERDR_AGENT_POOL_HEAVY_SLOTS", "")
    if env:
        if not env.isdigit() or int(env) < 1:
            raise ValueError(f"HERDR_AGENT_POOL_HEAVY_SLOTS must be a positive integer: {env!r}")
        result["heavy_slots"] = int(env)
    return result


def pool_limit(pool: str, last: int | None) -> int:
    """The pool's current limit; `last` when the limits cannot be read now (None: raise)."""
    try:
        return int(limits()[POOLS[pool][1]])
    except (OSError, ValueError):
        if last is None:
            raise
        return last


def state_dir() -> str:
    home = os.path.expanduser("~")
    default = os.path.join(home, ".cache", "herdr-agent-pool", "resources")
    path = os.environ.get("HERDR_AGENT_POOL_RESOURCES_DIR", default)
    os.makedirs(path, exist_ok=True)
    return path


def alive(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_json(path: str) -> dict[str, Any] | None:
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write_json(path: str, data: dict[str, Any]) -> None:
    """Atomic write: a reader never sees half a file."""
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def slot_files(pool: str) -> list[tuple[int, str]]:
    """(index, lock path) of every slot file of the pool, also those above the limit."""
    prefix = POOLS[pool][0]
    found = []
    for path in glob.glob(os.path.join(state_dir(), f"{prefix}-*.lock")):
        m = re.fullmatch(rf"{prefix}-(\d+)\.lock", os.path.basename(path))
        if m:
            found.append((int(m.group(1)), path))
    return sorted(found)


def try_lock(path: str) -> int | None:
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BlockingIOError:
        os.close(fd)
        return None


def free_slots(pool: str, slots: int) -> list[tuple[int, int]]:
    """(index, fd) of the pool's free slots below the limit, now locked by this process, minus
    one for each slot above the limit that is still held (a lowered limit admits nobody until
    those finish)."""
    prefix = POOLS[pool][0]
    free = []
    for i in range(slots):
        fd = try_lock(os.path.join(state_dir(), f"{prefix}-{i}.lock"))
        if fd is not None:
            free.append((i, fd))
    held_above = 0
    for i, path in slot_files(pool):
        if i >= slots:
            fd = try_lock(path)
            if fd is None:
                held_above += 1
            else:
                os.close(fd)
    keep = max(0, len(free) - held_above)
    for _, fd in free[keep:]:
        os.close(fd)
    return free[:keep]


@contextlib.contextmanager
def queue_lock(pool: str) -> Iterator[None]:
    fd = os.open(os.path.join(state_dir(), f"queue-{pool}.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def queue_dir(pool: str) -> str:
    path = os.path.join(state_dir(), f"queue-{pool}")
    os.makedirs(path, exist_ok=True)
    return path


def rank(ticket: dict[str, Any], now: float) -> tuple[int, float]:
    """Sort key: priority (aged tickets count as merge), then age."""
    since = float(ticket.get("since", now))
    prio = PRIORITIES.get(ticket.get("priority", "normal"), PRIORITIES["normal"])
    if now - since >= AGING_MINUTES * 60:
        prio = PRIORITIES["merge"]
    return prio, since


def waiting(pool: str, prune: bool = False) -> list[tuple[str, dict[str, Any]]]:
    """(file name, ticket) of the live waiters, in turn order; `prune` drops dead ones."""
    now = time.time()
    live = []
    for path in glob.glob(os.path.join(queue_dir(pool), "*.json")):
        ticket = read_json(path)
        if ticket is not None and alive(ticket.get("pid")):
            live.append((os.path.basename(path), ticket))
        elif prune and (ticket is not None or now - os.path.getmtime(path) > 60):
            with contextlib.suppress(OSError):
                os.remove(path)
    return sorted(live, key=lambda item: rank(item[1], now))


def try_admit(pool: str, me: str, slots: int) -> tuple[int, int] | None:
    """(slot, fd) when a slot is free and it is this ticket's turn, else None."""
    with queue_lock(pool):
        names = [name for name, _ in waiting(pool, prune=True)]
        position = names.index(me) if me in names else len(names)
        free = free_slots(pool, slots)
        if position >= len(free):
            for _, fd in free:
                os.close(fd)
            return None
        for _, fd in free[1:]:
            os.close(fd)
        return free[0]


def holders(pool: str) -> list[dict[str, Any]]:
    """Owner records of the pool's live holders, every slot (also above the limit)."""
    prefix = POOLS[pool][0]
    found = []
    for i, _ in slot_files(pool):
        owner = read_json(os.path.join(state_dir(), f"{prefix}-{i}.json"))
        if owner is not None and alive(owner.get("pid")):
            found.append(dict(owner, slot=i))
    return found


def describe(owner: dict[str, Any]) -> str:
    return f"{owner.get('label', '?')} ({owner.get('agent') or '?'})"


def effective_priority(asked: str | None) -> str:
    role = os.environ.get("CLAUDE_ROLE", "")
    if asked is None:
        return "plan" if role == "coordinator" else "normal"
    if asked in ROLE_PRIORITY and role != ROLE_PRIORITY[asked]:
        print(
            f"resource-budget: priority {asked} is for the {ROLE_PRIORITY[asked]}; "
            "queued as normal",
            file=sys.stderr,
        )
        return "normal"
    return asked


def raise_interrupted(signum: int, frame: Any) -> None:
    raise Interrupted()


def wait_turn(pool: str, me: str, timeout: float) -> tuple[int, int, int] | None:
    """(slot, fd, limit) once admitted; None when --timeout passed."""
    deadline = time.monotonic() + timeout if timeout else None
    slots = pool_limit(pool, None)
    told = False
    while True:
        slots = pool_limit(pool, slots)
        taken = try_admit(pool, me, slots)
        if taken is not None:
            return taken[0], taken[1], slots
        if not told:
            names = [name for name, _ in waiting(pool)]
            ahead = names.index(me) if me in names else len(names)
            busy = "; ".join(describe(o) for o in holders(pool)) or "?"
            print(
                f"resource-budget: waiting for one of {slots} {pool} slot(s) ({ahead} ahead "
                f"in the queue), held by: {busy}. Long wait? Ask the coordinator "
                "(resource-board.sh show).",
                file=sys.stderr,
            )
            told = True
        if deadline is not None and time.monotonic() >= deadline:
            return None
        time.sleep(POLL_SECONDS)


def admit(args: argparse.Namespace, label: str, priority: str) -> tuple[int, int, int] | int:
    """Queue, wait and take a slot: (slot, fd, limit), or the exit code when CMD must not run."""
    ticket = {
        "pid": os.getpid(),
        "priority": priority,
        "label": label,
        "cwd": os.getcwd(),
        "agent": os.environ.get("HERDR_AGENT_POOL_NAME", ""),
        "since": time.time(),
    }
    me = f"{time.time_ns()}-{os.getpid()}.json"
    path = os.path.join(queue_dir(args.pool), me)
    old = {
        s: signal.signal(s, raise_interrupted)
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    try:
        write_json(path, ticket)
        taken = wait_turn(args.pool, me, args.timeout)
    except Interrupted:
        print(
            "resource-budget: interrupted while waiting; the command did not run", file=sys.stderr
        )
        return EXIT_INTERRUPTED
    finally:
        with contextlib.suppress(OSError):
            os.remove(path)
        for s, handler in old.items():
            signal.signal(s, handler)
    if taken is None:
        print(f"resource-budget: no {args.pool} slot within {args.timeout:g} s", file=sys.stderr)
        return EXIT_TIMEOUT
    return taken


def cmd_run(args: argparse.Namespace) -> int:
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        print("resource-budget: run needs a command after --", file=sys.stderr)
        return 1
    if os.environ.get("HERDR_AGENT_POOL_SLOT"):  # already inside a heavy slot: no deadlock
        return subprocess.call(command)
    try:
        state_dir()
    except OSError as exc:  # the floor must never be the reason a check cannot run
        print(f"resource-budget: warning: no state directory ({exc}); unbudgeted", file=sys.stderr)
        return subprocess.call(command)
    label = args.label or " ".join(command)[:80]
    priority = effective_priority(args.priority)
    taken = admit(args, label, priority)
    if isinstance(taken, int):
        return taken
    slot, fd, slots = taken
    owner_file = os.path.join(state_dir(), f"{POOLS[args.pool][0]}-{slot}.json")
    owner = {
        "label": label,
        "cwd": os.getcwd(),
        "pid": os.getpid(),
        "priority": priority,
        "agent": os.environ.get("HERDR_AGENT_POOL_NAME", ""),
        "since": time.time(),
    }
    env = dict(os.environ, HERDR_AGENT_POOL_SLOT_COUNT=str(slots))
    if args.pool == "heavy":
        env["HERDR_AGENT_POOL_SLOT"] = str(slot)
    try:
        write_json(owner_file, owner)
        return subprocess.call(command, env=env)
    finally:
        with contextlib.suppress(OSError):
            os.remove(owner_file)
        os.close(fd)


def ago(since: Any) -> str:
    minutes = max(0, int((time.time() - float(since or time.time())) // 60))
    return f"{minutes} min"


def status(lim: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for pool, (_, key) in POOLS.items():
        slots = int(lim[key])
        out[pool] = {
            "limit": slots,
            "holders": [dict(o, above_limit=o["slot"] >= slots) for o in holders(pool)],
            "waiting": [t for _, t in waiting(pool)],
        }
    return out


def print_status(lim: dict[str, Any]) -> None:
    for pool, info in status(lim).items():
        print(
            f"## {pool.capitalize()} slots (hard limit: {info['limit']} at once; "
            f"{len(info['holders'])} in use)"
        )
        print()
        for o in info["holders"]:
            flag = " - **above the current limit**" if o["above_limit"] else ""
            print(
                f"- slot {o['slot']}: {o.get('label', '?')} - {o.get('agent') or '?'} in "
                f"{o.get('cwd', '?')}, for {ago(o.get('since'))} [{o.get('priority', '?')}]{flag}"
            )
        if not info["holders"]:
            print("- all free")
        for n, t in enumerate(info["waiting"], 1):
            print(
                f"- waiting #{n}: {t.get('label', '?')} - {t.get('agent') or '?'} "
                f"[{t.get('priority', '?')}], for {ago(t.get('since'))}"
            )
        print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("limits")
    st = sub.add_parser("status")
    st.add_argument("--json", action="store_true")
    run = sub.add_parser("run")
    run.add_argument("--pool", choices=sorted(POOLS), default="heavy")
    run.add_argument("--priority", choices=sorted(PRIORITIES), default=None)
    run.add_argument("--label", default="")
    run.add_argument("--timeout", type=float, default=0, help="seconds to wait; 0 = no limit")
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        lim = limits()
    except ValueError as exc:
        print(f"resource-budget: {exc}", file=sys.stderr)
        return 1
    if args.cmd == "run":
        return cmd_run(args)
    if args.cmd == "status":
        if args.json:
            print(json.dumps(status(lim), indent=2))
        else:
            print_status(lim)
        return 0
    print(json.dumps(lim, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
