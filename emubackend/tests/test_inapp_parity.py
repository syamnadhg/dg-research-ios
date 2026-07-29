"""Guard the Swift in-app orchestrator against drifting from the Python one.

There are now **two implementations of the same phase semantics** — `emubackend/phases.py` driving
Simulator Safari, and `ios/Sources/SuperResearchDeviceCore/InAppPipeline.swift` driving the app's own
web view. That duplication is forced (compiled Python cannot run on iOS), but it is the same shape as
the `control.py`/`Operations.swift` pair, and that one already taught the lesson: two hand-maintained
copies of the same rules in different languages drift silently, so the drift is made a test failure.

These assert the properties that were **expensive to learn**, not general equivalence. Each one below
corresponds to a real defect that reached a gate:

* toggle idempotence — shipped in Python, found by running the e2e twice
* stop-before-skip — a stop during a skippable phase must stop
* `phase_start` after the pause gate — a paused run must not advertise a phase it has not begun
* send asserts acceptance, not completion — the completion version failed on every run
* sources harvested by text, not href — the P1 incident, zero sources for a whole run
"""

from __future__ import annotations

import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SWIFT_PIPELINE = REPO / "ios" / "Sources" / "SuperResearchDeviceCore" / "InAppPipeline.swift"
SWIFT_HARNESS = REPO / "ios" / "C1Harness" / "main.swift"
MOCK_SELECTORS = REPO / "fixtures" / "mockplatform" / "selectors_mock.json"


def _code(path: Path) -> str:
    """Source with comments stripped, so a rule's documentation cannot satisfy the rule."""
    text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("//")
    )


def _balanced(source: str, start: int, opener: str = "{", closer: str = "}") -> str:
    """The balanced region beginning at the first *opener* at or after *start*."""
    begin = source.index(opener, start)
    depth = 0
    for i in range(begin, len(source)):
        if source[i] == opener:
            depth += 1
        elif source[i] == closer:
            depth -= 1
            if depth == 0:
                return source[begin + 1 : i]
    raise AssertionError(f"unbalanced {opener}{closer} from offset {begin}")


def _body_of(source: str, fragment: str, *, after: str | None = None) -> str:
    """A function body.

    *after* names the text immediately preceding the body's opening brace, and it is not optional
    bookkeeping: `run(...)`'s signature contains default arguments that are *closures* — `{ false }`,
    `{ _ in false }` — so "the first `{` after the name" lands inside the parameter list and the
    extracted "body" is a default value. Found the honest way, by three ordering tests passing against
    text that was not the body.
    """
    start = source.index(fragment)
    if after is not None:
        start = source.index(after, start)
    return _balanced(source, start)


def _array_literal(source: str, fragment: str) -> str:
    """A `[...]` literal's contents — for `let X: [String: [String]] = [ ... ]`.

    A separate helper because a Swift dictionary literal is bracketed, not braced, and reusing the
    brace-based reader silently returned the next unrelated block.

    Anchored on the `=` because a Swift *type annotation* is also bracketed: searching from the name
    finds `[String: [String]]` and extracts the type, not the value. Both mistakes in this module have
    the same shape — a delimiter search that hits a syntactically earlier, plausible-looking match — so
    each helper now names where the region actually starts instead of guessing.
    """
    start = source.index("=", source.index(fragment))
    return _balanced(source, start, opener="[", closer="]")


# ======================================================================================
# the bug that shipped once already
# ======================================================================================


def test_the_swift_toggle_step_checks_before_it_taps():
    """Idempotence. Without this the second run of any device disables deep research silently."""
    body = _body_of(_code(SWIFT_PIPELINE), "public func enableDeepResearch()")
    assert "if try await togglePressed(toggle) { return false }" in body, (
        "enableDeepResearch must return early when the toggle is already on. Deep-research state "
        "persists across sessions, so an unconditional tap turns it OFF on every run after the first "
        "— and the run then completes with it disabled while reporting success."
    )


def test_the_swift_toggle_step_verifies_its_own_outcome():
    body = _body_of(_code(SWIFT_PIPELINE), "public func enableDeepResearch()")
    assert "outcomeUnconfirmed" in body, (
        "a tap that did not take must surface, not pass silently — this is also the in-app isTrusted "
        "boundary, where a click lands and changes nothing"
    )


# ======================================================================================
# the ordering invariants
# ======================================================================================


def test_the_stop_check_precedes_the_skip_check_in_swift_too():
    """Otherwise a stop lands only on the phases nobody wanted to skip."""
    body = _body_of(_code(SWIFT_PIPELINE), "public mutating func run(", after="-> Outcome {")
    stop = body.index("shouldStop()")
    skip = body.index("shouldSkip(phase)")
    assert stop < skip, "the stop check must come first, as it does in emubackend/pipeline.py"


def test_phase_start_is_emitted_after_the_pause_gate_in_swift_too():
    """A paused run that already announced phase_start shows progress that is not happening."""
    body = _body_of(_code(SWIFT_PIPELINE), "public mutating func run(", after="-> Outcome {")
    gate = body.index("await awaitResume()")
    start = body.index('events.append((phase, "phase_start"))')
    assert gate < start, "the pause gate must precede the phase_start emission"


def test_a_skipped_phase_is_announced_rather_than_silent():
    body = _body_of(_code(SWIFT_PIPELINE), "public mutating func run(", after="-> Outcome {")
    assert 'phase_skipped' in body, "a silent skip is indistinguishable from a phase that never ran"


# ======================================================================================
# the two predicate lessons
# ======================================================================================


def test_send_asserts_acceptance_and_not_completion():
    """Gating send on a finished response reported a false failure on every single run."""
    body = _body_of(_code(SWIFT_PIPELINE), "public func send()")
    assert "response_container" in body, "send's predicate must check the container exists"
    assert "complete" not in body, (
        "send must NOT wait for completion — the response arrives hundreds of ms later, and a false "
        "failure escalates an agent onto a healthy page"
    )


def test_sources_are_harvested_by_text_not_by_href():
    """The P1 incident: every click landed, extraction returned 0 for an entire run."""
    body = _body_of(_code(SWIFT_PIPELINE), "public func harvestSources()")
    assert "innerText" in body
    assert "href" not in body, "a link-only harvest finds zero on a panel that renders non-anchors"


def test_the_composer_goes_through_the_model_updating_path():
    body = _body_of(_code(SWIFT_PIPELINE), "public func fillComposer(")
    assert "insertText" in body, (
        "assigning textContent leaves send disabled — these editors gate on their internal model"
    )


# ======================================================================================
# the manifest the C1 harness inlines
# ======================================================================================


def test_the_harness_does_not_inline_a_manifest():
    """The harness must take its platform and selectors from the GENERATED constant.

    It used to inline the mock's manifest, and that quietly capped C1 at one platform: the coverage gate
    could demand "run C1 against chatgpt" with no way to satisfy it short of editing Swift. This test
    exists to stop that regressing — an inlined copy would also drift from the manifest every other
    consumer reads.
    """
    code = _code(SWIFT_HARNESS)
    assert "SRManifest.selectors" in code, "the harness must use the generated manifest"
    assert "SRManifest.platform" in code, "the platform must come from the generated manifest"
    assert "MOCK_MANIFEST" not in code, (
        "a hardcoded manifest is back — it caps C1 at whatever platform was compiled in"
    )


def test_the_verdict_carries_its_manifests_provenance():
    """Without it the coverage gate cannot tell a wiring proof from real coverage."""
    code = _code(SWIFT_HARNESS)
    assert '"manifest_source": SRManifest.manifestSource' in code


def test_both_implementations_cover_the_same_phase_keys():
    """A key handled on one side and not the other is a phase that behaves differently per surface."""
    swift = _code(SWIFT_PIPELINE)
    for key in (
        "logged_in_marker",
        "composer",
        "send",
        "deep_research_toggle",
        "sources",
        "response_container",
    ):
        assert key in swift, f"the Swift orchestrator never references {key}"
