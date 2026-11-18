import XCTest

@testable import SuperResearchDeviceCore

/// The run's product: research documents, and the device identity every research write needs.
final class DocumentWriterTests: XCTestCase {

    private let config = FirebaseProjectConfig(
        projectID: "test-project", apiKey: "test-key",
        apiBaseURL: URL(string: "https://example.test")!, emulatorHost: nil
    )

    private func emitter(_ transport: StubTransport) async throws -> ContractEmitter {
        transport.prepend(.ok("{\"idToken\":\"id-1\",\"refreshToken\":\"r-1\",\"expiresIn\":\"3600\"}"))
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        return ContractEmitter(client: client, uid: "owner-1", researchId: "res-1",
                               deviceId: "dev-9", runId: "run-1")
    }

    // MARK: - ⭐ Item 18: deviceId on the research document itself

    func testTheRUNSTARTPatchCarriesTheDeviceId() async throws {
        // ⛔ The rule is `request.resource.data.deviceId == request.auth.token.deviceId` on the
        // research doc. Without the field in the WRITE, every research patch 403s and the run
        // cannot even start. The deviceId this repo already puts on pipeline_events is a different
        // field on a different document — which is exactly why this looked covered.
        let transport = StubTransport(responses: [.ok("{}")])
        let e = try await emitter(transport)
        try await e.startRun()
        let log = await e.written
        XCTAssertEqual(log.first?.fields["deviceId"], .string("dev-9"))
    }

    func testTheRUNFINISHPatchCarriesItTOO() async throws {
        // The subtler half: omitted here the run works right up to the moment it tries to finish,
        // and then cannot say that it did.
        let transport = StubTransport(responses: [.ok("{}"), .ok("{}")])
        let e = try await emitter(transport)
        try await e.finishRun(status: "complete")
        let patch = await e.written.last
        XCTAssertEqual(patch?.op, "patch")
        XCTAssertEqual(patch?.fields["deviceId"], .string("dev-9"))
        XCTAssertEqual(patch?.fields["status"], .string("complete"))
    }

    func testTheGoldenFixtureAgreesThatResearchPatchesCarryADeviceId() throws {
        // The fixture recorded the DEFECT — two research patches with no deviceId, which the real
        // rules would have rejected. Asserting against it here so the two cannot drift apart again
        // silently.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let golden = repo.appendingPathComponent("fixtures/golden/p0_p3_happy_path.jsonl")
        let text = try String(contentsOf: golden, encoding: .utf8)
        var researchPatches = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = entry["path"] as? String,
                  path == "users/{uid}/researches/{rid}",
                  entry["op"] as? String == "patch" else { continue }
            researchPatches += 1
            let fields = entry["fields"] as? [String: Any] ?? [:]
            XCTAssertEqual(fields["deviceId"] as? String, "{deviceId}",
                           "a research patch in the golden fixture has no deviceId: \(line)")
        }
        XCTAssertEqual(researchPatches, 2, "expected the start and finish patches")
    }

    // MARK: - The documents themselves

    func testADocumentIsWrittenAtItsDocTypeSoARerunOverwritesInPlace() async throws {
        let transport = StubTransport(responses: [.ok("{}")])
        let e = try await emitter(transport)

        let wrote = try await e.saveDocument(.chatgpt, content: "# Report\n\nBody text.")

        XCTAssertTrue(wrote)
        let log = await e.written
        let entry = try XCTUnwrap(log.last)
        XCTAssertEqual(entry.path, "users/owner-1/researches/res-1/documents/chatgpt")
        XCTAssertEqual(entry.fields["type"], .string("chatgpt"))
        XCTAssertEqual(entry.fields["name"], .string("chatgpt.md"))
        XCTAssertEqual(entry.fields["content"], .string("# Report\n\nBody text."))
        XCTAssertEqual(entry.fields["deviceId"], .string("dev-9"))
        XCTAssertNotNil(entry.fields["createdAt"])
    }

    func testAnEMPTYDocumentIsREFUSEDRatherThanWritten() async throws {
        // The frontend gates its "Read report" button on the document existing, so an empty write
        // earns a button that opens an empty modal — a run that looks finished and delivers nothing.
        let transport = StubTransport(responses: [])
        let e = try await emitter(transport)

        let wrote = try await e.saveDocument(.brief, content: "   \n\t\n  ")

        XCTAssertFalse(wrote)
        let log = await e.written
        XCTAssertTrue(log.isEmpty, "an empty document reached Firestore")
    }

    func testTheSizeStringIsComputedFromTheContent() async throws {
        let transport = StubTransport(responses: [.ok("{}")])
        let e = try await emitter(transport)
        try await e.saveDocument(.gemini, content: String(repeating: "x", count: 2048))
        let log = await e.written
        XCTAssertEqual(log.last?.fields["size"], .string("2 KB"))
    }

    func testAllFIVEDocTypesExistIncludingTheBriefAndTheConsolidated() {
        // ⚠ Five, not three. A run that writes only the three platform reports looks complete on
        // the Documents page and leaves P3 with nothing to make a podcast from.
        XCTAssertEqual(Set(ContractEmitter.DocType.allCases.map(\.rawValue)),
                       ["brief", "chatgpt", "claude", "gemini", "consolidated"])
    }

    func testEachDocTypeWritesToItsOwnPath() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 5))
        let e = try await emitter(transport)
        for docType in ContractEmitter.DocType.allCases {
            try await e.saveDocument(docType, content: "content for \(docType.rawValue)")
        }
        let paths = await e.written.map(\.path)
        XCTAssertEqual(Set(paths).count, 5, "two doc types shared a path: \(paths)")
        for docType in ContractEmitter.DocType.allCases {
            XCTAssertTrue(paths.contains { $0.hasSuffix("/documents/\(docType.rawValue)") })
        }
    }
}

/// `expireAt` must be a real Firestore timestamp, or the TTL never collects it.
final class ExpireAtTypeTests: XCTestCase {

    func testATimestampEncodesUnderTheTimestampTagAndNotAsAString() {
        // ⛔ Firestore's TTL reads `timestampValue` only. As a `stringValue` the field looks right
        // in the console, satisfies any rule that checks it exists, and is simply never collected.
        let json = FirestoreValue.timestamp("2026-09-07T12:00:00Z").json
        XCTAssertEqual(json["timestampValue"] as? String, "2026-09-07T12:00:00Z")
        XCTAssertNil(json["stringValue"], "written as a string, the TTL will never fire")
    }

    func testATimestampDecodesBackAsATimestampAndNotAsAString() {
        // Round-tripping a real timestamp out as a string would quietly disarm a working TTL.
        XCTAssertEqual(
            FirestoreValue.decode(["timestampValue": "2026-09-07T12:00:00Z"]),
            .timestamp("2026-09-07T12:00:00Z")
        )
    }

    func testAnOrdinaryStringIsStillAString() {
        XCTAssertEqual(FirestoreValue.decode(["stringValue": "hello"]), .string("hello"))
    }

    func testTheEVENTSExpireAtIsWrittenAsATimestamp() async throws {
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"i\",\"refreshToken\":\"r\",\"expiresIn\":\"3600\"}"), .ok("{}"),
        ])
        let client = FirestoreREST(
            config: FirebaseProjectConfig(projectID: "p", apiKey: "k",
                                          apiBaseURL: URL(string: "https://x.test")!,
                                          emulatorHost: nil),
            transport: transport
        )
        try await client.signIn(customToken: "ct")
        let emitter = ContractEmitter(client: client, uid: "u", researchId: "r",
                                      deviceId: "d", runId: "run")

        try await emitter.emit(type: "phase_start", phase: 0)

        let written = await emitter.written
        let expireAt = try XCTUnwrap(written.last?.fields["expireAt"])
        guard case .timestamp = expireAt else {
            return XCTFail("expireAt is \(expireAt) — as anything but a timestamp the TTL never fires")
        }
    }
}
