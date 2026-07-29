import XCTest

@testable import SuperResearchDeviceCore

/// Tests for the REST device backend.
///
/// The value encoding is where most of these live, because that is where this API is quietly hostile:
/// an integer sent as a JSON number is silently stored as a double, and a bool sent through the
/// `Any`-typed protocol boundary is silently stored as 1. Neither produces an error — the first
/// corrupts the event cursor, the second gets the whole write rejected by `hasOnly()` with a 403 that
/// names nothing.
final class FirestoreRESTTests: XCTestCase {

    private let config = FirebaseProjectConfig(
        projectID: "test-project",
        apiKey: "test-key",
        apiBaseURL: URL(string: "https://example.test")!,
        // An emulator host, so the two api-key paths above are distinguishable.
        emulatorHost: "127.0.0.1:8181"
    )

    // MARK: - Value encoding

    func testIntegersAreEncodedAsStringsOnTheWire() throws {
        // Firestore stores a JSON *number* as a double. seq and timestamp are int millis in this
        // contract, so a double would read back as 1.753e12 and break cursor comparisons — with no
        // error anywhere.
        let json = FirestoreValue.integer(1_753_000_000_000).json
        XCTAssertEqual(json["integerValue"] as? String, "1753000000000")
        XCTAssertNil(json["integerValue"] as? NSNumber, "must not be a JSON number")
    }

    func testBoolIsEncodedAsABooleanAndNotAsOne() throws {
        // pairConfirmedAt must be boolean true; stored as integer 1 the rules reject the write with a
        // 403 that names nothing.
        XCTAssertEqual(FirestoreValue.from(true), .boolean(true))
        XCTAssertEqual(FirestoreValue.from(true).json["booleanValue"] as? Bool, true)
        XCTAssertNil(FirestoreValue.from(true).json["integerValue"])
    }

    func testBoolAndOneStayDistinctEvenAsNSNumber() throws {
        // The case that matters and that native-Swift tests miss entirely: across an Obj-C boundary
        // both are NSNumber, and `as? Bool` / `as? Int` both succeed on either. Only
        // CFBooleanGetTypeID separates them.
        XCTAssertEqual(FirestoreValue.from(NSNumber(value: true)), .boolean(true))
        XCTAssertEqual(FirestoreValue.from(NSNumber(value: 1)), .integer(1))
        XCTAssertEqual(FirestoreValue.from(NSNumber(value: false)), .boolean(false))
        XCTAssertEqual(FirestoreValue.from(NSNumber(value: 0)), .integer(0))
    }

    func testAnNSNumberDoubleIsNotPromotedToAnInteger() throws {
        // 2.0 is numerically integral but was written as a double; promoting it would lose what the
        // caller meant.
        XCTAssertEqual(FirestoreValue.from(NSNumber(value: 2.0)), .double(2.0))
        XCTAssertEqual(FirestoreValue.from(NSNumber(value: 1.5)), .double(1.5))
    }

    func testALargeMillisecondTimestampSurvivesAsAnInteger() throws {
        // Int64 range. As a double this loses precision above 2^53 and, well before that, reads back
        // in scientific notation.
        XCTAssertEqual(
            FirestoreValue.from(NSNumber(value: 1_753_000_000_000)), .integer(1_753_000_000_000)
        )
    }

    func testIntegersDecodeFromEitherStringOrNumber() throws {
        // Both shapes occur in practice: what this client writes comes back as a string, what another
        // client wrote may come back as a number.
        XCTAssertEqual(FirestoreValue.decode(["integerValue": "42"]), .integer(42))
        XCTAssertEqual(FirestoreValue.decode(["integerValue": NSNumber(value: 42)]), .integer(42))
    }

    func testNestedMapsAndArraysRoundTrip() throws {
        let value = FirestoreValue.map([
            "agent": .string("gemini"),
            "seq": .integer(7),
            "tags": .array([.string("a"), .boolean(false)]),
        ])
        let encoded = value.json
        let decoded = FirestoreValue.decode(encoded)
        XCTAssertEqual(decoded, value)
    }

    func testAnUnknownValueTagDecodesToNilWithoutFailingTheDocument() throws {
        // Firestore has types this device never writes. One appearing in a document must not fail the
        // whole read.
        XCTAssertNil(FirestoreValue.decode(["geoPointValue": ["latitude": 0, "longitude": 0]]))
    }

    func testAnEmptyArrayDecodesAsEmptyRatherThanFailing() throws {
        // The API omits "values" entirely for an empty array.
        XCTAssertEqual(FirestoreValue.decode(["arrayValue": [:] as [String: Any]]), .array([]))
    }

    // MARK: - Patch semantics

    func testEveryTouchedFieldIsNamedInTheUpdateMaskIncludingDeletions() async throws {
        let transport = StubTransport(responses: [.ok("{}")])
        let client = FirestoreREST(config: config, transport: transport)
        try await signInStub(client, transport: transport)

        try await client.patchDocument(
            path: "devices/dev-1",
            set: ["pairConfirmedAt": .boolean(true), "status": .string("online")],
            delete: ["expireAt"]
        )

        let request = try transport.lastRequest()
        let mask = Set(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.filter { $0.name == "updateMask.fieldPaths" }.map { $0.value! }
        )
        XCTAssertEqual(mask, ["pairConfirmedAt", "status", "expireAt"])
    }

    func testADeletedFieldIsAbsentFromTheBodyRatherThanNull() async throws {
        // The whole point. An explicit null leaves expireAt *present*, the frontend distinguishes
        // absent from present-but-null, and so the TTL stays armed — pairing succeeds and then the
        // device document evaporates five minutes later.
        let transport = StubTransport(responses: [.ok("{}")])
        let client = FirestoreREST(config: config, transport: transport)
        try await signInStub(client, transport: transport)

        try await client.patchDocument(
            path: "devices/dev-1", set: ["status": .string("online")], delete: ["expireAt"]
        )

        let body = try transport.lastBodyJSON()
        let fields = body["fields"] as? [String: Any] ?? [:]
        XCTAssertNotNil(fields["status"])
        XCTAssertNil(fields["expireAt"], "a deleted field must not appear in the body at all")
    }

    // MARK: - Reads

    func testAMissingDocumentReadsAsNilRatherThanThrowing() async throws {
        // "Not claimed yet" is the normal state throughout polling.
        let transport = StubTransport(responses: [.status(404, "{\"error\":{\"code\":404}}")])
        let client = FirestoreREST(config: config, transport: transport)
        let fields = try await client.getDocument(path: "devices/x/pending/y", authenticated: false)
        XCTAssertNil(fields)
    }

    func testAnUnauthenticatedProductionReadSendsNeitherKeyNorBearerToken() async throws {
        // The bootstrap read. There is no session yet — the token to create one is what it fetches.
        //
        // ⚠ And it sends NO api key. The backend's own poller
        // (`auth/v2_flow.py::poll_pending_token`) issues a bare GET, and that is the path proven in
        // production. Appending `?key=` is not merely redundant: a key restricted by API or referrer
        // would 403 where omitting it succeeds, turning the pairing bootstrap into a permissions error
        // that points at the rules rather than at the key. This test asserted the opposite until the
        // backend was checked.
        let production = FirebaseProjectConfig(
            projectID: "p", apiKey: "test-key", apiBaseURL: URL(string: "https://x.test")!
        )
        let transport = StubTransport(responses: [.ok("{\"fields\":{}}")])
        let client = FirestoreREST(config: production, transport: transport)
        _ = try await client.getDocument(path: "devices/x/pending/y", authenticated: false)

        let request = try transport.lastRequest()
        XCTAssertFalse(request.url!.absoluteString.contains("key="), "no api key in production")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheEmulatorPathStillSendsTheKey() async throws {
        // The emulator wants it and ignores its value; keeping it there is what lets the C0-FE gate
        // authenticate as nobody.
        let transport = StubTransport(responses: [.ok("{\"fields\":{}}")])
        let client = FirestoreREST(config: config, transport: transport)   // config has an emulatorHost
        _ = try await client.getDocument(path: "devices/x/pending/y", authenticated: false)
        XCTAssertTrue(try transport.lastRequest().url!.absoluteString.contains("key=test-key"))
    }

    func testAnAuthenticatedRequestWithoutASessionFailsClearly() async throws {
        let client = FirestoreREST(config: config, transport: StubTransport(responses: []))
        do {
            _ = try await client.getDocument(path: "devices/x")
            XCTFail("expected notAuthenticated")
        } catch let error as FirestoreRESTError {
            XCTAssertEqual(error, .notAuthenticated)
        }
    }

    func testANonSuccessStatusCarriesTheBodyThrough() async throws {
        // Firestore rule denials are only distinguishable from real errors by reading the message, so
        // discarding the body would make every 403 identical.
        let transport = StubTransport(responses: [.status(403, "Missing or insufficient permissions")])
        let client = FirestoreREST(config: config, transport: transport)
        do {
            _ = try await client.getDocument(path: "devices/x/pending/y", authenticated: false)
            XCTFail("expected an http error")
        } catch let FirestoreRESTError.http(status, body) {
            XCTAssertEqual(status, 403)
            XCTAssertTrue(body.contains("insufficient permissions"))
        }
    }

    // MARK: - Tokens

    func testSignInStoresTheSessionAndAuthorizesLaterRequests() async throws {
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .ok("{\"fields\":{}}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "custom-abc")
        // Bound first: XCTAssert's argument is a non-concurrent autoclosure, so `await` cannot
        // appear inside it.
        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)

        _ = try await client.getDocument(path: "devices/dev-1")
        XCTAssertEqual(
            try transport.lastRequest().value(forHTTPHeaderField: "Authorization"), "Bearer id-1"
        )
    }

    func testTheTokenIsRefreshedShortlyBeforeItExpires() async throws {
        // A 60s skew guard: a token that expires in flight fails the request with a 401 that reads
        // like a permissions problem rather than an expiry.
        var now = Date(timeIntervalSince1970: 1_000_000)
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            // Note snake_case — the refresh endpoint differs from signInWithCustomToken.
            .ok("{\"id_token\":\"id-2\",\"refresh_token\":\"r-2\",\"expires_in\":\"3600\"}"),
            .ok("{\"fields\":{}}"),
        ])
        let client = FirestoreREST(config: config, transport: transport, clock: { now })
        try await client.signIn(customToken: "custom-abc")

        now = now.addingTimeInterval(3600 - 30)   // inside the skew window
        _ = try await client.getDocument(path: "devices/dev-1")

        XCTAssertEqual(
            try transport.lastRequest().value(forHTTPHeaderField: "Authorization"), "Bearer id-2"
        )
        XCTAssertTrue(
            transport.requests[1].url!.absoluteString.contains("securetoken.googleapis.com"),
            "the second call must be the refresh"
        )
    }

    func testTheTokenIsNotRefreshedWhileItIsStillFresh() async throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .ok("{\"fields\":{}}"),
        ])
        let client = FirestoreREST(config: config, transport: transport, clock: { now })
        try await client.signIn(customToken: "custom-abc")

        now = now.addingTimeInterval(60)
        _ = try await client.getDocument(path: "devices/dev-1")

        XCTAssertEqual(transport.requests.count, 2, "no refresh call should have been made")
    }

    func testAMalformedSignInResponseIsReportedRatherThanLeavingAHalfSession() async throws {
        let transport = StubTransport(responses: [.ok("{\"refreshToken\":\"r-1\"}")])
        let client = FirestoreREST(config: config, transport: transport)
        do {
            try await client.signIn(customToken: "custom-abc")
            XCTFail("expected malformedResponse")
        } catch let FirestoreRESTError.malformedResponse(message) {
            XCTAssertTrue(message.contains("idToken"))
        }
        let authenticated = await client.isAuthenticated
        XCTAssertFalse(authenticated)
    }

    // MARK: - The backend's own steps

    func testInitiatePairSendsTheHashAndReturnsWhatTheServerMinted() async throws {
        // The server mints the code and creates the device document — client create is
        // `allow create: if false`, so there is deliberately no Firestore write in this step.
        let transport = StubTransport(responses: [
            .ok("{\"deviceId\":\"dev-9\",\"pairCode\":\"JPNTY4F9\"}")
        ])
        let backend = RESTPairingBackend(config: config, transport: transport)
        let response = try await backend.initiatePair(secretHash: "abc123")

        XCTAssertEqual(response.deviceId, "dev-9")
        XCTAssertEqual(response.pairCode, "JPNTY4F9")
        // ⚠ FIELD NAMES verified against the backend's own caller,
        // `dg-research-backend/auth/v2_flow.py::initiate_pair_remote`. It sends `pollSecretHash`,
        // `machineName`, `hostname`, `os` — and no `platform`. This test asserted `secretHash` and
        // `platform: "ios"`, both invented, so it would have passed a build that could not pair at all.
        // A stub cannot tell you what the other end expects; only the other end can.
        let body = try transport.lastBodyJSON()
        XCTAssertEqual(body["pollSecretHash"] as? String, "abc123")
        XCTAssertNil(body["secretHash"], "the old, wrong name must not come back")
        XCTAssertNil(body["platform"], "there is no platform field in this route")
        XCTAssertNotNil(body["machineName"])
        XCTAssertNotNil(body["hostname"])
        XCTAssertNotNil(body["os"])
    }

    func testPollPendingReturnsNilUntilTheCustomTokenAppears() async throws {
        let transport = StubTransport(responses: [
            .status(404, "{}"),
            .ok("{\"fields\":{\"customToken\":{\"stringValue\":\"ct-1\"}}}"),
        ])
        let backend = RESTPairingBackend(config: config, transport: transport)
        let first = try await backend.pollPending(deviceId: "dev-9", secretHash: "abc123")
        XCTAssertNil(first)
        let second = try await backend.pollPending(deviceId: "dev-9", secretHash: "abc123")
        XCTAssertEqual(second, "ct-1")
    }

    func testPatchDeviceBridgesBoolsAndIntsThroughTheAnyBoundaryCorrectly() async throws {
        // The protocol speaks [String: Any], which is exactly where a Bool can become a 1.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"),
            .ok("{}"),
        ])
        let backend = RESTPairingBackend(config: config, transport: transport)
        try await backend.signIn(customToken: "ct-1")
        try await backend.patchDevice(
            deviceId: "dev-9",
            set: ["pairConfirmedAt": true, "lastHeartbeat": 1_753_000_000_000],
            delete: ["expireAt"]
        )

        let fields = try transport.lastBodyJSON()["fields"] as! [String: [String: Any]]
        XCTAssertEqual(fields["pairConfirmedAt"]?["booleanValue"] as? Bool, true)
        XCTAssertEqual(fields["lastHeartbeat"]?["integerValue"] as? String, "1753000000000")
    }

    // MARK: - Config

    func testAPlistMissingItsProjectIdSaysSoInsteadOfFailingLater() throws {
        XCTAssertThrowsError(
            try FirebaseProjectConfig(
                plist: ["API_KEY": "k"], apiBaseURL: URL(string: "https://x.test")!
            )
        )
        XCTAssertThrowsError(
            try FirebaseProjectConfig(
                plist: ["PROJECT_ID": "p"], apiBaseURL: URL(string: "https://x.test")!
            )
        )
        let good = try FirebaseProjectConfig(
            plist: ["PROJECT_ID": "p", "API_KEY": "k"], apiBaseURL: URL(string: "https://x.test")!
        )
        XCTAssertEqual(good.projectID, "p")
        XCTAssertTrue(good.documentsRoot.hasSuffix("/projects/p/databases/(default)/documents"))
    }

    // MARK: - Helpers

    private func signInStub(_ client: FirestoreREST, transport: StubTransport) async throws {
        transport.prepend(
            .ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}")
        )
        try await client.signIn(customToken: "ct")
    }
}

/// Records requests and replays queued responses, so every test above runs offline.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Response {
        case ok(String)
        case status(Int, String)

        var parts: (Data, Int) {
            switch self {
            case .ok(let body): return (Data(body.utf8), 200)
            case .status(let code, let body): return (Data(body.utf8), code)
            }
        }
    }

    private let lock = NSLock()
    private var queue: [Response]
    private(set) var requests: [URLRequest] = []
    /// `httpBody` is nil on a request read back from `URLRequest` in some paths, so bodies are captured
    /// at send time rather than reconstructed afterwards.
    private(set) var bodies: [Data?] = []

    init(responses: [Response]) { self.queue = responses }

    func prepend(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        queue.insert(response, at: 0)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        bodies.append(request.httpBody)
        guard !queue.isEmpty else {
            throw FirestoreRESTError.malformedResponse(
                "StubTransport ran out of responses after \(requests.count) requests"
            )
        }
        return queue.removeFirst().parts
    }

    func lastRequest() throws -> URLRequest {
        lock.lock(); defer { lock.unlock() }
        guard let last = requests.last else {
            throw FirestoreRESTError.malformedResponse("no requests were sent")
        }
        return last
    }

    func lastBodyJSON() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let body = bodies.last, let data = body else {
            throw FirestoreRESTError.malformedResponse("the last request had no body")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirestoreRESTError.malformedResponse("the last body was not a JSON object")
        }
        return json
    }
}
