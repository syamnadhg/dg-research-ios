import XCTest
@testable import SuperResearchDeviceCore

/// Whose run is on which worker.
///
/// ⛔ **`devices/{id}.workers` was read by this device and cleared by it and NEVER written.** That
/// map carries `{uid, title, phase, totalPhases}` per worker, and it is the only thing that puts a
/// busy pill on the person who fired the run — in the phone's People popup and in the web app's
/// "Shared with" popup alike. Without it a run in flight showed as an anonymous `busyWorkerIds`
/// entry and belonged, visibly, to nobody.
final class RunAttributionTests: XCTestCase {

    func testARunningWorkerIsAttributedToTheUserWhoFiredIt() {
        let activity = LiveRunActivity()
        activity.startRun(worker: 2, uid: "owner-1", title: "batteries", researchID: "res-1")

        let facts = activity.run(forWorker: 2)
        XCTAssertEqual(facts?.uid, "owner-1")
        XCTAssertEqual(facts?.title, "batteries")
        XCTAssertEqual(facts?.phase, 0)
        XCTAssertEqual(facts?.researchID, "res-1")
    }

    func testAPhaseUpdateForAWorkerWithNoRunCreatesNothing() {
        // ⛔ A phase update must not invent a run. An entry conjured here publishes a busy pill for
        // work that is not happening — and the web app counts that entry as occupied capacity, so
        // the invented pill also stops real runs being placed.
        let activity = LiveRunActivity()
        activity.setPhase(worker: 3, phase: 2)
        XCTAssertNil(activity.run(forWorker: 3))
        XCTAssertTrue(activity.runs.isEmpty)
    }

    func testAPhaseUpdateMovesARunningWorker() {
        let activity = LiveRunActivity()
        activity.startRun(worker: 1, uid: "u", title: "t", researchID: "r")
        activity.setPhase(worker: 1, phase: 2)
        XCTAssertEqual(activity.run(forWorker: 1)?.phase, 2)
        // The other fields survive the move — a phase update is not a re-registration.
        XCTAssertEqual(activity.run(forWorker: 1)?.uid, "u")
        XCTAssertEqual(activity.run(forWorker: 1)?.researchID, "r")
    }

    func testARunThatENDEDLeavesNoPillBehind() {
        // ⛔ An entry that outlives its run leaves a busy pill on someone's tile for ever, and the
        // slot is counted as occupied — so the device silently loses a worker.
        let activity = LiveRunActivity()
        activity.startRun(worker: 1, uid: "u", title: "t", researchID: "r")
        activity.endRun(worker: 1)
        XCTAssertNil(activity.run(forWorker: 1))
        XCTAssertTrue(activity.runs.isEmpty)
    }

    func testEndingONEWorkersRunLeavesTheOthersAlone() {
        let activity = LiveRunActivity()
        activity.startRun(worker: 1, uid: "a", title: "t1", researchID: "r1")
        activity.startRun(worker: 2, uid: "b", title: "t2", researchID: "r2")
        activity.endRun(worker: 1)
        XCTAssertNil(activity.run(forWorker: 1))
        XCTAssertEqual(activity.run(forWorker: 2)?.uid, "b")
    }

    func testTheRunAndThePlatformGlowAreIndependent() {
        // ⚠ Two different questions on one object: "whose run is this" outlives the platform it is
        // currently driving, which changes three times per run. Clearing the glow between platforms
        // must not un-attribute the run.
        let activity = LiveRunActivity()
        activity.startRun(worker: 1, uid: "u", title: "t", researchID: "r")
        activity.set(worker: 1, platform: "chatgpt")
        activity.clear(worker: 1)
        XCTAssertNil(activity.platform(forWorker: 1))
        XCTAssertNotNil(activity.run(forWorker: 1), "the run outlives the platform it was driving")
    }

    func testStoppingNeedsTheResearchIDTheUIDoesNotOtherwiseHave() {
        // The UI holds a worker ordinal. Stop is keyed by research id. Without this lookup the
        // popup can see a run it cannot name, and so cannot stop it.
        let activity = LiveRunActivity()
        activity.startRun(worker: 4, uid: "u", title: "t", researchID: "res-42")
        XCTAssertEqual(activity.run(forWorker: 4)?.researchID, "res-42")
    }
}
