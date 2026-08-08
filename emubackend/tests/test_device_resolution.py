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


# --- nobody pins a UDID, and `--udid` is safe to capture --------------------------------------

# Assembled rather than written out, so this file does not match its own scanner.
_UDID_LITERAL = re.compile(
    r"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-" + r"[0-9A-F]{12}\b"
)

#: Files allowed to contain a literal UDID: the ones recording an incident that was ABOUT a
#: specific device. A recipe step is never allowed one — that is the defect this guard exists for.
_UDID_ALLOWED = {
    "emubackend/tests/test_device_resolution.py",
}


def _udid_offenders(files, root):
    """The scan itself, factored out so it can be run against a PLANTED offender.

    ⚠ A scanner tested only against the real repo is a negative fixture: it passes because there is
    nothing to find, which is also what it does when the allow-list is too wide or the read is
    silently swallowed. Exercising it on a file known to be dirty is the only way to prove it can
    still say no.
    """
    offenders = []
    for path in files:
        rel = path.relative_to(root).as_posix()
        if rel in _UDID_ALLOWED:
            continue
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for match in _UDID_LITERAL.finditer(text):
            offenders.append(f"{rel}: {match.group()[:8]}...")
    return offenders


def _udid_scan_files():
    return (
        list(REPO.glob("bin/*.py")) + list(REPO.glob("bin/*.sh"))
        + list(REPO.glob("emubackend/**/*.py")) + list(REPO.glob("docs/*.md"))
        + list(REPO.glob("*.md"))
    )


def test_no_script_or_document_pins_a_literal_udid():
    """⭐ The 2026-08-07 recurrence guard, one level up from "first booted".

    EmulatorRecipe.md v5.0 hardcoded ``EB3E...`` in Appendix B and in the gate-zero steps. When the
    Mac rebooted and that device was replaced, every one of those commands kept running — against a
    phone with none of the four hand-made platform logins. A wrong-but-plausible device is the
    failure mode; a *dead* device at least errors, but only if nothing recreates it under a new id.

    Resolve by name: ``bin/sim.sh --udid``, or ``device.resolve_udid()`` in Python.
    """
    offenders = _udid_offenders(_udid_scan_files(), REPO)
    assert offenders == [], (
        "these pin a simulator UDID as a literal. Devices are recreated with new ids; use "
        f"`bin/sim.sh --udid` or device.resolve_udid(): {offenders}"
    )


def test_the_udid_guard_is_not_vacuous():
    """Both halves, because either one alone makes the scan pass while checking nothing.

    A regex that cannot match a UDID reports zero offenders. So does a correct regex over an empty
    file list — and the second is the likelier accident, since the globs are the part a refactor
    moves. Asserting only the pattern would leave exactly the decorative guard this repo keeps
    finding: green, and blind.
    """
    assert _UDID_LITERAL.search("EB3E3597-E62B-413B-B7E5-0FD286ACCC38")
    assert not _UDID_LITERAL.search("not-a-udid-at-all")
    scanned = _udid_scan_files()
    assert len(scanned) > 20, f"only {len(scanned)} files scanned — the globs are wrong"
    assert any(f.suffix == ".md" for f in scanned), "no markdown scanned — the recipe is where it bit"
    assert any(f.suffix == ".sh" for f in scanned), "no shell scanned"


def test_the_udid_scan_actually_flags_a_dirty_file(tmp_path):
    """⭐ The positive fixture. The repo is clean, so the guard above passes either way.

    Plant a UDID in a markdown file — the exact shape that bit, since Appendix B and the RUNBOOK
    were the two that pinned one — and require the scan to name it. Kills a widened allow-list and a
    read that fails open, neither of which the clean-repo assertion can see.
    """
    dirty = tmp_path / "docs" / "recipe.md"
    dirty.parent.mkdir()
    dirty.write_text("boot EB3E3597-E62B-413B-B7E5-0FD286ACCC38 then run the gate\n")
    clean = tmp_path / "docs" / "fine.md"
    clean.write_text("resolve by name with bin/sim.sh --udid\n")

    found = _udid_offenders([dirty, clean], tmp_path)
    assert found == ["docs/recipe.md: EB3E3597..."], found


def test_sim_sh_udid_mode_emits_the_udid_and_nothing_else():
    """`UDID=$(bin/sim.sh --udid)` must capture a bare id.

    Asserts the MECHANISM, not just that a UDID appears somewhere in the output: the early-exit has
    to come before the script's five-line status banner. If a later refactor moves it below those
    echoes the substitution captures `device SR-iPhone17Pro\nudid ...`, and every downstream simctl
    call fails on an argument that still visibly contains the right id.
    """
    text = (REPO / "bin" / "sim.sh").read_text()
    exit_at = text.index('"${1:-}" = "--udid"')
    first_banner = text.index('echo "device ')
    assert exit_at < first_banner, (
        "--udid exits AFTER the status banner, so command substitution captures the banner too"
    )
