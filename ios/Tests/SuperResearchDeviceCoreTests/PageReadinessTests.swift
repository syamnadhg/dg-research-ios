import XCTest
@testable import SuperResearchDeviceCore

/// The gate that stands between a freshly-created web view and a run that drives it.
///
/// ⛔ **This is the fix for a measured production failure, 2026-08-14.** The app creates one web
/// view per (worker, platform) lazily and calls `load()`, which returns immediately. The run took
/// the view straight out of that call and asked Gemini for its login marker **418ms** later. All
/// three platforms answered "nothing here", the run was abandoned four seconds after it began, and
/// the trace read exactly as if the owner had been signed out of everything.
final class PageReadinessTests: XCTestCase {

    private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    private func driver(_ page: FakePage) -> InAppPhaseDriver {
        InAppPhaseDriver(
            platform: "chatgpt",
            manifest: [
                "logged_in_marker": ["#signed-in-marker"],
                "composer": ["#composer"],
                "send": ["#send-button"],
                "response_container": ["#response-container"],
            ],
            page: page
        )
    }

    // MARK: - The failure that shipped

    func testAWebViewThatHasNotFinishedLoadingIsWaitedFOR_NotDeclaredSignedOut() async throws {
        // The exact production shape: the document has not completed, so nothing resolves. The old
        // code asked once and concluded "not signed in".
        let page = FakePage()
        page.readyState = "loading"
        page.bodyChildren = 0

        let readiness = try await driver(page).awaitPageReady(timeout: 0.2, sleep: noSleep)

        guard case .notReady(let reason) = readiness else {
            return XCTFail("an unloaded page must not be reported as signed out, got \(readiness)")
        }
        // The reason must carry the EVIDENCE, because "not ready" and "signed out" were confused
        // for each other and the only thing that separates them is what the page actually said.
        XCTAssertTrue(reason.contains("readyState=loading"), "the reason must say what it saw: \(reason)")
    }

    func testABlankWebViewIsNotMistakenForALoadedOne() async throws {
        // `about:blank` reports `readyState == "complete"`. A gate that trusted readyState alone
        // would pass instantly on a view whose navigation had not started.
        let page = FakePage()
        page.href = "about:blank"

        let readiness = try await driver(page).awaitPageReady(timeout: 0.2, sleep: noSleep)
        guard case .notReady = readiness else {
            return XCTFail("about:blank is not a loaded page, got \(readiness)")
        }
    }

    func testALoadedPageWhoseComposerHasNotHydratedIsNotReady() async throws {
        // ⭐ Measured on ChatGPT's splash shell: readyState complete, plus button present,
        // `#prompt-textarea` absent. A readiness signal weaker than the thing that depends on it
        // is not a gate — P1 types into the composer.
        let page = FakePage()
        page.missing = ["#composer"]

        let readiness = try await driver(page).awaitPageReady(timeout: 0.2, sleep: noSleep)
        guard case .notReady = readiness else {
            return XCTFail("a page with no composer cannot be typed into, got \(readiness)")
        }
    }

    func testAPageThatBecomesReadyPartWayThroughIsAccepted() async throws {
        // The healthy case, and the one the whole gate exists for: the view WAS loading and then
        // finished. A gate that only ever returned notReady would be just as broken.
        let page = FakePage()
        page.readyState = "loading"
        page.becomesReadyAfterReads = 3

        let readiness = try await driver(page).awaitPageReady(timeout: 5, sleep: noSleep)
        XCTAssertEqual(readiness, .ready)
    }

    func testAReadyPageIsAcceptedWithoutWaiting() async throws {
        let readiness = try await driver(FakePage()).awaitPageReady(timeout: 5, sleep: noSleep)
        XCTAssertEqual(readiness, .ready)
    }

    // MARK: - Genuinely signed out

    func testAVisibleSignInControlEndsTheWaitImmediately() async throws {
        // No amount of waiting fixes a signed-out account, and waiting the full ninety seconds on
        // each of three platforms before saying so wastes four and a half minutes to reach a
        // conclusion the page stated at once.
        let page = FakePage()
        page.missing = ["#composer"]
        page.interruption = "the session ended mid-wait — a sign-in control appeared: Log in"

        let readiness = try await driver(page).awaitPageReady(timeout: 60, sleep: noSleep)
        guard case .signedOut(let reason) = readiness else {
            return XCTFail("a visible sign-in control is a signed-out page, got \(readiness)")
        }
        XCTAssertTrue(reason.contains("Log in"))
    }

    func testTheSignInProbeIsNotRunAgainstAPageThatIsStillLoading() async throws {
        // ⛔ ORDER, and it is load-bearing. A signed-IN page mid-load has no composer and no
        // sign-in control either; asking before the document settles learns nothing. Worse, a page
        // that is still painting its login-shaped splash could answer yes and strand a signed-in
        // account. The probe must only be consulted once the document is up.
        let page = FakePage()
        page.readyState = "loading"
        page.bodyChildren = 0
        page.interruption = "a sign-in control appeared: Log in"

        _ = try await driver(page).awaitPageReady(timeout: 0.2, sleep: noSleep)
        XCTAssertFalse(
            page.sawInterruptionProbe,
            "the sign-in probe must not be asked of a document that has not finished loading"
        )
    }

    // MARK: - What the pipeline does with it

    func testTheRunRefusesToDrivePageThatNeverLoaded() async throws {
        let page = FakePage()
        page.readyState = "loading"
        page.bodyChildren = 0
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        do {
            _ = try await pipeline.run(pageReadyTimeout: 0.2, sleep: noSleep)
            XCTFail("a run must not drive a page that never loaded")
        } catch let InAppPhaseError.waitInterrupted(platform, reason) {
            XCTAssertEqual(platform, "chatgpt")
            XCTAssertTrue(reason.contains("composer never appeared"))
        }
        // Nothing was typed. The point of the gate is that the run does not act on a dead page.
        XCTAssertTrue(page.inserted.isEmpty, "nothing may be typed into a page that never loaded")
    }

    func testTheGateRunsEvenWhenTheLoginWalkIsSkipped() async throws {
        // ⛔ **The normal configuration.** Verification is opt-in, so nearly every real run skips
        // phase 0 — and gating readiness *inside* phase 0 would leave the ordinary path driving an
        // empty document. Same failure, one phase later, wearing a selector's name.
        let page = FakePage()
        page.readyState = "loading"
        page.bodyChildren = 0
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        do {
            _ = try await pipeline.run(
                shouldSkip: { $0 == 0 }, pageReadyTimeout: 0.2, sleep: noSleep
            )
            XCTFail("skipping the login walk must not skip the readiness gate")
        } catch let InAppPhaseError.waitInterrupted(_, reason) {
            XCTAssertTrue(reason.contains("composer never appeared"))
        }
    }

    func testASignedOutPageIsReportedAsNotLoggedInWithItsEvidence() async throws {
        let page = FakePage()
        page.missing = ["#composer"]
        page.interruption = "a sign-in control appeared: Sign in"
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        do {
            _ = try await pipeline.run(pageReadyTimeout: 5, sleep: noSleep)
            XCTFail("a signed-out page must not be driven")
        } catch let InAppPhaseError.notLoggedIn(platform, reason) {
            XCTAssertEqual(platform, "chatgpt")
            // The evidence, not just the verdict: this is what tells a reader afterwards whether
            // the account was really signed out or the page had simply not arrived.
            XCTAssertTrue(reason.contains("Sign in"), "got: \(reason)")
        }
    }
}
