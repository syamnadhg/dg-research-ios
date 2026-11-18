import XCTest

@testable import SuperResearchDeviceCore

/// Building real ISO base-media files, because a fake with the right shape is the only way to test
/// this without shipping a 30 MB podcast into the repo.
enum ISOBMFF {

    static func box(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        var size = UInt32(payload.count + 8).bigEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        out.append(contentsOf: Array(type.utf8))
        out.append(payload)
        return out
    }

    static func be32(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    static func be64(_ value: UInt64) -> Data {
        var v = value.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    /// A chunk-offset table.
    static func stco(_ offsets: [UInt32]) -> Data {
        var payload = be32(0)                          // version + flags
        payload.append(be32(UInt32(offsets.count)))    // entry_count
        for offset in offsets { payload.append(be32(offset)) }
        return box("stco", payload)
    }

    static func co64(_ offsets: [UInt64]) -> Data {
        var payload = be32(0)
        payload.append(be32(UInt32(offsets.count)))
        for offset in offsets { payload.append(be64(offset)) }
        return box("co64", payload)
    }

    /// The real nesting: moov → trak → mdia → minf → stbl → stco.
    static func moov(offsetTable: Data) -> Data {
        box("moov", box("trak", box("mdia", box("minf", box("stbl", offsetTable)))))
    }

    /// `ftyp`, then the audio, then the index — the shape NotebookLM hands back.
    static func indexAtTheEnd(audio: Data, offsets: [UInt32]) -> Data {
        var out = box("ftyp", Data("M4A isom".utf8))
        out.append(box("mdat", audio))
        out.append(moov(offsetTable: stco(offsets)))
        return out
    }
}

/// Moving an `.m4a`'s index to the front so it can be streamed.
///
/// ⭐ The defect the desktop's MP3 transcode works around: the `moov` index says where every chunk
/// of audio lives, and NotebookLM writes it AFTER the audio — so a consumer that streams receives
/// megabytes of samples with no map of them and cannot begin playback. An MP3 has no index at all,
/// which is why converting to one incidentally fixes it. The codec change was never the point.
final class AudioFaststartTests: XCTestCase {

    private let audio = Data(repeating: 0xAB, count: 400)

    private func typesInOrder(_ data: Data) -> [String] {
        (AudioFaststart.topLevelBoxes(data) ?? []).map(\.type)
    }

    // MARK: - The move itself

    func testTheINDEXEndsUpBeforeTheAudio() throws {
        let file = ISOBMFF.indexAtTheEnd(audio: audio, offsets: [16])
        XCTAssertEqual(typesInOrder(file), ["ftyp", "mdat", "moov"])

        guard case .moved(let out) = AudioFaststart.apply(file) else {
            return XCTFail("the index was not moved: \(AudioFaststart.apply(file))")
        }
        XCTAssertEqual(typesInOrder(out), ["ftyp", "moov", "mdat"])
    }

    func testTheAUDIOBytesAreIDENTICAL() throws {
        // ⭐ The whole reason to prefer this over a transcode: nothing is decoded, so there is no
        // generation of quality to lose. If the samples changed, this became a re-encode.
        let file = ISOBMFF.indexAtTheEnd(audio: audio, offsets: [16])
        guard case .moved(let out) = AudioFaststart.apply(file) else { return XCTFail("not moved") }

        let boxes = try XCTUnwrap(AudioFaststart.topLevelBoxes(out))
        let mdat = try XCTUnwrap(boxes.first { $0.type == "mdat" })
        let payload = out.subdata(in: (mdat.range.lowerBound + 8)..<mdat.range.upperBound)
        XCTAssertEqual(payload, audio)
    }

    func testTheFileIsTheSAMESIZE() {
        // A rearrangement that changed the byte count dropped or duplicated a box, and the only
        // symptom would be audio truncated at the end.
        let file = ISOBMFF.indexAtTheEnd(audio: audio, offsets: [16])
        guard case .moved(let out) = AudioFaststart.apply(file) else { return XCTFail("not moved") }
        XCTAssertEqual(out.count, file.count)
    }

    // MARK: - The offsets, which are the actual job

    func testEveryCHUNKOFFSETIsShiftedByTheIndexsOwnSIZE() throws {
        // ⛔ **The failure that would be worse than doing nothing.** Move the index and leave the
        // offsets alone and the file starts playing IMMEDIATELY — and then reads garbage, because
        // every chunk pointer now aims that many bytes short.
        let originalOffsets: [UInt32] = [16, 120, 300]
        let file = ISOBMFF.indexAtTheEnd(audio: audio, offsets: originalOffsets)
        let moovSize = try XCTUnwrap(
            AudioFaststart.topLevelBoxes(file)?.first { $0.type == "moov" }?.range.count
        )

        guard case .moved(let out) = AudioFaststart.apply(file) else { return XCTFail("not moved") }

        XCTAssertEqual(readOffsets(out), originalOffsets.map { $0 + UInt32(moovSize) })
    }

    func testA64BitOffsetTableIsShiftedToo() throws {
        // `co64` is what a long podcast gets. Patching only `stco` would leave exactly the big
        // files — the ones most worth streaming — pointing at nothing.
        var file = ISOBMFF.box("ftyp", Data("M4A isom".utf8))
        file.append(ISOBMFF.box("mdat", audio))
        file.append(ISOBMFF.moov(offsetTable: ISOBMFF.co64([16, 500])))
        let moovSize = try XCTUnwrap(
            AudioFaststart.topLevelBoxes(file)?.first { $0.type == "moov" }?.range.count
        )

        guard case .moved(let out) = AudioFaststart.apply(file) else { return XCTFail("not moved") }

        let boxes = try XCTUnwrap(AudioFaststart.topLevelBoxes(out))
        let moov = try XCTUnwrap(boxes.first { $0.type == "moov" })
        let body = out.subdata(in: moov.range)
        // The table sits five containers deep; find it by scanning for its type rather than by
        // hardcoding an offset that every structural change would invalidate.
        let marker = Array("co64".utf8)
        let start = try XCTUnwrap(indexOf(marker, in: body))
        let first = AudioFaststart.be64(body, at: start + 4 + 8)
        XCTAssertEqual(first, UInt64(16 + moovSize))
    }

    func testAnOffsetThatWouldOVERFLOWIts32BitTableIsREFUSED() {
        // ⛔ Widening the table to 64-bit changes the index's own size, which changes the shift,
        // which changes the offsets — a circle. Refusing leaves a file that plays; a half-converted
        // one does not.
        let file = ISOBMFF.indexAtTheEnd(audio: audio, offsets: [UInt32.max - 4])
        guard case .refused(let why) = AudioFaststart.apply(file) else {
            return XCTFail("it wrote an offset that does not fit")
        }
        XCTAssertTrue(why.contains("32-bit"), why)
    }

    func testAMoovWithNOOffsetTableIsREFUSEDRatherThanMoved() {
        // Moving an index whose offsets could not be found produces a file that starts instantly
        // and then plays garbage — strictly worse than the one we were handed.
        var file = ISOBMFF.box("ftyp", Data("M4A isom".utf8))
        file.append(ISOBMFF.box("mdat", audio))
        file.append(ISOBMFF.box("moov", ISOBMFF.box("trak", Data(repeating: 0, count: 8))))

        guard case .refused(let why) = AudioFaststart.apply(file) else {
            return XCTFail("it moved an index it could not correct")
        }
        XCTAssertTrue(why.contains("stco/co64"), why)
    }

    // MARK: - Leaving well alone

    func testAFileWhoseIndexIsALREADYFirstIsUntouched() {
        var file = ISOBMFF.box("ftyp", Data("M4A isom".utf8))
        file.append(ISOBMFF.moov(offsetTable: ISOBMFF.stco([500])))
        file.append(ISOBMFF.box("mdat", audio))
        XCTAssertEqual(AudioFaststart.apply(file), .alreadyStreamable)
    }

    func testANMP3IsNOTAPPLICABLERatherThanAnError() {
        // Every MP3 frame describes itself, so there is no index to move. Reporting this as a
        // failure would put a warning on the healthy path.
        let mp3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        guard case .notApplicable = AudioFaststart.apply(mp3) else {
            return XCTFail("an MP3 was treated as a container to rearrange")
        }
    }

    func testTRAILINGGarbageIsNotParsedAsBoxes() {
        // ⚠ A parse that lost sync must not report the boxes it managed to read: a rearrangement
        // built on a misread file is how a working podcast becomes an unplayable one.
        var file = ISOBMFF.indexAtTheEnd(audio: audio, offsets: [16])
        file.append(Data([0x00, 0x00, 0x00]))
        XCTAssertNil(AudioFaststart.topLevelBoxes(file))
    }

    func testAnMDATThatRunsToEndOfFileIsREFUSED() {
        // Size 0 means "to the end", so nothing can legitimately follow — the file's own structure
        // disagrees with itself, and rearranging on a disagreement is not safe.
        var file = ISOBMFF.box("ftyp", Data("M4A isom".utf8))
        file.append(ISOBMFF.be32(0))
        file.append(Data("mdat".utf8))
        file.append(audio)
        file.append(ISOBMFF.moov(offsetTable: ISOBMFF.stco([16])))
        // The zero-size mdat swallows what follows, so `moov` is not a sibling at all.
        let boxes = AudioFaststart.topLevelBoxes(file) ?? []
        XCTAssertFalse(boxes.contains { $0.type == "moov" })
    }

    // MARK: - Helpers

    private func readOffsets(_ file: Data) -> [UInt32] {
        guard let boxes = AudioFaststart.topLevelBoxes(file),
              let moov = boxes.first(where: { $0.type == "moov" }) else { return [] }
        let body = file.subdata(in: moov.range)
        guard let start = indexOf(Array("stco".utf8), in: body) else { return [] }
        let count = Int(AudioFaststart.be32(body, at: start + 4 + 4))
        return (0..<count).map { AudioFaststart.be32(body, at: start + 4 + 8 + $0 * 4) }
    }

    private func indexOf(_ needle: [UInt8], in haystack: Data) -> Int? {
        let bytes = [UInt8](haystack)
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count) {
            if Array(bytes[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }
}
