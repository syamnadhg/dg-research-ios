import XCTest
@testable import SuperResearchDeviceCore

/// Two runs, two workers, and the control channel that used to reach only one of them.
///
/// ⛔ **The device advertises one worker per browser profile and the owner can add profiles.** So a
/// second run is genuinely claimable — and everything that tracked "the run" was a single field.
/// The second claim overwrote it, and the first run kept going invisibly: its command subcollection
/// was no longer polled, so the owner's Stop reached nothing, and a backend reset could kill only
/// one of the two. Advertising capacity that cannot be tracked is the same defect the desktop
/// backend fixed by publishing what it can actually run; the answer here is to make it true.
final class ConcurrentRunsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-concurrent-\(UUID().uuidString)")
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
        return (b, spy)
    }

    private func command(
        id: String, command: String, millis: Int64
    ) -> FirestoreREST.ListedDocument {
        FirestoreREST.ListedDocument(
            id: id,
            fields: [
                "action": .string(command),
                "timestamp": .integer(millis),
                "command_id": .string("nonce-\(id)"),
            ],
            updateTime: "t"
        )
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// ⛔ **The headline.** Stop on the run occupying worker 2 must stop THAT run — with a single
    /// active-run field it stopped whichever run was claimed last, or nothing at all.
    func testSTOPReachesTheRunItWasWrittenForWhenTwoAreInFlight() async {
        let transport = FakeTransport()
        let (b, spy) = backend(transport)
        b.activeRuns[1] = (uid: "owner-1", researchID: "res-1")
        b.activeRuns[2] = (uid: "owner-1", researchID: "res-2")
        // ⛔ **A Stop in BOTH channels, and that is what makes this deterministic.** With one Stop,
        // a poll that reads only `activeRuns.first` passes or fails on Swift's per-process hash
        // seed: half the time `.first` IS the run under test, and the mutation proving this guard
        // reported MISSED for that reason. Two Stops means a single-run poll can only ever produce
        // one call, whichever run it picks.
        transport.commandsByPath["users/owner-1/researches/res-1/commands"] = [
            command(id: "c0", command: "stop", millis: now())
        ]
        transport.commandsByPath["users/owner-1/researches/res-2/commands"] = [
            command(id: "c1", command: "stop", millis: now())
        ]

        await b.pollRunCommands()

        // Sorted, because the dictionary's iteration order is not a promise the product makes.
        XCTAssertEqual(
            spy.calls.sorted(), ["stop:res-1", "stop:res-2"],
            "each Stop must reach the run it was written for — one call here means a run whose "
                + "command channel is never read, and nothing about that looks wrong from outside"
        )
    }

    /// Both subcollections are polled, not just one. A run whose commands are never READ is a run
    /// the owner cannot control, and nothing about it looks wrong from the outside.
    func testEVERYActiveRunsCommandChannelIsPolled() async {
        let transport = FakeTransport()
        let (b, _) = backend(transport)
        b.activeRuns[1] = (uid: "owner-1", researchID: "res-1")
        b.activeRuns[2] = (uid: "owner-2", researchID: "res-2")

        await b.pollRunCommands()

        XCTAssertTrue(transport.listedPaths.contains("users/owner-1/researches/res-1/commands"))
        XCTAssertTrue(transport.listedPaths.contains("users/owner-2/researches/res-2/commands"))
    }

    /// ⚠ **"First poll" is a fact about a RUN, not about the process.** It decides whether a command
    /// predates this session and must be acked rather than obeyed. A process-wide flag meant the
    /// second run skipped that check entirely — so a command left over from a previous session would
    /// execute against a brand-new run.
    func testTheSTALECheckIsAppliedToEachRunsFirstPollSeparately() async {
        let transport = FakeTransport()
        let (b, spy) = backend(transport)
        let ancient = now() - (48 * 60 * 60 * 1000)

        // Run 1 attaches first and has nothing waiting.
        b.activeRuns[1] = (uid: "owner-1", researchID: "res-1")
        await b.pollRunCommands()

        // Run 2 is claimed later, and its subcollection holds a command from a previous session.
        b.activeRuns[2] = (uid: "owner-1", researchID: "res-2")
        transport.commandsByPath["users/owner-1/researches/res-2/commands"] = [
            command(id: "old", command: "stop", millis: ancient)
        ]

        await b.pollRunCommands()

        XCTAssertEqual(spy.calls, [], "a previous session's Stop executed against a fresh run")
        XCTAssertTrue(
            transport.docPatches.contains {
                $0.path.hasSuffix("/res-2/commands/old")
                    && $0.set["staleSkipped"] == .boolean(true)
            },
            "the stale command was not acked as stale"
        )
    }

    /// ⛔ `dedupeKey` falls back to the DOCUMENT id, which is unique only inside one research's
    /// subcollection. Unscoped, one run's handled command marks a different run's identically-named
    /// command as already-seen — and that one is then silently never obeyed.
    func testTwoRunsWithIdenticallyNamedCommandsAreBothObeyed() async {
        let transport = FakeTransport()
        let (b, spy) = backend(transport)
        b.activeRuns[1] = (uid: "owner-1", researchID: "res-1")
        b.activeRuns[2] = (uid: "owner-1", researchID: "res-2")
        // Same document id, same nonce — what a frontend that derives ids from the ACTION produces.
        let shared = FirestoreREST.ListedDocument(
            id: "cmd", fields: ["action": .string("pause"), "timestamp": .integer(now())],
            updateTime: "t"
        )
        transport.commandsByPath["users/owner-1/researches/res-1/commands"] = [shared]
        transport.commandsByPath["users/owner-1/researches/res-2/commands"] = [shared]

        await b.pollRunCommands()

        XCTAssertEqual(Set(spy.calls), ["pause:res-1", "pause:res-2"],
                       "one run's command silenced the other's")
    }

    /// A run already in flight must never be handed out a second time — checked against EVERY active
    /// run, not just one. The zombie sweep is what would otherwise delete its queue document.
    func testAQueueEntryForANYRunInFlightIsLeftAlone() async {
        let transport = FakeTransport()
        let (b, _) = backend(transport)
        transport.document = [:]
        b.activeRuns[1] = (uid: "owner-1", researchID: "res-1")
        b.activeRuns[2] = (uid: "owner-1", researchID: "res-2")
        // Claimed long ago by "someone" — from the second beat on, our own claim looks exactly like
        // a dead sibling's, and the sweep would delete a run that is progressing perfectly well.
        transport.queue = [
            FirestoreREST.ListedDocument(
                id: "q2",
                fields: [
                    "action": .string("start"), "researchId": .string("res-2"),
                    "uid": .string("owner-1"), "assignedWorker": .integer(2),
                    "claimedAt": .integer(now() - 600_000),
                ],
                updateTime: "t"
            )
        ]

        await b.pollQueue()

        XCTAssertTrue(
            transport.deletedPaths.isEmpty,
            "the sweep deleted the queue entry of a run this device is still executing"
        )
    }
}
