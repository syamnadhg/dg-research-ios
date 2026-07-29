"""Tests for the AXe input channel's guards and parsing.

These do not need a Simulator: they cover the argument validation and the ``describe-ui``
parsing, both of which exist because their failure modes are misleading rather than loud.
"""

from __future__ import annotations

import pytest

from emubackend.substrate import hid


# --------------------------------------------------------------------------------------
# coordinate validation
# --------------------------------------------------------------------------------------


def test_tap_refuses_negative_coordinates():
    """A negative y reaches AXe as a flag, and AXe reports "Missing value for '-y'".

    That message points at the CLI when the defect is a bad calibration upstream, so the
    guard must reject it here with the real diagnosis.
    """
    with pytest.raises(hid.HidError) as exc:
        hid.tap("SOME-UDID", 100.0, -93392.4)
    assert "negative" in str(exc.value)
    assert "calibration" in str(exc.value)


def test_tap_refuses_nan_and_infinity():
    for bad in (float("nan"), float("inf"), float("-inf")):
        with pytest.raises(hid.HidError, match="finite|negative"):
            hid.tap("SOME-UDID", 100.0, bad)


def test_tap_refuses_coordinates_off_screen_when_screen_is_known():
    screen = hid.Screen(width=402.0, height=874.0)
    with pytest.raises(hid.HidError, match="outside the 402x874pt screen"):
        hid.tap("SOME-UDID", 100.0, 9000.0, screen=screen)


def test_tap_without_a_screen_cannot_check_the_upper_bound(monkeypatch):
    """Documents the deliberate limit: the bound is only enforced when screen is passed."""
    called: list[tuple] = []
    monkeypatch.setattr(hid, "_axe", lambda *a, **k: called.append(a) or "")
    hid.tap("SOME-UDID", 100.0, 9000.0)  # no screen -> permitted
    assert called, "the tap should have been issued"


# --------------------------------------------------------------------------------------
# describe-ui parsing
# --------------------------------------------------------------------------------------


_SAMPLE = """[
  {
    "enabled" : true,
    "AXFrame" : "{{0, 0}, {402, 874}}",
    "type" : "Application",
    "children" : [
      { "AXFrame" : "{{0, 0}, {402, 100}}", "type" : "Group" }
    ]
  }
]"""


def test_screen_size_reads_the_root_application_frame(monkeypatch):
    monkeypatch.setattr(hid, "_axe", lambda *a, **k: _SAMPLE)
    screen = hid.screen_size("SOME-UDID")
    assert (screen.width, screen.height) == (402.0, 874.0)


def test_screen_size_explains_the_not_yet_booted_failure(monkeypatch):
    """The real AXe error here is opaque; the guidance is the point of the message."""
    monkeypatch.setattr(
        hid,
        "_axe",
        lambda *a, **k: "Error: No translation object returned for simulator.",
    )
    with pytest.raises(hid.HidError) as exc:
        hid.screen_size("SOME-UDID")
    assert "bootstatus" in str(exc.value)
