"""The modal sweep, and the two gates that must NOT be swept.

⭐ Deliberately small, matching the backend: it has no cookie-banner, consent or onboarding
dismissal either, and explicitly tells its vision agent that a cookie banner is not a login wall.
Building a general dismisser would be inventing behaviour the reference implementation does not have.
"""
from __future__ import annotations

from emubackend import phases


class TestTheSweep:

    def test_the_backends_three_labels_are_swept(self):
        assert phases.sweep_targets(["Okay", "Got it", "Dismiss"], "chatgpt") == [
            "Okay", "Got it", "Dismiss"
        ]

    def test_matching_is_case_and_whitespace_insensitive(self):
        assert phases.sweep_targets(["  GOT  IT "], "chatgpt") == ["  GOT  IT "]

    def test_unrelated_controls_are_left_alone(self):
        # A sweep that presses anything it does not recognise is a sweep that cancels runs.
        assert phases.sweep_targets(["Send", "Delete chat", "Upgrade"], "chatgpt") == []

    def test_an_empty_label_is_not_swept(self):
        assert phases.sweep_targets(["", "   "], "chatgpt") == []


class TestTheGatesAreNotSwept:
    """⛔ The worst possible outcome this prevents.

    "Start research" and "Skip" are not decoration to be dismissed — they BLOCK the phase. Sweeping
    them means the phase reports success and no research ever starts, which looks exactly like a
    successful run until the harvest finds nothing.
    """

    def test_geminis_START_RESEARCH_is_never_swept(self):
        assert phases.sweep_targets(["Start research", "Okay"], "gemini") == ["Okay"]

    def test_claudes_SKIP_is_never_swept(self):
        assert phases.sweep_targets(["Skip", "Dismiss"], "claude") == ["Dismiss"]

    def test_the_gate_is_returned_for_the_caller_to_PRESS_deliberately(self):
        assert phases.gate_for("gemini", ["Okay", "Start research"]) == "Start research"
        assert phases.gate_for("claude", ["Skip"]) == "Skip"

    def test_a_gate_that_is_not_on_screen_is_none(self):
        assert phases.gate_for("gemini", ["Okay"]) is None

    def test_a_platform_with_no_gate_has_none(self):
        assert phases.gate_for("chatgpt", ["Start research", "Skip"]) is None

    def test_one_platforms_gate_is_not_anothers(self):
        # Claude's "Skip" is a gate on Claude and just a word on Gemini — sweeping it on Gemini
        # would be wrong for a different reason, so it is not in the sweep list at all.
        assert phases.sweep_targets(["Skip"], "gemini") == []


def test_NO_GATE_LABEL_MAY_EVER_APPEAR_IN_THE_SWEEP_LIST():
    """The invariant that keeps the sweep from cancelling the research it is meant to protect.

    ⚠ This is the killable form of the runtime gate-exclusion, which is currently redundant because
    the two lists do not overlap. The plausible future edit is adding "Skip" to the sweep list — it
    looks exactly like a dismissal — and that edit would make a phase report success while no
    research ever started. Asserted here so it fails loudly at the moment someone makes it.
    """
    swept = {label.lower() for label in phases.SWEEP_LABELS}
    for platform, gate in phases.PLATFORM_GATES.items():
        assert gate.lower() not in swept, (
            f"{platform}'s blocking gate {gate!r} is in the sweep list — the sweep would press it "
            f"as a dismissal, and the phase would report success having started no research"
        )
