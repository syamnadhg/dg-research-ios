import XCTest

@testable import SuperResearchDeviceCore

/// Tests for the in-app P0–P3 orchestrator, against a fake page.
///
/// The emphasis is on the properties that were expensive to learn on the Python side, because a second
/// implementation is exactly where they come back. In particular the toggle-idempotence bug is tested
/// from **both** starting states — a test that only covers "off, then enable" is the test that shipped
/// that bug once already.
/// A clock that does not actually wait.
///
/// ⚠ Not merely a speed-up. With a real `Task.sleep` the extraction suspends and resumes on a
/// different thread, and the fake page's unsynchronised state is then touched from both — which
/// surfaces as a malloc abort ("freed pointer was not the last allocation"), not as a failure.
private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

final class InAppPipelineTests: XCTestCase {

    static let mockManifest: [String: [String]] = [
        "logged_in_marker": ["#signed-in-marker"],
        "composer": ["[data-testid=\"composer\"]", "div[contenteditable=true]"],
        "send": ["[data-testid=\"send-button\"]"],
        "deep_research_toggle": ["[data-testid=\"deep-research-toggle\"]"],
        "sources": ["[data-testid=\"source\"]"],
        "response_container": ["[data-testid=\"response-container\"][data-state]"],
    ]

    private func driver(_ page: FakePage) -> InAppPhaseDriver {
        InAppPhaseDriver(platform: "chatgpt", manifest: Self.mockManifest, page: page)
    }

    // MARK: - The idempotence bug, from both directions

    func testAnAlreadyEnabledToggleIsLeftAlone() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]

        let tapped = try await driver(page).enableDeepResearch()

        XCTAssertFalse(tapped, "an already-on toggle must not be tapped")
        XCTAssertEqual(page.clicks, [], "tapping it would turn deep research OFF for the whole run")
        XCTAssertEqual(page.attributes["toggle"]?["aria-pressed"], "true")
    }

    func testADisabledToggleIsEnabled() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]

        let tapped = try await driver(page).enableDeepResearch()

        XCTAssertTrue(tapped)
        XCTAssertEqual(page.attributes["toggle"]?["aria-pressed"], "true")
    }

    func testRepeatedCallsConvergeRatherThanOscillate() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        let subject = driver(page)

        for _ in 0..<3 { _ = try await subject.enableDeepResearch() }

        XCTAssertEqual(page.attributes["toggle"]?["aria-pressed"], "true")
        XCTAssertEqual(page.clicks.count, 1, "only the first call should have needed to act")
    }

    func testAToggleThatDoesNotRespondIsReportedNotAssumed() async throws {
        // A tap that lands on a rotted selector, or a control that ignores untrusted events — exactly
        // the in-app isTrusted boundary. It must surface, not pass silently.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.ignoreClicks = true

        do {
            _ = try await driver(page).enableDeepResearch()
            XCTFail("an unconfirmed toggle must not be reported as success")
        } catch let InAppPhaseError.outcomeUnconfirmed(intent) {
            XCTAssertEqual(intent, "chatgpt.deep_research_toggle")
        }
    }

    func testAPlatformWithoutAToggleIsNotAFailure() async throws {
        let page = FakePage()
        var manifest = Self.mockManifest
        manifest.removeValue(forKey: "deep_research_toggle")
        let subject = InAppPhaseDriver(platform: "notebooklm", manifest: manifest, page: page)

        let tapped = try await subject.enableDeepResearch()
        XCTAssertFalse(tapped)
    }

    // MARK: - The write path that gates send

    func testTheComposerGoesThroughTheModelUpdatingPath() async throws {
        let page = FakePage()
        let path = try await driver(page).fillComposer("quantum error correction")

        XCTAssertEqual(path, "execCommand")
        XCTAssertEqual(page.inserted, ["quantum error correction"])
    }

    func testAnUnwritableComposerIsReportedRatherThanSilentlySkipped() async throws {
        let page = FakePage()
        page.insertResult = "not-a-text-target"
        do {
            _ = try await driver(page).fillComposer("x")
            XCTFail("expected the write path to be reported as unconfirmed")
        } catch let InAppPhaseError.outcomeUnconfirmed(intent) {
            XCTAssertEqual(intent, "chatgpt.composer")
        }
    }

    // MARK: - Selector resolution

    func testTheFallbackChainIsTriedInOrder() async throws {
        // Platforms A/B-test their DOM, so the first candidate failing is normal, not exceptional.
        let page = FakePage()
        page.missing = ["[data-testid=\"composer\"]"]
        _ = try await driver(page).fillComposer("x")
        XCTAssertEqual(page.queried.prefix(2).last, "div[contenteditable=true]")
    }

    func testAnUnresolvedSelectorFailsLoudlyAndNamesWhatItTried() async throws {
        let page = FakePage()
        page.missing = ["[data-testid=\"send-button\"]"]
        do {
            try await driver(page).send()
            XCTFail("a step whose target is missing must not report success")
        } catch let InAppPhaseError.unresolved(platform, key, tried) {
            XCTAssertEqual(platform, "chatgpt")
            XCTAssertEqual(key, "send")
            XCTAssertEqual(tried, ["[data-testid=\"send-button\"]"])
        }
    }

    // MARK: - Send asserts acceptance, not completion

    func testSendIsConfirmedByAcceptanceNotByAFinishedResponse() async throws {
        // Gating this on a finished response reported a false failure on EVERY run — the response
        // arrives hundreds of ms later. A false failure escalates an agent onto a healthy page.
        let page = FakePage()
        page.responseState = "streaming"
        try await driver(page).send()   // must not throw
    }

    // MARK: - Harvest

    func testSourcesAreHarvestedByTextNotByHref() async throws {
        // The P1 incident: sources render as non-anchor nodes, so a link-only harvest returned zero
        // for an entire run while every click landed and the run reported success.
        let page = FakePage()
        page.sourceTexts = ["nature.com — Surface codes", "arxiv.org — 2401.00001", ""]
        let sources = try await driver(page).harvestSources()
        XCTAssertEqual(sources, ["nature.com — Surface codes", "arxiv.org — 2401.00001"])
    }

    // MARK: - Pipeline ordering

    func testAFullRunCompletesAllFourPhasesInOrder() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a", "b"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "topic")

        let outcome = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        XCTAssertEqual(outcome.status, "complete")
        XCTAssertEqual(outcome.phasesCompleted.count, 4)
        XCTAssertEqual(outcome.sources, ["a", "b"])
        XCTAssertEqual(
            pipeline.events.map(\.event),
            ["phase_start", "phase_complete", "phase_start", "phase_complete",
             "phase_start", "phase_complete", "phase_start", "phase_complete"]
        )
    }

    func testTheStopCheckPrecedesTheSkipCheck() async throws {
        // A stop requested while a phase happens to be skippable must STOP, not be swallowed by the
        // skip — otherwise a stop lands only on the phases nobody wanted to skip.
        let page = FakePage()
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(shouldStop: { true }, shouldSkip: { _ in true }, sleep: noSleep)

        XCTAssertEqual(outcome.status, "stopped")
        XCTAssertTrue(pipeline.events.isEmpty, "nothing should have been announced")
    }

    func testPhaseStartIsEmittedAfterThePauseGateNotBefore() async throws {
        // A paused run that has already announced phase_start advertises a phase it has not begun, and
        // the frontend shows progress that is not happening.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        var resumeOrder: [String] = []
        var paused = true
        let outcome = try await pipeline.run(
            awaitResume: { resumeOrder.append("resumed"); paused = false },
            isPaused: { paused },
            responseTimeout: 1,
            sleep: noSleep
        )

        XCTAssertEqual(outcome.status, "complete")
        XCTAssertEqual(resumeOrder, ["resumed"], "the gate should have been hit exactly once")
        XCTAssertEqual(pipeline.events.first?.event, "phase_start")
    }

    func testASkippedPhaseIsAnnouncedAndDoesNotCountAsComplete() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]
        // ⭐ Skipping P1 is the owner-supplied-brief flow (the web app's `briefText`), so the brief
        // arrives from outside rather than not at all. Running this without one would assert that a
        // SUPPORTED flow kills the run.
        var pipeline = InAppPipeline(
            driver: driver(page), topic: "t",
            providedBrief: String(repeating: "An owner-written brief. ", count: 20)
        )

        let outcome = try await pipeline.run(shouldSkip: { $0 == 1 }, responseTimeout: 1, sleep: noSleep)

        XCTAssertEqual(outcome.phasesCompleted.count, 3)
        XCTAssertTrue(pipeline.events.contains { $0.phase == 1 && $0.event == "phase_skipped" })
        XCTAssertFalse(pipeline.events.contains { $0.phase == 1 && $0.event == "phase_start" })
    }

    func testP0FailsTheRunWhenTheDeviceIsNotSignedIn() async throws {
        let page = FakePage()
        page.missing = ["#signed-in-marker"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        do {
            _ = try await pipeline.run(sleep: noSleep)
            XCTFail("a not-signed-in device must not proceed to drive the page")
        } catch let InAppPhaseError.notLoggedIn(platform, reason) {
            XCTAssertEqual(platform, "chatgpt")
            // The page was up and hydrated — so this is the marker genuinely not resolving, NOT
            // the gate catching an unloaded view. Asserting the reason is what keeps those two
            // apart, and confusing them is the bug that cost a live run.
            XCTAssertTrue(
                reason.contains("logged_in_marker"),
                "a signed-out page must be reported as the MARKER failing, got: \(reason)"
            )
        }
    }

    func testAnAlreadyOnToggleIsReportedInTheOutcome()  async throws {
        // Surfaced rather than hidden: "we did not need to enable it" and "we enabled it" are
        // different facts, and conflating them is how the original bug stayed invisible.
        //
        // ⚠ The SCENARIO moved when P1 was reconciled to its contract. P1 now turns deep research
        // OFF (with Backspace — a second tap adds a tool), so on the ordinary path P2 always has to
        // enable it and "already on" can never happen. It can still happen on the owner-supplied-
        // brief flow, where P1 is skipped and the toggle survives from a previous run — which is
        // exactly the cross-run persistence the idempotence guard exists for.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(
            driver: driver(page), topic: "t",
            providedBrief: String(repeating: "An owner-written brief. ", count: 20)
        )

        let outcome = try await pipeline.run(
            shouldSkip: { $0 == 1 }, responseTimeout: 1, sleep: noSleep
        )

        XCTAssertTrue(outcome.deepResearchWasAlreadyOn)
        XCTAssertFalse(page.keys.contains("Backspace"),
                       "P1 was skipped, so nothing should have tried to turn the toggle off")
    }

    func testP1TURNSDEEPRESEARCHOFFWithBackspaceAndNotWithASecondTap() async throws {
        // ⛔ The platform's own instruction: "REMOVE it by pressing Backspace in the empty message
        // box; do NOT click the 'Deep research' tool (clicking adds a second one)". A mirror of
        // enable would leave P1 in a worse state than it started.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]   // left on by a previous run
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        XCTAssertTrue(page.keys.contains("Backspace"), "the pill was not removed with Backspace")
        // ...and P2 then had to enable it, because P1 genuinely turned it off.
        XCTAssertFalse(outcome.deepResearchWasAlreadyOn)
    }

    // MARK: - P1 and the effort tier

    /// ⭐ The normal case, and the one that must cost nothing: a signed-in account that ChatGPT has
    /// already left on the tier. P1 reads, finds it right, and opens no menu.
    func testP1ReadsTheTierAndOpensNoMenuWhenItIsAlreadyRight() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        XCTAssertFalse(page.tierMenuOpened, "a popover was opened over the composer for nothing")
        XCTAssertTrue(outcome.effortTier.contains("already on tier"), outcome.effortTier)
    }

    func testP1SELECTSTheTierWhenTheTriggerIsOnTheCheapMode() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        page.tierTriggerText = "Instant 5.5"
        page.tierRows = ["Instant 5.5", "Medium", "High", "Extra High", "Pro"]
        page.tierTriggerTextAfterPress = "ChatGPT Pro"
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        XCTAssertTrue(page.tierMenuOpened)
        XCTAssertTrue(outcome.effortTier.contains("selected"), outcome.effortTier)
    }

    /// ⛔ **The tier is RECORDED, never enforced — and the brief must still be produced.** Refusing
    /// to run P1 because the tier could not be *verified* would brick the device for anyone whose
    /// ChatGPT is not already on it, and the read cannot always tell "not on it" from "could not
    /// look". What must never happen is the opposite: a brief reported as written on the tier when
    /// it was not.
    func testP1STILLPRODUCESTheBriefWhenTheTierCouldNotBeEstablishedAndSaysSo() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        page.tierTriggerText = "Instant 5.5"
        page.tierRows = []                       // the React overlay that never opened
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        XCTAssertGreaterThanOrEqual(outcome.brief.count, Prompts.briefFloorChars)
        XCTAssertTrue(outcome.effortTier.contains("tier unknown"), outcome.effortTier)
        // ⛔ And it must NOT read as success. This is the assertion that stops a silent downgrade.
        XCTAssertFalse(outcome.effortTier.contains("already on tier"), outcome.effortTier)
        XCTAssertFalse(outcome.effortTier.contains("selected"), outcome.effortTier)
    }

    /// The tier step belongs to P1's platform alone. P2 runs against the SAME control on ChatGPT,
    /// and opening its menu mid-phase would put a popover over a composer holding the brief.
    func testTheTierStepDoesNotRunForAPlatformThatIsNotP1s() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        page.tierTriggerText = "Instant 5.5"
        page.tierRows = ["Instant 5.5", "Pro"]
        var pipeline = InAppPipeline(
            driver: InAppPhaseDriver(platform: "gemini", manifest: Self.mockManifest, page: page),
            topic: "t"
        )

        // ⚠ P2 onward is skipped deliberately: this fake's report and brief are the same text, and
        // the report-is-the-brief guard would fire on an unrelated phase. The claim here is about
        // P1 alone.
        let outcome = try await pipeline.run(
            shouldSkip: { $0 >= 2 }, responseTimeout: 1, sleep: noSleep
        )

        XCTAssertFalse(page.tierMenuOpened, "a non-P1 platform drove ChatGPT's model menu")
        XCTAssertEqual(outcome.effortTier, "", "a platform with no tier step reported one")
    }

    func testP1SendsTheWRAPPERPromptAndNotTheBareTopic() async throws {
        // The bare topic gets a chat answer, and P2 is then fed a conversation instead of a brief.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "solid-state batteries")

        _ = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        XCTAssertNotEqual(page.inserted.first, "solid-state batteries")
        XCTAssertTrue(page.inserted.first?.hasPrefix(
            "Please create a detailed research report brief") ?? false)
        XCTAssertTrue(page.inserted.first?.contains("solid-state batteries") ?? false)
    }

    func testP1REFUSESAStubAsTheBrief() async throws {
        // ⚠ The floor is only load-bearing against a SHORT response — a mutation proved that, by
        // passing while the fake answered at full brief length. The shape guarded against is the
        // one measured on the live page: a 15-character `"ChatGPT said:"` from an unfinished
        // response, which would otherwise be sent to three deep-research agents.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.responseText = "ChatGPT said:"
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        do {
            _ = try await pipeline.run(responseTimeout: 1, sleep: noSleep)
            XCTFail("a stub must not be accepted as the brief")
        } catch InAppPhaseError.outcomeUnconfirmed(let intent) {
            // ⛔ **Which guard refused it, not merely that something did.** `intent.contains("brief")`
            // alone passed with the floor deleted: a bare speaker label strips to nothing, P1 stored
            // an EMPTY brief, and P2's own `p2.brief-missing` threw a message that also contains the
            // word "brief". The run failed for the wrong reason and the test could not tell.
            XCTAssertTrue(intent.contains(".brief("), "the floor did not reject it — \(intent)")
            XCTAssertTrue(intent.contains("chars)"), "the refusal did not name the length — \(intent)")
        }
    }

    /// ⭐ The floor's own job, with the label-stripper taken out of the picture: prose that reads
    /// perfectly well and is simply too short to be a research brief.
    ///
    /// ⚠ The stub test above cannot prove this. Its fixture is a speaker label, so it is refused
    /// twice over — and it went on passing when the floor was deleted entirely.
    func testAShortButPERFECTLYReadableAnswerIsStillTooShortToBeABrief() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        // Real prose, nothing to strip, comfortably under the 400-character floor.
        page.responseText = "Solid-state batteries replace the liquid electrolyte with a solid one."
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        do {
            _ = try await pipeline.run(responseTimeout: 1, sleep: noSleep)
            XCTFail("a 69-character answer was accepted as a research brief")
        } catch InAppPhaseError.outcomeUnconfirmed(let intent) {
            XCTAssertTrue(intent.contains(".brief("), intent)
        }
    }

    /// ⛔⛔ **Reported when PRODUCED, not when the platform returns.** P1 and P2 run inside one call,
    /// so a brief that only surfaces on return arrives after this platform's own deep research —
    /// which is how a P2 failure destroyed a fifteen-minute brief and how the web app's phase-1 tile
    /// stayed open with nothing in it for a whole run.
    func testP1REPORTSTheBriefAsSoonAsItHasOne() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")
        let sink = EventSink()
        pipeline.onBriefProduced = { brief in sink.record(1, brief) }

        _ = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        // ⚠ `first?`, not `[0]`. Subscripting traps when the brief is never reported, and a mutant
        // that CRASHES the test process cannot be scored caught — the harness sees no result at all
        // rather than a red assertion.
        XCTAssertEqual(sink.events.count, 1, "the brief was never reported: \(sink.events)")
        XCTAssertEqual(sink.events.first?.event.isEmpty, false,
                       "the brief was reported as an empty string")
    }

    func testP2SendsTHEBRIEFAndNotTheTopic() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "solid-state batteries")

        let outcome = try await pipeline.run(responseTimeout: 1, sleep: noSleep)

        // Two fills: P1's wrapper, then P2's brief — never the topic twice.
        XCTAssertEqual(page.inserted.count, 2)
        XCTAssertEqual(page.inserted[1], outcome.brief)
        XCTAssertFalse(outcome.brief.isEmpty)
        XCTAssertFalse(outcome.report.isEmpty, "P2 must produce a report, not just send")
    }
}

/// A page that behaves like the mock platform: model-gated send, a real toggle, non-anchor sources.
final class FakePage: WebPage, @unchecked Sendable {
    /// Selectors that should match nothing, for the fallback-chain and loud-failure tests.
    var missing: Set<String> = []
    var attributes: [String: [String: String]] = [:]
    var inserted: [String] = []
    var insertResult: String? = "execCommand"
    var clicks: [Int] = []
    var queried: [String] = []
    var sourceTexts: [String] = []
    var responseState = "complete"
    /// Simulates a control that ignores the click — a rotted selector, or an isTrusted gate.
    var ignoreClicks = false

    // MARK: - What the readiness gate sees
    //
    // ⚠ Defaults describe a page that is already UP, because that is what every test written
    // before the gate existed assumed. A fake that defaulted to "still loading" would make the
    // whole suite fail at the gate for a reason none of those tests are about.

    var readyState = "complete"
    var href = "https://chatgpt.com/"
    var bodyChildren = 5
    /// A modal neutralising the composer, by label. Nil means the page is clear.
    var overlayBlocker: String?
    var overlayClearsOnEscape = true
    private(set) var sawOverlayProbe = false
    /// What `WAIT_INTERRUPTION_JS` reports — a visible sign-in control or a wall. Empty means none.
    var interruption = ""
    /// Flip to a loaded page after this many readiness reads — a view that finishes navigating.
    var becomesReadyAfterReads: Int?
    /// Was the sign-in probe actually asked? Its ORDER relative to the load check is asserted.
    private(set) var sawInterruptionProbe = false
    private var readinessReads = 0

    private static let modelTriggerHandle = 8
    private static let modelRowHandle = 9
    private static let toggleHandle = 10
    private static let composerHandle = 11
    private static let sendHandle = 12
    private static let markerHandle = 13
    private static let responseHandle = 14

    func querySelector(_ css: String) async throws -> Int? {
        queried.append(css)
        if missing.contains(css) { return nil }
        // The mark-then-press handoff. Without these the marked element is unresolvable and every
        // tier selection reports "could not be resolved" — a fake that can only ever answer no.
        if css.contains("model-trigger") { return Self.modelTriggerHandle }
        if css.contains("model-row") { return Self.modelRowHandle }
        if css.contains("Start research") {
            startResearchLooks += 1
            return startResearchLooks > startResearchAppearsAfter ? Self.startResearchHandle : nil
        }
        if css.contains("deep-research-toggle") { return Self.toggleHandle }
        if css.contains("composer") || css.contains("contenteditable") { return Self.composerHandle }
        if css.contains("send-button") { return Self.sendHandle }
        if css.contains("signed-in-marker") { return Self.markerHandle }
        if css.contains("response-container") { return Self.responseHandle }
        return nil
    }

    func querySelectorAll(_ css: String) async throws -> [Int] {
        queried.append(css)
        if css.contains("source") { return Array(100..<(100 + sourceTexts.count)) }
        return []
    }

    func attribute(_ handle: Int, _ name: String) async throws -> String? {
        if handle == Self.toggleHandle { return attributes["toggle"]?[name] }
        if handle == Self.responseHandle, name == "data-state" { return responseState }
        return nil
    }

    /// A synthetic brief, long enough to clear `Prompts.briefFloorChars`.
    ///
    /// ⚠ P1 now READS the response container and REFUSES anything under the floor — because the
    /// shape measured on the live page was a 15-character `"ChatGPT said:"`, which would otherwise
    /// be sent to three deep-research agents. A fake answering with nothing tests a P1 that the
    /// real pipeline would reject.
    var responseText = String(
        repeating: "A thorough research brief covering the leading approaches and their trade-offs. ",
        count: 8
    )

    /// Fires whenever the response container is read — a moment that is unambiguously INSIDE the
    /// run, so a test can ask "had anything been emitted by now?".
    var onResponseRead: (() -> Void)?

    func innerText(_ handle: Int) async throws -> String? {
        if handle == Self.responseHandle { onResponseRead?(); return responseText }
        let index = handle - 100
        guard index >= 0, index < sourceTexts.count else { return nil }
        return sourceTexts[index]
    }

    func click(_ handle: Int) async throws {
        clicks.append(handle)
        if handle == Self.startResearchHandle { startResearchClicks += 1 }
        guard !ignoreClicks else { return }
        if handle == Self.toggleHandle {
            let now = attributes["toggle"]?["aria-pressed"] == "true"
            attributes["toggle"]?["aria-pressed"] = now ? "false" : "true"   // a toggle toggles
        }
    }

    func insertText(_ handle: Int, _ text: String) async throws -> String? {
        if insertResult == "not-a-text-target" { return insertResult }
        inserted.append(text)
        return insertResult
    }

    /// Recorded, so "the pill was removed with Backspace" is checkable rather than assumed — and so
    /// a disable that silently fell back to a TAP (which adds a second tool) is visible.
    private(set) var keys: [String] = []
    func key(_ name: String) async throws {
        keys.append(name)
        // Backspace in an empty composer removes the Deep research pill — the platform's own
        // instruction, and the ONLY supported way to turn it off (a second tap adds a tool).
        if name == "Backspace" { attributes["toggle"]?["aria-pressed"] = "false" }
    }

    /// What the ChatGPT conversation-fetch extractor finds.
    ///
    /// ⚠ P2's ChatGPT path does NOT read the DOM — gate zero measured the report into a
    /// cross-origin frame — so a fake that only fills the response container exercises a path
    /// production never takes, and the extractor waits out its whole timeout instead of failing.
    var reportText = String(repeating: "Report body. ", count: 250)

    /// Is the opener's popup open? Modelled as page state, because the whole point of the dismissal
    /// fix is that this is a DIFFERENT fact from whether the target is findable.
    var popupOpen = false

    /// A menu that ignores Escape — the "will not close" case, which must never be reported as
    /// dismissed because the menu is then still covering the composer for the next phase.
    var escapeDoesNothing = false

    /// The plan control appears only after this many looks — the real one takes tens of seconds to
    /// render, which is what makes a read-once implementation conclude the step does not exist.
    var startResearchAppearsAfter = 10_000
    private(set) var startResearchLooks = 0
    private(set) var startResearchClicks = 0
    private static let startResearchHandle = 20

    /// Is the platform's own stop control VISIBLE? Independent of `responseState` on purpose: the
    /// defect being modelled is text that has settled while the platform is still working.
    var generating = false

    // MARK: - The model/effort trigger
    //
    // ⚠ Defaults describe a page ALREADY on the tier, so the tier step is a single read that opens
    // nothing — which is the normal state of a signed-in account and what every test written before
    // the step existed assumes. A fake defaulting to "not on tier" would make the whole suite drive
    // a menu none of those tests are about.

    var tierTriggerText = "ChatGPT Pro"
    var tierTriggerTextAfterPress: String?
    var tierRows: [String] = []
    var tierRowsVia = "radio"
    private var tierRowPressed = false
    /// Was a menu opened for the tier? The already-on-target path must never do this.
    private(set) var tierMenuOpened = false

    func evaluateJSON(_ expression: String) async throws -> Any? {
        // ⛔ The model-menu expressions are answered FIRST. Several of the older branches below match
        // on words general enough to claim them — and a branch that answers the wrong question hands
        // back the wrong SHAPE, which casts to nil and reads as "nothing was there".
        if expression.contains("'model-trigger'") {
            tierMenuOpened = true
            return ["marked": true, "via": "testid"]
        }
        if expression.contains("'model-row'") {
            tierRowPressed = true
            return ["clicked": true]
        }
        if expression.contains("census_ignored") {
            return [
                "rows": tierRows, "via": tierRows.isEmpty ? "" : tierRowsVia,
                "seen_used": [String](),
            ]
        }
        if expression.contains("out.indexOf(t)") { return [String]() }
        if expression.contains("found: false") {
            return [
                "found": true, "via": "testid",
                "text": tierRowPressed ? (tierTriggerTextAfterPress ?? tierTriggerText)
                    : tierTriggerText,
            ]
        }
        // ⛔ **Both of these must be answered BEFORE the in-flight probe below, because the
        // interruption scan matches its pattern.** `WAIT_INTERRUPTION_JS` also calls
        // `getBoundingClientRect` and `querySelectorAll`, so the older branch claimed it and handed
        // back a Bool where a reason string was expected. The cast then failed silently and the
        // scan read as "no interruption" — a probe that can only ever answer no.
        // The overlay probe. Defaults to "nothing was blocking", because a clear page is the
        // normal case and every test written before overlays existed assumes one.
        if expression.contains("clearOverlay") {
            sawOverlayProbe = true
            guard let blocker = overlayBlocker else {
                return ["ok": true, "cleared": false, "note": "nothing was blocking"]
            }
            return [
                "ok": overlayClearsOnEscape, "cleared": overlayClearsOnEscape,
                "blocker": ["tag": "DIV", "id": "", "cls": "", "label": blocker, "why": "inert"],
                "note": overlayClearsOnEscape ? "dismissed by Escape" : "Escape did not dismiss it",
            ]
        }
        if expression.contains("var AUTH") {
            sawInterruptionProbe = true
            return interruption
        }
        if expression.contains("document.readyState") {
            readinessReads += 1
            if let after = becomesReadyAfterReads, readinessReads >= after {
                return ["r": "complete", "h": href, "c": 5]
            }
            return ["r": readyState, "h": href, "c": bodyChildren]
        }
        // The in-flight probe — identified by its rendered-size test.
        if expression.contains("getBoundingClientRect"), expression.contains("querySelectorAll") {
            return generating
        }
        // Escape, dispatched as a real keyboard event, is what closes the menu.
        if expression.contains("KeyboardEvent"), expression.contains("Escape") {
            if !escapeDoesNothing { popupOpen = false }
            return true
        }
        // The opener-state probe. Answered from `popupOpen` and NOT from the target's presence.
        if expression.contains("aria-expanded") {
            return ["open": popupOpen]
        }
        if expression.contains("__srReport") {
            if expression.contains(".slice(") {
                let parts = expression.components(separatedBy: ".slice(").last?
                    .components(separatedBy: ")").first?
                    .components(separatedBy: ", ") ?? []
                guard parts.count == 2, let from = Int(parts[0]), let to = Int(parts[1]) else {
                    return ""
                }
                let chars = Array(reportText)
                guard from < chars.count else { return "" }
                return String(chars[from..<min(to, chars.count)])
            }
            if expression.contains("r.state") {
                return ["state": "ok", "chars": reportText.count, "status": "completed"]
            }
            return "started"
        }
        if expression.contains("data-state=\\\"complete\\\"") || expression.contains("complete") {
            return responseState == "complete"
        }
        return nil
    }
}

/// Tests for the loaded predicate.
///
/// This exists because `waitForReady` returned true on `about:blank` — a fresh `WKWebView` starts there
/// and it reports `readyState == "complete"` instantly, so the C1 gate ran an entire pipeline against a
/// three-node empty document and produced nine failures that all looked like broken selectors. The
/// condition was previously unreachable by any test, since reaching it needed a real web view; pulling
/// it out as a pure function is what makes the fix verifiable.
final class LoadedPredicateTests: XCTestCase {
    func testABlankPageIsNotLoadedEvenThoughItIsComplete() {
        XCTAssertFalse(
            WebAutomationBridge.isLoaded(
                readyState: "complete", href: "about:blank", bodyChildren: 3
            ),
            "about:blank is where every WKWebView starts — treating it as loaded races the real load"
        )
    }

    func testAnEmptyDocumentIsNotLoaded() {
        XCTAssertFalse(
            WebAutomationBridge.isLoaded(
                readyState: "complete", href: "http://127.0.0.1:8901/", bodyChildren: 0
            ),
            "an error page or stub can be complete and empty"
        )
    }

    func testAnIncompleteDocumentIsNotLoaded() {
        XCTAssertFalse(
            WebAutomationBridge.isLoaded(
                readyState: "loading", href: "http://127.0.0.1:8901/", bodyChildren: 5
            )
        )
    }

    func testARealPageIsLoaded() {
        XCTAssertTrue(
            WebAutomationBridge.isLoaded(
                readyState: "complete", href: "http://127.0.0.1:8901/", bodyChildren: 5
            )
        )
    }

    func testTheExpectedURLPinsWhichPageCounts() {
        // "a page loaded" and "the page I asked for loaded" are different facts. A redirect to a login
        // wall satisfies the first.
        XCTAssertFalse(
            WebAutomationBridge.isLoaded(
                readyState: "complete", href: "https://accounts.google.com/signin",
                bodyChildren: 5, expecting: "https://gemini.google.com"
            )
        )
        XCTAssertTrue(
            WebAutomationBridge.isLoaded(
                readyState: "complete", href: "https://gemini.google.com/app",
                bodyChildren: 5, expecting: "https://gemini.google.com"
            )
        )
    }

    func testMissingReadingsAreNotTreatedAsLoaded() {
        // A failed evaluation must not read as success — that is how a page nobody could talk to gets
        // reported as ready.
        XCTAssertFalse(
            WebAutomationBridge.isLoaded(readyState: nil, href: nil, bodyChildren: nil)
        )
    }
}

/// Dismissal must ask the OPENER, not the target.
///
/// ⛔ **The bug this replaces, measured on the live page.** Dismissal used to poll "is the target
/// still findable" as a stand-in for "is the menu still open". But activating the deep-research item
/// CREATES a matching pill in the composer, and that platform's entry is a text match with no CSS —
/// so the proxy stayed true forever. The run's own success signal was read as evidence of failure,
/// and the phase aborted after correctly doing everything it was asked to do.
///
/// ⚠ The fake answers the opener probe from page state that is INDEPENDENT of the target's presence.
/// A fake that derived one from the other could not fail this test, which is the shape where a guard
/// is satisfied by the test double rather than by the code.
final class DismissalAsksTheOpenerTests: XCTestCase {

    private static let manifest: [String: [String]] = [
        "composer": ["[data-testid=\"composer\"]"],
        "deep_research_toggle": ["[data-testid=\"deep-research-toggle\"]"],
        "response_container": ["[data-testid=\"response-container\"][data-state]"],
    ]

    private func driver(_ page: FakePage) -> InAppPhaseDriver {
        InAppPhaseDriver(
            platform: "chatgpt",
            manifest: Self.manifest,
            openers: ["deep_research_toggle": "[data-testid=\"composer-plus\"]"],
            page: page
        )
    }

    func testDismissalSucceedsWhileTheTargetIsSTILLFINDABLE() async throws {
        // The exact live shape: the menu is shut, and the pill the activation created is still on
        // screen — so the target resolves and always will.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]   // already on -> the dismissal path
        page.popupOpen = false                                  // the opener says: closed

        let enabled = try await driver(page).enableDeepResearch()

        XCTAssertFalse(enabled, "already-on must not tap; tapping would turn it OFF")
        // The target was findable throughout — the old proxy would have spun out and returned false.
        let target = try await page.querySelector("[data-testid=\"deep-research-toggle\"]")
        XCTAssertNotNil(target, "the fixture must keep the target findable, or this proves nothing")
    }

    func testAMenuThatWILLNOTCLOSEIsNotReportedAsDismissed() async throws {
        // ⚠ The other direction, and the one that must never fail open: an opener stuck reporting
        // open means the menu is still covering the composer, and the NEXT phase's send taps the
        // overlay. That has to surface here, not one phase later as a send problem.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]
        page.popupOpen = true
        page.escapeDoesNothing = true

        do {
            _ = try await driver(page).enableDeepResearch()
            XCTFail("a menu that would not close must fail the phase, not be tolerated silently")
        } catch let InAppPhaseError.menuWouldNotClose(platform, key) {
            XCTAssertEqual(platform, "chatgpt")
            XCTAssertEqual(key, "deep_research_toggle")
        }
    }
}

/// The plan-confirmation step, ported to the app half from a live measurement.
///
/// ⛔ Sending does not start Gemini's deep research. It replies with a ~1,200-character research
/// PLAN and stops: generation ends, the text is stable, nothing is empty, and it reads like a good
/// answer. Without the press, the wait completes and the extractor harvests the plan as the report.
/// The parity matters — the app half is what actually runs the phases on the device, so a fix on
/// only the other half leaves the shipping path broken.
final class PlanConfirmationTests: XCTestCase {

    private func driver(_ page: FakePage, captured: Bool) -> InAppPhaseDriver {
        var manifest: [String: [String]] = ["composer": ["[data-testid=\"composer\"]"]]
        if captured { manifest["start_research"] = ["button[aria-label=\"Start research\"]"] }
        return InAppPhaseDriver(platform: "gemini", manifest: manifest, page: page)
    }

    func testThePlanControlIsPRESSEDAndNotMerelyFound() async throws {
        let page = FakePage()
        page.startResearchAppearsAfter = 0

        let pressed = try await driver(page, captured: true)
            .startResearchIfOffered(attempts: 5, sleep: { _ in })

        XCTAssertTrue(pressed)
        // The MECHANISM: the click happened. "the selector resolved" would pass against a step that
        // found the button and walked straight past it — which is the bug.
        XCTAssertEqual(page.startResearchClicks, 1)
    }

    func testItIsPOLLEDBecauseThePlanArrivesLate() async throws {
        let page = FakePage()
        page.startResearchAppearsAfter = 3   // absent on the first looks, as for the real render

        let pressed = try await driver(page, captured: true)
            .startResearchIfOffered(attempts: 10, sleep: { _ in })

        XCTAssertTrue(pressed)
        XCTAssertGreaterThan(page.startResearchLooks, 3, "a single look would have missed it")
        XCTAssertEqual(page.startResearchClicks, 1)
    }

    func testAPlatformWithNoPlanStageIsNotAFailure() async throws {
        // ChatGPT and Claude start on send. An uncaptured entry means "no such step", never
        // "this run is broken".
        let page = FakePage()
        page.startResearchAppearsAfter = 0

        let pressed = try await driver(page, captured: false)
            .startResearchIfOffered(attempts: 5, sleep: { _ in })

        XCTAssertFalse(pressed)
        XCTAssertEqual(page.startResearchClicks, 0)
    }

    func testAControlThatNeverAppearsGivesUpRatherThanHanging() async throws {
        let page = FakePage()
        page.startResearchAppearsAfter = 10_000

        let pressed = try await driver(page, captured: true)
            .startResearchIfOffered(attempts: 3, sleep: { _ in })

        XCTAssertFalse(pressed)
    }
}


/// The app half's in-flight veto: stability is necessary, never sufficient.
///
/// ⛔ This half had NO in-flight check at all. Measured on live ChatGPT, an assistant turn read
/// `Pro thinking` — 27 characters — and held it, perfectly stable, while the platform was still
/// working. Stability alone accepts that as the answer; the harvest then finds nothing in it and the
/// run reports read drift about selectors that are correct.
final class InFlightVetoTests: XCTestCase {

    private static let manifest: [String: [String]] = [
        "response_container": ["[data-testid=\"response-container\"][data-state]"],
    ]

    private func driver(_ page: FakePage) -> InAppPhaseDriver {
        InAppPhaseDriver(platform: "chatgpt", manifest: Self.manifest, page: page)
    }

    func testStableTextIsNOTAcceptedWhileThePlatformSaysItIsStillWorking() async throws {
        let page = FakePage()
        page.responseState = "streaming"          // never the fixture-only complete short-circuit
        page.responseText = "Pro thinking"        // the measured shape: short, and perfectly stable
        page.generating = true

        let done = try await driver(page).awaitResponse(
            timeout: 2, now: { Date() }, sleep: { _ in }
        )

        XCTAssertFalse(done, "settled text was accepted as the answer while the platform was busy")
    }

    func testTheSameStableTextIsAcceptedOnceThePlatformHasSTOPPED() async throws {
        // The other half: the veto must not become the outage.
        let page = FakePage()
        page.responseState = "streaming"
        page.responseText = "Pro thinking"
        page.generating = false

        let done = try await driver(page).awaitResponse(
            timeout: 2, now: { Date() }, sleep: { _ in }
        )

        XCTAssertTrue(done)
    }

    func testAProbeThatCannotAnswerDoesNotStallAFinishedRun() async throws {
        // ⚠ Unknown means NOT generating. The veto only blocks a completion stability already
        // accepted, so a probe that cannot answer must never be able to hang a finished run.
        let page = FakePage()
        page.responseState = "streaming"
        page.responseText = "A settled, complete answer with real substance in it."
        page.generating = false

        let done = try await driver(page).awaitResponse(
            timeout: 2, now: { Date() }, sleep: { _ in }
        )
        XCTAssertTrue(done)
    }
}
