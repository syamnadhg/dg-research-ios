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

    async def get_attribute(self, name):
        # ⚠ Deliberately never "complete". `data-state=complete` is a short-circuit that returns
        # done before the text is ever classified, so a fixture answering it would make the
        # emptiness guard unreachable — the wait would pass for a reason the test did not intend.
        return None


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


# --------------------------------------------------------------------------------------------
# Item 3 — the `empty` verdict had NO CONSUMER.
#
# ⛔ `classify_response` has always been able to say "empty", and nothing ever asked it. The wait's
# own guard was a bare `text.strip()`, which catches whitespace and nothing else — but the shape
# measured on the live page is a SPEAKER PREFIX ("ChatGPT said:"), which is non-empty text that is
# perfectly stable. So it passed the stability gate, was accepted as the answer, and became the
# brief that three deep-research agents were handed. Meanwhile the harvest read it, found zero
# sources, and reported READ DRIFT — sending the next session to repair selectors that were working.
#
# Both ends are fixed here, and the tests assert the MECHANISM: whether completion happens and
# whether extraction is refused, not whether a string appears somewhere.


class _StablePrefixPage(_Page):
    """A container whose text never changes and is only a speaker prefix.

    The point of the fixture is that it is STABLE — the old guard's other condition — so the only
    thing that can refuse it is the emptiness verdict.
    """

    def __init__(self, text="ChatGPT said:"):
        super().__init__(text)


def test_a_stable_SPEAKER_PREFIX_is_never_accepted_as_a_finished_response():
    """It is stable, generation has stopped, and it is still not an answer."""
    driver = _driver("ChatGPT said:")
    verdict = asyncio.run(driver.await_response(timeout=0.6, stable_for=0.05, poll=0.02))
    assert verdict["done"] is False, (
        "a speaker prefix that never grew was accepted as the response — this is the exact shape "
        "that became the brief for three deep-research runs"
    )


def test_the_timeout_reason_NAMES_the_stall_rather_than_blaming_the_clock():
    # "still not complete after 0.6s" invites a longer timeout. The container being empty is a
    # platform-side stall and no amount of waiting fixes it.
    verdict = asyncio.run(_driver("ChatGPT said:").await_response(timeout=0.6, stable_for=0.05, poll=0.02))
    assert "EMPTY" in verdict["reason"] or "stall" in verdict["reason"], verdict["reason"]


def test_real_content_STILL_completes_so_the_guard_is_not_the_outage():
    # The other half of every guard: it must not refuse healthy pages.
    driver = _driver("ChatGPT said: A genuine answer with real substance in it, at length.")
    verdict = asyncio.run(driver.await_response(timeout=2.0, stable_for=0.05, poll=0.02))
    assert verdict["done"] is True


def test_a_clarifying_QUESTION_still_completes_the_wait_so_its_own_diagnosis_survives():
    """⚠ Only `empty` is refused, and this is why.

    A question passes the wait and is then raised BY NAME at the harvest — "the platform asked a
    clarifying question and is waiting". Refusing it here would replace that specific, actionable
    report with a generic timeout.
    """
    driver = _driver("ChatGPT said: Could you clarify which aspect you want me to focus on?")
    verdict = asyncio.run(driver.await_response(timeout=2.0, stable_for=0.05, poll=0.02))
    assert verdict["done"] is True


def test_harvest_REFUSES_an_empty_turn_rather_than_reporting_zero_sources():
    """Zero sources reads as read drift and sends the next session to repair healthy selectors."""
    with pytest.raises(phases.PlatformStateError) as exc:
        asyncio.run(_driver("ChatGPT said:").harvest_sources())
    assert "EMPTY" in str(exc.value)
    assert "not a selector failure" in str(exc.value)


# --------------------------------------------------------------------------------------------
# The in-flight probe must test VISIBILITY, not mere presence.
#
# ⛔ Measured on a COMPLETED Gemini deep-research run, 2026-08-09: the page said "I've completed
# your research", the 23,000-character report was in the DOM — and a `Stop response` button was
# still present at HEIGHT 0. A selector-only check reports "still generating" forever, so the wait
# can never finish, the run burns its whole timeout on a report already sitting there, and it then
# reports a timeout — which invites raising the budget for something no waiting fixes.
#
# ⚠ These EXECUTE the probe's JavaScript against stub elements rather than asserting on its source.
# A presence assertion ("the source mentions getBoundingClientRect") passes against a check that is
# never consulted, which is the failure mode this repo keeps re-learning.


def _run_generating_js(elements):
    """Execute the real in-flight expression against a stub document."""
    import json as _json
    import subprocess

    from emubackend.tests.test_gate_zero_surface import _node

    captured = {}

    class _Recorder(_Page):
        def __init__(self):
            super().__init__("x")

        async def evaluate(self, js, *a):
            captured["js"] = js
            return False

    manifest = SelectorManifest(
        platforms={"chatgpt": {k: SelectorEntry(css=("#x",), provenance="t")
                               for k in ("logged_in_marker", "composer", "send",
                                         "sources", "response_container")}},
        source="test",
    )
    driver = phases.PlatformDriver(
        "chatgpt",
        phases.PhaseDeps(
            manifest=manifest,
            registry=intents.IntentRegistry(),
            history=harvest.HarvestHistory(),
            pages={"chatgpt": _Recorder()},
            topic="t",
        ),
    )
    asyncio.run(driver.is_generating())
    assert "js" in captured, "the probe never evaluated anything — nothing was measured"

    harness = """
const els = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const mk = e => ({
  getBoundingClientRect: () => ({ width: e.w, height: e.h }),
});
const document = { querySelectorAll: () => els.map(mk) };
const getComputedStyle = e => ({ visibility: 'visible', display: 'block' });
console.log(JSON.stringify(%s));
""" % captured["js"]
    out = subprocess.run(
        [_node(), "-e", harness], input=_json.dumps(elements),
        capture_output=True, text=True, timeout=30,
    )
    assert out.returncode == 0, out.stderr
    return _json.loads(out.stdout)


def test_a_RETIRED_stop_control_at_zero_height_does_not_mean_generating():
    """The measured shape: the control is still in the DOM, rendered at nothing."""
    assert _run_generating_js([{"w": 0, "h": 0}]) is False, (
        "a zero-height stop button read as in-flight — the wait can then never complete and the "
        "run times out on a report that is already finished"
    )


def test_a_REAL_visible_stop_control_still_means_generating():
    # The other half: the guard must not declare every run finished the moment it starts.
    assert _run_generating_js([{"w": 32, "h": 32}]) is True


def test_a_visible_control_wins_when_a_retired_one_is_also_present():
    # Both in the DOM at once is the realistic mid-run state on a page that has run twice.
    assert _run_generating_js([{"w": 0, "h": 0}, {"w": 24, "h": 24}]) is True


def test_no_matching_control_at_all_means_not_generating():
    assert _run_generating_js([]) is False
