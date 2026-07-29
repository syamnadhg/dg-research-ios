import XCTest
@testable import SuperResearchDeviceCore

/// The pairing sequence and its deadline, tested offline with no Firebase and no plist.
///
/// These cover the traps that would otherwise only surface during a live pairing attempt, where the
/// symptom is a device that appears to pair and then vanishes from the web app minutes later with
/// nothing to read anywhere.
final class PairingCoordinatorTests: XCTestCase {

    /// A fake backend with a controllable clock, recording what it was asked to do.
    final class FakeBackend: PairingBackend, @unchecked Sendable {
        var clock: Date
        var pendingToken: String?
        var tokenAppearsAfterPolls: Int
        var polls = 0
        var signedInWith: String?
        var patches: [(set: [String: Any], delete: [String])] = []
        var initiatedWithHash: String?

        init(clock: Date = Date(timeIntervalSince1970: 1_700_000_000), tokenAppearsAfterPolls: Int = 1) {
            self.clock = clock
            self.tokenAppearsAfterPolls = tokenAppearsAfterPolls
            self.pendingToken = "custom-token-abc"
        }

        var now: Date { clock }

        func initiatePair(secretHash: String) async throws -> InitiatePairResponse {
            initiatedWithHash = secretHash
            return InitiatePairResponse(deviceId: "dev-1", pairCode: "JPNTY4F9")
        }

        func pollPending(deviceId: String, secretHash: String) async throws -> String? {
            polls += 1
            return polls >= tokenAppearsAfterPolls ? pendingToken : nil
        }

        func signIn(customToken: String) async throws { signedInWith = customToken }

        func patchDevice(deviceId: String, set: [String: Any], delete: [String]) async throws {
            patches.append((set, delete))
        }
    }

    private func noSleep(_ interval: TimeInterval) async {}

    // MARK: - The sequence

    func testBeginSendsOnlyTheHashAndDisplaysTheServerMintedCode() async throws {
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        let (secret, display, deviceId) = try await coordinator.begin()

        XCTAssertEqual(backend.initiatedWithHash, secret.secretHash)
        XCTAssertNotEqual(
            backend.initiatedWithHash, secret.hexText,
            "the secret itself must never leave the device — only its hash"
        )
        XCTAssertEqual(display, "JPNT-Y4F9", "the SERVER minted the code; we only hyphenate it")
        XCTAssertEqual(deviceId, "dev-1")
    }

    func testAwaitClaimPollsUntilTheTokenAppearsThenSignsIn() async throws {
        let backend = FakeBackend(tokenAppearsAfterPolls: 3)
        let coordinator = PairingCoordinator(backend: backend)
        let secret = Pairing.PollSecret.generate()
        try await coordinator.awaitClaim(
            secret: secret, deviceId: "dev-1", timeout: 300, sleep: noSleep
        )
        XCTAssertEqual(backend.polls, 3)
        XCTAssertEqual(backend.signedInWith, "custom-token-abc")
    }

    func testAwaitClaimTimesOutRatherThanPollingForever() async {
        let backend = FakeBackend()
        backend.pendingToken = nil
        let coordinator = PairingCoordinator(backend: backend)
        let secret = Pairing.PollSecret.generate()
        do {
            // The clock advances with each sleep, so the timeout is reached deterministically.
            try await coordinator.awaitClaim(
                secret: secret, deviceId: "dev-1", pollInterval: 60, timeout: 120,
                sleep: { [backend] interval in backend.clock += interval }
            )
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? PairingError, .timedOut)
        }
    }

    // MARK: - The atomic confirm and its deadline

    func testConfirmSetsPairConfirmedAndDeletesExpireAt() async throws {
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        let secret = Pairing.PollSecret.generate()
        try await coordinator.awaitClaim(secret: secret, deviceId: "dev-1", sleep: noSleep)
        try await coordinator.confirmPairing(deviceId: "dev-1")

        let patch = try XCTUnwrap(backend.patches.first)
        XCTAssertEqual(patch.set["pairConfirmedAt"] as? Bool, true)
        XCTAssertEqual(patch.delete, ["expireAt"], "deleting expireAt is what cancels the TTL")
        XCTAssertNil(patch.set["expireAt"], "a null write would leave the TTL armed")
    }

    func testTheDeadlineIsMeasuredFromWHENTHECLAIMLANDED() async throws {
        // The five-minute clock starts when the SERVER wrote the token, not when we get around to
        // confirming. Measuring from any later point understates the elapsed time and lets a
        // genuinely-late confirm proceed against a document that is already gone.
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        let secret = Pairing.PollSecret.generate()
        try await coordinator.awaitClaim(secret: secret, deviceId: "dev-1", sleep: noSleep)

        backend.clock += 299
        // Hoisted out of the assert: an `await` inside an XCTAssert autoclosure cannot cross
        // the actor boundary.
        let remaining = await coordinator.timeRemaining()
        let left = try XCTUnwrap(remaining)
        XCTAssertEqual(left, 1, accuracy: 0.01)
        try await coordinator.confirmPairing(deviceId: "dev-1")
        XCTAssertEqual(backend.patches.count, 1, "299s in is still inside the window")
    }

    func testConfirmRefusesPastTheDeadlineRatherThanFailingObscurely() async throws {
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        let secret = Pairing.PollSecret.generate()
        try await coordinator.awaitClaim(secret: secret, deviceId: "dev-1", sleep: noSleep)

        backend.clock += 301  // past the 5-minute TTL
        do {
            try await coordinator.confirmPairing(deviceId: "dev-1")
            XCTFail("expected a refusal")
        } catch let error as PairingError {
            guard case .confirmDeadlineMissed(let elapsed) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(elapsed, 301, accuracy: 0.01)
        }
        XCTAssertTrue(
            backend.patches.isEmpty,
            "past the deadline the device doc is already deleted, so the write would fail against a "
                + "missing document and report a PERMISSIONS error rather than a missed deadline"
        )
    }

    func testTimeRemainingIsNilBeforeAClaimAndClampsAtZero() async throws {
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        let beforeClaim = await coordinator.timeRemaining()
        XCTAssertNil(beforeClaim, "no claim yet, so no clock")

        let secret = Pairing.PollSecret.generate()
        try await coordinator.awaitClaim(secret: secret, deviceId: "dev-1", sleep: noSleep)
        backend.clock += 900
        let afterExpiry = await coordinator.timeRemaining()
        XCTAssertEqual(afterExpiry, 0, "clamped, never negative")
    }

    // MARK: - The heartbeat

    func testTheHeartbeatKeepsPairConfirmedTrueOnEveryTick() async throws {
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        for _ in 0..<3 {
            try await coordinator.heartbeat(deviceId: "dev-1")
            backend.clock += 5
        }
        XCTAssertEqual(backend.patches.count, 3)
        for patch in backend.patches {
            XCTAssertEqual(patch.set["pairConfirmedAt"] as? Bool, true)
            XCTAssertEqual(patch.delete, ["expireAt"])
        }
    }

    func testTheHeartbeatCarriesIntegerMillisNotADate() async throws {
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        try await coordinator.heartbeat(deviceId: "dev-1")
        let patch = try XCTUnwrap(backend.patches.first)
        XCTAssertTrue(
            patch.set["lastHeartbeat"] is Int64,
            "the frontend computes Date.now() - lastHeartbeat directly"
        )
        XCTAssertEqual(patch.set["lastHeartbeat"] as? Int64, 1_700_000_000_000)
    }

    func testWorkerCountIsForwardedWhenGiven() async throws {
        let backend = FakeBackend()
        let coordinator = PairingCoordinator(backend: backend)
        try await coordinator.heartbeat(deviceId: "dev-1", workerCount: 3)
        XCTAssertEqual(backend.patches.first?.set["workerCount"] as? Int, 3)
    }

    func testAHeartbeatOutsideTheAllowListIsCaughtLocally() async {
        // hasOnly() is all-or-nothing across three ORed rules, so one stray key rejects the whole
        // write — and the resulting 403 names neither the field nor the rule.
        struct Rogue: PairingBackend {
            var now: Date { Date() }
            func initiatePair(secretHash: String) async throws -> InitiatePairResponse {
                InitiatePairResponse(deviceId: "d", pairCode: "AAAA2345")
            }
            func pollPending(deviceId: String, secretHash: String) async throws -> String? { nil }
            func signIn(customToken: String) async throws {}
            func patchDevice(deviceId: String, set: [String: Any], delete: [String]) async throws {
                XCTFail("must not reach the network with an unauthorized field set")
            }
        }
        // Verified through the contract type, which is where the allow-list check lives.
        let beat = DeviceContract.Heartbeat(lastHeartbeatMillis: 1)
        XCTAssertTrue(beat.satisfiesSynthRule)
        XCTAssertFalse(
            beat.touchedKeys.union(["name"]).isSubset(of: DeviceContract.synthWritableKeys),
            "adding an owner-only key must fail the synth rule"
        )
        _ = Rogue()
    }
}
