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
    # Asserted as ORDER rather than as one exact line. The early-return block gained an opener dismissal,
    # which broke a substring match while leaving the property untouched — the kind of test that fails for
    # a reason unrelated to what it protects. What matters is that the CHECK precedes the TAP.
    # `togglePressed` became `deepResearchOn` when the rich Python predicate was ported: the old one read
    # only the handle's aria state, which after activation lands on an item the closing menu destroyed. The
    # property under test is unchanged — CHECK before TAP — so the test follows the rename rather than
    # pinning a name.
    check = body.index('deepResearchOn("deep_research_toggle")')
    tap = body.index("page.click(toggle)")
    assert check < tap, (
        "enableDeepResearch must test the toggle BEFORE tapping it. Deep-research state persists across "
        "sessions, so an unconditional tap turns it OFF on every run after the first — and the run then "
        "completes with it disabled while reporting success."
    )
    assert "return false" in body[:tap], (
        "the already-on path must return early rather than falling through to the tap"
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
    # `after=` is REQUIRED here, and for the reason `_body_of`'s own docstring gives: send's signature now
    # carries a closure default argument (`{ try? await Task.sleep(...) }`), so "the first `{` after the
    # name" lands inside the parameter list and the extracted "body" is a default value. Same trap the
    # `run(` tests hit; I walked into it again by adding a parameter.
    body = _body_of(_code(SWIFT_PIPELINE), "public func send(", after="async throws {")
    assert "response_container" in body, "send's predicate must check the container exists"
    # ⚠ The property is unchanged and still worth pinning: send waits for the response to START, never to
    # FINISH. It now POLLS within a bounded window, because checking once tolerated no render tick and
    # reported outcomeUnconfirmed on a send real ChatGPT had accepted — a false failure on a healthy page.
    # So the assertion is about the WAIT's bound, not about the absence of a loop.
    assert "acceptanceWindow" in body, "the acceptance wait must be explicitly bounded"
    assert "awaitResponse" not in body, (
        "send must not wait for completion — that is awaitResponse's separate, much longer job, because a "
        "deep-research answer can take 45 minutes"
    )


def test_sources_are_harvested_by_text_not_by_href():
    """The P1 incident: every click landed, extraction returned 0 for an entire run."""
    # The public entry now retries; the extraction itself moved to `harvestOnce`.
    body = _body_of(_code(SWIFT_PIPELINE), "private func harvestOnce()")
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
    """Without it the coverage gate cannot tell a wiring proof from real coverage.

    The chain got one link longer when the runner was extracted so the app could perform C1 too, and the
    test follows it rather than pinning the old single line: the runner writes whatever `manifestSource`
    it was given, and **every** entry point must feed it `SRManifest.manifestSource`. Checking only the
    runner would let a new entry point pass a placeholder and silently earn coverage credit.
    """
    runner = _code(REPO / "ios" / "Shared" / "C1Runner.swift")
    assert '"manifest_source": manifestSource' in runner

    entry_points = [
        REPO / "ios" / "C1Harness" / "main.swift",   # the standalone gate
        REPO / "ios" / "App" / "main.swift",         # the app's SR_C1 mode, which shares the cookie jar
    ]
    for path in entry_points:
        code = _code(path)
        assert "C1Runner(" in code, f"{path.name} does not construct the runner"
        assert "manifestSource: SRManifest.manifestSource" in code, (
            f"{path.name} constructs C1Runner without passing the real manifest provenance — that run "
            f"could be credited as coverage when it was a wiring proof"
        )


def test_every_c1_entry_point_exits_on_the_runners_verdict_rather_than_the_runner_doing_it():
    """`exit()` inside the shared runner would terminate the host app in the in-app mode.

    Invisible until it happens, and then it looks like the app crashing rather than a library killing it.
    """
    runner = _code(REPO / "ios" / "Shared" / "C1Runner.swift")
    assert "exit(" not in runner, "the shared runner must not exit the process"
    for path in (REPO / "ios" / "C1Harness" / "main.swift", REPO / "ios" / "App" / "main.swift"):
        code = _code(path)
        assert "exit(runner.allPassed ? 0 : 1)" in code, f"{path.name} must turn the verdict into a status"


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
