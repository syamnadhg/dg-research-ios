import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import SuperResearchDeviceCore

// ⚠ NOT COMPILE-VERIFIED. The Firebase SDK could not be fetched in the environment this was written
// in, so this file has never been built. The sequence it drives IS tested — against a fake, in the
// core package — so what remains here is mechanical. The full API surface it depends on, so it can
// be checked against the SDK version you resolve:
//
//   FirebaseApp.configure()
//   Auth.auth().signIn(withCustomToken:)                        -> async throws AuthDataResult
//   Firestore.firestore()
//   .collection(_:) / .document(_:)
//   DocumentReference.getDocument()                             -> async throws DocumentSnapshot
//   DocumentReference.updateData(_:)                            -> async throws
//   DocumentReference.addSnapshotListener(_:)                   -> ListenerRegistration
//   Query.addSnapshotListener(_:)                               -> ListenerRegistration
//   FieldValue.delete()
//
// Expect at most a signature fix or two. Nothing here is novel API usage.

/// `PairingBackend` on Firebase. Everything owner-gated about C0-FE lives behind this one type.
public final class FirebasePairingBackend: PairingBackend, @unchecked Sendable {

    /// Base URL of the frontend, used for `/api/devices/initiate-pair` and the QR's claim URL.
    private let apiBaseURL: URL
    private let db: Firestore
    private let session: URLSession

    /// - Parameter configureFirebase: call `FirebaseApp.configure()` unless the host app already did.
    ///   Configuring twice logs a warning and is otherwise harmless, but leaving it to the caller
    ///   means an app that configures in its own `init` is not fighting this type over it.
    public init(
        apiBaseURL: URL,
        configureFirebase: Bool = true,
        session: URLSession = .shared
    ) {
        if configureFirebase, FirebaseApp.app() == nil {
            // Reads GoogleService-Info.plist from the bundle. Without that file this throws at
            // runtime — which is the one hard prerequisite C0-FE has.
            FirebaseApp.configure()
        }
        self.apiBaseURL = apiBaseURL
        self.db = Firestore.firestore()
        self.session = session
    }

    public var now: Date { Date() }

    // MARK: - Step 1: initiate-pair (unauthenticated HTTP)

    /// `POST /api/devices/initiate-pair`.
    ///
    /// ⚠ The **server** mints the pair code and creates the device document — client creation of that
    /// document is `allow create: if false`, so there is deliberately no Firestore write here. We
    /// send only the hash of a secret we keep.
    public func initiatePair(secretHash: String) async throws -> InitiatePairResponse {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("api/devices/initiate-pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["secretHash": secretHash])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.http(status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(InitiatePairPayload.self, from: data)
        return InitiatePairResponse(deviceId: decoded.deviceId, pairCode: decoded.pairCode)
    }

    private struct InitiatePairPayload: Decodable {
        let deviceId: String
        let pairCode: String
    }

    // MARK: - Step 2: poll the pending inbox, BEFORE we have any credentials

    /// Read `devices/{deviceId}/pending/{secretHash}`.
    ///
    /// Legal unauthenticated because that path is `allow get: if true` — and `allow list: if false`,
    /// so knowing the hash is the only way in and the subcollection cannot be enumerated.
    ///
    /// ⚠ **This is the one genuinely unresolved question in the whole pairing flow**, flagged in
    /// `docs/FIRESTORE_CONTRACT.md` §13: whether the Firestore *iOS SDK* will issue a `getDocument`
    /// with no signed-in user at all, or whether it insists on at least an anonymous session. If it
    /// refuses, this method falls through to a plain REST GET, which is unambiguously allowed by the
    /// rule. Both paths are implemented rather than guessing which is needed, because guessing wrong
    /// here stalls pairing at exactly the step with no error surface — the poll simply never returns
    /// a token.
    public func pollPending(deviceId: String, secretHash: String) async throws -> String? {
        let ref = db.collection("devices").document(deviceId)
            .collection("pending").document(secretHash)
        do {
            let snapshot = try await ref.getDocument()
            guard snapshot.exists else { return nil }
            return snapshot.get("customToken") as? String
        } catch {
            // Fall back to REST rather than failing: if the SDK declines an unauthenticated read,
            // the rule still permits the request and REST makes it directly.
            return try await pollPendingViaREST(deviceId: deviceId, secretHash: secretHash)
        }
    }

    private func pollPendingViaREST(deviceId: String, secretHash: String) async throws -> String? {
        guard let projectId = FirebaseApp.app()?.options.projectID else {
            throw BackendError.missingProjectID
        }
        let path = "projects/\(projectId)/databases/(default)/documents"
            + "/devices/\(deviceId)/pending/\(secretHash)"
        guard let url = URL(string: "https://firestore.googleapis.com/v1/\(path)") else {
            throw BackendError.badURL(path)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }  // not claimed yet — the normal case
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        // REST wraps values: {"fields": {"customToken": {"stringValue": "…"}}}
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let fields = root?["fields"] as? [String: Any]
        let token = fields?["customToken"] as? [String: Any]
        return token?["stringValue"] as? String
    }

    // MARK: - Step 3: exchange the custom token

    public func signIn(customToken: String) async throws {
        _ = try await Auth.auth().signIn(withCustomToken: customToken)
    }

    // MARK: - Step 4: the atomic pair-confirm, and every heartbeat after it

    /// Patch the device document, setting some fields and **deleting** others.
    ///
    /// ⚠ `FieldValue.delete()` and not `NSNull()`. The frontend distinguishes absent from
    /// present-but-null, so a null write reports success while leaving the TTL armed — and the
    /// document then disappears on schedule, minutes after a pairing that appeared to work.
    ///
    /// ⚠ `updateData` and not `setData(merge:)`. A merge on a document the TTL has already removed
    /// would **recreate** it — without `ownerUid` or `syntheticDeviceUid`, so every later write fails
    /// the rules and the web app shows a device that can never do anything. `updateData` fails
    /// cleanly on a missing document, which is the outcome that can be diagnosed.
    public func patchDevice(deviceId: String, set: [String: Any], delete: [String]) async throws {
        var payload = set
        for field in delete {
            payload[field] = FieldValue.delete()
        }
        try await db.collection("devices").document(deviceId).updateData(payload)
    }

    // MARK: - Step 5: the queue listener

    /// Listen on `devices/{deviceId}/queue` and hand each queued document to *onQueued*.
    ///
    /// Returns the registration so the caller owns its lifetime. Not stored internally on purpose:
    /// a listener that outlives its screen keeps claiming work after the user has navigated away.
    public func listenToQueue(
        deviceId: String,
        onQueued: @escaping ([String: Any], String) -> Void
    ) -> ListenerRegistration {
        db.collection("devices").document(deviceId).collection("queue")
            .addSnapshotListener { snapshot, error in
                guard let snapshot, error == nil else { return }
                // documentChanges rather than the whole set: re-processing every existing document
                // on each snapshot would re-claim work already running.
                for change in snapshot.documentChanges where change.type == .added {
                    onQueued(change.document.data(), change.document.documentID)
                }
            }
    }

    public enum BackendError: Error {
        case http(status: Int, body: String)
        case missingProjectID
        case badURL(String)
    }
}
