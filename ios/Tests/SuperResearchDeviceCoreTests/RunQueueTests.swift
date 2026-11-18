import XCTest

@testable import SuperResearchDeviceCore

/// Run intake: how a topic submitted in the web app reaches this device, and how it is claimed
/// without racing another backend on the same account.
///
/// ⚠ These assert the **mechanism**, not the outcome. A single-claimer test passes against no claim
/// protocol at all — the whole point of a conditional claim is what happens when two backends read
/// the same document, so the interesting assertions here are about the precondition being *sent*,
/// and about a lost precondition being reported as a race-loss rather than as an error.
final class RunQueueTests: XCTestCase {

    private let config = FirebaseProjectConfig(
        projectID: "test-project",
        apiKey: "test-key",
        apiBaseURL: URL(string: "https://example.test")!,
        emulatorHost: nil
    )

    private func listed(
        id: String = "q1", fields: [String: FirestoreValue], updateTime: String? = "2026-08-08T19:00:00.123456Z"
    ) -> FirestoreREST.ListedDocument {
        FirestoreREST.ListedDocument(id: id, fields: fields, updateTime: updateTime)
    }

    // MARK: - Decoding

    func testTheClientMillisecondTimestampIsReadAndNotTheServerOne() throws {
        // The web app writes BOTH `submittedAt` (a serverTimestamp, landing a few ms later) and
        // `timestamp` (Date.now()) — deliberately, because the desktop backend's stale-queue
        // defense reads the client one. Reading `submittedAt` here would make this device's
        // staleness arithmetic disagree with the product's on every document.
        let entry = try XCTUnwrap(QueueEntry.decode(listed(fields: [
            "action": .string("start"),
            "timestamp": .integer(1_754_600_000_000),
            "submittedAt": .string("2026-08-08T19:00:05Z"),
        ])))
        XCTAssertEqual(entry.timestampMillis, 1_754_600_000_000)
    }

    func testUidAndSubmittedByAreKeptDISTINCT() throws {
        // The owner-controls-a-sharer's-run case. `uid` names whose tree the run lives in;
        // `submittedBy` names who is allowed to write the doc. Collapsing them into one field
        // writes the run into the wrong user's tree — and the rules would happily allow it,
        // because they only ever constrain `submittedBy`.
        let entry = try XCTUnwrap(QueueEntry.decode(listed(fields: [
            "action": .string("cancel"),
            "uid": .string("sharer-uid"),
            "submittedBy": .string("owner-uid"),
            "ownerControl": .string("stop"),
        ])))
        XCTAssertEqual(entry.uid, "sharer-uid")
        XCTAssertEqual(entry.submittedBy, "owner-uid")
        XCTAssertNotEqual(entry.uid, entry.submittedBy)
        XCTAssertEqual(entry.ownerControl, "stop")
    }

    func testAnAssignedWorkerIsReadFromEitherTheNumericOrTheStringShape() throws {
        // The sibling field on the device doc carries both shapes in the wild. Reading only one
        // makes a CLAIMED document look unclaimed, which is how two backends end up running it.
        for value in [FirestoreValue.integer(2), .double(2.0), .string("2")] {
            let entry = try XCTUnwrap(QueueEntry.decode(listed(fields: [
                "action": .string("start"), "assignedWorker": value,
            ])))
            XCTAssertEqual(entry.assignedWorker, 2, "shape \(value) read as \(String(describing: entry.assignedWorker))")
        }
    }

    func testADocumentWithNoActionIsNotAQueueEntry() throws {
        XCTAssertNil(QueueEntry.decode(listed(fields: ["topic": .string("x")])))
    }

    func testAnUnknownActionIsCarriedRatherThanDropped() throws {
        let entry = try XCTUnwrap(QueueEntry.decode(listed(fields: ["action": .string("teleport")])))
        XCTAssertEqual(entry.action, .unsupported("teleport"))
    }

    func testTheUpdateTimeIsCarriedOntoTheEntry() throws {
        // Without it there is no base version, and therefore no claim.
        let entry = try XCTUnwrap(QueueEntry.decode(
            listed(fields: ["action": .string("start")], updateTime: "2026-01-01T00:00:00Z")
        ))
        XCTAssertEqual(entry.updateTime, "2026-01-01T00:00:00Z")
    }

    // MARK: - The intake policy

    private func entry(
        action: QueueAction = .start, timestamp: Int64 = 0, assigned: Int? = nil,
        claimedAt: Int64? = nil, processed: Bool = false, restDeferred: Int64? = nil,
        researchId: String = "r1", uid: String = "u1"
    ) -> QueueEntry {
        QueueEntry(id: "q1", action: action, researchId: researchId, uid: uid,
                   submittedBy: uid, timestampMillis: timestamp, assignedWorker: assigned,
                   claimedAtMillis: claimedAt, processed: processed,
                   restDeferredAtMillis: restDeferred)
    }

    private let now: Int64 = 1_754_600_000_000

    func testAFreshUnclaimedStartIsClaimed() {
        XCTAssertEqual(
            RunQueuePolicy.decide(entry(timestamp: now - 5_000), now: now, workerIsResting: false),
            .claim
        )
    }

    func testAProcessedDocumentIsIgnored() {
        XCTAssertEqual(
            RunQueuePolicy.decide(entry(processed: true), now: now, workerIsResting: false),
            .ignore
        )
    }

    func testARecentlyClaimedDocumentIsLeftALONEWithinTheGrace() {
        // The sibling may still be alive. Deleting inside the grace window kills a healthy run.
        let e = entry(assigned: 1, claimedAt: now - (RunQueuePolicy.zombieGraceMillis - 1))
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: false), .waitOutGrace)
    }

    func testAClaimOlderThanTheGraceIsSweptAsAZombie() {
        let e = entry(assigned: 1, claimedAt: now - (RunQueuePolicy.zombieGraceMillis + 1))
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: false), .sweepZombie)
    }

    func testTheGraceBoundaryIsNotOffByOne() {
        // Exactly at the grace: still within. The desktop uses a strict `>`.
        let e = entry(assigned: 1, claimedAt: now - RunQueuePolicy.zombieGraceMillis)
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: false), .waitOutGrace)
    }

    func testAnOldUnclaimedStartIsSweptButOnlyAfterAHealthCheck() {
        // The wake-before-boot hole: park a run Friday, wake the workers from the phone on Sunday,
        // boot Monday — a naive sweep deletes the run the owner is still waiting for. The research
        // document is the authority on whether it is still wanted.
        let e = entry(timestamp: now - (RunQueuePolicy.abandonedMaxMillis + 1))
        XCTAssertEqual(
            RunQueuePolicy.decide(e, now: now, workerIsResting: false),
            .sweepAbandoned(needsHealthCheck: true)
        )
    }

    func testAnOldCANCELIsNEVERSwept() {
        // A cancel is a terminal SIGNAL, not queued work. Sweeping one silently drops the owner's
        // Stop with no feedback anywhere — and processing a stale cancel is an idempotent no-op.
        let e = entry(action: .cancel, timestamp: now - (RunQueuePolicy.abandonedMaxMillis * 10))
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: false), .claim)
    }

    func testNothingIsSweptWhileTheWorkerIsRESTING() {
        // Parking a run over a weekend is the feature, not a fault.
        let e = entry(timestamp: now - (RunQueuePolicy.abandonedMaxMillis + 1))
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: true), .claim)
    }

    func testARecentRestDeferralExemptsAnOtherwiseAbandonedDocument() {
        // After a wake-and-restart the worker is no longer resting, so age must be measured from
        // the last rest-defer stamp instead of from submission.
        let e = entry(timestamp: now - (RunQueuePolicy.abandonedMaxMillis * 3),
                      restDeferred: now - 60_000)
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: false), .claim)
    }

    func testADocumentWithNoReadableTimestampIsNeverSwept() {
        // Bug-compatible with the desktop, deliberately: sweeping a document whose age is unknown
        // deletes work on a guess.
        let e = entry(timestamp: 0)
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: false), .claim)
    }

    func testAnUnsupportedActionIsReportedRatherThanClaimed() {
        XCTAssertEqual(
            RunQueuePolicy.decide(entry(action: .unsupported("teleport")), now: now,
                                  workerIsResting: false),
            .unsupported("teleport")
        )
    }

    func testAnEntryClaimedWithNoClaimStampIsIgnoredNotStolen() {
        // Someone else owns it and we cannot age the claim. Claiming anyway is theft.
        let e = entry(assigned: 3, claimedAt: nil)
        XCTAssertEqual(RunQueuePolicy.decide(e, now: now, workerIsResting: false), .ignore)
    }

    // MARK: - Worker routing

    func testTheLowestFreeWorkerIsChosen() {
        XCTAssertEqual(RunQueuePolicy.freeWorker(count: 3, busy: [1], resting: []), 2)
    }

    func testARestingWorkerIsNotHandedARun() {
        // Resting is the owner's explicit "not now"; routing a run to one silently overrides it.
        XCTAssertEqual(RunQueuePolicy.freeWorker(count: 3, busy: [1], resting: [2]), 3)
        XCTAssertNil(RunQueuePolicy.freeWorker(count: 2, busy: [1], resting: [2]))
    }

    func testNoWorkersMeansNoPlacement() {
        XCTAssertNil(RunQueuePolicy.freeWorker(count: 0, busy: [], resting: []))
    }

    // MARK: - The conditional claim, over the wire

    func testTheClaimSendsAnUpdateTimePreconditionOnTheWire() async throws {
        // The load-bearing assertion of this whole item. A claim without the precondition is not a
        // weaker claim — it is NO claim, and two backends both run the research.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .ok("{}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        try await client.patchDocument(
            path: "devices/dev-1/queue/q1",
            set: ["assignedWorker": .integer(1), "claimedAt": .integer(now)],
            ifUpdateTime: "2026-08-08T19:00:00.123456Z"
        )
        let url = try XCTUnwrap(transport.lastRequest().url?.absoluteString)
        XCTAssertTrue(
            url.contains("currentDocument.updateTime=2026-08-08T19:00:00.123456Z")
                || url.contains("currentDocument.updateTime=2026-08-08T19%3A00%3A00.123456Z"),
            "the precondition was not sent: \(url)"
        )
    }

    func testAnUnconditionalPatchSendsNoPrecondition() async throws {
        // Every other caller of patchDocument must keep working unchanged.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .ok("{}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        try await client.patchDocument(path: "devices/dev-1", set: ["online": .boolean(true)])
        let url = try XCTUnwrap(transport.lastRequest().url?.absoluteString)
        XCTAssertFalse(url.contains("currentDocument"))
    }

    func testALostPreconditionSurfacesAsItsOwnCaseAndNotAsAGenericHTTPError() async throws {
        // Firestore reports it as HTTP 400 with a FAILED_PRECONDITION body, not a 409 — so a
        // status-code-only reader either misses it or over-matches every 400. Folded into `.http`
        // the caller's transient-retry policy RETRIES it, and a retry reads the sibling's claim as
        // the new base version: a clean race-loss becomes a stolen run.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .status(400, "{\"error\":{\"code\":400,\"status\":\"FAILED_PRECONDITION\","
                         + "\"message\":\"the stored version does not match\"}}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        do {
            try await client.patchDocument(
                path: "devices/dev-1/queue/q1", set: ["assignedWorker": .integer(1)],
                ifUpdateTime: "2026-08-08T19:00:00Z"
            )
            XCTFail("a lost precondition must throw")
        } catch FirestoreRESTError.preconditionFailed {
            // exactly right
        } catch {
            XCTFail("expected .preconditionFailed, got \(error)")
        }
    }

    func testAPlain400WithoutAPreconditionRequestStaysAGenericHTTPError() async throws {
        // Only a write that ASKED for a precondition may report one as lost. Otherwise a rules
        // evaluation error would be handed to the caller as a race it never entered — and the
        // caller's response to a lost race is to move on quietly.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .status(400, "{\"error\":{\"status\":\"FAILED_PRECONDITION\"}}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        do {
            try await client.patchDocument(path: "devices/dev-1", set: ["online": .boolean(true)])
            XCTFail("must throw")
        } catch FirestoreRESTError.http(let status, _) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("expected .http, got \(error)")
        }
    }

    func testAnUnrelated400IsNotMistakenForALostRace() async throws {
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .status(400, "{\"error\":{\"status\":\"INVALID_ARGUMENT\"}}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        do {
            try await client.patchDocument(
                path: "devices/dev-1/queue/q1", set: ["assignedWorker": .integer(1)],
                ifUpdateTime: "2026-08-08T19:00:00Z"
            )
            XCTFail("must throw")
        } catch FirestoreRESTError.http(let status, _) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("expected .http, got \(error)")
        }
    }

    func testTheListingCarriesEachDocumentsUpdateTime() async throws {
        // Dropped, there is no base version to claim against — which is the state this client was
        // in before this item.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .ok("""
            {"documents":[{"name":"projects/p/databases/(default)/documents/devices/d/queue/q1",
             "updateTime":"2026-08-08T19:00:00.123456Z",
             "fields":{"action":{"stringValue":"start"}}}]}
            """),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        let docs = try await client.listDocuments(collectionPath: "devices/d/queue")
        XCTAssertEqual(docs.first?.updateTime, "2026-08-08T19:00:00.123456Z")
    }
}
