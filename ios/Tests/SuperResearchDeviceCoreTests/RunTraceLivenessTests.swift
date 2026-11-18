import XCTest
@testable import SuperResearchDeviceCore

/// The trace has to be written AS the run happens, not flushed when it ends.
///
/// ⛔ **Twice on 2026-08-14 the app died mid-run and left a four-line trace file** ending at
/// `chatgpt.start` — because every phase event was buffered in memory and written only after the
/// platform finished or threw. A log you only get when the run ends cleanly is a log for the one
/// case that needed no log, and it cost two debugging cycles guessing how far P1 had got.
final class RunTraceLivenessTests: XCTestCase {

    /// ⭐ Asserts the events arrive **while the pipeline is still running**, not that they exist
    /// afterwards — the buffered version would satisfy an after-the-fact check perfectly.
    func testPhaseEventsReachTheTraceAsTheyHAPPEN() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(
            driver: InAppPhaseDriver(
                platform: "chatgpt", manifest: InAppPipelineTests.mockManifest, page: page
            ),
            topic: "t"
        )

        // Captured with a lock: `onEvent` is called from the pipeline's own task.
        let sink = EventSink()
        pipeline.onEvent = { phase, event in sink.record(phase, event) }
        // ⛔ The MECHANISM. Nothing is asserted after the run — the check happens the first time an
        // event fires, from inside the run, so a flush-at-the-end implementation cannot pass it.
        var sawEventDuringRun = false
        page.onResponseRead = { if !sink.isEmpty { sawEventDuringRun = true } }

        _ = try await pipeline.run(responseTimeout: 1, sleep: { _ in })

        XCTAssertTrue(
            sawEventDuringRun,
            "no event had been emitted by the time the run was reading a response — the trace is "
                + "still being flushed at the end, so a crash mid-run loses everything"
        )
        XCTAssertTrue(sink.events.contains { $0.event == "phase_start" }, "\(sink.events)")
    }

    /// The buffer is still populated and still carries ONLY the phase words, while the live sink is
    /// a strict superset that also carries step detail.
    ///
    /// ⛔ **Not equality.** The first version of this asserted the two were identical, which is
    /// exactly the design mistake it should have caught: putting `composer_filled` / `sent` /
    /// the tier verdict into `events` broke the golden phase-sequence fixture that keeps the two
    /// pipeline implementations in step. The contract wants only the phases; the trace wants both.
    func testTheBufferedEventsSurviveAlongsideTheLiveSink() async throws {
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        var pipeline = InAppPipeline(
            driver: InAppPhaseDriver(
                platform: "chatgpt", manifest: InAppPipelineTests.mockManifest, page: page
            ),
            topic: "t"
        )
        let sink = EventSink()
        pipeline.onEvent = { phase, event in sink.record(phase, event) }

        _ = try await pipeline.run(responseTimeout: 1, sleep: { _ in })

        XCTAssertFalse(pipeline.events.isEmpty, "the in-memory buffer was dropped")
        // The contract: nothing but the phase vocabulary reaches the buffer.
        let phaseWords: Set<String> = [
            "phase_start", "phase_complete", "phase_skipped", "not_signed_in", "page_never_ready",
        ]
        XCTAssertTrue(
            pipeline.events.allSatisfy { phaseWords.contains($0.event) },
            "step detail leaked into the golden phase sequence: \(pipeline.events.map(\.event))"
        )
        // ...and every buffered event also reached the sink, IN ORDER, with the detail interleaved.
        let sunkPhases = sink.events.map(\.event).filter { phaseWords.contains($0) }
        XCTAssertEqual(
            sunkPhases, pipeline.events.map(\.event),
            "the live sink dropped or reordered a phase the buffer recorded"
        )
        XCTAssertGreaterThan(
            sink.events.count, pipeline.events.count,
            "the sink carried no step detail at all — it is just a second copy of the buffer"
        )
    }
}

/// Thread-safe collector — `onEvent` fires from the pipeline's task, not the test's.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(phase: Int, event: String)] = []

    func record(_ phase: Int, _ event: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append((phase, event))
    }

    var events: [(phase: Int, event: String)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.isEmpty
    }
}
