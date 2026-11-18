import XCTest
@testable import SuperResearchDeviceCore

/// What the device says it is running, and when it may say "nothing".
///
/// ⛔ **Two failures meet here, in opposite directions.**
///
/// 1. `markBusy` published `busyWorkerIds` when a run was claimed and cleared it when the run
///    ended, and NOTHING cleared it at boot. A process that died in between — a crash, a
///    force-quit, iOS reclaiming a backgrounded app — left the field saying "worker 1 is busy" for
///    ever. `workerState` unions that into the live set, so no worker was ever free again and every
///    later claim was declined *silently*, because declining is also what a busy device does.
///
/// 2. The obvious fix — publish an empty set at start-up — is wrong on the OTHER path.
///    `reconcileBusyWorkers` runs from `startHeartbeat()`, and `bounceForReset` (the web app's
///    "tap Online to reset backend") calls that after its pause, potentially while a run is still
///    in flight. Publishing empty there hands a second run to the worker already driving one.
///
/// The correct answer is neither "empty" nor "leave it": publish what this process is ACTUALLY
/// running, which at boot is nothing and mid-bounce is the live run.
final class BusyReconciliationTests: XCTestCase {

    // MARK: - The placement rule these feed

    func testAStaleBusySetLeavesNOWorkerFreeAndSoDeclinesEveryClaim() {
        // The bricked state, stated as the placement decision it produced. One worker, and the
        // document says it is busy because a previous process died mid-run.
        XCTAssertNil(
            RunQueuePolicy.freeWorker(count: 1, busy: [1], resting: []),
            "a stale busy set is indistinguishable from a real one — this is why the device wedged"
        )
    }

    func testClearingTheStaleSetMakesTheWorkerClaimableAgain() {
        XCTAssertEqual(RunQueuePolicy.freeWorker(count: 1, busy: [], resting: []), 1)
    }

    func testAWorkerRUNNINGSomethingIsNeverHandedASecondRun() {
        // ⛔ The hazard on the reset path: if reconciliation published an empty set while worker 1
        // was still driving a run, this is the question that would be asked next — and it would
        // answer "worker 1 is free".
        XCTAssertNil(
            RunQueuePolicy.freeWorker(count: 1, busy: [1], resting: []),
            "a worker with a live run must not be offered again"
        )
        // With two workers the second is free, and that is correct — the rule is per worker, not
        // per device.
        XCTAssertEqual(RunQueuePolicy.freeWorker(count: 2, busy: [1], resting: []), 2)
    }

    func testRestingIsHonouredAlongsideBusy() {
        // Resting is the owner's explicit "not now"; handing it work would silently override them.
        XCTAssertNil(RunQueuePolicy.freeWorker(count: 2, busy: [1], resting: [2]))
    }
}

/// What the device publishes as its busy set.
///
/// ⛔ Two opposite failures meet in this one expression. Publishing too MUCH wedges the device for
/// ever (a killed run's worker never becomes claimable). Publishing too LITTLE hands a second run
/// to a worker already driving one — because `reconcileBusyWorkers` also runs on the reset path,
/// after `bounceForReset`'s pause, while a run may still be in flight.
final class RunPlacementTests: XCTestCase {

    private func ints(_ values: [FirestoreValue]) -> [Int] {
        values.compactMap { if case .integer(let n) = $0 { return Int(n) } else { return nil } }
    }

    func testAnIdleDevicePublishesNothing() {
        // The unwedge: at boot this process is running nothing, so it says nothing — and a worker
        // left busy by a killed process becomes claimable again.
        XCTAssertTrue(DeviceBackend.busyIDsToPublish(locallyBusy: []).isEmpty)
    }

    func testAWorkerRunningSomethingIsStillPublishedAsBusy() {
        // ⛔ The reset-path hazard. If this published empty while worker 1 was mid-run, the very
        // next placement decision would offer worker 1 out again: two runs, one set of web views.
        XCTAssertEqual(ints(DeviceBackend.busyIDsToPublish(locallyBusy: [1])), [1])
        // And the placement rule that consumes it agrees.
        XCTAssertNil(RunQueuePolicy.freeWorker(count: 1, busy: [1], resting: []))
    }

    func testTheSetIsSortedSoTheWireFormIsStable() {
        // An unsorted set would make an unchanged reconciliation look like a change to anything
        // diffing the device document.
        XCTAssertEqual(ints(DeviceBackend.busyIDsToPublish(locallyBusy: [3, 1, 2])), [1, 2, 3])
    }

    func testTheIDsAreINTEGERSOnTheWire() {
        // ⚠ The same trap `restingWorkerIds` already hit: the web app types these `number[]` and
        // filters reads on `typeof n === "number"`, so digit-strings park a worker for real while
        // the web app shows full capacity.
        guard case .integer = DeviceBackend.busyIDsToPublish(locallyBusy: [1]).first else {
            return XCTFail("busyWorkerIds must be integers on the wire, not strings")
        }
    }
}
