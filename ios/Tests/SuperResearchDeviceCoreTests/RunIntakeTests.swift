import XCTest

@testable import SuperResearchDeviceCore

private struct IntakeBoom: Error {}

/// Records what the backend handed it, so "the run was placed" is checkable rather than assumed.
/// A launcher that stays inside `launch` until it is told to finish.
///
/// ⚠ The only way to observe that `pollQueue` returned WHILE the run was still going — which is the
/// property that keeps the heartbeat alive and Stop working.
actor BlockingLauncher: RunLauncher {
    private(set) var started = false
    private(set) var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    /// How long it will hold before letting go of its own accord.
    ///
    /// ⛔ **Bounded on purpose, and the bound is what makes the guard useful.** Held for ever, a
    /// pipeline that awaited the run synchronously would never return from `pollQueue` — the test
    /// would HANG rather than fail, and a hanging test is one the harness cannot tell from a slow
    /// one. Measured: the mutation harness sat on exactly this shape for 31 minutes elsewhere in
    /// this repo. With a bound, the synchronous version comes back having already finished, and the
    /// assertion below reports that as the failure it is.
    private let selfRelease: Duration = .milliseconds(300)

    func launch(_ entry: QueueEntry, worker: Int) async {
        started = true
        // ⚠ Released-before-started is a real ordering here, not a theoretical one: the run is
        // detached, so the test can reach `release()` before the task has even been scheduled.
        // Suspending anyway would park `launch` on a continuation nobody will ever resume, and the
        // join at the end of the test hangs for ever — which the harness cannot tell from a slow
        // test.
        if released { return }
        let hold = Task { [selfRelease] in
            try? await Task.sleep(for: selfRelease)
            await self.release()
        }
        await withCheckedContinuation { self.continuation = $0 }
        hold.cancel()
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class SpyLauncher: RunLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var launched: [(entry: QueueEntry, worker: Int)] = []

    func launch(_ entry: QueueEntry, worker: Int) async {
        lock.lock(); defer { lock.unlock() }
        launched.append((entry, worker))
    }
}

/// The intake path end to end at the backend level: poll, claim, route, sweep.
///
/// ⚠ The one assertion that matters most is negative — that the queue is read from a **different
/// collection** than the commands the app already polls. A reviewer skimming for "does it poll the
/// device?" finds `pollCommands` and concludes intake works; so does a test whose fake answers
/// every path with the same array.
final class RunIntakeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        var s = DeviceIdentityStore(); s.fallbackDirectory = tempDir; s.clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func backend(
        _ transport: FakeTransport, workers: Int = 1
    ) -> (DeviceBackend, SpyLauncher) {
        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        s.save(deviceID: "dev-1", pollSecret: "secret", refreshToken: "refresh-abc")
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage())
        while registry.count < workers { registry.addWorker() }
        let b = DeviceBackend(transport: transport, store: s, workers: registry)
        let spy = SpyLauncher()
        b.launcher = spy
        return (b, spy)
    }

    private func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func startDoc(
        id: String = "q1", ageMillis: Int64 = 5_000, updateTime: String? = "2026-08-08T19:00:00Z",
        extra: [String: FirestoreValue] = [:]
    ) -> FirestoreREST.ListedDocument {
        var fields: [String: FirestoreValue] = [
            "action": .string("start"),
            "researchId": .string("res-1"),
            "uid": .string("owner-1"),
            "submittedBy": .string("owner-1"),
            "topic": .string("solid-state batteries"),
            "timestamp": .integer(nowMillis() - ageMillis),
        ]
        fields.merge(extra) { _, new in new }
        return FirestoreREST.ListedDocument(id: id, fields: fields, updateTime: updateTime)
    }

    // MARK: - The right collection

    func testTheQueueIsPolledANDItIsNotTheCommandsCollection() async {
        let transport = FakeTransport()
        transport.document = [:]
        let (b, _) = backend(transport)

        await b.pollQueue()

        XCTAssertTrue(transport.listedPaths.contains("devices/dev-1/queue"),
                      "the research lifecycle collection was never read")
        XCTAssertFalse(transport.listedPaths.contains("devices/dev-1/commands"),
                       "pollQueue read the device-operations collection instead")
    }

    func testAnEmptyQueueCostsNoFurtherReads() async {
        // The beat runs every 20 seconds forever. An idle device must not pay a device-doc read
        // per tick just to discover there is nothing to do.
        let transport = FakeTransport()
        transport.document = [:]
        let (b, _) = backend(transport)

        await b.pollQueue()

        XCTAssertEqual(transport.listedPaths, ["devices/dev-1/queue"])
    }

    // MARK: - The claim

    func testAClaimIsWrittenWithItsPreconditionAndTheRunIsPlaced() async {
        let transport = FakeTransport()
        transport.document = [:]                      // nothing busy, nothing resting
        transport.queue = [startDoc(updateTime: "2026-08-08T19:00:00.5Z")]
        let (b, spy) = backend(transport)

        await b.pollQueue()

        XCTAssertEqual(transport.conditionalPatches.count, 1)
        let claim = try? XCTUnwrap(transport.conditionalPatches.first)
        XCTAssertEqual(claim?.path, "devices/dev-1/queue/q1")
        XCTAssertEqual(claim?.ifUpdateTime, "2026-08-08T19:00:00.5Z",
                       "the claim must be conditional on the version it was read at")
        XCTAssertEqual(claim?.set["assignedWorker"], .integer(1))
        XCTAssertNotNil(claim?.set["claimedAt"])
        XCTAssertEqual(spy.launched.count, 1)
        XCTAssertEqual(spy.launched.first?.entry.topic, "solid-state batteries")
        XCTAssertEqual(spy.launched.first?.worker, 1)
    }

    func testALOSTRaceStandsDownQuietlyAndDoesNotRunTheResearch() async {
        // The expected outcome when a Mac backend and this phone watch the same account. It must
        // not raise, must not retry, and above all must not launch: both backends running one
        // research is the corruption this protocol exists to prevent.
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc()]
        transport.preconditionLosers = ["devices/dev-1/queue/q1"]
        let (b, spy) = backend(transport)

        await b.pollQueue()
        // ⭐ JOINED, and the join is the guard. This assertion used to be safe because the run was
        // synchronous — making it detached silently turned "it never launched" into "it has not
        // launched YET", and a mutation deleting the stand-down `return` sailed straight through.
        await b.awaitRunInFlight()

        XCTAssertEqual(transport.conditionalPatches.count, 1, "a lost race must not be retried")
        XCTAssertTrue(spy.launched.isEmpty, "the research ran despite losing the claim")
    }

    func testADocumentWithNoUpdateTimeIsNEVERClaimED() async {
        // No base version means no precondition, and an unconditional claim is not a claim.
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc(updateTime: nil)]
        let (b, spy) = backend(transport)

        await b.pollQueue()

        XCTAssertTrue(transport.conditionalPatches.isEmpty)
        // ⚠ Scoped to the QUEUE document. This asserted that nothing was written anywhere, which
        // was a proxy for "no unconditional claim" and stopped being one the moment the pass
        // started publishing the waiting queue — an unclaimable document IS a run still waiting,
        // and saying so on the device document is right. The claim is the write that must not
        // happen without its precondition.
        XCTAssertTrue(
            transport.docPatches.allSatisfy { !$0.path.contains("/queue/") },
            "it fell back to an UNCONDITIONAL write: \(transport.docPatches.map(\.path))"
        )
        XCTAssertTrue(spy.launched.isEmpty)
    }

    // MARK: - A run the beat loop survives

    func testTheRunIsDETACHEDSoTheBEATKeepsBeating() async {
        // ⛔ **The e2e-killer.** `beat()` awaits pollQueue → claimAndRun → the whole run. Awaiting a
        // 30-to-90-minute run there means no heartbeat (the web app shows the device OFFLINE within
        // the beat window), no device commands, and no run-command polling — so **Stop and Pause
        // from the web app reach nothing at all** while the run is in fact progressing normally.
        //
        // The mechanism is that `pollQueue` RETURNS while the launcher is still running.
        let transport = FakeTransport()
        // ⚠ An EMPTY device document, not a missing one: an unreadable device doc is treated as
        // "every worker busy" on purpose, so a missing one would make this test pass by never
        // claiming anything at all.
        transport.document = [:]
        transport.queue = [startDoc()]
        let (b, spy) = backend(transport, workers: 1)
        let blocker = BlockingLauncher()
        b.launcher = blocker
        _ = spy

        await b.pollQueue()

        // ⭐ The MECHANISM: the claim's bookkeeping is done and `pollQueue` has returned, while the
        // launcher is still inside `launch`. Asserted on the synchronous side-effect rather than on
        // the task having been scheduled, which would be a race.
        XCTAssertEqual(b.locallyBusyWorkers, [1], "the run was never claimed")
        let finishedAlready = await blocker.released
        XCTAssertFalse(finishedAlready, "pollQueue waited for the whole run")

        await blocker.release()
        await b.awaitRunInFlight()
    }

    func testAWorkerDrivingARunIsBUSYForTheNextPoll() async {
        // ⛔ With the run detached, the very next beat sees the device document — which nothing on
        // this device has ever written `busyWorkerIds` to — and would claim a SECOND entry onto the
        // worker already driving one. Two runs, one set of web views.
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc()]
        let (b, _) = backend(transport, workers: 1)
        let blocker = BlockingLauncher()
        b.launcher = blocker

        await b.pollQueue()
        XCTAssertEqual(b.locallyBusyWorkers, [1])

        await blocker.release()
        await b.awaitRunInFlight()
        XCTAssertEqual(b.locallyBusyWorkers, [], "the worker stayed busy after the run finished")
    }

    func testTheQueueEntryIsDELETEDWhenTheRunFinishes() async {
        // ⭐ "Consumption is by delete only" — the contract says so, and the device has delete
        // permission on its own queue. Without this our OWN 30-second zombie sweep is what removes
        // it, deciding the claimer is dead when the claimer is us.
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc()]
        let (b, spy) = backend(transport, workers: 1)
        _ = spy

        await b.pollQueue()
        await b.awaitRunInFlight()

        XCTAssertTrue(
            transport.deletedPaths.contains { $0.contains("/queue/") },
            "the queue entry was left behind: \(transport.deletedPaths)"
        )
    }

    func testARunIsRoutedToTheFirstWorkerThatIsNotBusy() async {
        let transport = FakeTransport()
        transport.document = ["busyWorkerIds": .array([.integer(1)])]
        transport.queue = [startDoc()]
        let (b, spy) = backend(transport, workers: 2)

        await b.pollQueue()
        // ⚠ Joined explicitly: the run is DETACHED so the heartbeat keeps beating during it, which
        // means `pollQueue` returns before the launcher has been called.
        await b.awaitRunInFlight()

        XCTAssertEqual(transport.conditionalPatches.first?.set["assignedWorker"], .integer(2))
        XCTAssertEqual(spy.launched.first?.worker, 2)
    }

    func testNothingIsClaimedWhenEveryWorkerIsBusy() async {
        let transport = FakeTransport()
        transport.document = ["busyWorkerIds": .array([.integer(1)])]
        transport.queue = [startDoc()]
        let (b, spy) = backend(transport, workers: 1)

        await b.pollQueue()

        XCTAssertTrue(transport.conditionalPatches.isEmpty,
                      "a busy device claimed work it cannot run")
        XCTAssertTrue(spy.launched.isEmpty)
    }

    func testARestingWorkerIsNotHandedARun() async {
        let transport = FakeTransport()
        transport.document = ["restingWorkerIds": .array([.integer(1)])]
        transport.queue = [startDoc()]
        let (b, spy) = backend(transport, workers: 1)

        await b.pollQueue()

        XCTAssertTrue(spy.launched.isEmpty, "resting is the owner's 'not now' and was overridden")
    }

    func testAFailedDeviceReadPLACESNOTHINGRatherThanAssumingWorkersAreFree() async {
        // The safe direction under uncertainty is to do no work.
        let transport = FakeTransport()
        transport.queue = [startDoc()]
        transport.readError = IntakeBoom()
        let (b, spy) = backend(transport, workers: 2)

        await b.pollQueue()

        XCTAssertTrue(transport.conditionalPatches.isEmpty)
        XCTAssertTrue(spy.launched.isEmpty)
    }

    func testAMISSINGDeviceDocumentAlsoPlacesNothing() async {
        // ⚠ A separate test because it is a separate branch, and a mutation proved it: a 404 on the
        // device document returns nil rather than throwing, so the throwing test above passes
        // happily while this path assumes every worker is free. Two branches, two tests — an
        // outcome shared by two guards says nothing about which one is load-bearing.
        let transport = FakeTransport()
        transport.queue = [startDoc()]
        transport.document = nil       // a genuine 404, NOT an error
        let (b, spy) = backend(transport, workers: 2)

        await b.pollQueue()

        XCTAssertTrue(transport.conditionalPatches.isEmpty)
        XCTAssertTrue(spy.launched.isEmpty)
    }

    // MARK: - Sweeps

    func testAZombieClaimIsDeleted() async {
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc(extra: [
            "assignedWorker": .integer(1),
            "claimedAt": .integer(nowMillis() - (RunQueuePolicy.zombieGraceMillis + 5_000)),
        ])]
        let (b, spy) = backend(transport)

        await b.pollQueue()

        XCTAssertEqual(transport.deletedPaths, ["devices/dev-1/queue/q1"])
        XCTAssertTrue(spy.launched.isEmpty)
    }

    func testAClaimInsideTheGraceIsLeftAlone() async {
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc(extra: [
            "assignedWorker": .integer(1), "claimedAt": .integer(nowMillis() - 1_000),
        ])]
        let (b, _) = backend(transport)

        await b.pollQueue()

        XCTAssertTrue(transport.deletedPaths.isEmpty, "a live sibling's claim was deleted")
    }

    func testAnAbandonedStartIsKeptWhileItsResearchDocSaysQueued() async {
        // Park a run, wake the workers from the phone, boot days later: the naive sweep deletes the
        // run the owner is waiting on.
        let transport = FakeTransport()
        transport.document = ["status": .string("queued")]
        transport.queue = [startDoc(ageMillis: RunQueuePolicy.abandonedMaxMillis + 60_000)]
        let (b, _) = backend(transport)

        await b.pollQueue()

        XCTAssertTrue(transport.deletedPaths.isEmpty, "a run still marked queued was deleted")
    }

    func testAnAbandonedStartIsDeletedOnceItsResearchIsNoLongerQueued() async {
        let transport = FakeTransport()
        transport.document = ["status": .string("stopped")]
        transport.queue = [startDoc(ageMillis: RunQueuePolicy.abandonedMaxMillis + 60_000)]
        let (b, _) = backend(transport)

        await b.pollQueue()

        XCTAssertEqual(transport.deletedPaths, ["devices/dev-1/queue/q1"])
    }

    func testAnAbandonedStartIsKEPTWhenTheHealthReadFAILS() async {
        // Never destroy work on a transient. A read that blipped is not evidence the owner moved
        // on, and the queue document is the parked run's only claim ticket.
        let transport = FakeTransport()
        transport.queue = [startDoc(ageMillis: RunQueuePolicy.abandonedMaxMillis + 60_000)]
        transport.readError = IntakeBoom()
        let (b, _) = backend(transport)

        await b.pollQueue()

        XCTAssertTrue(transport.deletedPaths.isEmpty,
                      "queued work was deleted because a read failed")
    }

    func testAProcessedEntryIsNeitherClaimedNorDeleted() async {
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc(extra: ["processed": .boolean(true)])]
        let (b, spy) = backend(transport)

        await b.pollQueue()

        XCTAssertTrue(transport.conditionalPatches.isEmpty)
        XCTAssertTrue(transport.deletedPaths.isEmpty)
        XCTAssertTrue(spy.launched.isEmpty)
    }

    func testAnUnpairedDeviceDoesNotPollAtAll() async {
        let transport = FakeTransport()
        var s = DeviceIdentityStore(); s.fallbackDirectory = tempDir; s.clear()
        let b = DeviceBackend(transport: transport, store: s,
                              workers: WorkerRegistry(storage: InMemoryWorkerStorage()))

        await b.pollQueue()

        XCTAssertTrue(transport.listedPaths.isEmpty)
    }
}

extension RunIntakeTests {

    func testTheLauncherSurvivesTheCallerGoingOutOfScope() async {
        // ⚠ A weakly-held launcher deallocates the moment the caller's local goes out of scope, so
        // `pollQueue` claims a run, calls through a nil reference, and the run silently never
        // starts — while the claim STAYS on the queue document, so the next backend to look treats
        // it as someone else's work. Held strongly, this passes.
        let transport = FakeTransport()
        transport.document = [:]
        transport.queue = [startDoc()]

        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        s.save(deviceID: "dev-1", pollSecret: "secret", refreshToken: "refresh-abc")
        let registry = WorkerRegistry(storage: InMemoryWorkerStorage())
        let backend = DeviceBackend(transport: transport, store: s, workers: registry)

        // The spy is created and released inside this scope on purpose.
        var launched = 0
        do {
            let spy = SpyLauncher()
            backend.launcher = spy
            _ = spy   // the local dies here
        }
        await backend.pollQueue()
        await backend.awaitRunInFlight()
        if let spy = backend.launcher as? SpyLauncher { launched = spy.launched.count }

        XCTAssertEqual(launched, 1, "the launcher was released before the run could start")
    }
}

/// What the web app puts ON the queue document, and what the device does with it.
final class RunQueueDecodeTests: XCTestCase {

    private func doc(_ fields: [String: FirestoreValue]) -> FirestoreREST.ListedDocument {
        var all = fields
        all["action"] = .string("start")
        return FirestoreREST.ListedDocument(
            id: "q1", fields: all, updateTime: "2026-08-12T00:00:00Z"
        )
    }

    func testTheOWNERSOwnBriefIsCarriedThrough() throws {
        // ⭐ A supported flow, not a test affordance: the web app's start payload carries
        // `briefText` for the case where the owner pastes their own brief and P1 is skipped.
        // Dropping it makes the device spend a P1 re-deriving a brief that already exists, then
        // answer a subtly different question from the one that was asked.
        let entry = try XCTUnwrap(QueueEntry.decode(doc(["briefText": .string("my own brief")])))
        XCTAssertEqual(entry.briefText, "my own brief")
    }

    func testAnAbsentBriefIsEmptyAndNotNil() throws {
        let entry = try XCTUnwrap(QueueEntry.decode(doc([:])))
        XCTAssertEqual(entry.briefText, "")
    }

    func testThePodcastLengthIsReadFromTheNestedCONFIG() throws {
        // ⚠ Nested inside `config`, not top level. Reading it from the top finds nothing and falls
        // back silently — the same outcome as never reading it, and indistinguishable from an owner
        // who chose no length.
        let entry = try XCTUnwrap(QueueEntry.decode(
            doc(["config": .map(["podcastLength": .string("short")])])
        ))
        XCTAssertEqual(entry.podcastLength, "short")
    }

    func testAnEmptyLengthIsTreatedAsUNSET() throws {
        // Firestore hands back "" for a field the frontend created and never filled; taking it
        // literally gives the resolver a value it cannot parse and loses the fallback's reason.
        let entry = try XCTUnwrap(QueueEntry.decode(
            doc(["config": .map(["podcastLength": .string("")])])
        ))
        XCTAssertNil(entry.podcastLength)
    }

    func testNoConfigAtAllIsNotAFailureToDecode() throws {
        let entry = try XCTUnwrap(QueueEntry.decode(doc([:])))
        XCTAssertNil(entry.podcastLength)
    }
}
