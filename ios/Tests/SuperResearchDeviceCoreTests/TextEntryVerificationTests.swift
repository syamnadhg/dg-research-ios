import XCTest
@testable import SuperResearchDeviceCore

/// The composer fill, and the status that nobody read.
///
/// ⛔ **A live run died on this, 2026-08-14.** `document.execCommand('insertText', …)` returned
/// **false** — the editor refused the text — and `ok` was consulted by nothing in the repository.
/// `fillComposer` reported success on an empty composer; ChatGPT's send button, which exists only
/// while the composer is non-empty, was then reported as an `unresolved` selector. The failure
/// surfaced one step downstream of its cause, wearing the name of a selector that was correct.
///
/// The rule enforced here is the repo's own, from `bin/gate_zero_run.py`: *"execCommand returning
/// true is not evidence the editor took it."* The gate read the text back. The product did not.
final class TextEntryVerificationTests: XCTestCase {

    // MARK: - The envelope reader

    func testARefusedInsertIsNOTReportedAsSuccess() {
        // ⭐ **The HISTORICAL shape, exactly: `{ok: false, path: "execCommand"}`.** The old runtime
        // always reported the branch it took, so a refusal and a success were the same `path`, and
        // only `ok` told them apart — which nothing read.
        //
        // ⚠ The first version of this test used `path: "refused"`, and mutation caught it: with the
        // `ok` guard deleted the reader falls through and returns the path, so a fixture whose path
        // ALREADY said "refused" passed either way. A test must not hand the guard its own answer.
        let verdict = WebAutomationBridge.readInsertResult(["ok": false, "path": "execCommand"])
        XCTAssertNotEqual(
            verdict, "execCommand",
            "a refused insert must not come back as the path it attempted"
        )
        XCTAssertTrue(
            verdict?.hasPrefix("refused") == true,
            "a refused insert must be reported as refused — got \(verdict ?? "nil")"
        )
    }

    func testTheRefusalCarriesWHYAndWhatTheComposerActuallyHolds() {
        // Without the reason this is just a different word for failure. The composer's actual
        // contents are what distinguish "typed nowhere" from "typed into the wrong element".
        let verdict = WebAutomationBridge.readInsertResult([
            "ok": false, "path": "refused",
            "err": "the editor refused the text (execCommand=false…)",
            "after": "",
        ])
        XCTAssertTrue(verdict?.contains("execCommand=false") == true, "\(verdict ?? "nil")")
        XCTAssertTrue(verdict?.contains("composer now") == true, "\(verdict ?? "nil")")
    }

    func testAVerifiedInsertReportsThePathThatWorked() {
        XCTAssertEqual(
            WebAutomationBridge.readInsertResult(["ok": true, "path": "paste", "verified": true]),
            "paste"
        )
    }

    func testAMissingOKIsTreatedAsREFUSEDRatherThanAssumedFine() {
        // ⛔ The failure-open direction. A runtime that changed shape must fail loudly rather than
        // resume reporting every fill as successful — which is precisely the state this code was in.
        let verdict = WebAutomationBridge.readInsertResult(["path": "execCommand"])
        XCTAssertTrue(verdict?.hasPrefix("refused") == true, "got \(verdict ?? "nil")")
    }

    func testANonTextTargetKeepsItsOwnSentinel() {
        // A structural miss is a different thing from an editor refusing, and the caller's message
        // should say which.
        XCTAssertEqual(
            WebAutomationBridge.readInsertResult(["err": "not-a-text-target"]), "not-a-text-target"
        )
    }

    func testAStaleHandleIsReportedAsARefusalRatherThanAsATextTargetProblem() {
        let verdict = WebAutomationBridge.readInsertResult(["err": "no-such-handle"])
        XCTAssertEqual(verdict, "refused: no-such-handle")
    }

    func testNoEnvelopeAtAllIsNotSuccess() {
        XCTAssertNil(WebAutomationBridge.readInsertResult(nil))
    }

    // MARK: - No caret is a DIFFERENT fault from a refusal

    /// ⛔ **`execCommand('insertText')` returns false before attempting anything when there is no
    /// range inside an editable root.** That is a different fault from an editor that took the
    /// selection and refused the text, and the two were previously reported identically — which is
    /// what made the 2026-08-14 measurement ambiguous after focus was already proven good
    /// (`hasFocus=true`, `execCommand=false`).
    func testAMissingCARETIsReportedAsItsOwnFaultNotAsARefusal() {
        let verdict = WebAutomationBridge.readInsertResult([
            "ok": false, "verified": false, "path": "no-caret",
            "err": "no caret could be placed inside the editor (hasFocus=true activeIsEditor=false "
                + "inert=true rect=0x0)",
        ])
        XCTAssertTrue(verdict?.hasPrefix("no-caret") == true, "got \(verdict ?? "nil")")
        XCTAssertFalse(
            verdict?.hasPrefix("refused") == true,
            "a missing caret must not be reported as the editor refusing — different cause, "
                + "different fix"
        )
    }

    func testTheNoCaretVerdictCarriesWhatWouldNameTheCause() {
        // Each field settles a different hypothesis: `inert` = a menu overlay marked the page
        // inert; `activeIsEditor` = focus landed somewhere else; `rect` = the element has no
        // layout to put a caret in.
        let verdict = WebAutomationBridge.readInsertResult([
            "ok": false, "path": "no-caret",
            "err": "no caret (hasFocus=true activeIsEditor=false inert=true rect=0x0)",
        ])
        for field in ["activeIsEditor", "inert", "rect"] {
            XCTAssertTrue(verdict?.contains(field) == true, "missing \(field): \(verdict ?? "nil")")
        }
    }

    func testAnEditorThatREFUSEDIsStillReportedAsRefused() {
        // The other half — a guard that called everything `no-caret` would be just as wrong.
        let verdict = WebAutomationBridge.readInsertResult(["ok": false, "path": "execCommand"])
        XCTAssertTrue(verdict?.hasPrefix("refused") == true, "got \(verdict ?? "nil")")
    }

    // MARK: - What the pipeline does with a refusal

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

    func testAComposerThatREFUSEDTheTextFailsAtTheCOMPOSER() async throws {
        // ⭐ The whole point of the fix: the failure is named where it happened. Before, this run
        // continued to `send` and died there — pointing three steps of debugging at a selector that
        // was never wrong.
        let page = FakePage()
        page.insertResult = "refused: the editor refused the text"
        let subject = driver(page)

        do {
            _ = try await subject.fillComposer("a research brief")
            XCTFail("a refused fill must not report success")
        } catch let InAppPhaseError.outcomeUnconfirmed(intent) {
            XCTAssertTrue(intent.contains("composer"), "the failure must name the composer: \(intent)")
            XCTAssertTrue(intent.contains("refused"), "and carry the reason: \(intent)")
        }
    }

    // MARK: - A modal over the page

    /// ⛔ **Measured live 2026-08-14, ChatGPT:** `hasFocus=true`, composer rendered at 308x276, and
    /// `inert=true`. A dialog was open over the page — and `inert`/`aria-hidden` content is neither
    /// focusable nor editable, so `focus()` no-ops and every synthetic event is dropped. The fill
    /// then fails for a reason that points at the editor rather than at the thing on top of it.
    ///
    /// Gemini, on the same run, filled successfully and failed later at `send` — which is what
    /// proves the caret work is right and isolates this to the overlay.
    func testTheComposerIsUNBLOCKEDBeforeTheTextIsTyped() async throws {
        let page = FakePage()
        page.overlayBlocker = "Upgrade to Pro"
        page.overlayClearsOnEscape = true

        _ = try await driver(page).fillComposer("a research brief")

        XCTAssertTrue(page.sawOverlayProbe, "the fill must clear a modal before typing into it")
        XCTAssertEqual(page.inserted, ["a research brief"])
    }

    func testAClearPageStillGetsFilledWithoutCeremony() async throws {
        // The normal case must cost nothing and must not be broken by the overlay handling.
        let page = FakePage()
        page.overlayBlocker = nil
        let path = try await driver(page).fillComposer("a research brief")
        XCTAssertEqual(path, "execCommand")
    }

    func testAModalThatREFUSESToCloseDoesNotStopTheAttempt() async throws {
        // ⚠ The overlay step is best-effort ON PURPOSE. If a dialog will not close, the fill's own
        // `no-caret` verdict — which names the blocking element — is the better report, and a
        // second error competing to describe the same moment only obscures it.
        let page = FakePage()
        page.overlayBlocker = "Stuck dialog"
        page.overlayClearsOnEscape = false

        _ = try? await driver(page).fillComposer("a research brief")

        XCTAssertTrue(page.sawOverlayProbe, "it must still have tried")
    }

    func testAnAcceptedFillReturnsThePathItUsed() async throws {
        let page = FakePage()
        page.insertResult = "paste"
        let path = try await driver(page).fillComposer("a research brief")
        XCTAssertEqual(path, "paste")
    }

    func testANoCaretFillFailsAtTheComposerToo() async throws {
        // It must not sail through as success just because it is not the word "refused".
        let page = FakePage()
        page.insertResult = "no-caret: no caret could be placed inside the editor"
        let subject = driver(page)
        do {
            _ = try await subject.fillComposer("a research brief")
            XCTFail("a fill with no caret placed must not report success")
        } catch let InAppPhaseError.outcomeUnconfirmed(intent) {
            XCTAssertTrue(intent.contains("composer"), intent)
            XCTAssertTrue(intent.contains("no-caret"), "the reason must survive to the caller: \(intent)")
        }
    }

    func testTheNonTextTargetSentinelStillFails() async throws {
        let page = FakePage()
        page.insertResult = "not-a-text-target"
        do {
            _ = try await driver(page).fillComposer("a research brief")
            XCTFail("a non-text target must not report success")
        } catch let InAppPhaseError.outcomeUnconfirmed(intent) {
            XCTAssertTrue(intent.contains("composer"))
        }
    }
}

/// What made a meaningless run look like a successful one.
///
/// ⛔ Measured live 2026-08-14. The run reported `status=complete`, wrote three documents and
/// handed off to the cloud. All three of these were wrong at once:
///
///  * the "report" was the BRIEF — 11,969 vs 11,970 chars, the same text;
///  * both began `Claude responded:`, a speaker label captured as content;
///  * and the brief came from CLAUDE, because ChatGPT was blocked and the executor let whichever
///    platform finished first become the brief writer.
///
/// The owner's verdict was that none of it meant anything. It didn't.
final class MeaninglessSuccessTests: XCTestCase {

    // MARK: - A report that is the brief

    func testAReportIdenticalToTheBriefIsNotAccepted() {
        let brief = String(repeating: "Deep Research Brief. ", count: 600)
        XCTAssertTrue(
            InAppPipeline.isSameText(brief, as: brief),
            "the exact case that shipped: P2 harvested the turn P1 had already produced"
        )
    }

    func testAOneCharacterDifferenceDoesNotMakeItADifferentReport() {
        // ⚠ The measured shape — 11,969 vs 11,970. Equality would have called these different and
        // let the run ship, which is precisely what happened.
        let brief = String(repeating: "Deep Research Brief. ", count: 600)
        XCTAssertTrue(InAppPipeline.isSameText(brief + ".", as: brief))
    }

    func testAGENUINEReportIsNotMistakenForTheBrief() {
        // The other direction, and the one that matters for not breaking healthy runs: a real
        // report is far longer than the brief that prompted it.
        let brief = String(repeating: "Brief. ", count: 100)
        let report = brief + String(repeating: "Findings, evidence and citations. ", count: 800)
        XCTAssertFalse(
            InAppPipeline.isSameText(report, as: brief),
            "a real report legitimately opens by restating the brief — length is what separates them"
        )
    }

    func testTwoDIFFERENTTextsOfTheSameLengthAreNotTheSame() {
        // Length alone is too weak: two answers can be coincidentally similar in size.
        let a = String(repeating: "aaaa ", count: 200)
        let b = String(repeating: "bbbb ", count: 200)
        XCTAssertFalse(InAppPipeline.isSameText(a, as: b))
    }

    func testAnEmptyReadIsNeverJudgedTheSame() {
        // Otherwise a failed extraction would be reported as "the report is the brief", which
        // names the wrong fault.
        XCTAssertFalse(InAppPipeline.isSameText("", as: "something"))
        XCTAssertFalse(InAppPipeline.isSameText("something", as: ""))
    }

    /// ⭐ Through the PIPELINE, not through the helper.
    ///
    /// ⚠ The first version of this asserted `isSameText` directly and mutation caught it: deleting
    /// the guard from `InAppPipeline` changed nothing, because the test never went near it. A test
    /// that exercises a helper is not a test that the product consults the helper.
    func testTheRunREFUSESAReportThatIsJustTheBrief() async throws {
        let page = FakePage()
        // One stable answer on the page for the whole run — which is exactly the live shape: the
        // turn P1 produced is still on screen when P2 reads, and it is stable, so the response
        // wait returns at once and the extractor harvests it again.
        page.responseText = String(repeating: "Deep Research Brief on the topic. ", count: 40)
        var pipeline = InAppPipeline(
            driver: InAppPhaseDriver(
                platform: "claude",
                manifest: [
                    "composer": ["#composer"], "send": ["#send-button"],
                    "response_container": ["#response-container"],
                ],
                page: page
            ),
            topic: "t"
        )

        do {
            _ = try await pipeline.run(
                shouldSkip: { $0 == 0 }, responseTimeout: 1, pageReadyTimeout: 1, sleep: noSleepHere
            )
            XCTFail("a report identical to the brief must not be accepted as research")
        } catch let InAppPhaseError.outcomeUnconfirmed(intent) {
            XCTAssertTrue(
                intent.contains("report-is-the-brief"),
                "the failure must name what actually happened: \(intent)"
            )
        }
    }

    private var noSleepHere: @Sendable (Duration) async throws -> Void { { _ in } }

    // MARK: - The speaker label

    func testTheSpeakerLabelIsStrippedFromTheProduct() {
        // ⛔ It was carried into P2's prompt AND into the saved document.
        XCTAssertEqual(
            InAppPhaseDriver.strippingSpeakerPrefix("Claude responded: Deep Research Brief: Nemo", platform: "claude"),
            "Deep Research Brief: Nemo"
        )
        XCTAssertEqual(
            InAppPhaseDriver.strippingSpeakerPrefix("ChatGPT said: Here is the brief", platform: "chatgpt"),
            "Here is the brief"
        )
    }

    func testOnlyALabelAtTheVERYSTARTIsRemoved() {
        // ⚠ Anchored, never a search-and-replace: "said:" appears throughout ordinary prose, and a
        // global strip would quietly edit the research itself.
        let body = "The paper said: models drift over time, and the author responded: not always."
        XCTAssertEqual(InAppPhaseDriver.strippingSpeakerPrefix(body, platform: "claude"), body)
    }

    func testOrdinaryContentIsLeftExactlyAlone() {
        let body = "Deep Research Brief: NemoClaw vs NemoHermes"
        XCTAssertEqual(InAppPhaseDriver.strippingSpeakerPrefix(body, platform: "claude"), body)
    }

    // MARK: - Who writes the brief

    func testTheBriefPlatformIsCHATGPTAndIsNotWhoeverFinishesFirst() {
        // ⛔ The desktop hardcodes P1 to chatgpt.com (`run_phase1`) and every event it emits says
        // agent="chatgpt". When ours let the first finisher win, a blocked ChatGPT silently
        // promoted Claude to brief writer — a different model answering a different contract, with
        // nothing in the run saying so.
        XCTAssertEqual(RunExecutor.briefPlatform, "chatgpt")
    }
}
