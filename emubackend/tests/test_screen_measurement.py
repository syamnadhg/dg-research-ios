"""The screen must be measured as the LARGEST accessibility frame, not the first one.

A regression suite for a bug that cost a full gate diagnosis. `screen_size` took the first `AXFrame`
in `axe describe-ui` output and assumed it was the root — which depends on which app is frontmost and
how its tree is ordered. It returned **402x100pt** for a device whose screen is 402x874. Every probe
tap was then computed inside a 100-point band, none reached the page, and B0a reported "fewer than two
probe taps produced a trusted event": a broken-input-channel message for a bad-measurement fault. B1
had passed minutes earlier through the same code, because a different app happened to be foreground.
"""

from __future__ import annotations

import pytest

from emubackend.substrate import hid


def frame(x: float, y: float, w: float, h: float) -> str:
    return f'"AXFrame" : "{{{{{x}, {y}}}, {{{w}, {h}}}}}"'


def test_the_largest_frame_wins_even_when_it_is_not_first():
    """The exact bug: a small frame appearing first must not be taken as the screen."""
    out = "\n".join([frame(0, 0, 402, 100), frame(0, 0, 402, 874), frame(0, 0, 60, 40)])
    screen = hid.largest_frame(out)
    assert (screen.width, screen.height) == (402.0, 874.0)


def test_a_single_full_screen_frame_is_returned_unchanged():
    screen = hid.largest_frame(frame(0, 0, 393, 852))
    assert (screen.width, screen.height) == (393.0, 852.0)


def test_negative_origins_do_not_confuse_the_parse():
    # Offscreen views report negative origins; only the SIZE matters.
    out = "\n".join([frame(-100, -50, 402, 874), frame(0, 0, 10, 10)])
    assert hid.largest_frame(out).height == 874.0


def test_no_frames_at_all_says_the_device_may_still_be_starting():
    with pytest.raises(hid.HidError, match="No translation object returned"):
        hid.largest_frame("nothing useful here")


@pytest.mark.parametrize(
    "w,h", [(402, 100), (402, 250), (100, 874), (60, 40)]
)
def test_a_plausible_but_too_small_result_is_refused_rather_than_returned(w, h):
    """The floor. A tiny screen produces taps that are computed, validated, dispatched — and land

    nowhere, which is the failure mode that wasted the most time. Refusing names the real problem.
    """
    with pytest.raises(hid.HidError, match="too small to be a device screen"):
        hid.largest_frame(frame(0, 0, w, h))


def test_a_real_device_size_clears_the_floor():
    for w, h in [(402, 874), (393, 852), (430, 932), (320, 568)]:
        assert hid.largest_frame(frame(0, 0, w, h)).height == float(h)
