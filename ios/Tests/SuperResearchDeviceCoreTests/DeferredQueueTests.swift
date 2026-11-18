import XCTest
@testable import SuperResearchDeviceCore

/// The runs a parked worker is NOT taking, and how they become visible.
///
/// ⛔ **Both apps already draw this and nothing on this device wrote it.** The web app's
/// Shared-with popup renders an amber `#N` badge per waiting run from the device document's
/// `queueOwners`; the phone's own People popup parses the identical field; the desktop backend
/// rewrites it on every queue recompute. The iOS backend only ever READ it — so parking a worker
/// did the right thing and looked, on every screen, like the submission had vanished. The rest
/// feature's whole promise is that the work waits *visibly*.
final class DeferredQueueTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-deferred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        var s = DeviceIdentityStore(); s.fallbackDirectory = tempDir; s.clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The ordering and the numbers

    private func entry(
        id: String, research: String, uid: String, topic: String = "t",
        at millis: Int64, action: String = "start",
        worker: Int? = nil, processed: Bool = false
    ) -> QueueEntry {
        var fields: [String: FirestoreValue] = [
            "action": .string(action),
            "researchId": .string(research),
            "submittedBy": .string(uid),
            "topic": .string(topic),
            "timestamp": .integer(millis),
        ]
        if let worker { fields["assignedWorker"] = .integer(Int64(worker)) }
        if processed { fields["processed"] = .boolean(true) }
        return QueueEntry.decode(
            FirestoreREST.ListedDocument(id: id, fields: fields, updateTime: "t")
        )!
    }

    func testWaitingRunsAreNumberedFromOneInSubmissionOrder() {
        let runs = RunQueuePolicy.deferredRuns([
            entry(id: "b", research: "r-2", uid: "u1", at: 200),
            entry(id: "a", research: "r-1", uid: "u1", at: 100),
        ])

        XCTAssertEqual(runs.map(\.researchID), ["r-1", "r-2"])
        XCTAssertEqual(runs.map(\.position), [1, 2])
    }

    /// ⚠ The sort happens INSIDE. The positions are the ordering claim, and a function that
    /// renumbered whatever order it was handed would publish a queue that disagrees with the one
    /// the claim path takes — the same list, two different answers about who is next.
    func testTheORDERIsNotTakenOnTrustFromTheCaller() {
        let runs = RunQueuePolicy.deferredRuns([
            entry(id: "z", research: "later", uid: "u1", at: 999),
            entry(id: "a", research: "earlier", uid: "u1", at: 1),
        ])

        XCTAssertEqual(runs.first?.researchID, "earlier", "a caller's order was published as truth")
    }

    /// ⛔ A claimed document is RUNNING, not waiting. It is excluded by the same filter the desktop
    /// scan uses — otherwise the run that just started is advertised as the one queued behind it.
    func testAClaimedOrProcessedDocumentIsNotAWaitingRun() {
        let runs = RunQueuePolicy.deferredRuns([
            entry(id: "a", research: "running", uid: "u1", at: 100, worker: 1),
            entry(id: "b", research: "done", uid: "u1", at: 150, processed: true),
            entry(id: "c", research: "waiting", uid: "u1", at: 200),
        ])

        XCTAssertEqual(runs.map(\.researchID), ["waiting"])
        XCTAssertEqual(runs.first?.position, 1, "the queue was numbered from the runs that left it")
    }

    /// A cancel is a terminal SIGNAL, not queued work — badging one would tell the owner a run is
    /// waiting when what is waiting is the instruction to stop it.
    func testACancelIsNotAQueuedRun() {
        let runs = RunQueuePolicy.deferredRuns([
            entry(id: "a", research: "r-1", uid: "u1", at: 100, action: "cancel"),
        ])

        XCTAssertTrue(runs.isEmpty, "\(runs)")
    }

    /// ⭐ The two counts say different things to the person reading them: runs of your own ahead of
    /// you are your own doing, runs of someone else's are the shared device being shared. The web
    /// app words the banner differently for exactly that reason, so the split has to be real.
    func testTheRunsAheadAreSPLITByWhoSubmittedThem() {
        let runs = RunQueuePolicy.deferredRuns([
            entry(id: "a", research: "r-1", uid: "me", at: 100),
            entry(id: "b", research: "r-2", uid: "someone-else", at: 200),
            entry(id: "c", research: "r-3", uid: "me", at: 300),
        ])

        let mine = runs.last
        XCTAssertEqual(mine?.position, 3)
        XCTAssertEqual(mine?.aheadFromSelf, 1, "my own earlier run was not counted as mine")
        XCTAssertEqual(mine?.aheadFromOthers, 1, "the other account's run was miscounted")
    }

    /// `submittedBy` wins over `uid`, which is the desktop's precedence. They differ on a run a
    /// SHARER submitted to someone else's device — and picking the wrong one puts the badge on the
    /// wrong person in the owner's popup.
    func testTheSUBMITTERIsWhoTheBadgeBelongsTo() {
        let doc = FirestoreREST.ListedDocument(
            id: "a",
            fields: [
                "action": .string("start"),
                "researchId": .string("r-1"),
                "uid": .string("device-owner"),
                "submittedBy": .string("the-sharer"),
                "timestamp": .integer(1),
            ],
            updateTime: "t"
        )

        let runs = RunQueuePolicy.deferredRuns([QueueEntry.decode(doc)!])

        XCTAssertEqual(runs.first?.uid, "the-sharer")
    }

    /// The head of the queue is waiting on the run that is RUNNING, which this document cannot
    /// name — so it names nothing rather than pointing at itself.
    func testTheHEADOfTheQueueIsBehindNothingAndTheRestNameTheirPredecessor() {
        let runs = RunQueuePolicy.deferredRuns([
            entry(id: "a", research: "first", uid: "u1", topic: "batteries", at: 100),
            entry(id: "b", research: "second", uid: "u1", at: 200),
        ])

        XCTAssertEqual(runs.first?.behindRunID, "")
        XCTAssertEqual(runs.last?.behindRunID, "first")
        XCTAssertEqual(runs.last?.behindTitle, "batteries")
    }

    /// Truncated at the desktop's own 60, so the same run does not read differently depending on
    /// which backend published it.
    func testALongTopicIsTruncatedTheWayTheDesktopTruncatesIt() {
        let long = String(repeating: "x", count: 200)
        let runs = RunQueuePolicy.deferredRuns([
            entry(id: "a", research: "r-1", uid: "u1", topic: long, at: 1),
        ])

        XCTAssertEqual(runs.first?.title.count, 60)
    }

    // MARK: - Publishing it

    private func backend(_ transport: FakeTransport) -> DeviceBackend {
        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        s.save(deviceID: "dev-1", pollSecret: "secret", refreshToken: "refresh-abc")
        return DeviceBackend(transport: transport, store: s,
                             workers: WorkerRegistry(storage: InMemoryWorkerStorage()))
    }

    /// A device whose only worker the owner has parked, with one run waiting.
    private func parkedDevice() -> (DeviceBackend, FakeTransport) {
        let transport = FakeTransport()
        transport.document = [
            "pairConfirmedAt": .integer(1),
            "status": .string("active"),
            "restingWorkerIds": .array([.integer(1)]),
        ]
        transport.queue = [
            FirestoreREST.ListedDocument(
                id: "q1",
                fields: [
                    "action": .string("start"),
                    "researchId": .string("r-1"),
                    "submittedBy": .string("u1"),
                    "topic": .string("solid-state batteries"),
                    "timestamp": .integer(Int64(Date().timeIntervalSince1970 * 1000)),
                ],
                updateTime: "t"
            )
        ]
        return (backend(transport), transport)
    }

    private func queueOwners(_ transport: FakeTransport) -> [FirestoreValue]? {
        guard let patch = transport.docPatches.last(where: { $0.set["queueOwners"] != nil }),
              case .array(let owners)? = patch.set["queueOwners"]
        else { return nil }
        return owners
    }

    func testAParkedWorkersWAITINGRunIsPublishedOntoTheDeviceDocument() async {
        let (device, transport) = parkedDevice()

        await device.pollQueue()

        guard case .map(let owner)? = queueOwners(transport)?.first else {
            return XCTFail("nothing was published: \(transport.docPatches.map(\.path))")
        }
        XCTAssertEqual(owner["runId"], .string("r-1"))
        XCTAssertEqual(owner["uid"], .string("u1"))
        XCTAssertEqual(owner["title"], .string("solid-state batteries"))
        XCTAssertEqual(owner["position"], .integer(1))
    }

    /// ⛔ **The run this pass CLAIMED must not be published as waiting.** The claim goes to the
    /// server, not to the array this loop is walking, so the entry it just started still looks
    /// unclaimed in memory — and the run that is now executing would be advertised as the one
    /// queued behind itself.
    func testTheRunJUSTCLAIMEDIsNotPublishedAsWaiting() async {
        let (device, transport) = parkedDevice()
        // Awake this time, so the entry is claimed rather than deferred.
        transport.document?["restingWorkerIds"] = .array([])

        await device.pollQueue()

        XCTAssertEqual(queueOwners(transport)?.count ?? 0, 0,
                       "the run that just started was published as queued behind itself")
    }

    /// ⛔ The last run leaving is exactly when the badges must disappear. `pollQueue` used to return
    /// early on an empty listing, which left the previous array on the document for ever — the
    /// owner's popup kept showing a run that had finished.
    func testANOWEMPTYQueueClearsTheBadges() async {
        let (device, transport) = parkedDevice()
        await device.pollQueue()
        XCTAssertEqual(queueOwners(transport)?.count, 1)

        transport.queue = []
        await device.pollQueue()

        XCTAssertEqual(queueOwners(transport)?.count, 0, "the finished run kept its badge")
    }

    /// A parked device is the steady state this feature exists for; republishing an unchanged queue
    /// every 20 seconds would cost a write per beat, for ever, to say nothing.
    func testAnUNCHANGEDQueueIsNotRepublished() async {
        let (device, transport) = parkedDevice()

        await device.pollQueue()
        let after = transport.docPatches.filter { $0.set["queueOwners"] != nil }.count
        await device.pollQueue()

        XCTAssertEqual(transport.docPatches.filter { $0.set["queueOwners"] != nil }.count, after,
                       "the same queue was published twice")
    }

    /// ⚠ The cache is updated only when the write is ACCEPTED. Remembering a failed publish as done
    /// means one dropped write leaves the badges wrong until the queue happens to change again.
    func testAFAILEDPublishIsRetriedOnTheNextBeat() async {
        let (device, transport) = parkedDevice()
        transport.patchFailures = ["devices/dev-1"]

        await device.pollQueue()
        transport.patchFailures = []
        await device.pollQueue()

        XCTAssertNotNil(queueOwners(transport), "the failed publish was remembered as done")
    }

    /// ⛔ **`deviceId` travels in the same patch or the write is a 403.** The rule is judged on the
    /// PAYLOAD (`request.resource.data.deviceId == request.auth.token.deviceId`), so a patch naming
    /// only the queue fields is refused however long the document has carried this device's stamp.
    func testTheWaitingRunsOwnDocumentIsToldWhereItStandsWithTheDeviceStamp() async {
        let (device, transport) = parkedDevice()

        await device.pollQueue()

        guard let patch = transport.docPatches.last(where: {
            $0.path == "users/u1/researches/r-1"
        }) else {
            return XCTFail("the run was never told its position: \(transport.docPatches.map(\.path))")
        }
        XCTAssertEqual(patch.set["deviceId"], .string("dev-1"), "this write would 403")
        XCTAssertEqual(patch.set["queuePosition"], .integer(1))
        XCTAssertEqual(patch.set["queueTotalAhead"], .integer(0))
    }

    // MARK: - The keep-alive stamp

    /// ⛔ **This is what makes "park it over the weekend" safe, and the field was read but never
    /// written.** Once the workers are awake the sweep ages a rest-deferred document from
    /// `restDeferredAt`; with nothing stamping it, a run parked on Friday is aged from its
    /// submission and the Monday sweep deletes the work the owner came back for.
    func testAParkedRunsAbandonmentClockIsRESTAMPEDWhileTheWorkerRests() async {
        let (device, transport) = parkedDevice()

        await device.pollQueue()

        let stamped = transport.docPatches.last { $0.path == "devices/dev-1/queue/q1" }
        XCTAssertNotNil(stamped?.set["restDeferredAt"],
                        "a parked run keeps the abandonment clock it was submitted with")
    }

    /// ⚠ Only while a worker is actually RESTING. Stamping a run that is merely waiting behind a
    /// busy worker would extend the abandonment horizon indefinitely for every queue — which is the
    /// hole the horizon exists to bound.
    func testARunWaitingOnABUSYWorkerIsNotKeptAliveForever() {
        let run = DeferredRun(uid: "u1", researchID: "r-1", title: "t", position: 1,
                              aheadFromSelf: 0, aheadFromOthers: 0, queueDocID: "q1")

        XCTAssertFalse(RunQueuePolicy.needsRestStamp(run, workersResting: false, now: 10_000))
        XCTAssertTrue(RunQueuePolicy.needsRestStamp(run, workersResting: true, now: 10_000))
    }

    /// A stamp that is still fresh costs no write — the pass runs every 20 seconds and the refresh
    /// interval is half an hour.
    func testAFRESHStampIsNotRewrittenOnEveryPass() {
        let now: Int64 = 10 * 60 * 60 * 1000
        func run(stampedAt: Int64) -> DeferredRun {
            DeferredRun(uid: "u1", researchID: "r-1", title: "t", position: 1,
                        aheadFromSelf: 0, aheadFromOthers: 0, queueDocID: "q1",
                        restDeferredAtMillis: stampedAt)
        }

        XCTAssertFalse(
            RunQueuePolicy.needsRestStamp(run(stampedAt: now - 60_000), workersResting: true, now: now)
        )
        XCTAssertTrue(
            RunQueuePolicy.needsRestStamp(
                run(stampedAt: now - RunQueuePolicy.restStampRefreshMillis - 1),
                workersResting: true, now: now
            ),
            "a stamp older than the refresh interval was left to rot"
        )
    }

    /// At the head of the queue the run ahead is the one RUNNING, so a previous "behind X" has to be
    /// REMOVED — left behind it renders as waiting on a run that ended an hour ago.
    func testTheHEADClearsAStalePredecessorRatherThanOverwritingIt() async {
        let (device, transport) = parkedDevice()

        await device.pollQueue()

        let deletes = transport.docDeletes.last { $0.path == "users/u1/researches/r-1" }?.delete
        XCTAssertEqual(deletes?.sorted(), ["queuedBehindRunId", "queuedBehindTitle"],
                       "a stale predecessor survives at the head of the queue")
    }
}
