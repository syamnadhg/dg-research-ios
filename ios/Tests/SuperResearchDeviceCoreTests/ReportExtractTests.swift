import XCTest

@testable import SuperResearchDeviceCore

/// A page that answers the extractor's evaluates from a script, recording what it was asked.
final class ScriptedPage: WebPage, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var evaluated: [String] = []
    /// Poll answers, consumed in order; the last one repeats.
    var pollAnswers: [[String: Any]] = []
    var reportText: String = ""
    /// When set, the Nth slice call returns this instead — for the truncation case.
    var truncateSliceAt: Int?
    private var pollIndex = 0
    private var sliceCalls = 0

    func evaluateJSON(_ expression: String) async throws -> Any? {
        lock.lock(); defer { lock.unlock() }
        evaluated.append(expression)
        if expression.contains("window.__srReport = { state: 'pending' }")
            || expression.hasPrefix("\n(function () {") {
            return "started"
        }
        if expression.contains("r.state") {
            let answer = pollAnswers.isEmpty
                ? ["state": "missing"]
                : pollAnswers[min(pollIndex, pollAnswers.count - 1)]
            pollIndex += 1
            return answer
        }
        if expression.contains(".slice(") {
            sliceCalls += 1
            if let cut = truncateSliceAt, sliceCalls >= cut { return "" }
            // Parse the offsets out of the generated expression so the test exercises the real one.
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
        return nil
    }

    func querySelector(_ css: String) async throws -> Int? { nil }
    func querySelectorAll(_ css: String) async throws -> [Int] { [] }
    func attribute(_ handle: Int, _ name: String) async throws -> String? { nil }
    func innerText(_ handle: Int) async throws -> String? { nil }
    func click(_ handle: Int) async throws {}
    func insertText(_ handle: Int, _ text: String) async throws -> String? { nil }
    func key(_ name: String) async throws { keys.append(name) }
    private(set) var keys: [String] = []

    var sliceExpressions: [String] { evaluated.filter { $0.contains(".slice(") } }
}

/// P2's product, extracted in-app.
final class ReportExtractTests: XCTestCase {

    private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    func testAFinishedExtractionIsPulledAcrossInFullAndInChunks() async throws {
        let page = ScriptedPage()
        page.reportText = String(repeating: "x", count: 95_000)
        page.pollAnswers = [["state": "pending"],
                            ["state": "ok", "chars": 95_000, "status": "completed"]]

        let text = try await ReportExtract.extract(from: page, sleep: noSleep)

        XCTAssertEqual(text.count, 95_000)
        XCTAssertEqual(text, page.reportText)
        // The mechanism: it chunked rather than asking for it all at once. One evaluate carrying
        // half a megabyte works on a short report and fails on the one that matters.
        XCTAssertEqual(page.sliceExpressions.count, 3)
        XCTAssertTrue(page.sliceExpressions[0].contains("slice(0, 40000)"))
        XCTAssertTrue(page.sliceExpressions[1].contains("slice(40000, 80000)"))
    }

    func testATRUNCATEDReadIsAnErrorAndNotAShortReport() async {
        // ⚠ The worst possible outcome: a truncated report is still markdown, still clears the
        // floor, and ships as research with its conclusions missing.
        let page = ScriptedPage()
        page.reportText = String(repeating: "y", count: 95_000)
        page.pollAnswers = [["state": "ok", "chars": 95_000, "status": "completed"]]
        page.truncateSliceAt = 2

        do {
            _ = try await ReportExtract.extract(from: page, sleep: noSleep)
            XCTFail("a short read must not be returned as the report")
        } catch ReportExtract.ExtractError.shortRead(let expected, let got) {
            XCTAssertEqual(expected, 95_000)
            XCTAssertEqual(got, 40_000)
        } catch {
            XCTFail("expected .shortRead, got \(error)")
        }
    }

    func testAPageReportedErrorSurfacesRatherThanTimingOut() async {
        let page = ScriptedPage()
        page.pollAnswers = [["state": "error", "error": "session HTTP 401"]]

        do {
            _ = try await ReportExtract.extract(from: page, sleep: noSleep)
            XCTFail("must throw")
        } catch ReportExtract.ExtractError.pageReportedError(let message) {
            XCTAssertEqual(message, "session HTTP 401")
        } catch {
            XCTFail("expected .pageReportedError, got \(error)")
        }
    }

    func testAConversationWithNoReportIsDistinctFromAFailure() async {
        // "There is no report here" and "the fetch failed" need different responses: one is a
        // retry, the other is not.
        let page = ScriptedPage()
        page.pollAnswers = [["state": "absent", "reason": "no widget_state"]]

        do {
            _ = try await ReportExtract.extract(from: page, sleep: noSleep)
            XCTFail("must throw")
        } catch ReportExtract.ExtractError.noReport {
            // right
        } catch {
            XCTFail("expected .noReport, got \(error)")
        }
    }

    func testAPollThatNeverSettlesTimesOutRatherThanLoopingForever() async {
        let page = ScriptedPage()
        page.pollAnswers = [["state": "pending"]]

        do {
            _ = try await ReportExtract.extract(
                from: page, pollInterval: .seconds(1), timeout: .seconds(5), sleep: noSleep
            )
            XCTFail("must throw")
        } catch ReportExtract.ExtractError.timedOut(let last) {
            XCTAssertEqual(last, "pending")
        } catch {
            XCTFail("expected .timedOut, got \(error)")
        }
    }

    func testTheExtractionIsSTARTEDEXACTLYONCE() async throws {
        // ⚠ The load-bearing count. The start script performs a real request to ChatGPT; a caller
        // that re-started it per poll would turn one request into dozens against a platform that
        // this repo deliberately paces.
        let page = ScriptedPage()
        page.reportText = "z"
        page.pollAnswers = [["state": "pending"], ["state": "pending"],
                            ["state": "ok", "chars": 1, "status": "completed"]]

        _ = try await ReportExtract.extract(from: page, sleep: noSleep)

        let starts = page.evaluated.filter { $0.contains("/api/auth/session") }
        XCTAssertEqual(starts.count, 1, "the extraction was restarted mid-poll")
    }

    func testAnUnreadablePollIsNotTreatedAsCompletion() {
        // A poller that reads an unparseable answer as terminal stops waiting on a live run.
        XCTAssertEqual(ReportExtract.Progress.decode(nil).state, "missing")
        XCTAssertEqual(ReportExtract.Progress.decode("nonsense").state, "missing")
        XCTAssertEqual(ReportExtract.Progress.decode(["chars": 10]).state, "missing")
        XCTAssertFalse(ReportExtract.Progress.decode(nil).isTerminal)
    }

    func testCharsSurvivesArrivingAsADouble() {
        // JSON numbers cross this bridge as Double often enough that an Int-only read silently
        // yields 0 — which reads as "the report is empty" rather than as a decode problem.
        XCTAssertEqual(ReportExtract.Progress.decode(
            ["state": "ok", "chars": 65_690.0]).chars, 65_690)
        XCTAssertEqual(ReportExtract.Progress.decode(
            ["state": "ok", "chars": 65_690]).chars, 65_690)
    }
}

/// The two halves of the extractor must not drift.
final class ReportExtractParityTests: XCTestCase {

    func testTheGeneratedScriptIsCurrentWithThePythonSource() throws {
        // ⚠ Regenerating rather than comparing prose: the Swift copy is GENERATED from the Python
        // module by `bin/gen_report_js.py`, and this asserts it is not stale. Two hand-maintained
        // copies of a walk over an undocumented shape diverge, and the divergence presents as
        // "extraction works on one surface and returns nothing on the other".
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let python = repo.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.fileExists(atPath: python.path) else {
            return XCTFail("the venv is missing — this check cannot run, so it must not pass")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = [repo.appendingPathComponent("bin/gen_report_js.py").path, "--check"]
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    func testTheGeneratedScriptCarriesTheWalkAndNotJustTheFetch() throws {
        // A generated file that lost its payload would still compile and still be "current".
        XCTAssertTrue(ReportExtract.startJS.contains("widget_state"))
        XCTAssertTrue(ReportExtract.startJS.contains("report_message"))
        XCTAssertTrue(ReportExtract.startJS.contains("/backend-api/conversation/"))
        XCTAssertTrue(ReportExtract.pollJS.contains("state"))
    }
}
