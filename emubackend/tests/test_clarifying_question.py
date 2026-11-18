"""The clarifying question — deep research's fourth response state.

⚠ Before this existed, a clarifying question passed the wait (it is content, it is stable,
generation has stopped) and then failed the harvest — so the run reported a **selector problem**
when the platform had simply asked something and was waiting for an answer.
"""
from __future__ import annotations

from emubackend import phases


def classify(text: str) -> dict:
    return phases.classify_response(text)


class TestTheQuestionIsRecognised:

    def test_a_short_clarifying_question_is_its_own_state(self):
        out = classify(
            "Before I start, could you clarify whether you want the analysis focused on "
            "passenger vehicles or on commercial fleets?"
        )
        assert out["state"] == "question"
        assert out["matched"]

    def test_the_speaker_prefix_does_not_hide_it(self):
        out = classify("ChatGPT said: A few questions before I begin — which markets matter most?")
        assert out["state"] == "question"

    def test_several_real_phrasings_are_all_caught(self):
        for text in (
            "To make sure I get this right, which of these angles should I prioritise?",
            "Would you like me to include pre-2020 sources?",
            "Should I focus on cost or on performance? Let me know.",
            "Can you clarify the scope before I begin?",
        ):
            assert classify(text)["state"] == "question", text


class TestARealReportIsNotMistakenForAQuestion:
    """⚠ The expensive direction. A report cost a deep-research unit; discarding it as a question
    throws that away, and the run then reports nothing found."""

    def test_a_long_report_ending_with_a_polite_offer_is_still_CONTENT(self):
        # "let me know if you'd like more detail" is how many reports end.
        report = ("# Findings\n\n" + ("Substantial analytical prose about the subject. " * 200)
                  + "\n\nLet me know if you would like more detail on any section.")
        assert len(report) > phases.CLARIFYING_MAX_CHARS
        assert classify(report)["state"] == "content"

    def test_a_question_mark_INSIDE_a_report_does_not_trip_it(self):
        report = ("Is solid-state viable at scale? That question framed the whole inquiry. "
                  * 60)
        assert len(report) > phases.CLARIFYING_MAX_CHARS
        assert classify(report)["state"] == "content"

    def test_a_marker_near_the_START_of_a_long_answer_does_not_trip_it(self):
        # Matched in the TAIL, because a clarifying question is the last thing on screen.
        text = ("Before I begin, here is the summary you asked for. "
                + "Then a great deal of substantive analysis follows. " * 60)
        assert len(text) > phases.CLARIFYING_MAX_CHARS
        assert classify(text)["state"] == "content"

    def test_a_SHORT_answer_whose_marker_is_only_at_the_START_is_content(self):
        # ⚠ The TAIL rule, isolated. The previous test is long enough that the length guard rejects
        # it first, so removing the tail restriction changed nothing there — a mutation proved it.
        # This one is comfortably under the length limit, so only the tail rule can decide.
        text = ("Before I begin: here is the short summary you asked for. "
                + "The technology reached pilot production and costs continue to fall. " * 6)
        assert len(text) < phases.CLARIFYING_MAX_CHARS
        assert len(text) > phases.CLARIFYING_TAIL_CHARS, (
            "the marker must fall OUTSIDE the examined tail for this to test anything"
        )
        assert classify(text)["state"] == "content"

    def test_a_SHORT_answer_with_no_marker_is_still_content(self):
        assert classify("Solid-state cells reached pilot production in 2026.")["state"] == "content"


class TestTheOtherStatesStillWin:

    def test_an_ERROR_is_still_an_error_even_if_it_asks_something(self):
        # Error is checked first, and must stay first: an error banner is non-empty text.
        out = classify("Error loading app. Failed to fetch template. Would you like me to retry?")
        assert out["state"] == "error"

    def test_an_EMPTY_turn_is_still_empty(self):
        assert classify("ChatGPT said:")["state"] == "empty"
        assert classify("   ")["state"] == "empty"


class TestTheHarvestStopsOnAQuestion:
    """It must RAISE, and say what happened — not return an empty harvest.

    An empty harvest is a read-drift signal, and read drift sends the next session to repair
    selectors that are working perfectly while the platform waits for an answer nobody gave it.
    """

    def test_the_harvest_raises_and_NAMES_the_question(self, tmp_path):
        import asyncio

        import pytest

        from emubackend.tests.test_selectors_and_phases import FakeHandle, _deps

        deps, page = _deps(tmp_path, toggle="false")
        page.dom["#resp"] = [
            FakeHandle(
                page, "#resp",
                "Before I start, could you clarify which markets you care about?",
                attrs={"data-state": "complete"},
            )
        ]
        driver = phases.PlatformDriver("chatgpt", deps)

        with pytest.raises(phases.PlatformStateError) as exc:
            asyncio.run(driver.harvest_sources())

        message = str(exc.value)
        assert "CLARIFYING QUESTION" in message
        assert "waiting for an answer" in message
        # ...and it does NOT read as a failure of the platform or of our selectors.
        assert "did not fail" in message
