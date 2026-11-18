import Foundation

/// Firebase Storage over REST — the audio upload P4 depends on.
///
/// ⚠ **This did not exist.** The Firestore client is Firestore-only, so P3's audio had nowhere to
/// go: the podcast would be generated, downloaded, transcoded, and then dropped. The frontend's
/// Podcasts page streams the returned URL directly from an `<audio src>`, which is why the upload
/// must come back with a **download-token URL** rather than a bare object path.
///
/// The `Firebase <idToken>` authorization scheme is Storage's, not Firestore's `Bearer` — a detail
/// with no error message worth reading if you get it wrong.
public actor FirebaseStorage {

    public enum StorageError: Error, Equatable {
        case notAuthenticated
        case noBucket
        case http(status: Int, body: String)
        case malformedResponse(String)
        /// The upload succeeded and returned no download token — so the object exists and nothing
        /// can play it. Its own case because "uploaded" and "playable" are different facts.
        case noDownloadToken
    }

    private let bucket: String
    private let transport: HTTPTransport
    private let tokenProvider: @Sendable () async throws -> String

    public init(
        bucket: String, transport: HTTPTransport = URLSessionTransport(),
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.bucket = bucket
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    /// Where a run's audio lives. Mirrors the backend exactly — the frontend and the storage rules
    /// both key on this shape, so a different layout uploads successfully to a path nothing reads.
    public static func audioObjectPath(
        ownerUID: String, researchID: String, filename: String
    ) -> String {
        "audio/\(ownerUID)/\(researchID)/\(filename)"
    }

    /// The content type, by extension.
    ///
    /// ⚠ Not cosmetic: a browser will refuse to play an `audio/*` it cannot identify, so an mp3
    /// uploaded as a generic type produces a Podcasts page with a player that does nothing.
    public static func contentType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".mp3") { return "audio/mpeg" }
        if lower.hasSuffix(".m4a") || lower.hasSuffix(".mp4") { return "audio/mp4" }
        return "audio/*"
    }

    /// Percent-encode an object path for the `name=` query and the download URL.
    ///
    /// ⚠ Slashes MUST be encoded. Firebase Storage is a flat key-value store whose "folders" are
    /// just slashes in the key, so an unencoded path is read as a URL path and the object lands
    /// somewhere else entirely — or 404s on read while the upload reported success.
    static func encode(_ path: String) -> String {
        path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        ) ?? path
    }

    /// Upload *data* and return a URL the frontend can stream without an Authorization header.
    public func upload(
        data: Data, ownerUID: String, researchID: String, filename: String
    ) async throws -> String {
        guard !bucket.isEmpty else { throw StorageError.noBucket }
        let token = try await tokenProvider()
        guard !token.isEmpty else { throw StorageError.notAuthenticated }

        let objectPath = Self.audioObjectPath(
            ownerUID: ownerUID, researchID: researchID, filename: filename
        )
        let encoded = Self.encode(objectPath)
        let url = URL(string:
            "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o"
            + "?uploadType=media&name=\(encoded)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // ⚠ `Firebase`, not `Bearer`. Storage's scheme differs from Firestore's, and the failure is
        // a 401 that names nothing.
        request.setValue("Firebase \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contentType(for: filename), forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (body, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw StorageError.http(
                status: status, body: String(data: body, encoding: .utf8) ?? "<non-utf8>"
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw StorageError.malformedResponse("the upload response was not a JSON object")
        }
        // Firebase returns a COMMA-SEPARATED list; the first entry is the active one.
        let tokens = (json["downloadTokens"] as? String ?? "")
            .split(separator: ",").map(String.init)
        guard let downloadToken = tokens.first, !downloadToken.isEmpty else {
            throw StorageError.noDownloadToken
        }
        return "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o/"
            + "\(encoded)?alt=media&token=\(downloadToken)"
    }
}
