import Foundation

/// Drives the pairing sequence, with the backend behind a protocol so the timing is testable.
///
/// Why the indirection rather than calling Firebase directly: the traps in pairing are all in the
/// *sequence and its timing* — the pre-auth poll, the custom-token exchange, and above all the
/// atomic confirm that has to land inside five minutes or the device document is deleted with no
/// recovery path. None of that needs Firebase to verify, and Firebase cannot be fetched in every
/// environment. Behind this protocol, the Firebase layer is thin mechanical glue over calls whose
/// *ordering* is already proven.
///
/// The Firebase implementation is the only part that needs `GoogleService-Info.plist`.
public protocol PairingBackend: Sendable {
    /// `POST /api/devices/initiate-pair`. The **server** mints the code and creates the device
    /// document; we send only the hash of our poll secret.
    func initiatePair(secretHash: String) async throws -> InitiatePairResponse

    /// Read `devices/{deviceId}/pending/{secretHash}` **unauthenticated**.
    ///
    /// Legal because that path is `allow get: if true` — and `allow list: if false`, so the secret
    /// cannot be defeated by enumerating the subcollection.
    func pollPending(deviceId: String, secretHash: String) async throws -> String?

    /// Exchange the custom token for a session (`Auth.signIn(withCustomToken:)`).
    func signIn(customToken: String) async throws

    /// Patch `devices/{deviceId}`, setting some fields and **deleting** others.
    ///
    /// The delete is a real field delete, never a null: the frontend distinguishes absent from
    /// present-but-null, so a null write reports success and leaves the TTL armed.
    func patchDevice(deviceId: String, set: [String: Any], delete: [String]) async throws

    /// Monotonic-ish wall clock, injected so the deadline logic is testable without waiting.
    var now: Date { get }
}

public struct InitiatePairResponse: Sendable, Equatable {
    public let deviceId: String
    /// The code the SERVER minted. The device only displays it.
    public let pairCode: String

    public init(deviceId: String, pairCode: String) {
        self.deviceId = deviceId
        self.pairCode = pairCode
    }
}

public enum PairingError: Error, Equatable {
    /// The claim never arrived within the poll window.
    case timedOut
    /// The confirm could not be issued inside the five-minute window.
    ///
    /// Surfaced as an error rather than attempted-anyway on purpose: past the deadline the device
    /// document is already gone, so the write would fail against a missing document and the
    /// *reported* cause would be a permissions error rather than a missed deadline.
    case confirmDeadlineMissed(elapsed: TimeInterval)
    /// A patch touched a key outside the synth allow-list.
    ///
    /// Caught locally because `hasOnly()` is all-or-nothing across three ORed rules, so one stray
    /// key rejects the whole write — and the 403 names neither the field nor the rule.
    case unauthorizedFields([String])
}

/// The pairing sequence, in order, with the deadline enforced.
public actor PairingCoordinator {
    private let backend: PairingBackend
    private var claimedAt: Date?

    public init(backend: PairingBackend) {
        self.backend = backend
    }

    /// Step 1–2: generate a secret and register it. Returns what to show the human.
    public func begin() async throws -> (secret: Pairing.PollSecret, display: String, deviceId: String) {
        let secret = Pairing.PollSecret.generate()
        let response = try await backend.initiatePair(secretHash: secret.secretHash)
        return (secret, Pairing.formatForDisplay(response.pairCode), response.deviceId)
    }

    /// Step 3: poll the pending document until the claim lands, then sign in.
    ///
    /// `claimedAt` is stamped the moment the token appears, because the five-minute clock started
    /// when the *server* wrote it — not when we later got around to confirming. Measuring from any
    /// later point would understate the elapsed time and let a genuinely-late confirm proceed.
    public func awaitClaim(
        secret: Pairing.PollSecret,
        deviceId: String,
        pollInterval: TimeInterval = 2,
        timeout: TimeInterval = 300,
        sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) async throws {
        let started = backend.now
        while backend.now.timeIntervalSince(started) < timeout {
            if let token = try await backend.pollPending(deviceId: deviceId, secretHash: secret.secretHash) {
                claimedAt = backend.now
                try await backend.signIn(customToken: token)
                return
            }
            await sleep(pollInterval)
        }
        throw PairingError.timedOut
    }

    /// Step 4: the atomic pair-confirm. **This is what cancels the TTL.**
    ///
    /// Refuses past the deadline rather than trying and reporting a confusing failure. Also checks
    /// the field set locally first, so an accidental extra key is named here instead of arriving as
    /// an opaque permission denial.
    public func confirmPairing(deviceId: String, workerCount: Int? = nil) async throws {
        let start = claimedAt ?? backend.now
        let elapsed = backend.now.timeIntervalSince(start)
        if elapsed > DeviceContract.pairConfirmDeadline {
            throw PairingError.confirmDeadlineMissed(elapsed: elapsed)
        }
        try await heartbeat(deviceId: deviceId, workerCount: workerCount)
    }

    /// The steady-state heartbeat — which is also the confirm, on every tick.
    public func heartbeat(deviceId: String, workerCount: Int? = nil) async throws {
        let beat = DeviceContract.Heartbeat(
            lastHeartbeatMillis: Int64(backend.now.timeIntervalSince1970 * 1000),
            workerCount: workerCount
        )
        guard beat.satisfiesSynthRule else {
            throw PairingError.unauthorizedFields(
                Array(beat.touchedKeys.subtracting(DeviceContract.synthWritableKeys)).sorted()
            )
        }
        try await backend.patchDevice(
            deviceId: deviceId, set: beat.fieldsToSet, delete: beat.fieldsToDelete
        )
    }

    /// Seconds left before the device document is TTL-deleted, or nil if no claim has landed.
    ///
    /// Exposed so a UI can show the window rather than letting it expire invisibly — the failure
    /// this whole class guards against is one the user currently cannot see coming.
    public func timeRemaining() -> TimeInterval? {
        guard let claimedAt else { return nil }
        let left = DeviceContract.pairConfirmDeadline - backend.now.timeIntervalSince(claimedAt)
        return max(0, left)
    }
}
