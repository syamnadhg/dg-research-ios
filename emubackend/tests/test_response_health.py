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


# ======================================================================================
# wired into the run — a classifier nobody calls is dead code
# ======================================================================================

import asyncio

from emubackend import harvest, intents, phases
from emubackend.selectors import SelectorEntry, SelectorManifest


class _Handle:
    def __init__(self, text):
        self.text = text

    async def inner_text(self):
        return self.text


class _Page:
    """Response container and sources both resolve; only the CONTENT differs per test."""

    def __init__(self, text):
        self.text = text

    async def query_selector(self, css):
        return _Handle(self.text)

    async def query_selector_all(self, css):
        return [_Handle(self.text)]

    async def evaluate(self, js, *a):
        return None


def _driver(text):
    manifest = SelectorManifest(
        platforms={
            "chatgpt": {
                key: SelectorEntry(css=("#x",), provenance="test")
                for key in ("logged_in_marker", "composer", "send", "sources", "response_container")
            }
        },
        source="test",
    )
    return phases.PlatformDriver(
        "chatgpt",
        phases.PhaseDeps(
            manifest=manifest,
            registry=intents.IntentRegistry(),
            history=harvest.HarvestHistory(),
            pages={"chatgpt": _Page(text)},
            topic="t",
        ),
    )


def test_harvest_refuses_to_extract_from_a_platform_error():
    """The banner's container resolves perfectly. Extracting harvests the error AS RESEARCH."""
    with pytest.raises(phases.PlatformStateError) as exc:
        asyncio.run(_driver(REAL_ERROR).harvest_sources())
    assert "error loading app" in str(exc.value)


def test_the_refusal_names_the_recovery_the_platform_offered():
    """"It failed, and there was a Retry" is actionable; "it failed" is not."""
    with pytest.raises(phases.PlatformStateError, match="recovery offered"):
        asyncio.run(_driver(REAL_ERROR).harvest_sources())


def test_the_refusal_is_not_a_manifest_error():
    """Different fault, opposite response.

    A ManifestError means the selector rotted and the agent should repair it. This means the selector is
    FINE and the platform failed — repairing would chase a healthy target, which is the recipe's
    "escalate onto a healthy page" failure reached by mis-attributing the fault.
    """
    from emubackend.selectors import ManifestError

    assert not issubclass(phases.PlatformStateError, ManifestError)


def test_a_healthy_response_still_harvests_normally():
    """The guard must not become the outage: real content passes straight through."""
    verdict = asyncio.run(
        _driver("ChatGPT said: A real answer with plenty of substance to it.").harvest_sources()
    )
    assert verdict is not None
