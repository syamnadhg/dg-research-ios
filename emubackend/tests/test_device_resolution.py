"""Which simulator is ours — and the guard that stops "first booted" coming back.

⚠ THE INCIDENT, 2026-08-07. The Mac rebooted. CoreSimulatorService found ``SR-iPhone17Pro`` in a
stale ``Booted`` state and shut it down; Simulator.app then booted its own remembered
``CurrentDeviceUDID``, a stock ``iPhone 17`` that had never had anything installed. The owner opened
the Simulator, saw a clean home screen, and concluded the app had been uninstalled.

The app was fine. What was not fine is that every device lookup in this repo resolved the target as
*the first booted simulator* — which, in that state, was the blank phone. A rebuild would have
installed onto it, the pairing and four hand-made platform logins would have appeared lost, and
every gate would have run green against nothing. This Mac has three devices whose names begin
"iPhone 17" across two runtimes.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from emubackend.substrate import device

REPO = Path(__file__).resolve().parent.parent.parent


# --- resolution order ------------------------------------------------------------------------


def test_an_explicit_udid_always_wins(monkeypatch):
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: ["OTHER"])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: "NAMED")
    assert device.resolve_udid("EXPLICIT") == "EXPLICIT"


def test_the_device_holding_the_app_wins_over_whatever_is_booted(monkeypatch):
    """⭐ The incident, directly. The blank phone was booted; ours was not."""
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: ["OURS"])
    monkeypatch.setattr(device, "booted_udids", lambda: ["BLANK-BOOTED"])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: "OURS")
    assert device.resolve_udid() == "OURS"


def test_when_several_devices_have_the_app_the_booted_one_wins(monkeypatch):
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: ["A", "B"])
    monkeypatch.setattr(device, "booted_udids", lambda: ["B"])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: None)
    assert device.resolve_udid() == "B"


def test_when_several_have_the_app_and_none_is_booted_the_named_one_wins(monkeypatch):
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: ["A", "B"])
    monkeypatch.setattr(device, "booted_udids", lambda: [])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: "B")
    assert device.resolve_udid() == "B"


def test_the_named_device_is_used_before_the_app_is_ever_installed(monkeypatch):
    # A fresh clone: the device exists, the app has never been built onto it.
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: [])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: "NAMED")
    monkeypatch.setattr(device, "booted_udids", lambda: ["SOMETHING-ELSE"])
    assert device.resolve_udid() == "NAMED"


def test_require_app_refuses_to_fall_back_to_a_blank_booted_device(monkeypatch):
    """⭐ A gate must fail loudly rather than run against a phone with nothing on it."""
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: [])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: None)
    monkeypatch.setattr(device, "booted_udids", lambda: ["BLANK"])
    with pytest.raises(device.NoDeviceFound):
        device.resolve_udid(require_app=True)


def test_without_require_app_a_booted_device_is_a_last_resort_not_a_default(monkeypatch):
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: [])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: None)
    monkeypatch.setattr(device, "booted_udids", lambda: ["BLANK"])
    assert device.resolve_udid() == "BLANK"


def test_nothing_at_all_raises_rather_than_returning_none(monkeypatch):
    monkeypatch.setattr(device, "udids_with_app_installed", lambda *a, **k: [])
    monkeypatch.setattr(device, "udid_for_name", lambda *a, **k: None)
    monkeypatch.setattr(device, "booted_udids", lambda: [])
    with pytest.raises(device.NoDeviceFound):
        device.resolve_udid()


# --- name matching ---------------------------------------------------------------------------


def test_the_name_match_is_anchored_so_a_prefix_cannot_win(monkeypatch):
    """``iPhone 17`` must not match ``iPhone 17 Pro Max``.

    There are three such devices on this Mac. An unanchored match is how the wrong one gets picked
    with no error anywhere.
    """
    listing = (
        "-- iOS 26.5 --\n"
        "    iPhone 17 Pro Max (11111111-1111-1111-1111-111111111111) (Shutdown)\n"
        "    iPhone 17 (22222222-2222-2222-2222-222222222222) (Booted)\n"
        "    SR-iPhone17Pro (33333333-3333-3333-3333-333333333333) (Shutdown)\n"
    )
    monkeypatch.setattr(device, "_run", lambda *a, **k: listing)
    assert device.udid_for_name("iPhone 17") == "22222222-2222-2222-2222-222222222222"
    assert device.udid_for_name("SR-iPhone17Pro") == "33333333-3333-3333-3333-333333333333"


def test_an_unknown_name_is_none_rather_than_the_first_row(monkeypatch):
    monkeypatch.setattr(
        device, "_run",
        lambda *a, **k: "    iPhone 17 (22222222-2222-2222-2222-222222222222) (Booted)\n",
    )
    assert device.udid_for_name("No-Such-Device") is None


# --- the guard -------------------------------------------------------------------------------


#: Files allowed to mention the booted list at all. `device.py` owns the concept; `sim.sh` reports
#: it to a human; `all_gates.sh` only prints it inside a hint string.
_BOOTED_ALLOWED = {
    "emubackend/substrate/device.py",
    "bin/sim.sh",
    "bin/all_gates.sh",
    "emubackend/tests/test_device_resolution.py",
    "docs/RUNBOOK.md",
}

_FIRST_BOOTED = re.compile(r"devices\s+booted")


def test_nothing_resolves_the_target_device_as_whatever_is_booted():
    """⭐ The guard. A positive fixture, because this is a scanner.

    The defect is not a wrong value — it is a *plausible* value from the wrong phone, which produces
    a green gate against a blank simulator. Only one module is allowed to ask which devices are
    booted, and it does so as one input among four.
    """
    offenders = []
    for path in list(REPO.glob("bin/*.py")) + list(REPO.glob("bin/*.sh")) + list(
        REPO.glob("emubackend/**/*.py")
    ):
        rel = path.relative_to(REPO).as_posix()
        if rel in _BOOTED_ALLOWED:
            continue
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        if _FIRST_BOOTED.search(text):
            offenders.append(rel)
    assert offenders == [], (
        "these resolve the simulator from the booted list directly. Use "
        "emubackend.substrate.device.resolve_udid() — on 2026-08-07 'first booted' was a stock "
        f"iPhone with nothing installed: {offenders}"
    )


def test_the_guard_is_not_vacuous():
    """The scan must actually be looking at files, or it passes by finding nothing."""
    scanned = (
        list(REPO.glob("bin/*.py")) + list(REPO.glob("bin/*.sh"))
        + list(REPO.glob("emubackend/**/*.py"))
    )
    assert len(scanned) > 20, f"only {len(scanned)} files scanned — the globs are probably wrong"


def test_the_allow_list_names_only_files_that_exist():
    """A stale allow-list entry silently exempts nothing and hides that the rule moved."""
    missing = [p for p in _BOOTED_ALLOWED if not (REPO / p).exists()]
    assert missing == [], f"allow-list names files that no longer exist: {missing}"
