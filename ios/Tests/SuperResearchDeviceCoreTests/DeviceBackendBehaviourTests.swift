import XCTest

@testable import SuperResearchDeviceCore

/// A transport that records what `DeviceBackend` actually asked it to do.
///
/// The whole point of extracting `DeviceTransport` was to make these observable. Before it,
/// `DeviceBackend` constructed a concrete `RESTPairingBackend` in its initialiser, so no test could
/// see the release path, the heartbeat, or the worker count it reported — which is how
/// `workerCount: 1` stayed hardcoded at two call sites, and how the unpair that only wrote
/// `status: "retired"` went unnoticed.
final class FakeTransport: DeviceTransport, @unchecked Sendable {
    var document: [String: FirestoreValue]?
    /// When set, `readDocument` throws it instead of returning. Models "offline" / "not signed in",
    /// which is a completely different thing from a 404 and must not be conflated with one.
    var readError: Error?

    private(set) var patches: [(deviceId: String, set: [String: Any], delete: [String])] = []
    private(set) var unpairCalls: [String] = []
    private(set) var restoredTokens: [String] = []
    var unpairResult: Result<String, Error> = .success("retired")
    var session: Bool = false
    var refreshToken: String? = "refresh-abc"

    var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    func initiatePair(secretHash: String) async throws -> InitiatePairResponse {
        InitiatePairResponse(deviceId: "dev-1", pairCode: "AAAA-BBBB")
    }
    /// When set, polling for the claim throws instead of returning nil.
    ///
    /// ⚠ Load-bearing for the cancel tests. `awaitClaim` polls every 2s for a FIFTEEN-MINUTE
    /// timeout, so a fake that simply returns nil forever makes the test hang for a quarter of an
    /// hour rather than fail — which is exactly what happened the first time these were written.
    /// Throwing reproduces the state a cancel-before-claim actually leaves behind (a device id and
    /// a secret, no session) and gets there immediately.
    var pollError: Error?

    func pollPending(deviceId: String, secretHash: String) async throws -> String? {
        if let pollError { throw pollError }
        return nil
    }
    func signIn(customToken: String) async throws { session = true }

    func patchDevice(deviceId: String, set: [String: Any], delete: [String]) async throws {
        patches.append((deviceId, set, delete))
    }

    func readDocument(path: String) async throws -> [String: FirestoreValue]? {
        if let readError { throw readError }
        return document
    }

    func unpairSelf(deviceId: String) async throws -> String {
        unpairCalls.append(deviceId)
        return try unpairResult.get()
    }

    private(set) var cancelPairCalls: [(deviceId: String, pollSecret: String)] = []
    var cancelPairResult: Result<String, Error> = .success("cancelled")

    func cancelPair(deviceId: String, pollSecret: String) async throws -> String {
        cancelPairCalls.append((deviceId, pollSecret))
        return try cancelPairResult.get()
    }

    func sessionRefreshToken() async -> String? { refreshToken }
    func restoreSession(refreshToken: String) async {
        restoredTokens.append(refreshToken)
        session = true
    }
    func hasSession() async -> Bool { session }
}

private struct Boom: Error {}

final class DeviceBackendBehaviourTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-backend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store().clear()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func store() -> DeviceIdentityStore {
        var s = DeviceIdentityStore()
        s.fallbackDirectory = tempDir
        return s
    }

    private func registry(workers: Int) -> WorkerRegistry {
        let r = WorkerRegistry(storage: InMemoryWorkerStorage())
        while r.count < workers { r.addWorker() }
        return r
    }

    /// A backend that believes it is already paired.
    private func paired(
        _ transport: FakeTransport, workers: Int = 1
    ) -> (DeviceBackend, DeviceIdentityStore) {
        let s = store()
        s.save(deviceID: "dev-1", pollSecret: "secret", refreshToken: "refresh-abc")
        return (
            DeviceBackend(transport: transport, store: s, workers: registry(workers: workers)),
            s
        )
    }

    // MARK: - ⭐ Unpair actually removes the device

    func testUnpairCallsTheServerRouteRatherThanWritingAStatusField() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport)

        let result = await backend.perform(try! XCTUnwrap(Operations.byID("unpair")))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(transport.unpairCalls, ["dev-1"],
                       "unpair-self is the ONLY route that can delete the device document")
        XCTAssertFalse(
            transport.patches.contains { ($0.set["status"] as? String) == "retired" },
            "writing status:retired is what the old unpair did, and no frontend code reads it — "
            + "the device tile stayed on the Account page forever"
        )
    }

    func testASuccessfulUnpairClearsTheLocalIdentity() async {
        let transport = FakeTransport()
        let (backend, identity) = paired(transport)

        _ = await backend.perform(try! XCTUnwrap(Operations.byID("unpair")))

        XCTAssertNil(identity.deviceID)
        XCTAssertNil(identity.refreshToken, "a stale session credential must not outlive the pair")
        let snapshot = await backend.loadSnapshot()
        XCTAssertFalse(snapshot.paired)
    }

    /// ⚠ The dangerous direction. Clearing local state after a FAILED unpair would leave a device
    /// that still exists on the server, still occupies the owner's slot, and can never be removed —
    /// because the credential authorising its removal is the thing we would have just deleted.
    func testAFailedUnpairKeepsTheIdentitySoItCanBeRetried() async {
        let transport = FakeTransport()
        transport.unpairResult = .failure(Boom())
        let (backend, identity) = paired(transport)

        let result = await backend.perform(try! XCTUnwrap(Operations.byID("unpair")))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(identity.deviceID, "dev-1", "the unpair must stay retry-able")
        XCTAssertNotNil(identity.refreshToken)
        XCTAssertTrue(result.message.contains("still paired"),
                      "the owner has to know the device was NOT released")
    }

    func testAnAlreadyDeletedDeviceCountsAsUnpairedRatherThanAsAFailure() async {
        let transport = FakeTransport()
        transport.unpairResult = .success("already-gone")
        let (backend, identity) = paired(transport)

        let result = await backend.perform(try! XCTUnwrap(Operations.byID("unpair")))

        XCTAssertTrue(result.ok, "the device being absent IS the goal")
        XCTAssertNil(identity.deviceID, "otherwise the local identity is stranded forever")
    }

    func testUnpairReArmsTheSessionFirstIfTheAppHasJustLaunched() async {
        let transport = FakeTransport()
        transport.session = false   // a relaunched app has no session
        let (backend, _) = paired(transport)

        _ = await backend.perform(try! XCTUnwrap(Operations.byID("unpair")))

        XCTAssertEqual(transport.restoredTokens, ["refresh-abc"],
                       "unpair is the operation most likely to be the first thing after a launch")
    }

    // MARK: - ⭐ A transient failure must not delete the pairing

    func testAThrownReadKeepsTheIdentityBecauseOfflineIsNotUnpaired() async throws {
        let transport = FakeTransport()
        transport.readError = Boom()
        let (backend, identity) = paired(transport)
        DeviceBackend.storedSupervised = true

        backend.resumeIfPaired()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            identity.deviceID, "dev-1",
            "`try?` used to flatten a thrown error into nil and the caller deleted the pairing — a "
            + "dropped connection at launch was enough to unpair the device permanently"
        )
    }

    /// ⚠ Launch re-arms the session BEFORE it probes. Without this the probe throws
    /// `notAuthenticated` every time, because `signIn` only ever runs during pairing — so a
    /// relaunched app can neither heartbeat nor unpair itself, and (before the `try?` fix) deleted
    /// its own pairing on the way past.
    func testResumeReArmsTheSessionBeforeProbingTheDocument() async throws {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        transport.session = false          // exactly what a relaunched app looks like
        let (backend, _) = paired(transport)
        DeviceBackend.storedSupervised = true

        backend.resumeIfPaired()
        try await Task.sleep(nanoseconds: 300_000_000)
        backend.stopHeartbeat()

        XCTAssertEqual(transport.restoredTokens, ["refresh-abc"],
                       "the persisted refresh token is the only credential a relaunch has")
    }

    func testAGenuine404DoesClearTheIdentity() async throws {
        let transport = FakeTransport()
        transport.document = nil      // getDocument returns nil ONLY for a real 404
        transport.readError = nil
        let (backend, identity) = paired(transport)

        backend.resumeIfPaired()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(identity.deviceID,
                     "a device document that is really gone leaves a worthless identity")
    }

    // MARK: - ⭐ On Startup governs whether the device serves

    func testAutostartOffMeansTheDeviceDoesNotComeOnlineByItself() async throws {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport)
        DeviceBackend.storedSupervised = false

        backend.resumeIfPaired()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(
            transport.patches.isEmpty,
            "the heartbeat used to start unconditionally, which made the On Startup toggle "
            + "decorative — the device came online whether or not it had been asked to"
        )
    }

    func testStartServingBringsANonSupervisedDeviceOnline() async throws {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport)
        DeviceBackend.storedSupervised = false

        let result = await backend.perform(try! XCTUnwrap(Operations.byID("serve")))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(result.ok)
        XCTAssertFalse(transport.patches.isEmpty, "Start serving must actually beat")
        backend.stopHeartbeat()
    }

    // MARK: - ⭐ The worker count that was hardcoded

    func testTheHeartbeatReportsTheRealWorkerCount() async throws {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport, workers: 3)
        DeviceBackend.storedSupervised = true

        backend.startHeartbeat()
        try await Task.sleep(nanoseconds: 300_000_000)
        backend.stopHeartbeat()

        let counts = transport.patches.compactMap { $0.set["workerCount"] as? Int }
        XCTAssertEqual(
            counts.first, 3,
            "this was the literal 1 at both the confirm and every beat, so the frontend sized the "
            + "whole capacity UI off a constant and handed the device one run at a time"
        )
    }

    // MARK: - Maintenance actually does something

    func testDoctorReportsFindingsRatherThanAVerdictAlone() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport)

        let result = await backend.perform(try! XCTUnwrap(Operations.byID("doctor")))
        let detail = try! XCTUnwrap(result.detail)

        XCTAssertTrue(detail.contains("Paired"))
        XCTAssertTrue(detail.contains("Session credential stored"))
        XCTAssertGreaterThan(detail.split(separator: "\n").count, 3,
                             "a doctor that names no findings cannot be acted on")
    }

    func testDoctorFlagsAnIdentityThatWouldNotSurviveRelaunch() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        // Paired in memory, but nothing on disk — exactly the state that lost the real pairing.
        let empty = store()
        empty.clear()
        let backend = DeviceBackend(
            transport: transport, store: empty, workers: registry(workers: 1)
        )
        _ = await backend.perform(try! XCTUnwrap(Operations.byID("unpair")))  // no-op, not paired

        let result = await backend.perform(try! XCTUnwrap(Operations.byID("doctor")))
        XCTAssertFalse(result.ok, "an unpaired device is a finding, not a clean bill of health")
    }

    func testClearStateDropsRunCachesAndLeavesLoginsAlone() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport)

        let result = await backend.perform(try! XCTUnwrap(Operations.byID("clear")))

        XCTAssertTrue(result.ok)
        let patch = try! XCTUnwrap(transport.patches.last)
        XCTAssertNotNil(patch.set["workers"])
        XCTAssertNotNil(patch.set["queueOwners"])
        XCTAssertNil(patch.set["logins"], "Clear state must not sign the device out of anything")
        XCTAssertNil(patch.set["pairConfirmedAt"], "nor unpair it")
    }

    func testVersionReportsSomethingOnTap() async {
        let transport = FakeTransport()
        let (backend, _) = paired(transport)
        let result = await backend.perform(try! XCTUnwrap(Operations.byID("version")))
        XCTAssertTrue(result.ok)
        XCTAssertNotNil(result.detail, "the owner asked that Version show the version on tap")
    }

    // MARK: - Worker rest

    func testRestingAWorkerWritesTheWholeArrayAndPrunesOutOfRangeIDs() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport, workers: 2)

        // "9" is past capacity — a worker parked and then removed. Left in place, nothing could ever
        // un-park it, because there is no pill to tap.
        let result = await backend.setWorkerResting(1, resting: true, current: ["9"])

        XCTAssertTrue(result.ok)
        let written = try! XCTUnwrap(transport.patches.last?.set["restingWorkerIds"] as? [String])
        XCTAssertEqual(written, ["1"])
    }

    func testWakingAWorkerRemovesItFromTheList() async {
        let transport = FakeTransport()
        transport.document = ["pairConfirmedAt": .boolean(true)]
        let (backend, _) = paired(transport, workers: 2)

        _ = await backend.setWorkerResting(2, resting: false, current: ["1", "2"])

        let written = try! XCTUnwrap(transport.patches.last?.set["restingWorkerIds"] as? [String])
        XCTAssertEqual(written, ["1"])
    }

    /// ⚠ Clear state's payload has to survive the REAL wire conversion, which the fake never runs.
    ///
    /// `testClearStateDropsRunCachesAndLeavesLoginsAlone` asserts what the transport was handed —
    /// and the fake stores `[String: Any]` verbatim. In production those values go through
    /// `FirestoreValue.from` on the way to `patchDocument`, and an empty map or array taking the
    /// `default:` branch would be silently serialised as the STRING "[]" rather than as an empty
    /// collection. The write would be accepted and the caches would never clear. Asserting the
    /// mechanism, not just the call.
    func testClearStatesEmptyCollectionsSurviveTheWireConversion() {
        XCTAssertEqual(FirestoreValue.from([String: Any]()), .map([:]),
                       "an empty `workers` map must stay a map")
        XCTAssertEqual(FirestoreValue.from([Any]()), .array([]),
                       "an empty `busyWorkerIds` array must stay an array")
    }

    // MARK: - ⭐ Cancelling a pair must leave nothing behind

    /// A pair that never reached a session cannot authenticate anything, so it proves ownership with
    /// the poll secret instead. This is the common case: the owner taps Cancel on the code screen.
    func testCancelBeforeTheClaimUsesTheSecretRatherThanASession() async {
        let transport = FakeTransport()
        transport.session = false
        let store = self.store()
        store.clear()
        let backend = DeviceBackend(
            transport: transport, store: store, workers: registry(workers: 1)
        )

        transport.pollError = Boom()          // the claim never lands; the owner taps Cancel
        _ = await backend.startPairing(onCode: { _, _ in }, onClaimed: {})
        await backend.abandonPairing()

        XCTAssertEqual(transport.cancelPairCalls.count, 1,
                       "initiate-pair also mints a synthetic Auth user and a secrets entry, and a "
                       + "Firestore TTL sweep can reach NEITHER — waiting for expiry leaks both")
        XCTAssertEqual(transport.cancelPairCalls.first?.deviceId, "dev-1")
        XCTAssertFalse(transport.cancelPairCalls.first?.pollSecret.isEmpty ?? true,
                       "the secret IS the proof; an empty one would 403")
        XCTAssertTrue(transport.unpairCalls.isEmpty,
                      "unpair-self needs a session this device does not have")
    }

    /// Past the exchange the device is a real authenticated principal, and `cancel-pair` refuses a
    /// claimed device by design — so the other route is the correct one.
    func testCancelAfterTheExchangeUsesUnpairSelf() async {
        let transport = FakeTransport()
        let (backend, _) = paired(transport)
        transport.session = true

        await backend.abandonPairing()

        XCTAssertEqual(transport.unpairCalls, ["dev-1"])
        XCTAssertTrue(transport.cancelPairCalls.isEmpty,
                      "cancel-pair refuses a claimed device; calling it would just 409")
    }

    func testCancellingTwiceIsHarmless() async {
        let transport = FakeTransport()
        transport.session = false
        let store = self.store()
        store.clear()
        let backend = DeviceBackend(
            transport: transport, store: store, workers: registry(workers: 1)
        )
        transport.pollError = Boom()
        _ = await backend.startPairing(onCode: { _, _ in }, onClaimed: {})

        await backend.abandonPairing()
        await backend.abandonPairing()

        XCTAssertEqual(transport.cancelPairCalls.count, 1,
                       "the second cancel has no device left to abandon and must not re-send")
    }

    /// ⚠ A failed cleanup must not trap the owner in a flow they asked to leave.
    /// ⚠ A 409 means the pair actually SUCCEEDED while the owner was reaching for Cancel. The
    /// endpoint refuses a claimed device on purpose — that refusal is what bounds an unauthenticated
    /// route to devices nobody has adopted. Treating it as a failure would log an error for the one
    /// outcome that is not one, and invite a retry that can never succeed.
    func testA409IsTreatedAsHavingPairedRatherThanAsAFailure() async {
        let transport = FakeTransport()
        transport.session = false
        transport.cancelPairResult = .failure(FirestoreRESTError.http(status: 409, body: ""))
        let store = self.store()
        store.clear()
        let backend = DeviceBackend(
            transport: transport, store: store, workers: registry(workers: 1)
        )
        transport.pollError = Boom()
        _ = await backend.startPairing(onCode: { _, _ in }, onClaimed: {})

        await backend.abandonPairing()

        XCTAssertEqual(transport.cancelPairCalls.count, 1)
        XCTAssertTrue(transport.unpairCalls.isEmpty, "a 409 must not escalate to a second route")
    }

    /// ⚠ A 404 must NOT read as success, and the reason is live right now: the backend half of
    /// cancel-pair shipped before the frontend route, so that path currently answers 404 for every
    /// caller. Treating it as "already gone" would report a cleanup that never happened and leave
    /// the synthetic login behind — silently, which is exactly how twenty of them accumulated
    /// unnoticed. The backend's own client maps 404 to "failed"; so does this one.
    func testA404IsAFailureRatherThanAssumingTheDeviceIsGone() async {
        let transport = FakeTransport()
        transport.session = false
        transport.cancelPairResult = .failure(FirestoreRESTError.http(status: 404, body: ""))
        let store = self.store()
        store.clear()
        let backend = DeviceBackend(
            transport: transport, store: store, workers: registry(workers: 1)
        )
        transport.pollError = Boom()
        _ = await backend.startPairing(onCode: { _, _ in }, onClaimed: {})

        await backend.abandonPairing()

        XCTAssertEqual(transport.cancelPairCalls.count, 1)
        XCTAssertTrue(transport.unpairCalls.isEmpty,
                      "a 404 must not escalate to a route that needs a session this device lacks")
        let snapshot = await backend.loadSnapshot()
        XCTAssertFalse(snapshot.paired, "the owner still leaves the flow cleanly")
    }

    func testAFailedCancelStillReturnsTheAppToACleanState() async {
        let transport = FakeTransport()
        transport.session = false
        transport.cancelPairResult = .failure(Boom())
        let store = self.store()
        store.clear()
        let backend = DeviceBackend(
            transport: transport, store: store, workers: registry(workers: 1)
        )
        transport.pollError = Boom()
        _ = await backend.startPairing(onCode: { _, _ in }, onClaimed: {})

        await backend.abandonPairing()

        let snapshot = await backend.loadSnapshot()
        XCTAssertFalse(snapshot.paired, "the UI must return to a clean state even when cleanup fails")
    }
}
