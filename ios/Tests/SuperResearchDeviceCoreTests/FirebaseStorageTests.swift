import XCTest

@testable import SuperResearchDeviceCore

/// The audio upload P4 depends on — and the client that did not exist until now.
final class FirebaseStorageTests: XCTestCase {

    private func storage(
        _ transport: StubTransport, bucket: String = "proj.appspot.com", token: String = "id-1"
    ) -> FirebaseStorage {
        FirebaseStorage(bucket: bucket, transport: transport) { token }
    }

    private let ok = StubTransport.Response.ok(#"{"name":"audio/u/r/p.mp3","downloadTokens":"tok-1"}"#)

    func testTheObjectPathMirrorsTheBackendExactly() {
        // The frontend and the storage RULES both key on this shape. A different layout uploads
        // successfully to a path nothing reads and nothing is authorised for.
        XCTAssertEqual(
            FirebaseStorage.audioObjectPath(
                ownerUID: "owner-1", researchID: "res-1", filename: "podcast.mp3"
            ),
            "audio/owner-1/res-1/podcast.mp3"
        )
    }

    func testSlashesAreENCODEDInTheObjectName() {
        // ⚠ Storage is a flat key-value store whose "folders" are slashes in the key. Unencoded,
        // the path is read as a URL path and the object lands somewhere else — or 404s on read
        // while the upload reported success.
        let encoded = FirebaseStorage.encode("audio/owner-1/res-1/podcast.mp3")
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertTrue(encoded.contains("%2F"))
    }

    func testTheContentTypeIsSpecificEnoughForABrowserToPlayIt() {
        // A browser refuses to play an `audio/*` it cannot identify, so a generic type yields a
        // Podcasts page with a player that does nothing.
        XCTAssertEqual(FirebaseStorage.contentType(for: "a.mp3"), "audio/mpeg")
        XCTAssertEqual(FirebaseStorage.contentType(for: "A.MP3"), "audio/mpeg")
        XCTAssertEqual(FirebaseStorage.contentType(for: "a.m4a"), "audio/mp4")
        XCTAssertEqual(FirebaseStorage.contentType(for: "a.wav"), "audio/*")
    }

    func testAnUploadSendsTheFIREBASESchemeAndNotBearer() async throws {
        // ⚠ Storage's scheme differs from Firestore's, and the failure is a 401 that names nothing.
        let transport = StubTransport(responses: [ok])
        _ = try await storage(transport).upload(
            data: Data("x".utf8), ownerUID: "owner-1", researchID: "res-1", filename: "p.mp3"
        )
        let request = try transport.lastRequest()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Firebase id-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/mpeg")
        XCTAssertTrue(request.url?.absoluteString.contains("uploadType=media") ?? false)
        XCTAssertTrue(request.url?.absoluteString.contains("audio%2Fowner-1%2Fres-1%2Fp.mp3") ?? false)
    }

    func testTheReturnedURLIsSTREAMABLEWithoutAnAuthorizationHeader() async throws {
        // The frontend puts this straight into an `<audio src>`. A bare object path there plays
        // nothing, and a URL needing a header plays nothing either.
        let transport = StubTransport(responses: [ok])
        let url = try await storage(transport).upload(
            data: Data("x".utf8), ownerUID: "owner-1", researchID: "res-1", filename: "p.mp3"
        )
        XCTAssertTrue(url.contains("alt=media"))
        XCTAssertTrue(url.contains("token=tok-1"))
        XCTAssertTrue(url.hasPrefix("https://firebasestorage.googleapis.com/v0/b/proj.appspot.com/o/"))
    }

    func testTheFIRSTOfSeveralDownloadTokensIsUsed() async throws {
        // Firebase returns a comma-separated list; the first entry is the active one.
        let transport = StubTransport(responses: [
            .ok(#"{"downloadTokens":"tok-active,tok-old,tok-older"}"#)
        ])
        let url = try await storage(transport).upload(
            data: Data("x".utf8), ownerUID: "u", researchID: "r", filename: "p.mp3"
        )
        XCTAssertTrue(url.hasSuffix("token=tok-active"))
    }

    func testAnUploadWithNODownloadTokenIsAnERRORAndNotASuccess() async {
        // "Uploaded" and "playable" are different facts. Returning the object path here would put a
        // dead link on the Podcasts page for a run that otherwise succeeded.
        let transport = StubTransport(responses: [.ok(#"{"name":"audio/u/r/p.mp3"}"#)])
        do {
            _ = try await storage(transport).upload(
                data: Data("x".utf8), ownerUID: "u", researchID: "r", filename: "p.mp3"
            )
            XCTFail("a tokenless upload must not be reported as a success")
        } catch FirebaseStorage.StorageError.noDownloadToken {
            // right
        } catch {
            XCTFail("expected .noDownloadToken, got \(error)")
        }
    }

    func testAnHTTPFailureCarriesItsStatusAndBody() async {
        let transport = StubTransport(responses: [.status(403, "Permission denied")])
        do {
            _ = try await storage(transport).upload(
                data: Data("x".utf8), ownerUID: "u", researchID: "r", filename: "p.mp3"
            )
            XCTFail("must throw")
        } catch FirebaseStorage.StorageError.http(let status, let body) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body, "Permission denied")
        } catch {
            XCTFail("expected .http, got \(error)")
        }
    }

    func testAMissingBucketFailsBEFOREAnyRequestIsMade() async {
        // A blank bucket produces a URL that is syntactically fine and points nowhere useful.
        let transport = StubTransport(responses: [])
        do {
            _ = try await FirebaseStorage(bucket: "", transport: transport) { "id-1" }
                .upload(data: Data("x".utf8), ownerUID: "u", researchID: "r", filename: "p.mp3")
            XCTFail("must throw")
        } catch FirebaseStorage.StorageError.noBucket {
            XCTAssertTrue(transport.requests.isEmpty, "it sent a request with no bucket")
        } catch {
            XCTFail("expected .noBucket, got \(error)")
        }
    }

    func testAnEmptyTokenFailsBEFOREAnyRequestIsMade() async {
        let transport = StubTransport(responses: [])
        do {
            _ = try await FirebaseStorage(bucket: "b", transport: transport) { "" }
                .upload(data: Data("x".utf8), ownerUID: "u", researchID: "r", filename: "p.mp3")
            XCTFail("must throw")
        } catch FirebaseStorage.StorageError.notAuthenticated {
            XCTAssertTrue(transport.requests.isEmpty)
        } catch {
            XCTFail("expected .notAuthenticated, got \(error)")
        }
    }

    func testTheBODYIsTheAudioAndNotAJSONWrapper() async throws {
        let transport = StubTransport(responses: [ok])
        let audio = Data([0xFF, 0xFB, 0x90, 0x00])
        _ = try await storage(transport).upload(
            data: audio, ownerUID: "u", researchID: "r", filename: "p.mp3"
        )
        XCTAssertEqual(try transport.lastRequest().httpBody, audio)
    }
}
