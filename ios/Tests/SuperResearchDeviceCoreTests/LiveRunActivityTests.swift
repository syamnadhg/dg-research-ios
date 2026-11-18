import XCTest

@testable import SuperResearchDeviceCore

/// Which platform each worker is driving, right now — what Browser watch glows.
final class LiveRunActivityTests: XCTestCase {

    func testAWorkerReportsThePlatformItIsDriving() {
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        XCTAssertEqual(activity.platform(forWorker: 1), "chatgpt")
    }

    func testMovingToTheNextPlatformREPLACESThePreviousOne() {
        // ⛔ A run drives the three platforms in SEQUENCE. Two glowing at once would mean the first
        // was never cleared — and a stale glow points the owner at a tab where nothing is
        // happening, which is worse than no glow at all.
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        activity.set(worker: 1, platform: "gemini")
        XCTAssertEqual(activity.platform(forWorker: 1), "gemini")
        XCTAssertEqual(activity.busyWorkers, [1])
    }

    func testCLEARINGLeavesNothingGlowing() {
        // The run ended, however it ended. A glow that outlives its run never changes again, and
        // "never changes" is indistinguishable from "still working" on a 90-minute run.
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        activity.clear(worker: 1)
        XCTAssertNil(activity.platform(forWorker: 1))
        XCTAssertTrue(activity.busyWorkers.isEmpty)
    }

    func testAnEMPTYPlatformIsTreatedAsCleared() {
        // "" arrives from a caller that meant "none"; storing it would glow a tile whose id is the
        // empty string — which is no tile, so nothing glows and nothing says why.
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        activity.set(worker: 1, platform: "")
        XCTAssertNil(activity.platform(forWorker: 1))
    }

    func testWORKERSAreTrackedINDEPENDENTLY() {
        // Two workers, two runs, two different platforms. Keying by anything less would make the
        // card glow the other worker's tab.
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        activity.set(worker: 2, platform: "claude")
        XCTAssertEqual(activity.platform(forWorker: 1), "chatgpt")
        XCTAssertEqual(activity.platform(forWorker: 2), "claude")
        activity.clear(worker: 1)
        XCTAssertEqual(activity.platform(forWorker: 2), "claude", "clearing one cleared the other")
    }

    func testEVERYChangeNotifiesTheUI() {
        // ⚠ Without the callback the glow renders once and freezes: the core has no Combine, so
        // nothing else would tell SwiftUI the run had moved on.
        let activity = LiveRunActivity()
        let counter = Counter()
        activity.onChange = { counter.bump() }
        activity.set(worker: 1, platform: "chatgpt")
        activity.set(worker: 1, platform: "gemini")
        activity.clear(worker: 1)
        XCTAssertEqual(counter.value, 3)
    }
}

/// A thread-safe tally, because `onChange` is `@Sendable`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// The pipeline's own reporting — set on entry, cleared on EVERY exit.
///
/// ⚠ These drive `InAppRunPipeline`, not the store. A mutation deleting the pipeline's `defer` was
/// MISSED by the store's own tests, which is the obvious-in-hindsight point: a guard on the thing
/// being reported to says nothing about whether anyone reports.
final class PipelineActivityReportingTests: XCTestCase {

    /// A page that answers nothing, so P0's logged-in check fails and the run throws.
    private final class DeadPage: WebPage, @unchecked Sendable {
        /// What the activity store said while the pipeline was inside the run.
        private(set) var platformDuringRun: String?
        var activity: LiveRunActivity?

        /// ⚠ Recorded at BOTH entry points, because the first thing the run touches is no longer a
        /// selector. The readiness gate asks `document.readyState` before any phase resolves
        /// anything — so a probe that only watched `querySelector` observed nothing at all and
        /// reported "the glow was never set" about a glow that was set correctly.
        private func observe() {
            if platformDuringRun == nil { platformDuringRun = activity?.platform(forWorker: 3) }
        }

        func evaluateJSON(_ expression: String) async throws -> Any? {
            observe()
            return nil
        }
        func querySelector(_ css: String) async throws -> Int? {
            observe()
            return nil
        }
        func querySelectorAll(_ css: String) async throws -> [Int] { [] }
        func attribute(_ handle: Int, _ name: String) async throws -> String? { nil }
        func innerText(_ handle: Int) async throws -> String? { nil }
        func click(_ handle: Int) async throws {}
        func insertText(_ handle: Int, _ text: String) async throws -> String? { nil }
        func key(_ name: String) async throws {}
    }

    private func entry() -> QueueEntry {
        QueueEntry(id: "q1", action: .start, researchId: "r", uid: "u", submittedBy: "u", topic: "t")
    }

    func testTheGlowIsSETWhileTheRunIsOnAPlatformAndCLEAREDAfterItThrows() async {
        // ⛔ Cleared on the FAILURE path too. A glow that outlives its run points the owner at a tab
        // where nothing is happening — and on a 90-minute run, "never changes" is indistinguishable
        // from "still working".
        let activity = LiveRunActivity()
        let page = DeadPage()
        page.activity = activity
        let pipeline = InAppRunPipeline(
            pages: { _, _ in page }, worker: 3,
            manifest: ["chatgpt": ["logged_in_marker": ["#nope"]]],
            responseTimeout: 0.1, extractionTimeout: .milliseconds(1),
            // This page answers nothing, so the readiness gate is what rejects it. At the
            // production timeout that assertion costs ninety seconds of real clock.
            pageReadyTimeout: 0.2,
            activity: activity,
            sleep: { _ in }
        )

        do {
            _ = try await pipeline.runPhases(entry: entry(), platform: "chatgpt", brief: "b")
            XCTFail("a page that answers nothing must not produce a run")
        } catch { /* expected */ }

        XCTAssertEqual(page.platformDuringRun, "chatgpt", "the glow was never set")
        XCTAssertNil(activity.platform(forWorker: 3), "the glow outlived the run")
    }

    /// ⛔⛔ **The forwarding, exercised through the real pipeline.** Browser watch read
    /// "P1 · Research brief" for the whole of ChatGPT's deep research, because the only writer of
    /// the phase was the executor's counter — which cannot advance while a platform is inside its
    /// own P1→P2→P3. Asserting on a hand-built snapshot passes whether or not anything forwards the
    /// platform's phase; mutation proved exactly that, so this drives `runPhases` instead.
    func testThePLATFORMSOwnPhaseReachesTheWorkerFactWhileItIsRunning() async {
        let activity = LiveRunActivity()
        // ⚠ A page that actually REACHES the phases. The first version used the dead page, which
        // fails at the readiness gate before a single `phase_start` — so `platformPhase` stayed at
        // its default and the assertion passed whether or not anything forwarded it. A test that
        // cannot observe the number moving cannot guard the number moving.
        let page = FakePage()
        page.attributes["toggle"] = ["aria-pressed": "false"]
        page.sourceTexts = ["a"]
        activity.startRun(worker: 3, uid: "u", title: "t", researchID: "r")
        let pipeline = InAppRunPipeline(
            pages: { _, _ in page }, worker: 3,
            manifest: ["chatgpt": InAppPipelineTests.mockManifest],
            responseTimeout: 1, extractionTimeout: .milliseconds(50),
            pageReadyTimeout: 1, activity: activity, sleep: { _ in }
        )

        _ = try? await pipeline.runPhases(entry: entry(), platform: "chatgpt", brief: "")

        XCTAssertNotNil(activity.runs[3], "the run fact vanished, so nothing could carry a phase")
        XCTAssertGreaterThanOrEqual(
            activity.runs[3]?.platformPhase ?? -1, 1,
            "the platform's own phase never reached the fact the screen renders from — which is why "
                + "Browser watch read 'Research brief' through the whole of deep research"
        )
    }
}
