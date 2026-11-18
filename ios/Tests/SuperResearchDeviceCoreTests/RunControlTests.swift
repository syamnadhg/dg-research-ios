import XCTest

@testable import SuperResearchDeviceCore

final class SpyController: RunController, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []

    func stopRun(researchID: String) async { record("stop:\(researchID)") }
    func pauseRun(researchID: String) async { record("pause:\(researchID)") }
    func resumeRun(researchID: String) async { record("resume:\(researchID)") }

    private func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
}

/// Stop, Pause and Resume for a run already in flight — the channel the web app's Stop button
/// actually writes to, and the one the recipe listed as a queue action that does not exist.
final class RunControlTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        var s = DeviceIdentityStore(); s.fallbackDirectory = tempDir; s.clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func backend(_ transport: FakeTransport) -> (DeviceBackend, SpyController) {
        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        s.save(deviceID: "dev-1", pollSecret: "secret", refreshToken: "refresh-abc")
        let b = DeviceBackend(transport: transport, store: s,
                              workers: WorkerRegistry(storage: InMemoryWorkerStorage()))
        let spy = SpyController()
        b.controller = spy
        b.activeRuns[1] = (uid: "owner-1", researchID: "res-1")
        return (b, spy)
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func cmd(
        _ action: String, id: String = "c1", ageMillis: Int64 = 1_000,
        extra: [String: FirestoreValue] = [:]
    ) -> FirestoreREST.ListedDocument {
        var fields: [String: FirestoreValue] = [
            "action": .string(action),
            "timestamp": .integer(now() - ageMillis),
            "command_id": .string("nonce-\(id)"),
        ]
        fields.merge(extra) { _, new in new }
        return FirestoreREST.ListedDocument(id: id, fields: fields)
    }

    // MARK: - The right collection

    func testTheRunsOwnCommandCollectionIsPolled() async {
        let transport = FakeTransport()
        let (b, _) = backend(transport)

        await b.pollRunCommands()

        XCTAssertTrue(transport.listedPaths.contains("users/owner-1/researches/res-1/commands"),
                      "the run-control channel was never read; saw \(transport.listedPaths)")
    }

    func testNothingIsPolledWhenThisDeviceIsRunningNothing() async {
        let transport = FakeTransport()
        let (b, _) = backend(transport)
        b.activeRuns = [:]

        await b.pollRunCommands()

        XCTAssertTrue(transport.listedPaths.isEmpty)
    }

    // MARK: - Executing

    func testAFreshStopREACHESTheRun() async {
        let transport = FakeTransport()
        transport.commands = [cmd("stop")]
        let (b, spy) = backend(transport)

        await b.pollRunCommands()

        XCTAssertEqual(spy.calls, ["stop:res-1"])
    }

    func testPauseAndResumeBothReachTheRun() async {
        let transport = FakeTransport()
        transport.commands = [cmd("pause", id: "c1"), cmd("resume", id: "c2")]
        let (b, spy) = backend(transport)

        await b.pollRunCommands()

        XCTAssertEqual(spy.calls, ["pause:res-1", "resume:res-1"])
    }

    func testACommandIsAckedBEFOREItRuns() async {
        // `stop` tears down the loop this code runs in. Acking afterwards means a crash mid-handler
        // leaves a command that re-executes on every poll for the life of the run.
        let transport = FakeTransport()
        transport.commands = [cmd("stop")]
        let (b, _) = backend(transport)

        await b.pollRunCommands()

        XCTAssertEqual(transport.docPatches.first?.path,
                       "users/owner-1/researches/res-1/commands/c1")
        XCTAssertEqual(transport.docPatches.first?.set["processed"], .boolean(true))
        XCTAssertEqual(transport.deletedPaths, ["users/owner-1/researches/res-1/commands/c1"])
    }

    func testAnAlreadyProcessedCommandIsNotRunAgain() async {
        let transport = FakeTransport()
        transport.commands = [cmd("stop", extra: ["processed": .boolean(true)])]
        let (b, spy) = backend(transport)

        await b.pollRunCommands()

        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testAnUnsupportedActionIsAckedOnceRatherThanRetriedForever() async {
        let transport = FakeTransport()
        transport.commands = [cmd("teleport")]
        let (b, spy) = backend(transport)

        await b.pollRunCommands()

        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertEqual(transport.deletedPaths.count, 1, "an unknown action was left to re-deliver")
    }

    // MARK: - ⭐ The staleness gate, which is first-poll ONLY

    func testAPreviousSESSIONSStopIsAckedButNOTRun() async {
        // Every pre-existing document arrives at once on first read. A previous session's
        // unprocessed stop would otherwise kill a run seconds after this device came back.
        let transport = FakeTransport()
        transport.commands = [cmd("stop", ageMillis: RunControlPolicy.staleMillis + 5_000)]
        let (b, spy) = backend(transport)

        await b.pollRunCommands()

        XCTAssertTrue(spy.calls.isEmpty, "a stale command from a previous session executed")
        XCTAssertEqual(transport.docPatches.first?.set["staleSkipped"], .boolean(true))
    }

    func testAnOldLOOKINGLIVECommandSTILLEXECUTES() async throws {
        // ⚠⚠ The regression this exists to prevent, and it is the opposite mistake: `timestamp` is
        // written by the BROWSER's clock. Applying the staleness gate to live commands discards the
        // owner's clicks on any clock skew — leaving a run stuck on pause after they pressed
        // Resume, with nothing anywhere saying why.
        let transport = FakeTransport()
        transport.commands = []
        let (b, spy) = backend(transport)

        await b.pollRunCommands()                    // first poll: attaches, sees nothing
        transport.commands = [cmd("resume", ageMillis: RunControlPolicy.staleMillis + 600_000)]
        await b.pollRunCommands()                    // live delivery, ten minutes "old"

        XCTAssertEqual(spy.calls, ["resume:res-1"],
                       "a live command was discarded as stale because of clock skew")
    }

    func testTheSameCommandDeliveredTwiceRunsONCE() async {
        let transport = FakeTransport()
        transport.commands = [cmd("stop")]
        let (b, spy) = backend(transport)

        await b.pollRunCommands()
        await b.pollRunCommands()   // redelivered before the delete landed

        XCTAssertEqual(spy.calls, ["stop:res-1"])
    }

    // MARK: - The policy, directly

    func testADecisionIsAnsweredOnceEvenWhenTheNonceDiffers() {
        // The web app mints a fresh nonce per click, so two clicks on one alert card carry
        // different nonces and the same decision id. Keying on the nonce runs it twice.
        let first = RunCommandEntry(id: "a", command: .resume, commandID: "nonce-1",
                                    decisionID: "dec-9")
        let second = RunCommandEntry(id: "b", command: .resume, commandID: "nonce-2",
                                     decisionID: "dec-9")
        XCTAssertEqual(first.dedupeKey, second.dedupeKey)
        XCTAssertEqual(
            RunControlPolicy.decide(second, now: 0, isFirstPoll: false,
                                    alreadySeen: [first.dedupeKey]),
            .ignore
        )
    }

    func testTwoDIFFERENTCommandsAreNotCollapsedIntoOne() {
        // The dedupe must not be so eager that a genuine second command is swallowed.
        let pause = RunCommandEntry(id: "a", command: .pause, commandID: "nonce-1")
        let resume = RunCommandEntry(id: "b", command: .resume, commandID: "nonce-2")
        XCTAssertNotEqual(pause.dedupeKey, resume.dedupeKey)
        XCTAssertEqual(
            RunControlPolicy.decide(resume, now: 0, isFirstPoll: false,
                                    alreadySeen: [pause.dedupeKey]),
            .execute
        )
    }

    func testACommandWithNoIdentifiersAtAllStillDeduplicates() {
        let bare = RunCommandEntry(id: "doc-7", command: .stop)
        XCTAssertEqual(bare.dedupeKey, "doc:doc-7")
    }

    func testTheStaleBoundaryIsNotOffByOne() {
        let entry = RunCommandEntry(id: "a", command: .stop,
                                    timestampMillis: 1_000_000 - RunControlPolicy.staleMillis)
        XCTAssertEqual(
            RunControlPolicy.decide(entry, now: 1_000_000, isFirstPoll: true, alreadySeen: []),
            .execute, "exactly at the bound is still live"
        )
    }

    func testACommandWithNoTimestampIsNotSweptAsStale() {
        // Age unknown is not age infinite. Acking a stop the owner just pressed because its
        // timestamp was missing is the same class of failure as the clock-skew one.
        let entry = RunCommandEntry(id: "a", command: .stop, timestampMillis: 0)
        XCTAssertEqual(
            RunControlPolicy.decide(entry, now: 9_999_999, isFirstPoll: true, alreadySeen: []),
            .execute
        )
    }

    func testTheSeenSetIsBOUNDED() {
        // This poller lives for the whole run; an unbounded set grows with every click.
        var seen: [String] = []
        for i in 0..<500 { RunControlPolicy.remember("k\(i)", in: &seen, limit: 200) }
        XCTAssertEqual(seen.count, 200)
        XCTAssertEqual(seen.first, "k300", "the OLDEST entries must be the ones dropped")
        XCTAssertEqual(seen.last, "k499")
    }
}
