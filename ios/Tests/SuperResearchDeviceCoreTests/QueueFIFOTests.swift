import XCTest
@testable import SuperResearchDeviceCore

/// The order runs are claimed in, and the capacity that order is spent against.
///
/// ⭐ **A listing is not a queue.** Firestore's `listDocuments` returns documents ordered by document
/// NAME, and a queue document's name says nothing about when it was submitted. The desktop backend
/// sorts before it claims; this device did not, so with two runs waiting it claimed whichever id
/// happened to sort first — a coin flip that looks, from the outside, exactly like the queue being
/// ignored.
final class QueueFIFOTests: XCTestCase {

    private func entry(
        id: String, research: String, submittedAt: Int64? = nil, clientMillis: Int64 = 0
    ) -> QueueEntry {
        QueueEntry(
            id: id, action: .start, researchId: research, uid: "owner-1", submittedBy: "owner-1",
            timestampMillis: clientMillis, submittedAtMillis: submittedAt
        )
    }

    // MARK: - Ordering

    /// ⛔ The headline: submission order wins over document-id order, which is what a listing gives.
    func testTheRunSUBMITTEDFirstIsClaimedFirstEvenWhenItsIdSortsLast() {
        let listed = [
            entry(id: "aaa-later", research: "r2", submittedAt: 2_000),
            entry(id: "zzz-earlier", research: "r1", submittedAt: 1_000),
        ]
        XCTAssertEqual(
            RunQueuePolicy.fifoOrdered(listed).map(\.researchId), ["r1", "r2"],
            "the queue was claimed in document-id order, not submission order"
        )
    }

    /// ⭐ **The SERVER stamp wins over the client one, and this is the case that forced it.** Two
    /// people share a device; the sharer's browser clock is a few seconds behind the owner's. The
    /// sharer submits SECOND but their document carries the EARLIER client timestamp, so ordering by
    /// the client clock runs them first and the owner's run — which genuinely reached Firestore
    /// first — waits behind it.
    func testACLIENTClockThatIsBehindDoesNotJumpTheQueue() {
        let owner = entry(id: "d1", research: "owner-run", submittedAt: 1_000, clientMillis: 9_999)
        let sharer = entry(id: "d2", research: "sharer-run", submittedAt: 2_000, clientMillis: 1)

        let order = RunQueuePolicy.fifoOrdered([sharer, owner]).map(\.researchId)

        XCTAssertEqual(order, ["owner-run", "sharer-run"])
        // Said explicitly: ordering by the client clock gives the opposite answer.
        XCTAssertLessThan(sharer.timestampMillis, owner.timestampMillis)
    }

    func testTheCLIENTClockIsUsedWhenTheServerStampIsMissing() {
        let older = entry(id: "z", research: "older", clientMillis: 100)
        let newer = entry(id: "a", research: "newer", clientMillis: 500)
        XCTAssertEqual(
            RunQueuePolicy.fifoOrdered([newer, older]).map(\.researchId), ["older", "newer"]
        )
    }

    /// ⚠ Demoted, never dropped. An unorderable document is still work somebody asked for — and it
    /// must not sort FIRST, which is what a zero-valued key would do.
    func testADocumentWithNoUsableStampGoesLASTRatherThanFirst() {
        let unstamped = entry(id: "aaa", research: "unstamped")
        let stamped = entry(id: "zzz", research: "stamped", submittedAt: 5_000)

        let order = RunQueuePolicy.fifoOrdered([unstamped, stamped]).map(\.researchId)

        XCTAssertEqual(order, ["stamped", "unstamped"])
        XCTAssertEqual(order.count, 2, "an unorderable document was dropped from the queue")
    }

    /// ⛔ Two submissions in the same millisecond must have ONE answer. Without the tiebreak the
    /// order depends on the sort's stability and on whatever order the listing happened to arrive
    /// in — which is the very thing being fixed.
    func testATIEIsBrokenByDocumentIdSoTheOrderIsDeterministic() {
        let a = entry(id: "aaa", research: "r-a", submittedAt: 7_000)
        let b = entry(id: "bbb", research: "r-b", submittedAt: 7_000)
        XCTAssertEqual(RunQueuePolicy.fifoOrdered([b, a]).map(\.researchId), ["r-a", "r-b"])
        XCTAssertEqual(RunQueuePolicy.fifoOrdered([a, b]).map(\.researchId), ["r-a", "r-b"])
    }

    // MARK: - Reading the server stamp off the wire

    /// ⚠ Firestore emits fractional seconds and omits them when they are zero. A parser configured
    /// for one shape silently returns nil for the other — and a nil stamp demotes a perfectly
    /// ordered document to last place, which is a queue jumping backwards for no visible reason.
    func testBOTHRFC3339ShapesParse() {
        XCTAssertEqual(
            QueueEntry.epochMillis(fromRFC3339: "2026-08-14T10:00:00.250Z"), 1_786_701_600_250
        )
        XCTAssertEqual(
            QueueEntry.epochMillis(fromRFC3339: "2026-08-14T10:00:00Z"), 1_786_701_600_000
        )
        XCTAssertNil(QueueEntry.epochMillis(fromRFC3339: "not a timestamp"))
    }

    func testAServerTimestampIsDecodedFromTheQueueDocument() throws {
        let doc = FirestoreREST.ListedDocument(
            id: "q1",
            fields: [
                "action": .string("start"),
                "researchId": .string("r1"),
                "submittedAt": .timestamp("2026-08-14T10:00:00.250Z"),
            ],
            updateTime: "2026-08-14T10:00:01Z"
        )
        let decoded = try XCTUnwrap(QueueEntry.decode(doc))
        XCTAssertEqual(decoded.submittedAtMillis, 1_786_701_600_250)
    }

    /// A document written by a test double or an older client carries a NUMBER under the same key.
    /// Reading only the RFC-3339 form would return nil and demote it for no reason.
    func testANumericSubmittedAtIsAlsoAccepted() throws {
        let doc = FirestoreREST.ListedDocument(
            id: "q1",
            fields: ["action": .string("start"), "submittedAt": .integer(4_242)],
            updateTime: "t"
        )
        XCTAssertEqual(try XCTUnwrap(QueueEntry.decode(doc)).submittedAtMillis, 4_242)
    }

    // MARK: - What pollQueue actually claims

    /// ⛔ **The call site, not just the rule.** Mutation caught that deleting the sort from
    /// `pollQueue` changed nothing any test could see — the ordering tests above all call
    /// `fifoOrdered` directly, so they pass against a queue loop that never sorts. This drives the
    /// real loop and asserts which document was CLAIMED.
    func testPollQueueClaimsTheEARLIESTSubmissionAndOnlyOneOnASingleWorkerDevice() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        var store = DeviceIdentityStore()
        store.fallbackDirectory = tempDir
        store.save(deviceID: "dev-1", pollSecret: "secret", refreshToken: "refresh-abc")
        defer { store.clear() }

        let transport = FakeTransport()
        transport.document = [:]   // nothing busy, nothing resting
        // Ids sort the OPPOSITE way from the submission times — the whole point.
        transport.queue = [
            queued(id: "aaa", research: "later", submittedAt: "2026-08-14T10:00:05Z"),
            queued(id: "zzz", research: "earlier", submittedAt: "2026-08-14T10:00:01Z"),
        ]
        let backend = DeviceBackend(
            transport: transport, store: store,
            workers: WorkerRegistry(storage: InMemoryWorkerStorage())   // one profile
        )

        await backend.pollQueue()

        let claims = transport.conditionalPatches.map(\.path)
        XCTAssertEqual(
            claims, ["devices/dev-1/queue/zzz"],
            "the queue was claimed in document-id order, or a one-worker device claimed both"
        )
    }

    private func queued(
        id: String, research: String, submittedAt: String
    ) -> FirestoreREST.ListedDocument {
        FirestoreREST.ListedDocument(
            id: id,
            fields: [
                "action": .string("start"), "researchId": .string(research),
                "uid": .string("owner-1"), "submittedBy": .string("owner-1"),
                "submittedAt": .timestamp(submittedAt),
                "timestamp": .integer(Int64(Date().timeIntervalSince1970 * 1000)),
            ],
            updateTime: "2026-08-14T10:00:06Z"
        )
    }

    // MARK: - Capacity

    /// The single-worker case — the shape a foreground `serve` has on the desktop, and the shape
    /// this device has whenever the owner keeps one browser profile.
    func testASingleWorkerDeviceTakesONERunAndLeavesTheRestQueued() {
        XCTAssertEqual(RunQueuePolicy.freeWorker(count: 1, busy: [], resting: []), 1)
        XCTAssertNil(
            RunQueuePolicy.freeWorker(count: 1, busy: [1], resting: []),
            "a busy single-worker device took a second run"
        )
    }

    func testAMultiWorkerDeviceFillsTheLowestFreeWorkerFirst() {
        XCTAssertEqual(RunQueuePolicy.freeWorker(count: 3, busy: [1], resting: []), 2)
        XCTAssertEqual(RunQueuePolicy.freeWorker(count: 3, busy: [1], resting: [2]), 3)
        XCTAssertNil(RunQueuePolicy.freeWorker(count: 3, busy: [1, 3], resting: [2]))
    }

    /// ⚠ Resting is the owner's explicit "not now". A device whose only worker is resting has no
    /// capacity at all — handing it a run silently overrides the decision.
    func testARestingWorkerIsNotCapacity() {
        XCTAssertNil(RunQueuePolicy.freeWorker(count: 1, busy: [], resting: [1]))
    }
}
