import XCTest

@testable import SuperResearchDeviceCore

/// Records the handoff's calls **in order**, because the order is the correctness.
final class SpyHandoff: HandoffTransport, @unchecked Sendable {
    enum Call: Equatable {
        case patch([String: FirestoreValue])
        case post(researchId: String, ownerUid: String)
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    private(set) var patchedPaths: [(uid: String, researchId: String)] = []
    /// Which patch attempts throw, by index, so a partial failure is exercisable.
    var failingPatchIndices: Set<Int> = []
    private var patchCount = 0

    func patchResearch(
        uid: String, researchId: String, set: [String: FirestoreValue]
    ) async throws {
        lock.lock()
        let index = patchCount
        patchCount += 1
        let shouldFail = failingPatchIndices.contains(index)
        if !shouldFail {
            calls.append(.patch(set))
            patchedPaths.append((uid, researchId))
        }
        lock.unlock()
        if shouldFail { throw HandoffBoom() }
    }

    func postUploadYouTube(researchId: String, ownerUid: String) async {
        lock.lock(); defer { lock.unlock() }
        calls.append(.post(researchId: researchId, ownerUid: ownerUid))
    }

    /// Every field this handoff ever wrote, flattened.
    var allWrittenFields: [String: FirestoreValue] {
        calls.reduce(into: [:]) { acc, call in
            if case .patch(let set) = call { acc.merge(set) { _, new in new } }
        }
    }
}

private struct HandoffBoom: Error {}

/// The run's far end: P3 is done here, P4 and P5 belong to the cloud.
final class RunHandoffTests: XCTestCase {

    private let now: Int64 = 1_754_600_000_000

    func testAllThreeStepsHappenInTheDesktopsOrder() async {
        let spy = SpyHandoff()

        await RunHandoff.handOff(uid: "owner-1", researchId: "res-1", now: now, transport: spy)

        XCTAssertEqual(spy.calls.count, 3)
        // 1. beDone — the field the NEXT run's queue gate waits on.
        guard case .patch(let first) = spy.calls[0] else { return XCTFail("first call was not a patch") }
        XCTAssertEqual(first["beDone"], .boolean(true))
        XCTAssertEqual(first["beDoneAt"], .integer(now))
        // 2. the frontend catch-up marker.
        guard case .patch(let second) = spy.calls[1] else { return XCTFail("second call was not a patch") }
        XCTAssertEqual(second["needsFeTrigger"], .boolean(true))
        XCTAssertEqual(second["needsFeTriggerAt"], .integer(now))
        // 3. and only then the cloud trigger.
        XCTAssertEqual(spy.calls[2], .post(researchId: "res-1", ownerUid: "owner-1"))
    }

    func testTheMarkerIsWrittenBEFORETheTriggerFires() async {
        // ⚠ The single most important ordering here. Reversed, a failed POST leaves no backstop and
        // the run dies silently with the audio already paid for.
        let spy = SpyHandoff()

        await RunHandoff.handOff(uid: "owner-1", researchId: "res-1", now: now, transport: spy)

        let markerIndex = spy.calls.firstIndex {
            if case .patch(let set) = $0 { return set["needsFeTrigger"] != nil }
            return false
        }
        let postIndex = spy.calls.firstIndex {
            if case .post = $0 { return true }
            return false
        }
        XCTAssertNotNil(markerIndex)
        XCTAssertNotNil(postIndex)
        XCTAssertLessThan(markerIndex!, postIndex!, "the POST fired before its own backstop")
    }

    func testStatusIsNEVERWrittenAsCompleted() async {
        // The cloud P5 chain owns `status`. A phone that writes `completed` reports a run finished
        // that has no video and no email.
        let spy = SpyHandoff()

        await RunHandoff.handOff(uid: "owner-1", researchId: "res-1", now: now, transport: spy)

        XCTAssertNil(spy.allWrittenFields["status"],
                     "the handoff wrote `status`, which belongs to the cloud chain")
    }

    func testAFailedBeDoneStillWritesTheMarkerAndFiresTheTrigger() async {
        // Three independent recoveries, not a transaction. Aborting after the first failure turns
        // one degraded run into a dead one.
        let spy = SpyHandoff()
        spy.failingPatchIndices = [0]

        let outcome = await RunHandoff.handOff(
            uid: "owner-1", researchId: "res-1", now: now, transport: spy
        )

        XCTAssertFalse(outcome.beDoneWritten)
        XCTAssertTrue(outcome.markerWritten)
        XCTAssertTrue(spy.calls.contains(.post(researchId: "res-1", ownerUid: "owner-1")))
    }

    func testAFailedMarkerStillFiresTheTrigger() async {
        // With the backstop gone the POST is the only route left, so it must still be taken.
        let spy = SpyHandoff()
        spy.failingPatchIndices = [1]

        let outcome = await RunHandoff.handOff(
            uid: "owner-1", researchId: "res-1", now: now, transport: spy
        )

        XCTAssertTrue(outcome.beDoneWritten)
        XCTAssertFalse(outcome.markerWritten)
        XCTAssertTrue(spy.calls.contains(.post(researchId: "res-1", ownerUid: "owner-1")))
    }

    func testTheResearchIsAddressedByTheOWNERSUidNotTheSubmitters() async {
        // A sharer's run lives under the sharer's uid. Addressing it by the submitting user writes
        // into the wrong tree — and the rules permit that, because they constrain `submittedBy`.
        let spy = SpyHandoff()

        await RunHandoff.handOff(uid: "sharer-uid", researchId: "res-9", now: now, transport: spy)

        XCTAssertEqual(spy.patchedPaths.first?.uid, "sharer-uid")
        XCTAssertEqual(spy.patchedPaths.first?.researchId, "res-9")
        XCTAssertEqual(spy.calls.last, .post(researchId: "res-9", ownerUid: "sharer-uid"))
    }

    func testOnlyUploadYouTubeIsCalledAndNotP5AsWell() async {
        // `uploadYouTube` owns the P5 chain; calling P5 too would double it.
        let spy = SpyHandoff()

        await RunHandoff.handOff(uid: "owner-1", researchId: "res-1", now: now, transport: spy)

        let posts = spy.calls.filter { if case .post = $0 { return true }; return false }
        XCTAssertEqual(posts.count, 1)
    }
}
