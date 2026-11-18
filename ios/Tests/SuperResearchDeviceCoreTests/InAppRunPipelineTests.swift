import XCTest

@testable import SuperResearchDeviceCore

/// The join between the executor's order and the driver's steps.
///
/// ⚠ Until this existed the executor talked to a protocol nothing implemented — every test passed
/// against a stub while a claimed run reached no platform at all.
final class InAppRunPipelineTests: XCTestCase {

    private let manifest: [String: [String: [String]]] = [
        "chatgpt": [
            "logged_in_marker": ["#signed-in-marker"],
            "composer": ["#composer"],
            "send": ["#send-button"],
            "deep_research_toggle": ["#deep-research-toggle"],
            "sources": [".source"],
            "response_container": ["#response-container"],
        ],
    ]

    private func entry(topic: String = "solid-state batteries") -> QueueEntry {
        QueueEntry(id: "q1", action: .start, researchId: "res-1", uid: "u", submittedBy: "u",
                   topic: topic)
    }

    private func page() -> FakePage {
        let p = FakePage()
        p.attributes["toggle"] = ["aria-pressed": "false"]
        p.sourceTexts = ["a"]
        return p
    }

    func testTheRUNREACHESTheRealDriverAndProducesABriefAndAReport() async throws {
        let p = page()
        let pipeline = InAppRunPipeline(
            pages: { _, _ in p }, worker: 1, manifest: manifest,
            responseTimeout: 1, extractionTimeout: .seconds(1)
        )

        let out = try await pipeline.runPhases(entry: entry(), platform: "chatgpt", brief: "")

        XCTAssertFalse(out.brief.isEmpty)
        XCTAssertNotNil(out.report)
        // The mechanism: the WRAPPER prompt reached the composer, not the bare topic.
        XCTAssertTrue(p.inserted.first?.hasPrefix("Please create a detailed research report brief")
                      ?? false)
    }

    func testASUPPLIEDBriefIsUsedAndP1IsNotReRun() async throws {
        // The executor derives the brief once and passes it to every platform after the first.
        let p = page()
        let pipeline = InAppRunPipeline(
            pages: { _, _ in p }, worker: 1, manifest: manifest,
            responseTimeout: 1, extractionTimeout: .seconds(1)
        )
        let supplied = String(repeating: "An existing brief. ", count: 30)

        let out = try await pipeline.runPhases(
            entry: entry(), platform: "chatgpt", brief: supplied
        )

        XCTAssertEqual(out.brief, supplied)
        // P1 still runs its own phase, but P2's fill must be the SUPPLIED brief.
        XCTAssertTrue(p.inserted.contains(supplied), "P2 did not send the supplied brief")
    }

    func testAnEMPTYReportComesBackAsNILRatherThanAnEmptyString() async throws {
        // The executor distinguishes "this platform produced nothing" from "it produced an empty
        // string", and only the first is a fact it can act on.
        let p = page()
        p.reportText = ""
        let pipeline = InAppRunPipeline(
            pages: { _, _ in p }, worker: 1, manifest: manifest,
            responseTimeout: 1, extractionTimeout: .seconds(1)
        )

        let out = try await pipeline.runPhases(entry: entry(), platform: "chatgpt", brief: "")

        XCTAssertNil(out.report)
    }

    func testTheWORKERSOwnPageIsTheOneDriven() async throws {
        // Each worker has its own cookie jar and its own long-lived view; driving another worker's
        // page would mean two runs sharing one session.
        let mine = page()
        let theirs = page()
        let pipeline = InAppRunPipeline(
            pages: { _, worker in worker == 2 ? mine : theirs }, worker: 2, manifest: manifest,
            responseTimeout: 1, extractionTimeout: .seconds(1)
        )

        _ = try await pipeline.runPhases(entry: entry(), platform: "chatgpt", brief: "")

        XCTAssertFalse(mine.inserted.isEmpty, "worker 2's own page was never driven")
        XCTAssertTrue(theirs.inserted.isEmpty, "another worker's page was driven")
    }

    func testAPlatformWithNOManifestEntryFailsLOUDLY() async {
        // A missing manifest must not silently produce an empty run — the selector values are the
        // one thing that arrives late, and a skip here would report success on a platform nothing
        // touched.
        let pipeline = InAppRunPipeline(
            pages: { _, _ in self.page() }, worker: 1, manifest: [:],
            responseTimeout: 1, extractionTimeout: .seconds(1)
        )

        do {
            _ = try await pipeline.runPhases(entry: entry(), platform: "gemini", brief: "")
            XCTFail("a platform with no selectors must fail rather than run empty")
        } catch {
            // Any error is acceptable; silence is not.
        }
    }
}
