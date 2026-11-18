import XCTest
@testable import SuperResearchDeviceCore

/// The FE→device direction, which did not exist.
///
/// ⛔ **The web app parks a worker by writing `restingWorkerIds` straight onto `devices/{id}`** — a
/// whole array of numbers, no command document, nothing addressed to this device. So the only way
/// the phone can learn about it is by reading that document again. It never did: `refresh()` runs on
/// explicit actions only. The device→web direction always worked (the device writes the field and
/// the web app has a live listener), which is exactly what made this look like a one-way bug rather
/// than a missing read.
final class RestSyncTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-rest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        var s = DeviceIdentityStore(); s.fallbackDirectory = tempDir; s.clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func backend(_ transport: FakeTransport) -> DeviceBackend {
        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        s.save(deviceID: "dev-1", pollSecret: "secret", refreshToken: "refresh-abc")
        return DeviceBackend(transport: transport, store: s,
                             workers: WorkerRegistry(storage: InMemoryWorkerStorage()))
    }

    // MARK: - Reading what the web app wrote

    /// The web app writes plain NUMBERS. Parsing only strings is the historical trap, and it made a
    /// worker parked from the web app render awake on the phone — so tapping the pill "woke" a
    /// worker that was already awake.
    func testAWorkerPARKEDFromTheWebAppIsReadBackAsResting() async {
        let transport = FakeTransport()
        transport.document = [
            "pairConfirmedAt": .integer(1),
            "restingWorkerIds": .array([.integer(2)]),
        ]

        let snapshot = await backend(transport).loadSnapshot()

        XCTAssertEqual(snapshot.restingWorkerIDs, [2])
    }

    /// ⭐ **The push is what makes the read happen at all.** Without a channel the device reads the
    /// document only when the owner taps something on the phone — which is precisely the situation
    /// the owner is not in when they park a worker from their laptop.
    func testTheBEATPushesASnapshotSoAWebAppChangeArrivesUnprompted() async {
        let transport = FakeTransport()
        transport.document = [
            "pairConfirmedAt": .integer(1),
            "restingWorkerIds": .array([.integer(1)]),
        ]
        let device = backend(transport)
        var pushed: [DeviceSnapshot] = []
        device.onSnapshot = { pushed.append($0) }

        await device.beatOnceForTesting()

        XCTAssertEqual(pushed.count, 1, "the beat published no snapshot")
        XCTAssertEqual(pushed.first?.restingWorkerIDs, [1])
    }

    // MARK: - The beat says what it read, every tick

    /// ⛔ **EVERY tick, not only when something changed.** The change-only line reads well and is
    /// useless in the exact situation it exists for: the owner parks a worker on their laptop, the
    /// phone does not move, and silence cannot say whether the beat is dead, the read failed, or the
    /// document is genuinely unchanged. Two beats over an unchanged document must produce two lines.
    func testTheBeatLogsItsSTATEOnEveryTickEvenWhenNothingChanged() async {
        let transport = FakeTransport()
        transport.document = [
            "pairConfirmedAt": .integer(1),
            "status": .string("active"),
            "restingWorkerIds": .array([.integer(2)]),
        ]
        let device = backend(transport)
        device.onSnapshot = { _ in }
        var lines: [String] = []
        device.beatLogger = { lines.append($0) }

        await device.beatOnceForTesting()
        await device.beatOnceForTesting()

        XCTAssertEqual(lines.count, 2, "the beat only speaks up when something changes: \(lines)")
        XCTAssertTrue(lines.allSatisfy { $0.contains("resting=[2]") }, "\(lines)")
    }

    /// The line has to carry the DOCUMENT's resting set — the phone's own copy would answer "did the
    /// web app's write arrive" with the phone's own belief and read as a confirmation.
    func testTheBeatLineNamesTheRestingSetTheDocumentReported() {
        var snapshot = DeviceSnapshot()
        snapshot.online = true
        snapshot.restingWorkerIDs = [3, 1]
        snapshot.busyWorkerIDs = [2]

        let line = DeviceBackend.beatSummary(snapshot: snapshot, workerCount: 4)

        XCTAssertTrue(line.contains("resting=[1, 3]"), line)
        XCTAssertTrue(line.contains("busy=[2]"), line)
        XCTAssertTrue(line.contains("workers=4"), line)
        XCTAssertTrue(line.contains("doc=ok"), line)
    }

    /// ⭐ **The `workers` MAP and `busyWorkerIds` are different fields, and the web app trusts the
    /// map.** A worker listed in the map renders as a busy pill in the Shared-with popup, and a busy
    /// pill is given no click handler at all — so a stale entry silently disables the owner's rest
    /// toggle in the browser while the phone, which reads the other field, shows that same worker
    /// idle and toggles it happily. One line has to carry both or the asymmetry cannot be seen.
    func testTheBeatLineSeparatesTheRunMAPFromTheBusySet() {
        var snapshot = DeviceSnapshot()
        snapshot.online = true
        snapshot.busyWorkerIDs = []
        snapshot.workers = [
            WorkerState(id: "1", uid: "someone", title: "t", phase: 1, totalPhases: 4),
            WorkerState(id: "2", uid: nil, title: nil, phase: nil, totalPhases: nil),
        ]

        let line = DeviceBackend.beatSummary(snapshot: snapshot, workerCount: 2)

        XCTAssertTrue(line.contains("busy=[]"), line)
        XCTAssertTrue(line.contains("runMap=[\"1\"]"),
                      "a worker the web app would render as busy is not on the line: \(line)")
    }

    /// The owner is on the line because every owner-only control in the web app is gated on
    /// `ownerUid === user.uid`, and a false comparison there renders controls with NO handler —
    /// silently. Truncated: it is a real account identifier in a log the owner shares.
    func testTheBeatLineNamesTheOWNERButOnlyItsPrefix() async {
        let transport = FakeTransport()
        transport.document = [
            "pairConfirmedAt": .integer(1),
            "status": .string("active"),
            "ownerUid": .string("abcdefghijklmnop"),
        ]
        let device = backend(transport)
        device.onSnapshot = { _ in }
        var lines: [String] = []
        device.beatLogger = { lines.append($0) }

        await device.beatOnceForTesting()

        XCTAssertTrue(lines.first?.contains("owner=abcdefgh") == true, "\(lines)")
        XCTAssertFalse(lines.first?.contains("ijklmnop") == true,
                       "the whole account identifier was written to the log: \(lines)")
    }

    /// ⚠ WHICH device document this is, truncated. A re-pair leaves the old tile on the Account page
    /// under the same `UIDevice.name`, so two tiles look identical in the browser and only one is
    /// live — a toggle on the dead one writes a document nothing reads.
    func testTheBeatLineNamesWHICHDeviceDocumentItRead() {
        var snapshot = DeviceSnapshot()
        snapshot.online = true
        snapshot.deviceID = "0123456789abcdef"

        let line = DeviceBackend.beatSummary(snapshot: snapshot, workerCount: 1)

        XCTAssertTrue(line.contains("device=01234567"), line)
        XCTAssertFalse(line.contains("89abcdef"), "the whole device id was written to the log: \(line)")
    }

    /// A document with no owner says so, rather than rendering an empty string that reads as a
    /// truncation bug.
    func testAMissingOwnerIsNamedRatherThanBlank() {
        var snapshot = DeviceSnapshot()
        snapshot.online = true

        XCTAssertTrue(DeviceBackend.beatSummary(snapshot: snapshot, workerCount: 1)
            .contains("owner=none"))
    }

    /// ⚠ An unreadable tick returns empty sets, which is indistinguishable from a quiet device
    /// unless the line says which one it was — and "resting=[] " on a failed read is precisely the
    /// evidence that would be misread as "the web app never wrote it".
    func testAnUNREADABLETickIsNamedAsSuchRatherThanReadingAsAQuietDevice() {
        var snapshot = DeviceSnapshot()
        snapshot.online = false

        let line = DeviceBackend.beatSummary(snapshot: snapshot, workerCount: 1)

        XCTAssertFalse(line.contains("doc=ok"), "a failed read claimed the document was fine: \(line)")
        XCTAssertTrue(line.contains("unreadable"), line)
    }

    /// ⛔ **The round trip, because the arithmetic alone proves nothing.** A test that builds the
    /// snapshot by hand passes whether or not the device ever PUBLISHES a start time — mutation
    /// showed exactly that: deleting the `startedAt` write left this suite green. The map is the
    /// only channel between the run and the screen, so the write has to be asserted on the wire.
    func testTheDeviceWritesTheStartStampIntoTheWorkersMap() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .integer(1), "status": .string("active")]
        let device = backend(transport)
        device.onSnapshot = { (_: DeviceSnapshot) in }
        LiveRunActivity.shared.startRun(
            worker: 1, uid: "owner-1", title: "t", researchID: "res-1",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        defer { LiveRunActivity.shared.endRun(worker: 1) }

        await device.beatOnceForTesting()

        let published = transport.docPatches.last { (patch: (path: String, set: [String: FirestoreValue])) in
            patch.set["workers"] != nil
        }
        guard case .map(let map)? = published?.set["workers"],
              case .map(let entry)? = map["1"]
        else { return XCTFail("no worker entry was published: \(transport.docPatches.map(\.path))") }
        XCTAssertEqual(entry["startedAt"], .integer(1_700_000_000_000),
                       "the map carries no start time, so the clock counts from nothing")
    }

    // MARK: - A dropped read is not an unpairing

    /// ⛔ **This is what made a periodic refresh dangerous, and the code said the opposite of its own
    /// comment.** `paired` is false on a fresh snapshot, so every non-404 read failure returned an
    /// UNPAIRED one — and unpaired is destructive rather than cosmetic: the root screen swaps to "No
    /// user paired" and every open sheet is force-closed. Harmless while nothing refreshed on a
    /// timer; on a 20-second beat, one tunnel throws the owner out of whatever they were doing.
    func testAnUNREADABLEDocumentReportsOFFLINEAndSTILLPAIRED() async {
        let transport = FakeTransport()
        transport.readError = URLError(.notConnectedToInternet)

        let snapshot = await backend(transport).loadSnapshot()

        XCTAssertTrue(snapshot.paired, "a dropped read was reported as an unpairing")
        XCTAssertFalse(snapshot.online, "an unreadable device must not claim to be online")
    }

    /// ...but a document that really says "not paired" still unpairs. The downgrade has to come from
    /// the DOCUMENT, never from the transport.
    func testADocumentWithNoPairConfirmationDOESReportUnpaired() async {
        let transport = FakeTransport()
        transport.document = [:]

        let snapshot = await backend(transport).loadSnapshot()
        XCTAssertFalse(snapshot.paired)
    }

    // MARK: - Ordering

    /// ⛔ Completion order is not issue order. A beat load issued before the owner's toggle can land
    /// after that toggle's own refresh, and a bare assignment would put the stale value back.
    func testAnOLDERSnapshotIsNotAllowedToReplaceANewerOne() {
        XCTAssertTrue(SnapshotOrdering.shouldApply(incoming: 5, applied: 4))
        XCTAssertFalse(SnapshotOrdering.shouldApply(incoming: 3, applied: 4),
                       "a stale read was allowed to revert the screen")
        XCTAssertFalse(SnapshotOrdering.shouldApply(incoming: 4, applied: 4),
                       "the same read applied twice costs a needless invalidation")
    }

    /// ⚠ Zero means "unsequenced" — `DeviceSnapshot.unpaired` and test fixtures carry it. Treating
    /// those as stale would make the one snapshot that must always land — the unpaired one, which is
    /// how the UI learns the device was reset — the only one that never does.
    func testAnUNSEQUENCEDSnapshotAlwaysApplies() {
        XCTAssertTrue(SnapshotOrdering.shouldApply(incoming: 0, applied: 99))
    }

    /// The stamp is taken when the load STARTS, so two loads are ordered by issue rather than by
    /// whichever network round trip happened to finish first.
    func testEachLoadCarriesAStrictlyIncreasingStamp() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .integer(1)]
        let device = backend(transport)

        let first = await device.loadSnapshot()
        let second = await device.loadSnapshot()

        XCTAssertGreaterThan(second.sequence, first.sequence)
        XCTAssertGreaterThan(first.sequence, 0, "an unstamped load can never be ordered")
    }
}

/// The elapsed clock in Browser watch, which never moved.
final class RunElapsedTests: XCTestCase {

    private func snapshot(startedAtMillis: Int64) -> DeviceSnapshot {
        var s = DeviceSnapshot()
        s.workerCount = 1
        s.workers = [WorkerState(id: "1", uid: "owner", title: "t", phase: 2, totalPhases: 6,
                                 startedAtMillis: startedAtMillis)]
        return s
    }

    /// ⛔ **Stuck at 00:00 for every live run.** The per-worker snapshot was built with
    /// `elapsedSeconds: 0` — a literal, because the `workers` map carried no start time — so the one
    /// number the clock exists to show was hard-coded to nothing. Beside a run that is genuinely
    /// working, a clock that never moves reads as a frozen app.
    func testAWorkersRunReportsTheTimeSinceItSTARTED() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let run = snapshot(startedAtMillis: Int64(started.timeIntervalSince1970 * 1000))
            .run(forWorker: 1, now: started.addingTimeInterval(125))

        XCTAssertEqual(run?.elapsedSeconds, 125)
    }

    /// ...and the START STAMP travels with it, because the screen ticks locally: a clock redrawn
    /// only when a snapshot lands would move in twenty-second steps, which is broken differently.
    func testTheRunCarriesItsStartStampSoTheScreenCanTickBetweenBeats() {
        let run = snapshot(startedAtMillis: 1_700_000_000_000).run(forWorker: 1)
        XCTAssertEqual(run?.startedAtMillis, 1_700_000_000_000)
    }

    /// ⚠ An unknown stamp is zero, not a count since 1970. Older documents have no `startedAt`, and
    /// rendering 480,000 minutes for them would look like a different fault entirely.
    func testAnUNKNOWNStartStampReadsAsZeroRatherThanFifty_Years() {
        XCTAssertEqual(RunState.elapsed(since: 0, now: Date(timeIntervalSince1970: 1_700_000_000)), 0)
    }

    /// ⚠ And a FUTURE stamp floors at zero rather than going negative: the phone's clock and the
    /// server's disagree by a second or two routinely, and "-2" reads as a bug in something else.
    func testAFUTUREStampFloorsAtZeroInsteadOfCountingBackwards() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RunState.elapsed(since: 1_000_030_000, now: now), 0)
    }
}
