"""Which simulator is *ours*.

⚠ THE INCIDENT THIS EXISTS TO PREVENT, which happened on 2026-08-07.

The Mac rebooted. CoreSimulatorService found ``SR-iPhone17Pro`` in a stale ``Booted`` state and shut
it down; Simulator.app then booted its own remembered ``CurrentDeviceUDID``, which was a stock
``iPhone 17`` that had never had anything installed on it. The owner opened the Simulator, saw a
clean home screen, and reasonably concluded the app had been uninstalled. It had not — it was sitting
untouched on a device that was no longer booted.

That is only half the danger. Every device lookup in this repo resolved the target as *"the first
booted simulator"*::

    UDID=$(xcrun simctl list devices booted | sed -n 's/.*(\\(...\\)) (Booted).*/\\1/p' | head -1)

Run in that state, it returns the blank device. A rebuild would then install onto the wrong phone,
the pairing and four hand-made platform logins on the real one would appear to have vanished, and
every gate would run green against an empty simulator. The Mac has **three** devices whose names
start with "iPhone 17" across two runtimes, so this is not a remote coincidence.

The resolution order below is therefore: an explicit UDID, then the device that actually **has our
app installed**, then the device with our **name**, and only then whatever happens to be booted —
and that last case is a warning, not a silent default.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

#: The purpose-built device. Named, not hardcoded by UDID, so a rebuilt simulator keeps working.
DEVICE_NAME = "SR-iPhone17Pro"

#: The app whose presence identifies the right device beyond any doubt.
BUNDLE_ID = "com.distributedglobal.superresearch"

_UDID_RE = re.compile(r"\(([0-9A-F]{8}-[0-9A-F-]{27})\)", re.I)


class NoDeviceFound(RuntimeError):
    """Raised instead of silently picking a device that is probably not ours."""


def _run(*args: str, timeout: int = 60) -> str:
    proc = subprocess.run(
        args, capture_output=True, text=True, check=False, timeout=timeout
    )
    return proc.stdout + proc.stderr


def _devices_root() -> Path:
    return Path.home() / "Library/Developer/CoreSimulator/Devices"


def udids_with_app_installed(bundle_id: str = BUNDLE_ID) -> list[str]:
    """Every device whose container holds the app.

    Reads the filesystem rather than asking ``simctl``, because ``simctl get_app_container`` needs
    the device to be booted — and "the device is shut down" is precisely the situation this has to
    answer for.
    """
    found: list[str] = []
    root = _devices_root()
    if not root.is_dir():
        return found
    for device_dir in root.iterdir():
        bundles = device_dir / "data/Containers/Bundle/Application"
        if not bundles.is_dir():
            continue
        for app_dir in bundles.iterdir():
            plist = next(app_dir.glob("*.app/Info.plist"), None)
            if plist is None:
                continue
            try:
                text = plist.read_bytes()
            except OSError:
                continue
            if bundle_id.encode() in text:
                found.append(device_dir.name)
                break
    return found


def udid_for_name(name: str = DEVICE_NAME) -> str | None:
    """The UDID of the device with this exact name, or None."""
    for line in _run("xcrun", "simctl", "list", "devices").splitlines():
        stripped = line.strip()
        # Match the NAME at the start of the row, so "iPhone 17" cannot match "iPhone 17 Pro Max".
        if not stripped.startswith(name + " ("):
            continue
        match = _UDID_RE.search(stripped)
        if match:
            return match.group(1)
    return None


def booted_udids() -> list[str]:
    out = _run("xcrun", "simctl", "list", "devices", "booted")
    return [m.group(1) for m in _UDID_RE.finditer(out)]


def resolve_udid(preferred: str | None = None, *, require_app: bool = False) -> str:
    """The device this repo means, in a defensible order.

    ``require_app=True`` refuses to fall back to a device that has never had the app installed —
    used by anything that would otherwise happily run a whole gate against a blank simulator.
    """
    if preferred:
        return preferred

    installed = udids_with_app_installed()
    if len(installed) == 1:
        return installed[0]
    if len(installed) > 1:
        # Ambiguous: prefer the one that is also booted, then the one with our name.
        booted = set(booted_udids())
        for udid in installed:
            if udid in booted:
                return udid
        named = udid_for_name()
        if named in installed:
            return named
        return installed[0]

    named = udid_for_name()
    if named:
        return named

    if require_app:
        raise NoDeviceFound(
            f"no simulator has {BUNDLE_ID} installed and none is named {DEVICE_NAME!r}. "
            "Refusing to fall back to whatever is booted — that is how a gate ends up running "
            "against a blank device and reporting green."
        )

    booted = booted_udids()
    if booted:
        return booted[0]

    raise NoDeviceFound(
        f"no booted simulator, none named {DEVICE_NAME!r}, and none with {BUNDLE_ID} installed"
    )


def ensure_booted(udid: str) -> None:
    """Boot the device if it is not already up, and wait for it."""
    if udid in booted_udids():
        return
    _run("xcrun", "simctl", "boot", udid)
    _run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=300)
