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


@pytest.mark.parametrize("w,h", [(402, 100), (402, 250), (100, 874), (60, 40)])
def test_a_too_small_result_is_refused_rather_than_returned(w, h):
    """The floor. A tiny screen produces taps that are computed, validated, dispatched — and land

    nowhere, which is the failure mode that wasted the most time. Refusing names the real problem.
    """
    with pytest.raises(hid.HidError, match="looks like a device screen in points"):
        hid.largest_frame(frame(0, 0, w, h))


def test_a_pixel_denominated_frame_is_not_mistaken_for_the_screen():
    """The second wrong answer, and the reason largest-by-area alone is not enough.

    A 1206x2622 frame (402x874 at 3x) appeared while another app was foreground. Taken as the screen it
    made every tap compute against a display three times too big, so they clamped to the right edge —
    every recorded event had clientX pinned at 402.
    """
    out = "\n".join([frame(0, 0, 1206, 2622), frame(0, 0, 402, 874)])
    assert hid.largest_frame(out) == hid.Screen(width=402.0, height=874.0)


def test_all_three_historical_wrong_answers_are_rejected_together():
    """The exact tree that broke B0a twice, plus the correct frame."""
    out = "\n".join(
        [frame(0, 0, 402, 100), frame(0, 0, 1206, 2622), frame(0, 0, 402, 874), frame(0, 0, 30, 750)]
    )
    assert hid.largest_frame(out) == hid.Screen(width=402.0, height=874.0)


def test_a_tree_of_only_pixel_frames_says_so_instead_of_guessing():
    with pytest.raises(hid.HidError, match="denominated in PIXELS"):
        hid.largest_frame(frame(0, 0, 1206, 2622))


def test_the_largest_ipad_still_counts_as_plausible():
    """The 12.9\" iPad Pro is 1024x1366pt — the bound must not exclude a real device."""
    assert hid.largest_frame(frame(0, 0, 1024, 1366)).height == 1366.0


def test_a_real_device_size_clears_the_floor():
    for w, h in [(402, 874), (393, 852), (430, 932), (320, 568)]:
        assert hid.largest_frame(frame(0, 0, w, h)).height == float(h)
