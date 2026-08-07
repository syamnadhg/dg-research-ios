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

    /// What the frontend's Account page labels this device.
    ///
    /// The desktop backend sends its hostname. An iPhone has no hostname worth showing, so this sends
    /// the user-visible device name ("Sammy's iPhone") — the same thing they would recognise in
    /// Settings, which is the point of the field.
    private var deviceName: String { Self.deviceNameProvider() }
    private var osString: String { Self.osStringProvider() }

    /// Injected so the core package stays UIKit-free and testable; the app supplies the real values.
    public static var deviceNameProvider: @Sendable () -> String = { "iOS Simulator" }
    public static var osStringProvider: @Sendable () -> String = { "iOS" }

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
        // ⚠ FIELD NAMES VERIFIED against the backend's own caller
        // (`dg-research-backend/auth/v2_flow.py::initiate_pair_remote`). They are
        // `pollSecretHash` / `machineName` / `hostname` / `os` — NOT `secretHash`, and there is no
        // `platform` field. My first version sent `{secretHash, platform}`, which the route would have
        // rejected on the very first pairing attempt with an error naming neither field.
        //
        // This is the one request in the whole flow that talks to the frontend rather than to Firestore,
        // so it is the one place where a name mismatch is invisible until a human tries to pair.
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "pollSecretHash": secretHash,
                "machineName": deviceName,
                "hostname": deviceName,
                "os": osString,
            ]
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

    // MARK: Step 5 — release the device, for real

    /// `POST /api/devices/unpair-self`, authenticated as the synthetic device user.
    ///
    /// ⚠ This is the **only** way the device can actually disappear. `match /devices/{deviceId}` in
    /// the rules carries `allow create, delete: if false`, so no client can delete the document;
    /// the route runs firebase-admin and does the whole retire — revokes and deletes the synthetic
    /// Auth user, drops the device secret, deletes the document, and expires orphaned runs.
    ///
    /// What it replaced was a `patchDevice(set: ["status": "retired"])`, which no frontend code
    /// reads. Nothing was removed, the tile stayed on the Account page, and the app said "Unpaired".
    ///
    /// Returns the route's own `action` — `retired` / `left-shared` / `owner-unlinked`. A 404 is
    /// reported as `already-gone` rather than thrown: the device being absent is the goal, and
    /// failing the unpair because it was already unpaired would strand the local identity forever.
    public func unpairSelf(deviceId: String) async throws -> String {
        let (status, data) = try await client.authorizedPOST(
            url: config.apiBaseURL.appendingPathComponent("api/devices/unpair-self"),
            body: ["deviceId": deviceId]
        )
        if status == 404 { return "already-gone" }
        guard (200..<300).contains(status) else {
            throw FirestoreRESTError.http(
                status: status, body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["action"] as? String) ?? "retired"
    }

    /// `POST /api/devices/cancel-pair` — undo an initiate-pair that was never claimed.
    ///
    /// ⚠ UNAUTHENTICATED, and it has to be: a device that has not been claimed has no custom token,
    /// which is exactly why `unpair-self` cannot serve this case. The poll secret is the proof —
    /// the same credential that authorises collecting the custom token, so this grants strictly
    /// less than the caller already holds.
    ///
    /// What it cleans up is NOT just a document. `initiate-pair` also mints a synthetic Firebase
    /// Auth user and a `_internal/device_secrets` entry, and a Firestore TTL sweep can touch
    /// neither — TTL deletes documents and cannot reach Firebase Auth at all. That is how eighteen
    /// orphaned machine logins accumulated between May and July from pairs that were never claimed.
    ///
    /// ⚠ **A 404 is a FAILURE here, not success** — the opposite of `unpairSelf` above, and the
    /// difference is not cosmetic. That route exists, so its 404 means "device not found", which is
    /// the goal. This route may not exist *at all*: the backend half shipped ahead of the frontend
    /// half, so today Next.js answers this path with a plain 404. Reading that as "already gone"
    /// would have the app report a cleanup that never happened and leak precisely the synthetic
    /// login this feature exists to remove — silently, which is how twenty of them accumulated.
    ///
    /// The mapping is taken verbatim from the backend's own `cancel_pair_remote`, which is the
    /// contract both clients answer to: 200 → cancelled, 409 → claimed, everything else → failed.
    public func cancelPair(deviceId: String, pollSecret: String) async throws -> String {
        var request = URLRequest(
            url: config.apiBaseURL.appendingPathComponent("api/devices/cancel-pair")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Matches the terminal's 10s. A hung server must not keep this request alive behind the
        // owner for a default 60 seconds after they have already left the screen.
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["deviceId": deviceId, "pollSecret": pollSecret]
        )
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw FirestoreRESTError.http(
                status: status, body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["action"] as? String) ?? "cancelled"
    }

    /// The persisted half of the session — see `FirestoreREST.currentRefreshToken`.
    public func sessionRefreshToken() async -> String? {
        await client.currentRefreshToken
    }

    public func restoreSession(refreshToken: String) async {
        await client.restoreSession(refreshToken: refreshToken)
    }

    public func hasSession() async -> Bool {
        await client.isAuthenticated
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
