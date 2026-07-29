import XCTest

@testable import SuperResearchDeviceCore

/// Tests for the in-app P0–P3 orchestrator, against a fake page.
///
/// The emphasis is on the properties that were expensive to learn on the Python side, because a second
/// implementation is exactly where they come back. In particular the toggle-idempotence bug is tested
/// from **both** starting states — a test that only covers "off, then enable" is the test that shipped
/// that bug once already.
final class InAppPipelineTests: XCTestCase {

    private static let mockManifest: [String: [String]] = [
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

        let outcome = try await pipeline.run(responseTimeout: 1)

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

        let outcome = try await pipeline.run(shouldStop: { true }, shouldSkip: { _ in true })

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
            responseTimeout: 1
        )

        XCTAssertEqual(outcome.status, "complete")
        XCTAssertEqual(resumeOrder, ["resumed"], "the gate should have been hit exactly once")
        XCTAssertEqual(pipeline.events.first?.event, "phase_start")
    }

    func testASkippedPhaseIsAnnouncedAndDoesNotCountAsComplete() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(shouldSkip: { $0 == 1 }, responseTimeout: 1)

        XCTAssertEqual(outcome.phasesCompleted.count, 3)
        XCTAssertTrue(pipeline.events.contains { $0.phase == 1 && $0.event == "phase_skipped" })
        XCTAssertFalse(pipeline.events.contains { $0.phase == 1 && $0.event == "phase_start" })
    }

    func testP0FailsTheRunWhenTheDeviceIsNotSignedIn() async throws {
        let page = FakePage()
        page.missing = ["#signed-in-marker"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        do {
            _ = try await pipeline.run()
            XCTFail("a not-signed-in device must not proceed to drive the page")
        } catch let InAppPhaseError.notLoggedIn(platform) {
            XCTAssertEqual(platform, "chatgpt")
        }
    }

    func testAnAlreadyOnToggleIsReportedInTheOutcome()  async throws {
        // Surfaced rather than hidden: "we did not need to enable it" and "we enabled it" are
        // different facts, and conflating them is how the original bug stayed invisible.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "true"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(responseTimeout: 1)
        XCTAssertTrue(outcome.deepResearchWasAlreadyOn)
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

    private static let toggleHandle = 10
    private static let composerHandle = 11
    private static let sendHandle = 12
    private static let markerHandle = 13
    private static let responseHandle = 14

    func querySelector(_ css: String) async throws -> Int? {
        queried.append(css)
        if missing.contains(css) { return nil }
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

    func innerText(_ handle: Int) async throws -> String? {
        let index = handle - 100
        guard index >= 0, index < sourceTexts.count else { return nil }
        return sourceTexts[index]
    }

    func click(_ handle: Int) async throws {
        clicks.append(handle)
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

    func evaluateJSON(_ expression: String) async throws -> Any? {
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
