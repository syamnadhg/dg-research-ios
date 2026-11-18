import XCTest
@testable import SuperResearchDeviceCore

/// What Browser watch says while a platform is working.
///
/// ⛔ **Measured live 2026-08-17.** The strip read "P1 · Research brief" for the entire time ChatGPT
/// was doing its deep-research report, and no platform tile was highlighted at all. Both come from
/// the same structural fact: P1 and P2 happen inside ONE `runPhases` call per platform, while the
/// executor's phase counter only advances BETWEEN those calls.
final class BrowserWatchPhaseTests: XCTestCase {

    private func snapshot(_ worker: WorkerState) -> DeviceSnapshot {
        var s = DeviceSnapshot()
        s.workerCount = 1
        s.workers = [worker]
        return s
    }

    /// ⛔ The headline: the strip must name the phase the PLATFORM is in.
    func testTheStripNamesTheP2ReportWhileThePlatformIsWritingIt() {
        let run = snapshot(WorkerState(id: "1", uid: "owner", title: "t",
                                       phase: 1, totalPhases: 6, platformPhase: 2))
            .run(forWorker: 1)

        XCTAssertEqual(run?.phase, 2)
        XCTAssertEqual(run?.phaseName, "Deep research",
                       "the strip read the run-wide counter, which cannot move during a platform's "
                        + "own phases — so it says 'Research brief' for forty minutes of P2")
    }

    /// ⚠ And falls back to the run-wide phase for a document written before the field existed,
    /// rather than rendering "Init" at every device that has not been updated.
    func testAnOLDERDocumentWithNoPlatformPhaseStillNamesSomething() {
        let run = snapshot(WorkerState(id: "1", uid: "owner", title: "t", phase: 3, totalPhases: 6))
            .run(forWorker: 1)

        XCTAssertEqual(run?.phase, 3)
        XCTAssertEqual(run?.phaseName, "NotebookLM + audio")
    }
}

/// The glow, once more than one platform can run at once.
final class LiveRunActivityConcurrencyTests: XCTestCase {

    /// ⛔ **The old model could not express this.** `byWorker` held ONE platform per worker, so a
    /// second platform starting replaced the first — and when P2 drives three agents at once, two
    /// of them would render as idle while they researched.
    func testEveryRunningPlatformIsReportedNotJustTheLatest() {
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        activity.set(worker: 1, platform: "gemini")

        XCTAssertEqual(activity.platforms(forWorker: 1), ["chatgpt", "gemini"],
                       "in START order, so the handover after a finish has a reason")
    }

    /// ...and exactly ONE of them is in front, because only one page can be on screen and only one
    /// may take the owner's input.
    func testTheMOSTRECENTLYStartedPlatformIsTheForegroundOne() {
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        activity.set(worker: 1, platform: "claude")

        XCTAssertEqual(activity.platform(forWorker: 1), "claude")
    }

    /// ⛔ **One agent finishing must not darken the others.** The run pipeline's `defer` used to
    /// call `clear(worker:)`, which removes the worker outright — correct when the RUN ends, and
    /// with three concurrent agents it meant the first to finish switched the other two off.
    func testONEPlatformFinishingLeavesTheOthersGlowing() {
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")
        activity.set(worker: 1, platform: "gemini")

        activity.finished(worker: 1, platform: "gemini")

        XCTAssertEqual(activity.platforms(forWorker: 1), ["chatgpt"])
        XCTAssertEqual(activity.platform(forWorker: 1), "chatgpt",
                       "the front was left pointing at a platform that had finished")
    }

    /// The last one finishing clears the worker, so a finished run leaves no glow behind — the
    /// stale-glow failure the original single-string model was built to avoid.
    func testTheLASTPlatformFinishingLeavesNothingGlowing() {
        let activity = LiveRunActivity()
        activity.set(worker: 1, platform: "chatgpt")

        activity.finished(worker: 1, platform: "chatgpt")

        XCTAssertTrue(activity.platforms(forWorker: 1).isEmpty)
        XCTAssertNil(activity.platform(forWorker: 1))
    }

    /// ⚠ The handover goes to the platform running LONGEST — deterministic by construction, and a
    /// reason rather than a tiebreak. This was a Set with an alphabetical pick, which is arbitrary
    /// AND untestable: a Set has no defined order, so no assertion could tell a deliberate rule
    /// from a lucky hash seed. Mutation proved it — `sorted().first` and `first` both passed.
    func testTheFrontHandsOverToTheLONGESTRunningPlatform() {
        let activity = LiveRunActivity()
        for platform in ["gemini", "claude", "chatgpt"] {
            activity.set(worker: 1, platform: platform)
        }

        activity.finished(worker: 1, platform: "chatgpt")

        XCTAssertEqual(activity.platform(forWorker: 1), "gemini",
                       "the front went somewhere other than the platform that started first")
    }
}

/// The run state the card renders, taken from the process that owns it.
final class LiveRunStateTests: XCTestCase {

    /// ⛔ **"No runs live" while ChatGPT was visibly researching.** The card read
    /// `DeviceSnapshot.run(forWorker:)`, fed only by the device document's `workers` map — which is
    /// republished once per 20-second beat. So the strip lags the START of a run by up to a beat,
    /// and for the whole window between a run ending and the next publish it reports nothing at
    /// all, however busy the page is.
    func testTheRUNNINGProcessCanAnswerWithoutADocumentRoundTrip() {
        let activity = LiveRunActivity()
        activity.startRun(worker: 2, uid: "u", title: "solid-state batteries", researchID: "r",
                          now: { Date(timeIntervalSince1970: 1_000_000) })
        activity.setPlatformPhase(worker: 2, phase: 2)

        let state = activity.runState(forWorker: 2, now: Date(timeIntervalSince1970: 1_000_090))

        XCTAssertEqual(state?.title, "solid-state batteries")
        XCTAssertEqual(state?.phase, 2, "the card would still say Research brief")
        XCTAssertEqual(state?.elapsedSeconds, 90)
    }

    /// ...and an idle worker answers nil, so an idle device still reads as idle rather than as a
    /// card that failed to load.
    func testAnIDLEWorkerHasNoLiveRun() {
        XCTAssertNil(LiveRunActivity().runState(forWorker: 1))
    }
}
