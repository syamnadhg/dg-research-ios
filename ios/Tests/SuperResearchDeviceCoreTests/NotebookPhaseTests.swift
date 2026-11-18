import XCTest

@testable import SuperResearchDeviceCore

/// A page that answers the NotebookLM driver's ported JavaScript.
///
/// ⚠ Keyed on a DISTINCTIVE fragment of each expression and it records every one it is asked, so
/// the tests below can assert what was evaluated and **in what order** rather than only what came
/// back. That ordering is the mechanism in three of these — a verify taken after the save reads a
/// dialog that is already closed, and would pass a state assertion just as happily.
///
/// ⚠ The JavaScript's own semantics are NOT tested here; they are executed under node against a DOM
/// stub in `emubackend/tests/test_notebook_js.py`. A fake that both supplies and judges the answer
/// proves only that the fake agrees with itself.
final class ScriptedNotebookPage: WebPage, @unchecked Sendable {
    /// Fragment → the value to return, first match wins in insertion order.
    private var rules: [(marker: String, value: Any?)] = []
    private(set) var evaluated: [String] = []
    private(set) var clicked: [Int] = []
    private(set) var inserted: [String] = []
    var handles: [String: Int] = [:]
    /// Handle → visible text, for the manifest keys that resolve by TEXT alone.
    ///
    /// ⚠ Not decoration: `add_source` and `insert_source` carry NO css on purpose — the sheet's
    /// controls are icon-font ligatures with no stable id — so a fake with no text channel cannot
    /// resolve the two controls P3's source step is entirely made of.
    var textNodes: [Int: String] = [:]
    /// Selectors that resolve only after N looks, for the polling paths.
    var appearsAfter: [String: Int] = [:]
    private var looks: [String: Int] = [:]
    var insertResult: String? = "execCommand"

    /// A closure form for answers that change between calls (a URL that only appears after a click).
    private var dynamic: [(marker: String, value: () -> Any?)] = []

    func on(_ marker: String, _ value: Any?) { rules.append((marker, value)) }
    /// Take precedence over an earlier rule for the same marker.
    ///
    /// ⚠ Needed because first-match-wins is what makes rule order readable, and a test that wants
    /// to CHANGE a shared fixture's answer would otherwise silently keep the fixture's — which is
    /// how a drift test ends up asserting against a page that never drifted.
    func override(_ marker: String, _ value: Any?) { rules.insert((marker, value), at: 0) }
    func on(_ marker: String, dynamic value: @escaping () -> Any?) {
        dynamic.append((marker, value))
    }

    func evaluateJSON(_ expression: String) async throws -> Any? {
        evaluated.append(expression)
        for rule in dynamic where expression.contains(rule.marker) { return rule.value() }
        for rule in rules where expression.contains(rule.marker) { return rule.value }
        return nil
    }

    func querySelector(_ css: String) async throws -> Int? {
        looks[css, default: 0] += 1
        if let after = appearsAfter[css], looks[css]! <= after { return nil }
        return handles[css]
    }

    func querySelectorAll(_ css: String) async throws -> [Int] {
        css == InAppPhaseDriver.textFallbackRoles ? textNodes.keys.sorted() : []
    }
    func attribute(_ handle: Int, _ name: String) async throws -> String? { nil }
    func innerText(_ handle: Int) async throws -> String? { textNodes[handle] }
    func click(_ handle: Int) async throws { clicked.append(handle) }
    func insertText(_ handle: Int, _ text: String) async throws -> String? {
        if insertResult == "not-a-text-target" { return insertResult }
        inserted.append(text)
        return insertResult
    }
    func key(_ name: String) async throws {}

    /// Did anything containing *marker* get evaluated?
    func sawEvaluation(containing marker: String) -> Bool {
        evaluated.contains { $0.contains(marker) }
    }

    /// The index of the first evaluation containing *marker*, or nil.
    func indexOfEvaluation(containing marker: String) -> Int? {
        evaluated.firstIndex { $0.contains(marker) }
    }
}

private let nlmManifest: [String: [String]] = [
    "create_notebook": ["button[aria-label=\"Create new notebook\"]"],
    "source_textarea": ["textarea[aria-label=\"Pasted text\"]"],
    "share": ["button[aria-label=\"Share\"]"],
]
private let nlmTexts: [String: String] = [
    "add_source": "Copied text", "insert_source": "Insert",
]
private let nlmOpeners: [String: String] = ["add_source": "__url:?addSource=true"]

private func driver(_ page: ScriptedNotebookPage) -> NotebookPhaseDriver {
    NotebookPhaseDriver(
        manifest: nlmManifest, texts: nlmTexts, openers: nlmOpeners, page: page
    )
}

private let nothing: @Sendable (Duration) async throws -> Void = { _ in }

// MARK: - The URL predicate

final class NotebookURLTests: XCTestCase {

    func testTheNotebookIdIsReadFromThePathAndStopsAtAQuery() {
        XCTAssertEqual(
            NotebookPhaseDriver.notebookID("https://notebook.google.com/notebook/abc-123?addSource=true"),
            "abc-123"
        )
        XCTAssertEqual(NotebookPhaseDriver.notebookID("https://notebook.google.com/"), "")
    }

    func testTheHOSTIsMatchedAsAFAMILYAndNeverAsALiteral() {
        // ⛔ Google renamed this product's host once already and four separate gates keyed on the
        // old literal went dark in the same moment — the outage presented as "the platform is
        // signed out". Both hosts must pass.
        XCTAssertTrue(NotebookPhaseDriver.isNotebookURL("https://notebook.google.com/notebook/x1"))
        XCTAssertTrue(NotebookPhaseDriver.isNotebookURL("https://notebooklm.google.com/notebook/x1"))
    }

    func testANonGoogleHostIsRejectedEvenWithTheRightPath() {
        // A page-wide read is allowed precisely because this predicate gates every candidate; a
        // lookalike host would let an arbitrary link be written as the owner's notebook.
        XCTAssertFalse(NotebookPhaseDriver.isNotebookURL("https://notebook.google.com.evil.test/notebook/x"))
        XCTAssertFalse(NotebookPhaseDriver.isNotebookURL("https://example.test/notebook/x"))
    }

    func testABareNotebookPathWithNoIdIsNotALink() {
        XCTAssertFalse(NotebookPhaseDriver.isNotebookURL("https://notebook.google.com/notebook/"))
    }

    func testANonHttpSchemeIsRejected() {
        // `javascript:` and `data:` URLs parse perfectly well and would be written into the
        // research document as the owner's notebook link.
        XCTAssertFalse(NotebookPhaseDriver.isNotebookURL("javascript:alert(1)//notebook.google.com/notebook/x"))
    }
}

// MARK: - Creating the notebook

final class NotebookCreationTests: XCTestCase {

    func testAnExistingNotebookIsREUSEDAndNothingIsClicked() async throws {
        // ⛔ Every P3 creates a PERMANENT notebook in the owner's real Google account and nothing
        // anywhere cleans them up. A retry that creates rather than reuses is a cost that
        // accumulates for ever, and the run looks identical either way.
        let page = ScriptedNotebookPage()
        page.on("location.href", "https://notebook.google.com/notebook/already-here")
        page.handles["button[aria-label=\"Create new notebook\"]"] = 7

        let url = try await driver(page).createNotebook(sleep: nothing)

        XCTAssertEqual(url, "https://notebook.google.com/notebook/already-here")
        XCTAssertEqual(page.clicked, [], "it created a SECOND notebook on a resumed run")
    }

    func testItWaitsForTheURLToCarryAnIdRatherThanReturningTheListPage() async throws {
        // ⚠ Creation navigates and the id only exists once the server answers. Returning the
        // pre-navigation URL anchors every later step — including the download re-anchor — to the
        // notebook LIST, where another run's audio card is what gets downloaded.
        let page = ScriptedNotebookPage()
        var looks = 0
        page.on("location.href", dynamic: {
            looks += 1
            return looks > 2 ? "https://notebook.google.com/notebook/new-1" : "https://notebook.google.com/"
        })
        page.handles["button[aria-label=\"Create new notebook\"]"] = 7

        let url = try await driver(page).createNotebook(sleep: nothing)

        XCTAssertEqual(url, "https://notebook.google.com/notebook/new-1")
        XCTAssertEqual(page.clicked, [7])
    }

    func testAMissingCreateControlIsALoudFailure() async {
        let page = ScriptedNotebookPage()
        page.on("location.href", "https://notebook.google.com/")
        do {
            _ = try await driver(page).createNotebook(sleep: nothing)
            XCTFail("P3 continued with no notebook")
        } catch NotebookPhaseDriver.NotebookError.noNotebook { /* expected */ } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

// MARK: - The source

final class NotebookSourceTests: XCTestCase {

    private func page(withTextarea: Bool = true) -> ScriptedNotebookPage {
        let page = ScriptedNotebookPage()
        page.on("location.href", "https://notebook.google.com/notebook/nb-1")
        page.handles["textarea[aria-label=\"Pasted text\"]"] = withTextarea ? 20 : nil
        page.textNodes = [40: "content_paste Copied text", 41: "Insert"]
        return page
    }

    private let report = String(repeating: "Consolidated research findings. ", count: 40)

    func testAThinReportIsRefusedBEFOREThePageIsTouched() async {
        // Generating an Audio Overview from a stub produces a podcast about nothing — at the end of
        // a run that has already spent three deep-research units.
        let page = self.page()
        do {
            try await driver(page).addSource("too short", notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing)
            XCTFail("a stub was accepted as the notebook's source")
        } catch let NotebookPhaseDriver.NotebookError.sourceTooShort(chars) {
            XCTAssertEqual(chars, 9)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(page.evaluated.isEmpty, "it navigated before checking it had anything to add")
    }

    func testTheAddSourceSheetIsReachedByNAVIGATINGAndNotByTapping() async throws {
        // ⛔ The manifest records the opener as `__url:?addSource=true` — and NOTHING in either half
        // of this codebase read that prefix, so a machine-readable opener sat inert as prose. This
        // asserts the navigation actually happens, with the query appended to the notebook's URL.
        let page = self.page()
        page.handles["dummy"] = 1
        try await driver(page).addSource(
            report, notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing
        )
        XCTAssertTrue(
            page.sawEvaluation(containing: "location.assign('https://notebook.google.com/notebook/nb-1?addSource=true')"),
            "the add-source sheet was never navigated to; evaluated: \(page.evaluated)"
        )
    }

    func testAnExistingQueryOnTheNotebookURLIsReplacedRatherThanAppendedTo() async throws {
        // Otherwise the URL grows a second `?`, which is not a query at all, and the sheet never
        // opens — while the navigation itself reports success.
        let page = self.page()
        try await driver(page).addSource(
            report, notebookURL: "https://notebook.google.com/notebook/nb-1?foo=bar", sleep: nothing
        )
        XCTAssertTrue(
            page.sawEvaluation(containing: "location.assign('https://notebook.google.com/notebook/nb-1?addSource=true')"),
            "evaluated: \(page.evaluated)"
        )
    }

    func testAMissingTextareaFailsWithTheREASONRatherThanPressingInsert() async {
        // ⚠ The likeliest failure on this surface, and it must not be attributed to the paste. The
        // one time this sheet was opened it was opened by a REAL tap; every click the pipeline can
        // make reports `isTrusted === false`.
        let page = self.page(withTextarea: false)
        do {
            try await driver(page).addSource(
                report, notebookURL: "https://notebook.google.com/notebook/nb-1", attempts: 2,
                sleep: nothing
            )
            XCTFail("the source was reported as added with no textarea")
        } catch let NotebookPhaseDriver.NotebookError.sourceNotAccepted(why) {
            XCTAssertTrue(why.contains("untrusted"), "the message names no cause: \(why)")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(page.inserted.isEmpty)
    }

    func testTheReportIsPastedWHOLEAndOnce() async throws {
        // One paste, not three: one interaction is one chance for the sheet to close early, and the
        // Audio Overview is generated from the notebook as a whole either way.
        let page = self.page()
        try await driver(page).addSource(
            report, notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing
        )
        // Trimmed, because leading/trailing whitespace in a pasted source becomes a leading
        // silence in the podcast; the BODY must otherwise be whole.
        XCTAssertEqual(page.inserted, [report.trimmingCharacters(in: .whitespacesAndNewlines)])
        XCTAssertEqual(page.inserted.count, 1)
    }

    func testATextareaThatRefusesTheTextIsAFailureNotASilentSkip() async {
        let page = self.page()
        page.insertResult = "not-a-text-target"
        do {
            try await driver(page).addSource(
                report, notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing
            )
            XCTFail("an empty notebook was accepted")
        } catch NotebookPhaseDriver.NotebookError.sourceNotAccepted { /* expected */ } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

// MARK: - The public link

final class NotebookShareTests: XCTestCase {

    private func page() -> ScriptedNotebookPage {
        let page = ScriptedNotebookPage()
        page.handles["button[aria-label=\"Share\"]"] = 30
        return page
    }

    func testNoShareControlDEGRADESToTheNotebookURLAndNeverThrows() async throws {
        // ⛔ A run that has produced a podcast must not die because a share dialog moved. The
        // backend takes the same position; this is that shape, ported.
        let page = ScriptedNotebookPage()
        let outcome = try await driver(page).share(
            notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing
        )
        XCTAssertEqual(outcome.url, "https://notebook.google.com/notebook/nb-1")
        XCTAssertFalse(outcome.publicVerified)
        XCTAssertFalse(outcome.accessSet)
    }

    func testTheLinkIsReadFromTheDialogWhenOneIsThere() async throws {
        let page = self.page()
        page.on("no_link_in_dialog", ["url": "https://notebook.google.com/notebook/nb-1", "via": "input"])
        page.on("return 'selected'", "selected")
        page.on("var scope = document.querySelector", false)
        page.on("notebook access", "opened")
        page.on("var PHRASE", true)

        let outcome = try await driver(page).share(notebookURL: "https://x.test/nb", sleep: nothing)

        XCTAssertEqual(outcome.url, "https://notebook.google.com/notebook/nb-1")
        XCTAssertTrue(outcome.publicVerified)
        XCTAssertTrue(outcome.accessSet)
    }

    func testALinkThatIsNotANotebookURLIsDISCARDEDRatherThanWritten() async throws {
        // The read ranges over the page, so a stray readonly input holding some other URL would
        // otherwise be published as the owner's notebook.
        let page = self.page()
        page.on("notebook access", "opened")
        page.on("no_link_in_dialog", ["url": "https://example.test/not-a-notebook", "via": "input"])

        let outcome = try await driver(page).share(
            notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing
        )
        XCTAssertEqual(outcome.url, "https://notebook.google.com/notebook/nb-1")
    }

    func testAnALREADYPublicNotebookCountsAsAccessSetRatherThanAsAFailure() async throws {
        // ⭐ Finding the control already on target and not touching it is the BEST outcome. The
        // access opener only fires on a control reading Restricted/Private, so on a second share
        // there is by design nothing left to click — and the old reading called that a failure.
        let page = self.page()
        page.on("notebook access", "opened")
        page.on("return 'selected'", "")
        page.on("var scope = document.querySelector", true)

        let outcome = try await driver(page).share(notebookURL: "https://x.test/nb", sleep: nothing)

        XCTAssertTrue(outcome.accessSet)
        XCTAssertTrue(outcome.reason.contains("already"))
    }

    func testTheACCESSVerdictIsREADBeforeTheDialogIsSAVED() async throws {
        // ⛔ The mechanism, not the outcome. Saving closes the dialog, so a verify taken afterwards
        // reads an empty page and returns false — which the caller reports as "this link may
        // genuinely be private" about a notebook that was just made public.
        let page = self.page()
        page.on("notebook access", "opened")
        page.on("var PHRASE", true)
        page.on("'saved'", "saved")

        _ = try await driver(page).share(notebookURL: "https://x.test/nb", sleep: nothing)

        guard let verify = page.indexOfEvaluation(containing: "var PHRASE"),
              let save = page.indexOfEvaluation(containing: "=== 'save'") else {
            return XCTFail("one of the two steps never ran: \(page.evaluated.count) evaluations")
        }
        XCTAssertLessThan(verify, save, "the dialog was saved before its state was read")
    }

    func testADialogThatYIELDSNoLinkStillReturnsTheNOTEBOOKURL() async throws {
        // ⭐ CAUGHT BY MUTATION, and the lesson is about the OTHER degrade test above it: that one
        // exercises the early return taken when there is no Share control at all, so it never
        // reaches the fallback it was written to prove. This is the path where the dialog opened,
        // the read found nothing, and the run must still come away with a link.
        //
        // ⛔ Returning "" here leaves the P3 tile with no NotebookLM row, which reads as "P3 never
        // ran" rather than as "the link may be private".
        let page = self.page()
        page.on("no_link_in_dialog", ["url": "", "via": "no_link_in_dialog"])

        let outcome = try await driver(page).share(
            notebookURL: "https://notebook.google.com/notebook/nb-7", sleep: nothing
        )

        XCTAssertEqual(outcome.url, "https://notebook.google.com/notebook/nb-7")
        XCTAssertFalse(outcome.publicVerified)
    }

    func testAnUnsetUnverifiedShareSaysSoInTheReason() async throws {
        let page = self.page()
        let outcome = try await driver(page).share(notebookURL: "https://x.test/nb", sleep: nothing)
        XCTAssertTrue(outcome.reason.contains("private"), outcome.reason)
    }
}

// MARK: - The Audio Overview

final class NotebookAudioTests: XCTestCase {

    func testNothingIsGeneratedWhenAPodcastIsALREADYThere() async throws {
        // A second Generate is how the account ends up with two podcasts — and the download then
        // picks one of them by position.
        let page = ScriptedNotebookPage()
        page.on("audio_magic_eraser", true)
        _ = try await driver(page).generateAudio(length: .long, sleep: nothing)
        XCTAssertFalse(page.sawEvaluation(containing: "label === 'generate'"))
    }

    func testNothingIsGeneratedWhileOneIsSTILLGenerating() async throws {
        let page = ScriptedNotebookPage()
        page.on("audio_magic_eraser", false)
        page.on("creating audio", true)
        _ = try await driver(page).generateAudio(length: .long, sleep: nothing)
        XCTAssertFalse(page.sawEvaluation(containing: "label === 'generate'"))
    }

    func testTheSHORTVariantSetsNoLengthBecauseItHasNoLengthStep() async throws {
        // ⛔ `short` is a DIFFERENT format tile ("Brief"), not a shorter Deep Dive, and the backend's
        // own variant table records that it has no separate length step. A flow that always sets
        // format-then-length hunts for a control that is not on screen.
        let page = ScriptedNotebookPage()
        page.on("Customise Audio Overview", true)
        page.on("label === 'generate'", true)
        page.on("=== want", true)

        _ = try await driver(page).generateAudio(length: .short, sleep: nothing)

        let picks = page.evaluated.filter { $0.contains("=== want") }
        XCTAssertEqual(picks.count, 1, "a length step ran for the Brief variant")
        XCTAssertTrue(picks[0].contains("'Brief'"), picks[0])
    }

    func testTheLONGVariantSetsDeepDiveANDLong() async throws {
        let page = ScriptedNotebookPage()
        page.on("Customise Audio Overview", true)
        page.on("label === 'generate'", true)
        page.on("=== want", true)

        _ = try await driver(page).generateAudio(length: .long, sleep: nothing)

        let picks = page.evaluated.filter { $0.contains("=== want") }
        XCTAssertEqual(picks.count, 2)
        XCTAssertTrue(picks[0].contains("'Deep Dive'"))
        XCTAssertTrue(picks[1].contains("'Long'"))
    }

    func testTheDEFAULTVariantSetsDeepDiveAndDefault() async throws {
        let page = ScriptedNotebookPage()
        page.on("Customise Audio Overview", true)
        page.on("label === 'generate'", true)
        page.on("=== want", true)

        _ = try await driver(page).generateAudio(length: .default, sleep: nothing)

        let picks = page.evaluated.filter { $0.contains("=== want") }
        XCTAssertEqual(picks.count, 2)
        XCTAssertTrue(picks[1].contains("'Default'"))
    }

    func testAMissingCustomiseArrowFailsRatherThanFallingBackToTheCardBody() async {
        // ⛔ Clicking the card BODY fires NotebookLM's one-click DEFAULT audio — the confirmed
        // source of duplicate podcasts. A "helpful" fallback here is worse than the failure.
        let page = ScriptedNotebookPage()
        page.on("Customise Audio Overview", false)
        page.on("label === 'generate'", false)
        do {
            _ = try await driver(page).generateAudio(length: .long, sleep: nothing)
            XCTFail("it reported a generation that never started")
        } catch let NotebookPhaseDriver.NotebookError.audioNeverStarted(why) {
            XCTAssertTrue(why.contains("card BODY"), why)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAnUNREADABLEPageIsNotReady() async throws {
        // Generation takes up to ninety minutes, so a false "ready" reports a podcast that does not
        // exist while a false "not ready" costs more waiting. Those are not symmetrical.
        let page = ScriptedNotebookPage()   // answers nil to everything
        let ready = try await driver(page).audioIsReady()
        XCTAssertFalse(ready)
    }

    func testTheWaitGivesUpRatherThanHangingForEver() async throws {
        let page = ScriptedNotebookPage()
        page.on("audio_magic_eraser", false)
        var clock = Date(timeIntervalSince1970: 0)
        let done = try await driver(page).awaitAudio(
            timeout: 60, poll: .seconds(30),
            now: { clock }, sleep: { d in clock += TimeInterval(d.components.seconds) }
        )
        XCTAssertFalse(done)
    }

    func testTheWaitReturnsAsSoonAsTheCardIsComplete() async throws {
        let page = ScriptedNotebookPage()
        var polls = 0
        page.on("audio_magic_eraser", dynamic: { polls += 1; return polls >= 2 })
        var clock = Date(timeIntervalSince1970: 0)
        let done = try await driver(page).awaitAudio(
            timeout: 600, poll: .seconds(30),
            now: { clock }, sleep: { d in clock += TimeInterval(d.components.seconds) }
        )
        XCTAssertTrue(done)
        XCTAssertEqual(polls, 2, "it kept polling a finished podcast")
    }
}

// MARK: - The download

final class NotebookDownloadTests: XCTestCase {

    /// Base64 of four ASCII bytes, so a chunked read is checkable end to end.
    private func chunkedPage(_ payload: [UInt8], chunk: Int) -> ScriptedNotebookPage {
        let page = ScriptedNotebookPage()
        page.on("location.href", "https://notebook.google.com/notebook/nb-1")
        page.on("__srAudioCapture = { url", true)
        page.on("=== 'download'", true)
        page.on("window.__srAudioCapture && window.__srAudioCapture.url", "https://x.test/a.m4a")
        page.on("credentials: 'include'", payload.count)
        page.rules(forChunk: payload, size: chunk)
        return page
    }

    func testTheAudioIsAssembledFromChunksInORDER() async throws {
        let payload: [UInt8] = Array(0..<40)
        let page = chunkedPage(payload, chunk: 7)
        let data = try await driver(page).downloadAudio(
            notebookURL: "https://notebook.google.com/notebook/nb-1", chunkBytes: 7, sleep: nothing
        )
        XCTAssertEqual([UInt8](data), payload)
    }

    func testTheDownloadREANCHORSWhenThePageHasDrifted() async throws {
        // ⛔ A verified root cause on the desktop: the page drifts between generate and download,
        // and a drifted page surfaces a DIFFERENT notebook's audio card. The download then succeeds
        // and delivers another run's podcast.
        let payload: [UInt8] = [1, 2, 3, 4]
        let page = chunkedPage(payload, chunk: 4)
        page.override("location.href", "https://notebook.google.com/notebook/SOMEONE-ELSE")

        _ = try await driver(page).downloadAudio(
            notebookURL: "https://notebook.google.com/notebook/nb-1", chunkBytes: 4, sleep: nothing
        )
        XCTAssertTrue(
            page.sawEvaluation(containing: "location.assign('https://notebook.google.com/notebook/nb-1')"),
            "it downloaded from whatever notebook the page had drifted to"
        )
    }

    func testAnAlreadyAnchoredPageIsNotNavigated() async throws {
        let payload: [UInt8] = [9, 9, 9, 9]
        let page = chunkedPage(payload, chunk: 4)
        _ = try await driver(page).downloadAudio(
            notebookURL: "https://notebook.google.com/notebook/nb-1", chunkBytes: 4, sleep: nothing
        )
        XCTAssertFalse(page.sawEvaluation(containing: "location.assign"))
    }

    func testAZeroLengthChunkIsAFailureAndNotAnEndOfStream() async {
        // ⛔ Otherwise this loops for ever — or, if treated as the end, delivers a TRUNCATED podcast,
        // which plays perfectly right up to where it stops.
        let page = ScriptedNotebookPage()
        page.on("location.href", "https://notebook.google.com/notebook/nb-1")
        page.on("__srAudioCapture = { url", true)
        page.on("=== 'download'", true)
        page.on("window.__srAudioCapture && window.__srAudioCapture.url", "https://x.test/a.m4a")
        page.on("credentials: 'include'", 100)
        page.on("window.__srAudioRead(", "")

        do {
            _ = try await driver(page).downloadAudio(
                notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing
            )
            XCTFail("a truncated podcast was returned as complete")
        } catch NotebookPhaseDriver.NotebookError.audioNotDownloadable { /* expected */ } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAFailedFETCHIsReportedRatherThanReturningEmptyBytes() async {
        let page = ScriptedNotebookPage()
        page.on("location.href", "https://notebook.google.com/notebook/nb-1")
        page.on("__srAudioCapture = { url", true)
        page.on("=== 'download'", true)
        page.on("window.__srAudioCapture && window.__srAudioCapture.url", "https://x.test/a.m4a")
        page.on("credentials: 'include'", -1)

        do {
            _ = try await driver(page).downloadAudio(
                notebookURL: "https://notebook.google.com/notebook/nb-1", sleep: nothing
            )
            XCTFail("an unfetchable URL produced a podcast")
        } catch NotebookPhaseDriver.NotebookError.audioNotDownloadable { /* expected */ } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testThePlayerSourceIsTheFallbackWhenTheRowProducesNoURL() async throws {
        let payload: [UInt8] = [7, 7]
        let page = ScriptedNotebookPage()
        page.on("location.href", "https://notebook.google.com/notebook/nb-1")
        page.on("__srAudioCapture = { url", true)
        page.on("=== 'download'", true)
        page.on("window.__srAudioCapture && window.__srAudioCapture.url", "")
        page.on("querySelector('audio')", "blob:https://notebook.google.com/xyz")
        page.on("credentials: 'include'", payload.count)
        page.rules(forChunk: payload, size: 2)

        let data = try await driver(page).downloadAudio(
            notebookURL: "https://notebook.google.com/notebook/nb-1", chunkBytes: 2, attempts: 1,
            sleep: nothing
        )
        XCTAssertEqual([UInt8](data), payload)
        XCTAssertTrue(page.sawEvaluation(containing: "blob:") || page.sawEvaluation(containing: "credentials: 'include'"))
    }

    func testTheCAPTUREIsArmedBEFORETheDownloadRowIsPressed() async throws {
        // ⛔ The mechanism. Arming afterwards misses the URL entirely — the click has already
        // happened — and the fallback then delivers whatever the player happens to hold, which on a
        // notebook with two cards is the wrong podcast.
        let payload: [UInt8] = [3, 3, 3, 3]
        let page = chunkedPage(payload, chunk: 4)
        _ = try await driver(page).downloadAudio(
            notebookURL: "https://notebook.google.com/notebook/nb-1", chunkBytes: 4, sleep: nothing
        )
        guard let arm = page.indexOfEvaluation(containing: "__srAudioCapture = { url"),
              let press = page.indexOfEvaluation(containing: "=== 'download'") else {
            return XCTFail("one of the two steps never ran")
        }
        XCTAssertLessThan(arm, press)
    }
}

extension ScriptedNotebookPage {
    /// Answer `__srAudioRead(offset, length)` from a payload, so a chunk loop can be exercised.
    func rules(forChunk payload: [UInt8], size: Int) {
        on("window.__srAudioRead(", dynamic: { [weak self] in
            guard let expression = self?.evaluated.last,
                  let open = expression.firstIndex(of: "("),
                  let close = expression.lastIndex(of: ")") else { return nil }
            let args = expression[expression.index(after: open)..<close]
                .split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard args.count == 2 else { return nil }
            let start = min(args[0], payload.count)
            let end = min(args[0] + min(args[1], size), payload.count)
            return Data(payload[start..<end]).base64EncodedString()
        })
    }
}

/// Browser watch during phase 3.
///
/// ⛔ **`InAppNotebookStage` never touched `LiveRunActivity`**, so the glow went dark for the whole
/// of P3 — the longest stretch of a run, and the one the owner most wants to watch (the notebook
/// being built, the audio being generated). Reported 2026-08-14: "P3 notebooklm must glow".
final class NotebookStageActivityTests: XCTestCase {

    /// A page that records what the activity store said WHILE the stage was running.
    private final class ObservingPage: WebPage, @unchecked Sendable {
        private(set) var platformDuringRun: String?
        var activity: LiveRunActivity?

        private func observe() {
            if platformDuringRun == nil { platformDuringRun = activity?.platform(forWorker: 2) }
        }
        func evaluateJSON(_ expression: String) async throws -> Any? { observe(); return nil }
        func querySelector(_ css: String) async throws -> Int? { observe(); return nil }
        func querySelectorAll(_ css: String) async throws -> [Int] { [] }
        func attribute(_ handle: Int, _ name: String) async throws -> String? { nil }
        func innerText(_ handle: Int) async throws -> String? { nil }
        func click(_ handle: Int) async throws {}
        func insertText(_ handle: Int, _ text: String) async throws -> String? { nil }
        func key(_ name: String) async throws {}
    }

    func testNOTEBOOKLMGlowsForTheWholeOfP3AndIsClearedWhenItEnds() async {
        let activity = LiveRunActivity()
        let page = ObservingPage()
        page.activity = activity
        let stage = InAppNotebookStage(
            pages: { _ in page }, worker: 2,
            manifest: ["notebook_new": ["#nope"]],
            audioTimeout: 0.1, activity: activity, log: { _ in }
        )
        let entry = QueueEntry(
            id: "q", action: .start, researchId: "r", uid: "u", submittedBy: "u", topic: "t"
        )

        // This page answers nothing, so the stage throws — which is the point: the glow must be
        // set while it runs and cleared however it ends.
        _ = try? await stage.run(entry: entry, consolidated: "body", lengthAtClaim: "long")

        XCTAssertEqual(
            page.platformDuringRun, "notebooklm",
            "Browser watch showed nothing at all for the whole of phase 3"
        )
        XCTAssertNil(
            activity.platform(forWorker: 2),
            "a glow that outlives P3 points the owner at a tab where nothing is happening"
        )
    }
}
