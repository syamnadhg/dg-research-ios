import XCTest
@testable import SuperResearchDeviceCore

/// How the owner's run-wide Settings map onto the PER-PLATFORM pipeline.
///
/// ⛔ **The two numberings collide, and mapping them by equality is a silent bug.** The product's
/// phases are run-wide — 1 brief, 2 research, 3 PODCAST, 4 video — while the per-platform pipeline's
/// are 0 login, 1 brief, 2 report, **3 the source harvest**. Passing `skipPhases` straight through
/// makes "I don't want a podcast" delete the source telemetry on all three platforms, which nothing
/// reports and nobody connects back to the toggle they pressed.
final class InAppRunPipelineSettingsTests: XCTestCase {

    private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    // MARK: - The mapping itself

    func testTurningThePodcastOffDoesNotDeleteTheSourceHarvest() {
        // Product phase 3 is the podcast; pipeline phase 3 is the source harvest. They share a
        // number and nothing else.
        let podcastOff = RunConfig(skipPhases: [3, 4])
        XCTAssertFalse(
            InAppRunPipeline.skips(phase: 3, config: podcastOff),
            "the per-platform phase 3 is the SOURCE HARVEST, not the owner's podcast setting"
        )
    }

    func testTheLoginWalkIsMappedFromVerifyLoginsRatherThanFromSkipPhases() {
        // ⚠ Two different fields in the product. Folding them together would let "skip the brief"
        // also disable login verification.
        XCTAssertTrue(InAppRunPipeline.skips(phase: 0, config: RunConfig(skipInitVerify: true)))
        XCTAssertFalse(InAppRunPipeline.skips(phase: 0, config: RunConfig(skipInitVerify: false)))
        XCTAssertFalse(
            InAppRunPipeline.skips(phase: 0, config: RunConfig(skipInitVerify: false, skipPhases: [0, 1])),
            "skipPhases must not be able to switch off login verification"
        )
    }

    func testSkippingTheBriefIsMappedStraightThrough() {
        XCTAssertTrue(InAppRunPipeline.skips(phase: 1, config: RunConfig(skipPhases: [1])))
        XCTAssertFalse(InAppRunPipeline.skips(phase: 1, config: RunConfig(skipPhases: [3])))
    }

    func testTheReportPhaseIsNeverSkippedHere() {
        // An agent the owner switched off is not driven at all — the executor decides that before
        // this type is reached. A platform that IS being driven must produce its report.
        XCTAssertFalse(InAppRunPipeline.skips(phase: 2, config: RunConfig(skipPhases: [2])))
    }

    // MARK: - What the pipeline actually does with it

    func testAPodcastLessRunSTILLHarvestsSourcesFromThePlatform() async throws {
        // The mapping asserted through the thing it controls, not just as a function: with the
        // podcast switched off, the per-platform run must still reach its harvest.
        let page = FakePage()
        page.sourceTexts = ["https://example.com/a", "https://example.com/b"]
        let driver = InAppPhaseDriver(
            platform: "chatgpt",
            manifest: [
                "logged_in_marker": ["#signed-in-marker"],
                "composer": ["#composer"],
                "send": ["#send-button"],
                "response_container": ["#response-container"],
                "sources": ["#source-link"],
            ],
            page: page
        )
        var pipeline = InAppPipeline(driver: driver, topic: "t", providedBrief: "a supplied brief")

        let podcastOff = RunConfig(skipPhases: [3, 4])
        let outcome = try await pipeline.run(
            shouldSkip: { InAppRunPipeline.skips(phase: $0, config: podcastOff) },
            responseTimeout: 0.1, extractionTimeout: .milliseconds(1),
            pageReadyTimeout: 1, sleep: noSleep
        )

        XCTAssertEqual(
            outcome.sources.count, 2,
            "switching off the PODCAST must not switch off the per-platform source harvest"
        )
        XCTAssertFalse(
            pipeline.events.contains { $0.phase == 3 && $0.event == "phase_skipped" },
            "the harvest phase was skipped by a setting that has nothing to do with it"
        )
    }
}
