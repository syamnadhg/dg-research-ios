"""P1 produces a BRIEF, with Deep Research off — and P2 consumes it.

Three defects lived here together, and none of them made a run fail. It typed the bare topic (a
chat answer, not a brief); it never turned Deep Research off, which persists across runs, so run 2's
P1 produced a 30-minute report where a brief was wanted; and it captured nothing at all, so P1 had
no product and P2 silently re-asked the topic. Every one of those produces a plausible artefact.
"""
from __future__ import annotations

import pytest

from emubackend import prompts


class TestTheWrapperPrompt:

    def test_the_topic_is_wrapped_in_the_backends_own_request(self):
        # Verbatim from the backend. The instruction to omit preamble is load-bearing: P1's output
        # is pasted straight into three deep-research agents, so "Sure! Here's a brief:" would
        # become the first line of every P2 prompt.
        prompt = prompts.brief_prompt("solid-state batteries")
        assert prompt.startswith(
            "Please create a detailed research report brief for a deep research LLM agent"
        )
        assert "that covers this topic: solid-state batteries." in prompt
        assert "no preamble or post-amble" in prompt

    def test_the_prompt_is_NOT_the_bare_topic(self):
        # The defect, stated as an assertion.
        assert prompts.brief_prompt("x" * 30) != "x" * 30

    def test_feedback_is_appended_only_when_present(self):
        assert "USER FEEDBACK" not in prompts.brief_prompt("t")
        assert "USER FEEDBACK" not in prompts.brief_prompt("t", "   ")
        with_feedback = prompts.brief_prompt("t", "focus on cost")
        assert with_feedback.endswith("USER FEEDBACK (incorporate this): focus on cost")

    def test_an_empty_topic_is_REFUSED_rather_than_sent_as_a_bare_wrapper(self):
        # "Please create a research brief that covers this topic: ." is a request a platform will
        # cheerfully answer, and the run would then spend three deep-research units on the answer.
        for empty in ("", "   ", "\n\t"):
            with pytest.raises(ValueError):
                prompts.brief_prompt(empty)

    def test_the_topic_is_trimmed_but_not_otherwise_mangled(self):
        prompt = prompts.brief_prompt("  quantum error correction  ")
        assert "topic: quantum error correction." in prompt


class TestTheTimeoutIsKeyedOnThePhase:
    """⛔ ChatGPT is used TWICE, in two different modes, and one timeout for "chatgpt" is wrong for
    one of them whichever value is chosen."""

    def test_p1_and_p2_do_not_share_a_timeout(self):
        assert prompts.response_timeout(1) != prompts.response_timeout(2)

    def test_p2_allows_far_longer_than_the_240s_that_produced_the_bad_read(self):
        # The measured deep-research run took 8m57s. 240s expired mid-research and the harvest read
        # `Pro thinking` — 27 characters — as the report.
        assert prompts.response_timeout(2) > 240.0
        assert prompts.response_timeout(2) >= 9 * 60

    def test_p1_is_generous_for_a_brief_but_nowhere_near_p2(self):
        assert 60.0 <= prompts.response_timeout(1) <= 600.0

    def test_an_unknown_phase_gets_P1s_timeout_and_never_P2s(self):
        # Erring toward a fast failure on a phase nobody has characterised, rather than a
        # forty-minute hang.
        assert prompts.response_timeout(99) == prompts.response_timeout(1)
        assert prompts.response_timeout(99) != prompts.response_timeout(2)

    def test_phase_zero_has_its_own_and_is_not_treated_as_missing(self):
        # `phase: 0` is a real phase; a truthiness lookup would drop it into the default.
        assert prompts.response_timeout(0) == prompts.RESPONSE_TIMEOUT_SECONDS[0]


class TestTheChatModePlaceholders:
    """A platform that cannot say "chat mode" can never report a positive OFF.

    ⚠ Every entry here is a MEASURED composer placeholder, and each was added after the platform in
    question turned out to be unable to confirm itself off. The guard is deliberately asymmetric —
    "cannot tell" stays false so escalation is refused rather than guessed — but a guard that can
    never say "off" is only half a guard, and it blocks legitimate recovery forever.
    """

    #: Measured in-app, 2026-08-08.
    MEASURED = {
        "chatgpt": "Ask ChatGPT",
        "gemini": "Ask Gemini",
        "claude": "Write your prompt to Claude",
        "notebooklm": "Ask a question or create something",
    }

    def _chat_placeholders(self) -> str:
        from emubackend import phases
        return phases._TOGGLE_STATE_JS

    def _needles(self) -> list[str]:
        import re
        return re.findall(r"placeholder\.includes\('([^']+)'\)", self._chat_placeholders())

    def test_claudes_REAL_placeholder_is_recognised_as_chat_mode(self):
        # ⛔ The bug this caught: Claude's composer says "Write your prompt to Claude", which matched
        # nothing in the list — so Claude could never report `confirmed_off`, and P1's
        # disable-deep-research step could never confirm on that platform.
        #
        # ⚠ Asserted by RUNNING the same matching rule the page does, not by grepping the source for
        # a string — a presence assertion passes against a needle that is never consulted.
        measured = self.MEASURED["claude"].lower()
        assert any(n in measured for n in self._needles()), self._needles()

    def test_every_measured_platform_placeholder_matches_something(self):
        needles = self._needles()
        for platform, placeholder in self.MEASURED.items():
            if platform == "notebooklm":
                continue  # not a research composer; it has no deep-research toggle
            assert any(n in placeholder.lower() for n in needles), (
                f"{platform}'s measured placeholder {placeholder!r} matches no chat-mode needle, "
                f"so that platform can never report a positive OFF"
            )
