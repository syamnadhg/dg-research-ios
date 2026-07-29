"""The Mac-side control bridge — full terminal parity, without touching the backend.

The owner asked for the app to manage everything they currently manage from the BE terminal. Most of
those operations act on the **Mac's own process and filesystem**, which a phone cannot do. So the
phone sends an *operation id* and a bridge on the Mac performs it — by **invoking the backend's CLI
as a subprocess**, exactly as a human at a terminal does.

That is what keeps A8 intact: the backend is **invoked, never modified.** No file in
``dg-research-backend`` changes; the bridge lives here and shells out to the installed command.

⚠ **This is a remote-execution surface, and it is designed as one.** A channel that let a document
specify a command line would be remote code execution on the owner's machine dressed up as a
feature. Three structural defences, none of them advisory:

1. **A closed registry mapped to literal argv.** The wire format carries an id. An unknown id
   resolves to nothing executable. No string from the channel ever reaches a command line.
2. **No shell, ever.** ``subprocess.run`` with a list and ``shell=False``, so quoting, globbing and
   ``;`` have no meaning.
3. **Destructive operations need a matching confirmation token.** The phone must echo back a token
   the bridge issued, so a replayed or spoofed document cannot uninstall the backend on its own.
"""

from __future__ import annotations

import json
import secrets
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

__all__ = [
    "OPERATIONS",
    "BridgeError",
    "ControlBridge",
    "Operation",
    "argv_for",
]


@dataclass(frozen=True)
class Operation:
    id: str
    title: str
    scope: str  # "device" | "daemon"
    risk: str  # "safe" | "disruptive" | "destructive"
    argv: tuple[str, ...]
    group: str

    @property
    def requires_confirmation(self) -> bool:
        return self.risk != "safe"


def _op(id: str, title: str, scope: str, risk: str, argv: list[str], group: str) -> Operation:
    return Operation(id, title, scope, risk, tuple(argv), group)


#: The canonical registry. **Mirrored in `ios/App/Operations.swift`**, and a test asserts the two
#: agree — two hand-maintained copies of a security-relevant allow-list in different languages is
#: exactly the thing that drifts silently, so the drift is made a test failure instead.
OPERATIONS: dict[str, Operation] = {
    o.id: o
    for o in [
        _op("pair", "Pair this device", "device", "safe", ["--pair"], "Pairing"),
        _op("unpair", "Unpair", "device", "destructive", ["--unpair"], "Pairing"),
        _op("retire", "Retire", "device", "destructive", ["--retire"], "Pairing"),
        _op("serve", "Start serving", "daemon", "safe", ["--serve"], "Runtime"),
        _op("restart", "Restart", "daemon", "disruptive", ["--restart"], "Runtime"),
        _op("resurrect", "Resurrect", "daemon", "disruptive", ["--resurrect"], "Runtime"),
        _op("resume", "Resume run", "daemon", "safe", ["--resume"], "Runtime"),
        _op("daemon-loop", "Daemon loop", "daemon", "safe", ["--daemon-loop"], "Runtime"),
        _op("doctor", "Doctor", "daemon", "safe", ["--doctor"], "Maintenance"),
        _op("version", "Version", "daemon", "safe", ["--version"], "Maintenance"),
        _op("update", "Update", "daemon", "disruptive", ["--update"], "Maintenance"),
        _op("upgrade", "Upgrade", "daemon", "disruptive", ["--upgrade"], "Maintenance"),
        _op("collect", "Collect diagnostics", "daemon", "safe", ["--collect"], "Maintenance"),
        _op("clear", "Clear state", "daemon", "destructive", ["--clear"], "Maintenance"),
        _op("uninstall", "Uninstall", "daemon", "destructive", ["--uninstall"], "Maintenance"),
        _op("login", "Seed platform logins", "daemon", "safe", ["--login"], "Platforms"),
    ]
}


class BridgeError(RuntimeError):
    """The bridge refused a request. Refusals are always explained."""


def argv_for(op_id: str, *, executable: str = "superresearch") -> list[str]:
    """Resolve an operation id to its full argv.

    The single point where an id becomes a command. Anything not in the registry raises — an unknown
    id must not fall through to something that runs.
    """
    op = OPERATIONS.get(op_id)
    if op is None:
        raise BridgeError(
            f"unknown operation {op_id!r}. The registry is a closed allow-list precisely so an "
            f"unrecognised id cannot become an executable command; known: {sorted(OPERATIONS)}"
        )
    return [executable, *op.argv]


@dataclass
class ControlBridge:
    """Executes allow-listed operations on this machine.

    *executable* defaults to the installed ``superresearch`` command. *runner* is injectable so the
    tests can assert on the exact argv without running anything — which is the only way to test a
    command executor without executing commands.
    """

    executable: str = "superresearch"
    runner: Any = None
    timeout: float = 900.0
    #: id -> (token, issued_at). Single-use, short-lived.
    _tokens: dict[str, tuple[str, float]] = field(default_factory=dict)
    token_ttl: float = 120.0
    log: list[dict] = field(default_factory=list)

    def issue_confirmation(self, op_id: str, *, now: float | None = None) -> str:
        """Mint a single-use token for a risky operation.

        The phone shows its confirmation dialog, then echoes this back. That makes a *replayed* or
        forged command document insufficient on its own: without a live token the bridge declines,
        so an attacker who can write to the channel still cannot trigger an uninstall.
        """
        if op_id not in OPERATIONS:
            raise BridgeError(f"unknown operation {op_id!r}")
        token = secrets.token_hex(16)
        self._tokens[op_id] = (token, now if now is not None else time.time())
        return token

    def _check_token(self, op: Operation, supplied: str | None, now: float) -> None:
        if not op.requires_confirmation:
            return
        entry = self._tokens.pop(op.id, None)  # single use: popped whether or not it matches
        if entry is None:
            raise BridgeError(
                f"{op.id} is {op.risk} and needs a confirmation token; none was issued. "
                f"Call issue_confirmation() after the user confirms."
            )
        token, issued = entry
        if now - issued > self.token_ttl:
            raise BridgeError(
                f"the confirmation token for {op.id} expired after {self.token_ttl:.0f}s. "
                f"A stale token is refused so a delayed replay cannot act on an old decision."
            )
        if not supplied or not secrets.compare_digest(supplied, token):
            raise BridgeError(f"the confirmation token for {op.id} does not match")

    def execute(
        self, op_id: str, *, confirmation: str | None = None, now: float | None = None
    ) -> dict:
        """Run one operation. Returns a record; never raises for a non-zero exit.

        A failing backend command is *data* the app displays, not an exception — the phone needs the
        exit code and the output either way, and turning a failure into a traceback would lose both.
        """
        now = now if now is not None else time.time()
        op = OPERATIONS.get(op_id)
        if op is None:
            raise BridgeError(f"unknown operation {op_id!r}")
        if op.scope != "daemon":
            raise BridgeError(
                f"{op.id} is device-scoped — the phone performs it against Firestore itself. "
                f"The bridge only runs daemon-scoped operations."
            )
        self._check_token(op, confirmation, now)

        argv = argv_for(op.id, executable=self.executable)
        run = self.runner or _default_runner
        # shell=False is implicit with a list argv, and it is the reason a hostile id could not do
        # anything even if one got past the registry: there is no shell to inject into.
        completed = run(argv, self.timeout)
        record = {
            "op": op.id,
            "argv": argv,
            "exit": completed.get("returncode"),
            "stdout": (completed.get("stdout") or "")[-4000:],
            "stderr": (completed.get("stderr") or "")[-4000:],
            "at": now,
        }
        self.log.append(record)
        return record


def _default_runner(argv: list[str], timeout: float) -> dict:
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False, shell=False
        )
        return {"returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    except FileNotFoundError:
        return {
            "returncode": 127,
            "stdout": "",
            "stderr": (
                f"{argv[0]!r} is not on PATH. The bridge invokes the installed backend command; "
                f"it does not contain a copy of it."
            ),
        }
    except subprocess.TimeoutExpired:
        return {"returncode": 124, "stdout": "", "stderr": f"timed out after {timeout:.0f}s"}


def swift_registry_ids(swift_source: Path) -> set[str]:
    """Extract operation ids from the Swift mirror, for the drift check.

    Parsed rather than trusted: two hand-maintained copies of a security-relevant allow-list in
    different languages drift, and a drift here means the app offers an operation the bridge will
    refuse, or vice versa.
    """
    import re

    text = swift_source.read_text(encoding="utf-8")
    return set(re.findall(r'id:\s*"([a-z-]+)",\s*title:', text))
