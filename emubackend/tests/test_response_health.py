"""Classifying what is actually IN the response container — the agent's first real failure catalogue.

Both entries here were MEASURED on live ChatGPT during the first real deep-research attempt, and neither
appeared on the imagined list the goal supplied (human-verification prompts, quota modals, mid-wait
logout):

* the feature's own sub-app failing to load — ``Error loading app  Failed to fetch template  Retry``
* a retry that succeeds as a click and produces nothing — that turn stayed EMPTY for six minutes

Both defeat presence-based judgement, which is exactly why this exists. ``response_present`` is
deliberately true for a container in any state (asserting completion at send time reports a false failure
on every run, and with acting enabled escalates onto a healthy page). The price of that correctness is
that presence cannot distinguish a streaming answer from an error banner from six minutes of nothing, so
the run asks a second question later. This is that question.
"""

from __future__ import annotations

import pytest

from emubackend.phases import classify_response

#: Verbatim from the live page.
REAL_ERROR = "ChatGPT said: Error loading app Failed to fetch template Retry"
#: Also verbatim, after clicking the platform's own Retry — for six minutes.
REAL_EMPTY = "ChatGPT said: "


def test_the_real_error_banner_is_an_error_not_content():
    """The banner is non-empty text. An emptiness-first check calls it an answer."""
    got = classify_response(REAL_ERROR)
    assert got["state"] == "error"
    assert got["matched"] == "error loading app"


def test_the_real_error_reports_that_recovery_was_offered():
    """The platform offered Retry. A report saying so is actionable; "it failed" is not."""
    assert classify_response(REAL_ERROR)["recovery_offered"] == ["retry"]


def test_the_real_empty_turn_is_empty_not_content():
    """Six minutes of a speaker prefix and nothing else. `len(text) > 0` reads this as an answer."""
    assert classify_response(REAL_EMPTY)["state"] == "empty"


def test_a_genuine_answer_is_content():
    got = classify_response(
        "ChatGPT said: The newest stable Swift release is Swift 6.3.3, released on June 30, 2026."
    )
    assert got["state"] == "content"
    assert got["chars"] > 40


def test_error_is_checked_before_emptiness():
    """Order matters and is asserted, because the failure it prevents is silent.

    An error banner classified as content is handed to the harvester as research — output that looks like
    an answer, which is worse than a crash.
    """
    assert classify_response("Something went wrong. Please try again.")["state"] == "error"


@pytest.mark.parametrize(
    "text,expected",
    [
        ("You've reached your limit for deep research.", "error"),
        ("Verify you are human to continue", "error"),
        ("Network error", "error"),
        ("", "empty"),
        ("   ", "empty"),
        ("Claude said:", "empty"),
        ("Gemini said: Here is a real answer with substance.", "content"),
    ],
)
def test_the_catalogue(text, expected):
    assert classify_response(text)["state"] == expected


def test_a_speaker_prefix_alone_never_counts_as_an_answer():
    """Every platform's prefix, not just ChatGPT's — the trap is the shape, not the vendor."""
    for prefix in ("ChatGPT said:", "Claude said:", "Gemini said:", "You said:"):
        assert classify_response(prefix)["state"] == "empty", prefix


def test_the_prefix_is_stripped_rather_than_searched_for():
    """A prefix appearing MID-text is content, not an empty marker.

    Otherwise an answer that quotes the platform ("...then ChatGPT said: hello") could be mistaken for a
    bare prefix by a naive `in` check.
    """
    got = classify_response("Earlier in the thread ChatGPT said: hello, and that mattered because...")
    assert got["state"] == "content"
