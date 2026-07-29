"""The trusted-input channel: AXe HID events into the Simulator.

Why a second channel exists at all: `Runtime.evaluate` can dispatch a click, but a
JS-dispatched event carries ``isTrusted === false``, and the chat SPAs this pipeline drives
reject exactly those. `simctl` has no tap command. `idb` is unmaintained and its 5-arg HID
wire format silently drops taps on iOS 26. `pymobiledevice3`'s WebInspector is
physical-device-only. So AXe (Xcode-26 9-arg SimulatorKit HID) is the channel.

AXe coordinates are **screen points**, not CSS pixels, and their origin is the top-left of
the *device screen* — above Safari's chrome. Translating a DOM rect into one of these is
:mod:`emubackend.substrate.geometry`'s job, and it measures the offset rather than assuming it.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass

__all__ = ["HidError", "Screen", "screen_size", "screenshot", "swipe", "tap", "type_text"]

# axe reports the application frame as e.g. "{{0, 0}, {402, 874}}"
_AXFRAME_RE = re.compile(
    r'"AXFrame"\s*:\s*"\{\{\s*([\d.-]+),\s*([\d.-]+)\s*\},\s*\{\s*([\d.-]+),\s*([\d.-]+)\s*\}\}"'
)


class HidError(RuntimeError):
    """An AXe invocation failed."""


@dataclass(frozen=True)
class Screen:
    width: float
    height: float


def _axe(*args: str, timeout: float = 60.0) -> str:
    proc = subprocess.run(
        ["axe", *args], capture_output=True, text=True, check=False, timeout=timeout
    )
    if proc.returncode != 0:
        raise HidError(
            f"axe {' '.join(args)} failed ({proc.returncode}): "
            f"{proc.stderr.strip() or proc.stdout.strip()}"
        )
    return proc.stdout


def screen_size(udid: str) -> Screen:
    """Screen size in **points**, read from the accessibility tree's root frame.

    Measured rather than looked up from a device-name table: a table goes stale with every
    new device, and picking the wrong row produces taps that land plausibly but wrongly.

    ⚠ This can fail with *"No translation object returned for simulator"* if the device is
    booted but not yet finished starting up. ``xcrun simctl bootstatus <udid> -b`` first.
    """
    out = _axe("describe-ui", "--udid", udid)
    match = _AXFRAME_RE.search(out)
    if not match:
        raise HidError(
            "could not parse an AXFrame from `axe describe-ui`. If it said "
            "'No translation object returned', the device is still starting — run "
            "`xcrun simctl bootstatus <udid> -b` and retry."
        )
    return Screen(width=float(match.group(3)), height=float(match.group(4)))


def tap(udid: str, x: float, y: float, screen: Screen | None = None) -> None:
    """A trusted single tap at screen point (*x*, *y*).

    Coordinates are validated first. Without this, a bad calibration reaches AXe as a
    negative number and AXe's own argument parser reports *"Missing value for '-y'"* —
    because ``-93392`` looks like a flag. That message sends you looking for a CLI problem
    when the actual defect is upstream in the geometry, which is an expensive detour.
    """
    for axis, value in (("x", x), ("y", y)):
        if value != value or value in (float("inf"), float("-inf")):  # NaN / inf
            raise HidError(f"refusing to tap: {axis}={value!r} is not a finite number")
        if value < 0:
            raise HidError(
                f"refusing to tap: {axis}={value:.1f} is negative, which means the "
                f"calibration is wrong (AXe would report this as a missing argument value)"
            )
    if screen is not None and (x > screen.width or y > screen.height):
        raise HidError(
            f"refusing to tap ({x:.1f},{y:.1f}): outside the "
            f"{screen.width:.0f}x{screen.height:.0f}pt screen — the calibration is wrong"
        )
    _axe("tap", "-x", f"{x:g}", "-y", f"{y:g}", "--udid", udid)


def type_text(udid: str, text: str) -> None:
    """Trusted keystrokes into whatever currently has focus.

    ⚠ Not a substitute for ``document.execCommand('insertText', …)`` on
    ``contenteditable`` surfaces: ProseMirror-based composers (which the chat platforms
    use) need the execCommand path to update their internal model. Use HID typing for
    plain inputs, execCommand for rich editors.
    """
    _axe("type", text, "--udid", udid)


def swipe(
    udid: str,
    x1: float,
    y1: float,
    x2: float,
    y2: float,
    duration: float | None = None,
) -> None:
    """A trusted swipe — the only way to scroll, since a JS scroll is untrusted.

    A JS ``window.scrollTo`` *does* move the page, but it does not reproduce the URL-bar
    collapse/expansion that a real swipe triggers, and that collapse changes the very
    chrome offset a tap depends on. Scrolling by swipe keeps the measured geometry honest.
    """
    args = [
        "swipe",
        "--start-x", f"{x1:g}", "--start-y", f"{y1:g}",
        "--end-x", f"{x2:g}", "--end-y", f"{y2:g}",
        "--udid", udid,
    ]
    if duration is not None:
        args += ["--duration", f"{duration:g}"]
    _axe(*args)


def screenshot(udid: str, path: str) -> str:
    """Capture a PNG — the cheapest way to see *why* an assertion failed."""
    _axe("screenshot", "--udid", udid, "--output", path)
    return path
