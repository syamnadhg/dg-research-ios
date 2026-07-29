import XCTest

@testable import SuperResearchDeviceCore

/// **The C0-FE gate.** The device pairs, end to end, against the real `firestore.rules`.
///
/// This is the strongest form the gate can take without the owner's project, and it is stronger than it
/// sounds: **the rules are the contract.** A write the real rules accept is a write the real project
/// accepts; one they reject would have failed in production with a 403 naming neither field nor rule.
/// The frontend's server half is played by `bin/c0fe_fixture.py`, which writes as an admin principal
/// exactly as the real route does — but every write the *device* makes goes through the real rules.
///
/// Skipped unless `SR_EMULATOR_HOST` is set, so `swift test` stays offline by default. Run the whole
/// thing with `bin/c0fe_gate.sh`.
///
/// ⚠ Still owner-gated, and the gate's verdict says so: whether the **deployed** ruleset matches this
/// repo's file, and whether the real frontend route behaves like the fixture.
final class C0FEPairingGateTests: XCTestCase {

    private var host: String {
        get throws {
            guard let host = ProcessInfo.processInfo.environment["SR_EMULATOR_HOST"] else {
                throw XCTSkip("set SR_EMULATOR_HOST to run the C0-FE gate (see bin/c0fe_gate.sh)")
            }
            return host
        }
    }

    private func makeConfig() throws -> FirebaseProjectConfig {
        FirebaseProjectConfig(
            projectID: "demo-sr",
            // Any non-empty key: the emulator does not validate it, which is what makes this runnable
            // without the owner's project.
            apiKey: "emulator-key",
            apiBaseURL: URL(string: "http://127.0.0.1:8907")!,   // the fixture
            emulatorHost: try host
        )
    }

    /// The whole sequence, in order, with the deadline live.
    func testTheDevicePairsAndTheConfirmCancelsTheTTL() async throws {
        let config = try makeConfig()
        let backend = RESTPairingBackend(config: config)
        let coordinator = PairingCoordinator(backend: backend)

        // Step 1–2: register the secret hash. The SERVER mints the code and creates the document.
        let (secret, display, deviceId) = try await coordinator.begin()
        XCTAssertFalse(deviceId.isEmpty)
        XCTAssertEqual(display, "JPNT-Y4F9", "the device only formats what the server minted")

        // Step 3: poll until the claim lands, then exchange the custom token. The fixture claims on a
        // timer, so this genuinely has to wait.
        try await coordinator.awaitClaim(
            secret: secret, deviceId: deviceId, pollInterval: 0.5, timeout: 30
        )
        let authenticated = await backend.firestore.isAuthenticated
        XCTAssertTrue(authenticated, "signInWithCustomToken should have produced a session")

        // Step 4: the atomic pair-confirm. This is what cancels the TTL.
        try await coordinator.confirmPairing(deviceId: deviceId, workerCount: 1)

        let fields = try await backend.firestore.getDocument(path: "devices/\(deviceId)")
        XCTAssertNotNil(fields, "the device document must still exist after the confirm")
        XCTAssertEqual(fields?["pairConfirmedAt"], .boolean(true))
        // The assertion that actually protects against the silent-evaporation failure. A null write
        // would leave the field present and the TTL armed, and this is what catches that.
        XCTAssertNil(
            fields?["expireAt"],
            "expireAt must be GONE, not null — a present-but-null value leaves the TTL armed and the "
                + "document is deleted minutes later, long after pairing looked successful"
        )
        XCTAssertNotNil(fields?["lastHeartbeat"])
    }

    /// The negative case, which matters more than the positive one.
    ///
    /// `hasOnly()` is all-or-nothing across three ORed rules, so an accept-only test would pass against
    /// a rule that permitted everything. This proves the rules are actually constraining the device.
    func testOneExtraFieldIsRejectedByTheRealRules() async throws {
        let config = try makeConfig()
        let backend = RESTPairingBackend(config: config)
        let coordinator = PairingCoordinator(backend: backend)

        let (secret, _, deviceId) = try await coordinator.begin()
        try await coordinator.awaitClaim(
            secret: secret, deviceId: deviceId, pollInterval: 0.5, timeout: 30
        )

        do {
            // `name` is outside the synthetic-device allow-list. Sent directly rather than through the
            // coordinator, because the coordinator catches this locally — and here the point is that
            // the *rules* catch it too, so the local check is a better error message rather than the
            // only line of defence.
            try await backend.patchDevice(
                deviceId: deviceId,
                set: [
                    "pairConfirmedAt": true,
                    "status": "active",
                    "lastHeartbeat": Int(Date().timeIntervalSince1970 * 1000),
                    "name": "hijacked",
                ],
                delete: ["expireAt"]
            )
            XCTFail("the rules must reject a write carrying a field outside the allow-list")
        } catch let FirestoreRESTError.http(status, _) {
            XCTAssertEqual(status, 403, "expected a permission denial")
        }
    }

    /// The heartbeat is the confirm, on every tick — so it must keep being accepted.
    func testTheSteadyStateHeartbeatKeepsBeingAccepted() async throws {
        let config = try makeConfig()
        let backend = RESTPairingBackend(config: config)
        let coordinator = PairingCoordinator(backend: backend)

        let (secret, _, deviceId) = try await coordinator.begin()
        try await coordinator.awaitClaim(
            secret: secret, deviceId: deviceId, pollInterval: 0.5, timeout: 30
        )
        try await coordinator.confirmPairing(deviceId: deviceId, workerCount: 1)

        // Twice, because the second one runs against a document that no longer has `expireAt` — a rule
        // that only permitted the delete-while-present case would pass the first and fail here.
        try await coordinator.heartbeat(deviceId: deviceId, workerCount: 1)
        try await coordinator.heartbeat(deviceId: deviceId, workerCount: 1)

        let fields = try await backend.firestore.getDocument(path: "devices/\(deviceId)")
        XCTAssertNotNil(fields?["lastHeartbeat"])
    }

    /// Reading the pending document must work with **no session at all**.
    ///
    /// This is the bootstrap, and it is easy to get wrong in a way that only shows up on a fresh device:
    /// the token needed to authenticate is the thing being fetched, so an implementation that quietly
    /// requires a session works forever on an already-paired device and never on a new one.
    func testThePendingDocumentIsReadableWithoutASession() async throws {
        let config = try makeConfig()
        let backend = RESTPairingBackend(config: config)

        let (secret, _, deviceId) = try await PairingCoordinator(backend: backend).begin()
        let authenticated = await backend.firestore.isAuthenticated
        XCTAssertFalse(authenticated, "no session should exist at this point")

        // Absent-not-error while unclaimed, then present once claimed — both without authenticating.
        let before = try await backend.pollPending(
            deviceId: deviceId, secretHash: secret.secretHash
        )
        XCTAssertNil(before)

        try await Task.sleep(nanoseconds: 4_000_000_000)   // let the fixture's claim timer fire
        let after = try await backend.pollPending(deviceId: deviceId, secretHash: secret.secretHash)
        XCTAssertNotNil(after, "the custom token must be readable unauthenticated")
    }
}
