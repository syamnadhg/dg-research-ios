import Foundation

/// `PairingBackend` over REST — the real, dependency-free device backend.
///
/// The pairing *sequence* is not implemented here: `PairingCoordinator` owns it and is already tested
/// against a fake, including the five-minute confirm deadline and the field allow-list. This type only
/// supplies the five primitives, which is why swapping the SDK for REST is a small change rather than
/// a rewrite — the logic worth getting right never depended on which one it was.
public final class RESTPairingBackend: PairingBackend {
    private let config: FirebaseProjectConfig
    private let client: FirestoreREST
    private let transport: HTTPTransport

    public init(
        config: FirebaseProjectConfig,
        transport: HTTPTransport = URLSessionTransport(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = transport
        self.client = FirestoreREST(config: config, transport: transport, clock: clock)
    }

    public var now: Date { Date() }

    /// Exposed so the app can reuse the authenticated session for heartbeats, queue polls and
    /// `pipeline_events` writes rather than signing in a second time.
    public var firestore: FirestoreREST { client }

    // MARK: Step 1 — initiate-pair

    /// `POST /api/devices/initiate-pair`, unauthenticated.
    ///
    /// ⚠ The **server** mints the pair code and creates the device document. Client creation of that
    /// document is `allow create: if false`, so there is deliberately no Firestore write in this step —
    /// the device sends only the SHA-256 of a poll secret it keeps. An earlier draft of this design had
    /// the device generating the code, which the rules would have rejected outright.
    public func initiatePair(secretHash: String) async throws -> InitiatePairResponse {
        var request = URLRequest(
            url: config.apiBaseURL.appendingPathComponent("api/devices/initiate-pair")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["secretHash": secretHash, "platform": "ios"]
        )

        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw FirestoreRESTError.http(
                status: status, body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceId = json["deviceId"] as? String,
            let pairCode = json["pairCode"] as? String
        else {
            throw FirestoreRESTError.malformedResponse(
                "initiate-pair must return deviceId and pairCode"
            )
        }
        return InitiatePairResponse(deviceId: deviceId, pairCode: pairCode)
    }

    // MARK: Step 2 — poll for the claim

    /// Read `devices/{deviceId}/pending/{secretHash}` **unauthenticated** and return the custom token
    /// once the web app has claimed the device.
    ///
    /// Unauthenticated is legal by design, not by oversight: that path is `allow get: if true`, and its
    /// sibling `allow list: if false` means the secret cannot be sidestepped by listing the
    /// subcollection. This is the bootstrap — there is no session yet, since the token to create one is
    /// what we are collecting.
    public func pollPending(deviceId: String, secretHash: String) async throws -> String? {
        let fields = try await client.getDocument(
            path: "devices/\(deviceId)/pending/\(secretHash)",
            authenticated: false
        )
        guard case .string(let token)? = fields?["customToken"] else { return nil }
        return token
    }

    // MARK: Step 3 — exchange it

    public func signIn(customToken: String) async throws {
        try await client.signIn(customToken: customToken)
    }

    // MARK: Step 4 — the atomic pair-confirm, and every later device patch

    /// Patch `devices/{deviceId}`, setting some fields and deleting others.
    ///
    /// This carries the pair-confirm, which is the step that makes pairing stick. The claim arms
    /// `expireAt: now + 5min` under a TTL policy; this write must land inside that window with exactly
    /// the allow-listed field set, or **the device document is deleted** and pairing appears to have
    /// succeeded before quietly vanishing minutes later.
    ///
    /// `hasOnly()` is all-or-nothing across three ORed rules, so one stray key rejects the whole write
    /// with a 403 that names neither the field nor the rule — which is why `PairingCoordinator` checks
    /// the key set locally before it ever gets here.
    public func patchDevice(deviceId: String, set: [String: Any], delete: [String]) async throws {
        try await client.patchDocument(
            path: "devices/\(deviceId)",
            set: set.mapValues(FirestoreValue.from),
            delete: delete
        )
    }
}

// MARK: - Reading the project config

extension FirebaseProjectConfig {
    /// Build a config from a `GoogleService-Info.plist` dictionary.
    ///
    /// Takes the parsed dictionary rather than reading `Bundle.main` so the core package stays free of
    /// bundle assumptions and this is testable without a plist on disk. The app does the reading.
    public init(plist: [String: Any], apiBaseURL: URL) throws {
        guard let projectID = plist["PROJECT_ID"] as? String, !projectID.isEmpty else {
            throw FirestoreRESTError.malformedResponse(
                "GoogleService-Info.plist has no PROJECT_ID — is it the right project's plist?"
            )
        }
        guard let apiKey = plist["API_KEY"] as? String, !apiKey.isEmpty else {
            throw FirestoreRESTError.malformedResponse(
                "GoogleService-Info.plist has no API_KEY"
            )
        }
        self.init(projectID: projectID, apiKey: apiKey, apiBaseURL: apiBaseURL)
    }
}
