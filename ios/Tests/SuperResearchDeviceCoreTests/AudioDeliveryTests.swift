import XCTest

@testable import SuperResearchDeviceCore

/// Getting the podcast into Storage and telling the frontend where it is.
final class AudioDeliveryTests: XCTestCase {

    private func storage(_ transport: StubTransport) -> FirebaseStorage {
        FirebaseStorage(bucket: "proj.appspot.com", transport: transport) { "id-1" }
    }

    private let ok = StubTransport.Response.ok(#"{"downloadTokens":"tok-1"}"#)
    /// An ISO base-media `ftyp` box at offset 4 — what NotebookLM actually hands back.
    private let m4a = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])
    private let mp3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00])

    func testTheFilenameIsDerivedFromTheRunAndNotFromTheTitle() {
        // NotebookLM's own download name is title-derived: arbitrary, non-unique, and sometimes
        // full of characters needing URL escaping. Two runs on one topic would collide in Storage.
        XCTAssertEqual(AudioDelivery.filename(researchID: "res-1"), "podcast-res-1.mp3")
        XCTAssertNotEqual(
            AudioDelivery.filename(researchID: "res-1"),
            AudioDelivery.filename(researchID: "res-2")
        )
    }

    func testTheAudioIsUploadedAndAStreamableURLComesBack() async throws {
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: mp3, ownerUID: "owner-1", researchID: "res-1", storage: storage(transport)
        )
        XCTAssertTrue(delivered.url.contains("alt=media"))
        XCTAssertTrue(delivered.url.contains("podcast-res-1.mp3"))
    }

    func testEMPTYAudioIsRefusedBEFOREItIsUploaded() async {
        // A zero-byte object uploads happily, returns a valid URL, and puts a player on the
        // Podcasts page that plays silence — indistinguishable from an unlistened podcast.
        let transport = StubTransport(responses: [])
        do {
            _ = try await AudioDelivery.deliver(
                audio: Data(), ownerUID: "u", researchID: "r", storage: storage(transport)
            )
            XCTFail("empty audio must not be uploaded")
        } catch AudioDelivery.DeliveryError.emptyAudio {
            XCTAssertTrue(transport.requests.isEmpty, "it uploaded nothing-bytes anyway")
        } catch {
            XCTFail("expected .emptyAudio, got \(error)")
        }
    }

    // MARK: - The link the frontend actually reads

    func testTheLinkFieldIsAUDIOFILEAndNotAUDIO() {
        // ⛔ Different fields, different consumers. `links.audio` is the NotebookLM SHARE PAGE — a
        // web page — which the Doc renders as "Audio Overview". `links.audio_file` is the
        // downloadable object the YouTube step fetches. Swapping them hands P4 an HTML page to
        // upload as a video.
        let patch = AudioDelivery.linkPatch(url: "https://example.test/a.mp3")
        XCTAssertNotNil(patch["links.audio_file"])
        XCTAssertNil(patch["links.audio"])
    }

    func testTheLinkIsAMAPWithAUrlMemberAndNotABareString() throws {
        // ⛔ MEASURED in the frontend, at three call sites including the P3-handoff gate:
        // `linksAgg.audio_file?.url`. A bare string leaves that read undefined, so the cloud takes
        // its "no usable audio" fast path — P4 skipped, P5 completed — and the finished research
        // has no podcast and no error anywhere.
        let patch = AudioDelivery.linkPatch(url: "https://example.test/a.mp3")
        guard case .map(let record)? = patch["links.audio_file"] else {
            return XCTFail("links.audio_file must be a map, not \(String(describing: patch["links.audio_file"]))")
        }
        XCTAssertEqual(record["url"], .string("https://example.test/a.mp3"))
        // The label is what the P5 Doc composer renders verbatim.
        XCTAssertEqual(record["label"], .string("Podcast Audio (Storage)"))
        XCTAssertEqual(record["phase"], .integer(3))
    }

    func testTheNotebookPatchWritesBOTHSlotsAndCarriesTheACCESSVerdict() throws {
        // Two slots because the frontend consumes them differently — `notebooklm` is the P3 tile's
        // "Open NotebookLM" row, `audio` is what the Doc renders as "Audio Overview".
        let patch = AudioDelivery.notebookLinkPatch(
            url: "https://notebook.google.com/notebook/abc", publicVerified: false
        )
        guard case .map(let notebook)? = patch["links.notebooklm"],
              case .map(let audio)? = patch["links.audio"] else {
            return XCTFail("both link slots must be written")
        }
        // ⚠ `verified` carries the PUBLIC-ACCESS verdict, not "we got a URL". A private notebook's
        // URL is well-formed and shaped identically to a public one; the recipient of the P5 email
        // gets "Request access" instead of a notebook, and nothing upstream can tell.
        XCTAssertEqual(notebook["verified"], .boolean(false))
        XCTAssertEqual(audio["verified"], .boolean(false))
        XCTAssertEqual(notebook["url"], .string("https://notebook.google.com/notebook/abc"))
    }

    func testAVerifiedShareMarksBothLinksVerified() throws {
        let patch = AudioDelivery.notebookLinkPatch(url: "https://x.test/notebook/1", publicVerified: true)
        guard case .map(let notebook)? = patch["links.notebooklm"] else { return XCTFail("no slot") }
        XCTAssertEqual(notebook["verified"], .boolean(true))
    }
}


/// Renaming is not converting — and refusing is not delivering.
///
/// ⛔ The cheap way to satisfy "we need MP3" is to change the extension and upload the same AAC
/// bytes. The object then has an `.mp3` name, the URL works, a lenient player may even play it —
/// and it is not an MP3. Every consumer that actually inspects the file fails on something that
/// looks correct everywhere else.
///
/// ⛔ **And the opposite mistake is just as real.** An earlier version of this guard REFUSED to
/// upload anything that was not an MP3, which is stricter than the backend it copies: that
/// transcode is explicitly *"best-effort and non-raising … returns the ORIGINAL path unchanged so
/// the podcast is never lost"*. Refusing turns "the podcast streams awkwardly for one consumer"
/// into "there is no podcast", at the end of a run that has already spent three deep-research units.
final class AudioFormatGuardTests: XCTestCase {

    /// An ID3v2 tag — the ordinary start of an encoder's output.
    private let mp3ID3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00])
    /// A raw MPEG frame sync, for encoders that emit no tag.
    private let mp3Sync = Data([0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00])
    private let m4a = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])
    private let ok = StubTransport.Response.ok(#"{"downloadTokens":"tok-1"}"#)

    private func storage(_ transport: StubTransport) -> FirebaseStorage {
        FirebaseStorage(bucket: "p.appspot.com", transport: transport) { "id-1" }
    }

    func testTheFormatIsReadFromTheBYTESNotTheFilename() {
        XCTAssertEqual(AudioDelivery.AudioFormat.sniff(mp3ID3), .mp3)
        XCTAssertEqual(AudioDelivery.AudioFormat.sniff(mp3Sync), .mp3)
        XCTAssertEqual(AudioDelivery.AudioFormat.sniff(m4a), .m4a)
    }

    func testAACBytesAreNEVERUploadedUnderAnMp3Name() async throws {
        // The mislabelling this whole file is organised around. With no encoder linked the bytes go
        // up as what they ARE — the name follows the content, so the two cannot disagree.
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: m4a, ownerUID: "u", researchID: "r", storage: storage(transport)
        )
        XCTAssertEqual(delivered.format, "m4a")
        XCTAssertTrue(delivered.url.contains("podcast-r.m4a"))
        XCTAssertFalse(delivered.url.contains(".mp3"), "AAC bytes were named .mp3")
        // ⭐ And it is REPORTED as a degrade, so a run whose podcast is not the requested format
        // says so rather than being indistinguishable from a clean one.
        XCTAssertTrue(delivered.degraded)
        XCTAssertTrue(delivered.reason.contains("licence"), "the reason must name the actual cause")
    }

    func testTheAudioIsSTILLDELIVEREDWhenNoEncoderIsLinked() async throws {
        // ⛔ The regression this replaces: the run reached the end, produced a podcast, and threw it
        // away because it was the wrong container. The transport call count is the mechanism — the
        // upload has to have actually happened.
        let transport = StubTransport(responses: [ok])
        _ = try await AudioDelivery.deliver(
            audio: m4a, ownerUID: "u", researchID: "r", storage: storage(transport)
        )
        XCTAssertEqual(transport.requests.count, 1, "the podcast was not uploaded at all")
    }

    func testTheContentTypeFollowsTheREALFormat() async throws {
        // Not cosmetic: a browser refuses to play an `audio/*` it cannot identify, so a Podcasts
        // page gets a player that does nothing.
        let transport = StubTransport(responses: [ok])
        _ = try await AudioDelivery.deliver(
            audio: m4a, ownerUID: "u", researchID: "r", storage: storage(transport)
        )
        XCTAssertEqual(
            try transport.lastRequest().value(forHTTPHeaderField: "Content-Type"), "audio/mp4"
        )
    }

    func testAWORKINGTranscoderProducesAnMp3Object() async throws {
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: m4a, ownerUID: "u", researchID: "res-9", storage: storage(transport),
            transcoder: FakeTranscoder(.encoded(Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00])))
        )
        XCTAssertEqual(delivered.format, "mp3")
        XCTAssertFalse(delivered.degraded)
        XCTAssertTrue(delivered.url.contains("podcast-res-9.mp3"))
        XCTAssertEqual(
            try transport.lastRequest().value(forHTTPHeaderField: "Content-Type"), "audio/mpeg"
        )
    }

    func testATranscoderThatReturnsNonMP3BytesIsNOTBelieved() async throws {
        // ⛔ The subtle one. A broken encoder that hands back the input, or a truncated file, would
        // otherwise be uploaded as `.mp3` on the strength of having been *called* — the exact
        // name-lies-about-bytes failure, reintroduced through the seam built to prevent it.
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: m4a, ownerUID: "u", researchID: "r", storage: storage(transport),
            transcoder: FakeTranscoder(.encoded(Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70])))
        )
        XCTAssertEqual(delivered.format, "m4a")
        XCTAssertTrue(delivered.degraded)
        XCTAssertTrue(delivered.reason.contains("not MP3"))
    }

    func testAnEmptyTranscodeIsNotBelievedEither() async throws {
        // An encoder that exits 0 having written nothing. The backend guards the same case by
        // requiring the destination to exist AND be non-empty before adopting it.
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: m4a, ownerUID: "u", researchID: "r", storage: storage(transport),
            transcoder: FakeTranscoder(.encoded(Data()))
        )
        XCTAssertEqual(delivered.format, "m4a")
        XCTAssertTrue(delivered.degraded)
    }

    func testAlreadyMP3AudioIsNOTReEncoded() async throws {
        // Idempotent, matching the backend's own first line. Re-encoding costs a generation of
        // quality for no gain; the mechanism asserted is that the transcoder is never ASKED.
        let transport = StubTransport(responses: [ok])
        let transcoder = FakeTranscoder(.encoded(Data([0xFF, 0xFB, 0x00, 0x00])))
        let delivered = try await AudioDelivery.deliver(
            audio: mp3ID3, ownerUID: "u", researchID: "r", storage: storage(transport),
            transcoder: transcoder
        )
        let calls = await transcoder.calls
        XCTAssertEqual(calls, 0, "an MP3 was handed to the encoder anyway")
        XCTAssertEqual(delivered.format, "mp3")
        XCTAssertFalse(delivered.degraded)
    }

    func testAnUnknownContainerKeepsThePlatformsDefaultRatherThanBeingGuessedAt() async throws {
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: Data([0x01, 0x02, 0x03, 0x04, 0x05]), ownerUID: "u", researchID: "r",
            storage: storage(transport)
        )
        XCTAssertEqual(delivered.format, "m4a")
        XCTAssertFalse(delivered.url.contains(".mp3"))
    }
}

/// Records whether it was called, because "did the encode run" is the fact several of these assert.
private actor FakeTranscoder: AudioTranscoder {
    private let result: TranscodeResult
    private(set) var calls = 0

    init(_ result: TranscodeResult) { self.result = result }

    func toMP3(_ data: Data) async -> TranscodeResult {
        calls += 1
        return result
    }
}

/// The remux has to run on the REAL upload path, not merely exist.
///
/// ⭐ This is the permanent answer to "we need MP3": the reason the desktop transcodes is that
/// NotebookLM's `.m4a` keeps its index after the audio, so a streaming consumer cannot start. Moving
/// the index fixes that directly — losslessly, with no encoder and no licence — and every measured
/// consumer already accepts the container.
final class AudioStreamabilityTests: XCTestCase {

    private let ok = StubTransport.Response.ok(#"{"downloadTokens":"tok-1"}"#)
    private let audio = Data(repeating: 0xAB, count: 400)

    private func storage(_ transport: StubTransport) -> FirebaseStorage {
        FirebaseStorage(bucket: "p.appspot.com", transport: transport) { "id-1" }
    }

    func testTheUPLOADEDBytesHaveTheirIndexAtTheFRONT() async throws {
        // ⛔ The mechanism, asserted on what actually went over the wire. A remux that runs and is
        // then not uploaded is the same as no remux at all.
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: ISOBMFF.indexAtTheEnd(audio: audio, offsets: [16]),
            ownerUID: "u", researchID: "r", storage: storage(transport)
        )

        let body = try XCTUnwrap(transport.lastRequest().httpBody)
        let types = (AudioFaststart.topLevelBoxes(body) ?? []).map(\.type)
        XCTAssertEqual(types, ["ftyp", "moov", "mdat"])
        XCTAssertTrue(delivered.streamable)
        XCTAssertTrue(delivered.reason.contains("index moved"), delivered.reason)
    }

    func testAnMP3IsUploadedUNTOUCHEDAndIsStillStreamable() async throws {
        // Every MP3 frame describes itself, so there is no index to move — and rearranging one
        // would be corruption. Streamable is TRUE for the same reason.
        let mp3 = Data([0x49, 0x44, 0x33, 0x03] + Array(repeating: UInt8(0x11), count: 60))
        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: mp3, ownerUID: "u", researchID: "r", storage: storage(transport)
        )
        XCTAssertEqual(try transport.lastRequest().httpBody, mp3)
        XCTAssertTrue(delivered.streamable)
    }

    func testAContainerThatCannotBeCorrectedIsSTILLDELIVERED() async throws {
        // ⚠ A podcast that must be downloaded before it plays is a far smaller problem than no
        // podcast — and the web app downloads either way. Recorded, not refused.
        var unfixable = ISOBMFF.box("ftyp", Data("M4A isom".utf8))
        unfixable.append(ISOBMFF.box("mdat", audio))
        unfixable.append(ISOBMFF.box("moov", ISOBMFF.box("trak", Data(repeating: 0, count: 8))))

        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: unfixable, ownerUID: "u", researchID: "r", storage: storage(transport)
        )

        XCTAssertEqual(transport.requests.count, 1, "the podcast was thrown away")
        XCTAssertFalse(delivered.streamable)
        XCTAssertTrue(delivered.reason.contains("stco/co64"), delivered.reason)
    }

    func testAFileWhoseIndexIsAlreadyFirstUploadsUnchanged() async throws {
        var already = ISOBMFF.box("ftyp", Data("M4A isom".utf8))
        already.append(ISOBMFF.moov(offsetTable: ISOBMFF.stco([500])))
        already.append(ISOBMFF.box("mdat", audio))

        let transport = StubTransport(responses: [ok])
        let delivered = try await AudioDelivery.deliver(
            audio: already, ownerUID: "u", researchID: "r", storage: storage(transport)
        )
        XCTAssertEqual(try transport.lastRequest().httpBody, already)
        XCTAssertTrue(delivered.streamable)
    }
}
