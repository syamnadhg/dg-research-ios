import Foundation

/// Firestore and Identity Toolkit over their REST APIs, with no SDK dependency.
///
/// **Why REST rather than the Firebase Apple SDK.** Three reasons, in order of weight:
///
/// 1. **It keeps the app buildable with one command.** The app is compiled by a single `swiftc`
///    invocation with no Xcode project and no package graph — that is what makes it installable here
///    at all, on a machine with no Apple Developer account. Linking `FirebaseFirestore` drags in a
///    C++ core, gRPC, abseil, leveldb and BoringSSL, plus resource bundles, and none of that survives
///    a hand-rolled `.app`. It would mean adopting an Xcode project to get a document read.
/// 2. **It is testable.** This file has no dependencies, so it lives in the core package and `swift
///    test` reaches it. The SDK-backed `FirebasePairingBackend` cannot be unit-tested at all — it was
///    written but never compiled, and is kept only for a future Xcode-based build.
/// 3. **The wire shapes are already verified.** The Python side exercised these exact documents
///    against the real `firestore.rules` in the emulator (14/14), so this is transcribing a proven
///    contract rather than discovering one.
///
/// What is given up: the SDK's realtime snapshot listener. Firestore's `Listen` is gRPC-only, so
/// changes are polled instead. For a device backend that is not a real loss — it polls its queue
/// regardless, and polling has the better failure mode, since a dropped stream is indistinguishable
/// from an idle one whereas a failed poll is an error you can see.
public struct FirebaseProjectConfig: Sendable, Equatable {
    public let projectID: String
    /// The Firebase Web API key, from `GoogleService-Info.plist` (`API_KEY`).
    ///
    /// Not a secret in the sense a password is — it identifies the project and is shipped in every
    /// Firebase client — but it is still kept out of git with the plist, which is gitignored.
    public let apiKey: String
    /// Frontend origin, for `/api/devices/initiate-pair` and the QR's claim URL.
    public let apiBaseURL: URL

    /// `host:port` of the Firebase emulator suite, when pointing at it instead of production.
    ///
    /// Present so this client can be verified against the **real `firestore.rules`** with no
    /// credentials — the rules are the contract, so a write they accept is a write the project accepts.
    /// Without an injectable host the REST layer could only ever be tested against stubs, which proves
    /// the code agrees with my idea of the API rather than with the API.
    ///
    /// `nil` in production. There is deliberately no environment-variable fallback inside this type: a
    /// client that could be redirected to another host by ambient configuration is a client that could
    /// be redirected by anything that can set an environment variable.
    public let emulatorHost: String?

    public init(
        projectID: String, apiKey: String, apiBaseURL: URL, emulatorHost: String? = nil
    ) {
        self.projectID = projectID
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.emulatorHost = emulatorHost
    }

    var documentsRoot: String {
        let base = emulatorHost.map { "http://\($0)/v1" }
            ?? "https://firestore.googleapis.com/v1"
        return "\(base)/projects/\(projectID)/databases/(default)/documents"
    }

    /// Identity Toolkit's base, which the emulator serves on its **own** port — not Firestore's.
    var identityRoot: String {
        emulatorAuthHost.map { "http://\($0)/identitytoolkit.googleapis.com/v1" }
            ?? "https://identitytoolkit.googleapis.com/v1"
    }

    /// Secure Token (refresh) shares the Auth emulator's port but a different path prefix.
    var secureTokenRoot: String {
        emulatorAuthHost.map { "http://\($0)/securetoken.googleapis.com/v1" }
            ?? "https://securetoken.googleapis.com/v1"
    }

    /// The Auth emulator's authority, derived from the Firestore one.
    ///
    /// Derived rather than configured separately because the two always run together in the suite, and
    /// a second knob would just be a second thing to get out of step.
    private var emulatorAuthHost: String? {
        guard let emulatorHost else { return nil }
        let host = emulatorHost.split(separator: ":").first.map(String.init) ?? emulatorHost
        return "\(host):9199"
    }
}

// MARK: - Typed values

/// Firestore REST wraps every scalar in a one-key type tag. Encoding is where this API bites.
///
/// ⚠ **Integers travel as JSON strings** — `{"integerValue": "1753000000000"}`, not a number. Send a
/// JSON number and Firestore stores a *double*; the field then reads back as `1.753e12`, comparisons
/// against it behave oddly, and nothing ever reports an error. `seq` and `timestamp` are int millis in
/// this contract, so getting this wrong would silently corrupt the event cursor.
public enum FirestoreValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case null
    case array([FirestoreValue])
    case map([String: FirestoreValue])

    public var json: [String: Any] {
        switch self {
        case .string(let v): return ["stringValue": v]
        case .integer(let v): return ["integerValue": String(v)]  // string on the wire, see above
        case .double(let v): return ["doubleValue": v]
        case .boolean(let v): return ["booleanValue": v]
        case .null: return ["nullValue": NSNull()]
        case .array(let items):
            return ["arrayValue": ["values": items.map(\.json)]]
        case .map(let fields):
            return ["mapValue": ["fields": fields.mapValues(\.json)]]
        }
    }

    /// Decode one tagged value. Unknown tags decode to `nil` rather than throwing: Firestore has types
    /// this device never writes (`geoPointValue`, `referenceValue`, `bytesValue`), and a document that
    /// happens to carry one should not fail the whole read.
    public static func decode(_ tagged: [String: Any]) -> FirestoreValue? {
        if let v = tagged["stringValue"] as? String { return .string(v) }
        if let v = tagged["integerValue"] {
            // Accepted as either, because that is what the API actually returns: a value written as a
            // string comes back as a string, but one written by another client as a number comes back
            // as a number. Refusing the second would make this brittle to who wrote the field.
            if let s = v as? String, let i = Int64(s) { return .integer(i) }
            if let n = v as? NSNumber { return .integer(n.int64Value) }
        }
        if let v = tagged["booleanValue"] as? Bool { return .boolean(v) }
        if let v = tagged["doubleValue"] as? NSNumber { return .double(v.doubleValue) }
        if tagged["nullValue"] != nil { return .null }
        if let wrapper = tagged["arrayValue"] as? [String: Any] {
            let values = wrapper["values"] as? [[String: Any]] ?? []   // absent means empty, not error
            return .array(values.compactMap(FirestoreValue.decode))
        }
        if let wrapper = tagged["mapValue"] as? [String: Any] {
            let fields = wrapper["fields"] as? [String: [String: Any]] ?? [:]
            return .map(fields.compactMapValues(FirestoreValue.decode))
        }
        return nil
    }

    /// Best-effort bridge from the `[String: Any]` the `PairingBackend` protocol speaks.
    ///
    /// ⚠ **`Bool` and `1` are the same type once a value crosses an Obj-C boundary** — both arrive as
    /// `NSNumber`, and `NSNumber as? Bool` and `NSNumber as? Int` both succeed. So the distinction
    /// cannot be made by the order of the `as?` cases; it needs `CFBooleanGetTypeID`, which is the one
    /// reliable discriminator. Getting this wrong is expensive in both directions: `pairConfirmedAt`
    /// stored as integer `1` is rejected by the rules with a 403 that names nothing, and `seq` stored
    /// as `true` corrupts the event cursor.
    ///
    /// Native Swift values never had this problem — `Bool as? Int` fails in Swift — which is exactly
    /// why an ordering-based version passes its tests and then misbehaves on the first plist- or
    /// JSON-sourced dictionary. Mutation testing surfaced it: reordering the cases changed nothing,
    /// which meant the ordering was not doing the work the comment claimed.
    public static func from(_ any: Any) -> FirestoreValue {
        // Checked first and explicitly, so neither branch below depends on case order.
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            if Self.isIntegral(number) { return .integer(number.int64Value) }
            return .double(number.doubleValue)
        }
        switch any {
        case let v as Bool: return .boolean(v)
        case let v as String: return .string(v)
        case let v as Int: return .integer(Int64(v))
        case let v as Int64: return .integer(v)
        case let v as Double: return .double(v)
        case let v as [Any]: return .array(v.map(FirestoreValue.from))
        case let v as [String: Any]: return .map(v.mapValues(FirestoreValue.from))
        case is NSNull: return .null
        default: return .string(String(describing: any))
        }
    }

    /// Whether an `NSNumber` holds a whole number, so `lastHeartbeat` survives as an integer.
    ///
    /// `objCType` rather than a value comparison: `2.0` is numerically integral but was written as a
    /// double, and silently promoting it would lose that the caller meant a double.
    static func isIntegral(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type)
    }
}

// MARK: - Errors

public enum FirestoreRESTError: Error, Equatable {
    /// Non-2xx. Carries the status and the body, because Firestore's rule denials are only
    /// distinguishable from real errors by reading the message.
    case http(status: Int, body: String)
    case malformedResponse(String)
    case notAuthenticated
}

// MARK: - The client

/// Minimal Firestore + Identity Toolkit client: sign in, get, patch.
///
/// An `actor` because the ID token is mutable shared state refreshed on demand, and the device does
/// several concurrent things (heartbeat, queue poll, event writes). Two coroutines refreshing at once
/// would each burn the refresh token.
public actor FirestoreREST {
    private let config: FirebaseProjectConfig
    private let transport: HTTPTransport

    private var idToken: String?
    private var refreshToken: String?
    private var expiry: Date?
    /// Injected so token-expiry logic is testable without waiting an hour.
    private let clock: @Sendable () -> Date

    public init(
        config: FirebaseProjectConfig,
        transport: HTTPTransport,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = transport
        self.clock = clock
    }

    public var isAuthenticated: Bool { idToken != nil }

    // MARK: Auth

    /// Exchange a custom token for a session. The REST equivalent of
    /// `Auth.auth().signIn(withCustomToken:)`.
    ///
    /// The resulting ID token carries the `deviceId` custom claim, which is the **only** claim the
    /// Firestore rules read — and they read it fifteen times. Without it every write into the user
    /// tree is a 403 whose message says nothing about claims.
    public func signIn(customToken: String) async throws {
        let body: [String: Any] = ["token": customToken, "returnSecureToken": true]
        let json = try await postJSON(
            url: "\(config.identityRoot)/accounts:signInWithCustomToken",
            body: body
        )
        guard let id = json["idToken"] as? String else {
            throw FirestoreRESTError.malformedResponse("no idToken in signInWithCustomToken response")
        }
        idToken = id
        refreshToken = json["refreshToken"] as? String
        expiry = Self.expiryDate(from: json["expiresIn"], now: clock())
    }

    /// Refresh the ID token. Called automatically; public so a long-lived daemon can pre-warm.
    public func refreshIfNeeded() async throws {
        guard let refreshToken else { return }
        // A 60s skew guard, because a token that expires mid-flight fails the request rather than
        // being retried — and the failure is a 401 that reads like a permissions problem.
        //
        // Bound to `deadline` rather than `guard let expiry`: the shorthand would shadow the property
        // with a non-optional local, and the assignments below would then be writing to the shadow.
        guard let deadline = expiry, clock().addingTimeInterval(60) >= deadline else { return }

        var request = URLRequest(
            url: URL(string: "\(config.secureTokenRoot)/token?key=\(config.apiKey)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)"
            .data(using: .utf8)

        let json = try await send(request)
        // Snake_case here and camelCase in signInWithCustomToken — the two endpoints genuinely differ,
        // which is exactly the sort of thing that is discovered at runtime rather than in review.
        guard let id = json["id_token"] as? String else {
            throw FirestoreRESTError.malformedResponse("no id_token in refresh response")
        }
        idToken = id
        self.refreshToken = json["refresh_token"] as? String ?? refreshToken
        expiry = Self.expiryDate(from: json["expires_in"], now: clock())
    }

    static func expiryDate(from raw: Any?, now: Date) -> Date? {
        // Also a string-typed number on the wire.
        let seconds: Double? = (raw as? String).flatMap(Double.init) ?? (raw as? NSNumber)?.doubleValue
        guard let seconds else { return nil }
        return now.addingTimeInterval(seconds)
    }

    // MARK: Documents

    /// Read one document. `authenticated: false` omits the bearer token.
    ///
    /// Unauthenticated is a real, deliberate mode, not a fallback: `devices/{id}/pending/{hash}` is
    /// `allow get: if true` precisely so a device that has no session yet can collect its custom
    /// token. Sibling `allow list: if false` keeps the secret from being enumerated away.
    ///
    /// Returns `nil` for 404, because "not claimed yet" is the normal state while polling and is not
    /// an error.
    public func getDocument(
        path: String, authenticated: Bool = true
    ) async throws -> [String: FirestoreValue]? {
        var url = "\(config.documentsRoot)/\(path)"
        if !authenticated { url += "?key=\(config.apiKey)" }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "GET"
        if authenticated { try await authorize(&request) }

        do {
            let json = try await send(request)
            let fields = json["fields"] as? [String: [String: Any]] ?? [:]
            return fields.compactMapValues(FirestoreValue.decode)
        } catch FirestoreRESTError.http(status: 404, _) {
            return nil
        }
    }

    /// Patch a document: set some fields, delete others.
    ///
    /// ⚠ **The delete mechanism is a field named in `updateMask` and absent from the body.** Writing
    /// an explicit null instead leaves the field *present*, and the frontend distinguishes absent from
    /// present-but-null — so a null `expireAt` reports success while leaving the TTL armed, and the
    /// device document evaporates five minutes later. That is the failure where pairing appears to
    /// work and then silently undoes itself.
    public func patchDocument(
        path: String, set: [String: FirestoreValue], delete: [String] = []
    ) async throws {
        var components = URLComponents(string: "\(config.documentsRoot)/\(path)")!
        // Every touched path goes in the mask — the set ones and the deleted ones alike. A mask
        // listing only the set fields would leave the deletions silently unapplied.
        components.queryItems = (Array(set.keys) + delete).map {
            URLQueryItem(name: "updateMask.fieldPaths", value: $0)
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await authorize(&request)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["fields": set.mapValues(\.json)]
        )
        _ = try await send(request)
    }

    // MARK: Plumbing

    private func authorize(_ request: inout URLRequest) async throws {
        try await refreshIfNeeded()
        guard let idToken else { throw FirestoreRESTError.notAuthenticated }
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
    }

    private func postJSON(url: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(url)?key=\(config.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw FirestoreRESTError.http(
                status: status,
                body: String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            )
        }
        if data.isEmpty { return [:] }   // a patch can legitimately return an empty body
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirestoreRESTError.malformedResponse("response was not a JSON object")
        }
        return json
    }
}

/// The one seam that touches the network, so everything above it is testable offline.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }
}
