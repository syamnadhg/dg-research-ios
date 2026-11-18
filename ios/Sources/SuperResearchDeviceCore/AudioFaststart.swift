import Foundation

/// Move an `.m4a`'s index to the front so it can be streamed.
///
/// ⭐ **This is the actual defect the desktop's MP3 transcode works around.** An ISO base-media file
/// keeps its index — the `moov` box, which says where every chunk of audio lives — as a *box like
/// any other*, and NotebookLM writes it **after** the audio. A consumer that streams therefore
/// receives megabytes of samples with no map of them and cannot begin playback until the whole file
/// has arrived. An MP3 has no index at all (every frame describes itself), so converting to one
/// *incidentally* fixes it. The codec change was never the point.
///
/// ⭐ So this fixes it directly: the same audio bytes, the same container, the index moved ahead of
/// the samples. Nothing is decoded and nothing is re-encoded, so there is no quality generation to
/// lose, no encoder to vendor, and no licence to decide — the three costs the transcode route has
/// and this one does not.
///
/// ⚠ **The whole job is the offset fixup.** `stco`/`co64` hold ABSOLUTE file offsets for every
/// chunk. Moving the index forward pushes all the audio later by exactly the index's own size, so
/// every one of those offsets is now wrong — and a file with a correctly-placed index and stale
/// offsets is *worse* than the original: it starts playing immediately and then reads garbage.
public enum AudioFaststart {

    public enum Outcome: Equatable {
        /// The index is already ahead of the samples. Nothing to do.
        case alreadyStreamable
        case moved(Data)
        /// Not an ISO base-media file at all — an MP3, say, which needs none of this.
        case notApplicable(String)
        /// It could be done but not *safely*. Refused rather than attempted.
        case refused(String)
    }

    /// Boxes that contain other boxes, so the offset table can be found by walking rather than by
    /// guessing where it sits.
    ///
    /// ⚠ `stbl` is the one that matters and the other four are the path to it. A walker that only
    /// looked at the top level would find no `stco` at all and report a clean run having patched
    /// nothing — the silent version of this failure.
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts"]

    public static func apply(_ data: Data) -> Outcome {
        guard let boxes = topLevelBoxes(data) else {
            return .notApplicable("not an ISO base-media file — no boxes could be read")
        }
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            return .notApplicable("no moov box — this is not an indexed container")
        }
        guard let mdat = boxes.first(where: { $0.type == "mdat" }) else {
            return .notApplicable("no mdat box — there is no media to index")
        }
        if moov.range.lowerBound < mdat.range.lowerBound { return .alreadyStreamable }
        // ⚠ A zero-size box runs to the end of the file, so nothing can legitimately follow it.
        // Seeing `moov` after such an `mdat` means the parse disagrees with the file; rearranging
        // on a disagreement is how a working podcast becomes an unplayable one.
        guard !mdat.extendsToEOF else {
            return .refused("the mdat box runs to end-of-file yet moov follows it — the file's own "
                            + "structure is inconsistent, so it is left alone")
        }

        let delta = moov.range.count
        var index = data.subdata(in: moov.range)
        guard let patched = shiftChunkOffsets(in: &index, by: delta) else {
            return .refused("a chunk offset would not fit in its 32-bit table after the move; "
                            + "rewriting it as 64-bit changes the index's own size, which changes "
                            + "the shift — left alone rather than half-converted")
        }
        guard patched > 0 else {
            // ⛔ Zero patched entries means the walk found no offset table. Moving the index
            // anyway produces a file that starts instantly and then plays garbage — strictly worse
            // than the one we were handed.
            return .refused("no stco/co64 offset table was found inside moov, so the offsets "
                            + "could not be corrected")
        }

        var out = Data()
        out.reserveCapacity(data.count)
        for box in boxes where box.type != "moov" && box.range.lowerBound < mdat.range.lowerBound {
            out.append(data.subdata(in: box.range))
        }
        out.append(index)
        for box in boxes where box.type != "moov" && box.range.lowerBound >= mdat.range.lowerBound {
            out.append(data.subdata(in: box.range))
        }
        // ⚠ Same length, always. A rearrangement that changed the byte count means a box was
        // dropped or duplicated, and the only symptom would be truncated audio at the end.
        guard out.count == data.count else {
            return .refused("the rearranged file changed size (\(data.count) → \(out.count)) — "
                            + "a box was lost or duplicated")
        }
        return .moved(out)
    }

    // MARK: - Boxes

    struct Box: Equatable {
        let type: String
        let range: Range<Int>
        /// Size 0 means "to the end of the file" — legal only for the last box.
        let extendsToEOF: Bool
    }

    /// Read the top-level box list, or nil if the bytes are not a box structure at all.
    static func topLevelBoxes(_ data: Data) -> [Box]? {
        var boxes: [Box] = []
        var cursor = 0
        let total = data.count
        while cursor + 8 <= total {
            let size32 = Int(be32(data, at: cursor))
            guard let type = ascii(data, at: cursor + 4, length: 4) else { return nil }
            var size = size32
            var extendsToEOF = false
            if size32 == 1 {
                // 64-bit `largesize` follows the header. Real podcasts do exceed 4 GB nowhere near,
                // but a reader that cannot parse the form at all mis-frames every later box.
                guard cursor + 16 <= total else { return nil }
                let large = be64(data, at: cursor + 8)
                guard large <= Int.max else { return nil }
                size = Int(large)
            } else if size32 == 0 {
                size = total - cursor
                extendsToEOF = true
            }
            guard size >= 8, cursor + size <= total else { return nil }
            boxes.append(
                Box(type: type, range: cursor..<(cursor + size), extendsToEOF: extendsToEOF)
            )
            cursor += size
        }
        // ⚠ A trailing fragment means the parse lost sync. Reporting the boxes we did read would
        // let a rearrangement run on a misread file.
        guard cursor == total, !boxes.isEmpty else { return nil }
        return boxes
    }

    /// Add *delta* to every chunk offset inside an already-extracted `moov`, in place.
    ///
    /// Returns how many entries were patched, or nil when a 32-bit table would overflow.
    static func shiftChunkOffsets(in moov: inout Data, by delta: Int) -> Int? {
        var patched = 0
        var overflowed = false
        walk(&moov, from: 0, to: moov.count) { data, type, payloadStart, payloadEnd in
            guard type == "stco" || type == "co64" else { return }
            // [version+flags: 4][entry_count: 4][entries…]
            guard payloadStart + 8 <= payloadEnd else { return }
            let count = Int(be32(data, at: payloadStart + 4))
            let width = type == "stco" ? 4 : 8
            var at = payloadStart + 8
            for _ in 0..<count {
                guard at + width <= payloadEnd else { return }
                if width == 4 {
                    let value = Int(be32(data, at: at)) + delta
                    guard value <= Int(UInt32.max) else { overflowed = true; return }
                    write32(&data, at: at, UInt32(value))
                } else {
                    let value = Int(be64(data, at: at)) + delta
                    write64(&data, at: at, UInt64(value))
                }
                patched += 1
                at += width
            }
        }
        return overflowed ? nil : patched
    }

    /// Depth-first walk of a box tree, calling *visit* for every leaf.
    private static func walk(
        _ data: inout Data, from start: Int, to end: Int,
        _ visit: (inout Data, String, Int, Int) -> Void
    ) {
        var cursor = start
        while cursor + 8 <= end {
            let size32 = Int(be32(data, at: cursor))
            guard let type = ascii(data, at: cursor + 4, length: 4) else { return }
            var size = size32
            var header = 8
            if size32 == 1 {
                guard cursor + 16 <= end else { return }
                let large = be64(data, at: cursor + 8)
                guard large <= Int.max else { return }
                size = Int(large)
                header = 16
            } else if size32 == 0 {
                size = end - cursor
            }
            guard size >= header, cursor + size <= end else { return }
            if containers.contains(type) {
                walk(&data, from: cursor + header, to: cursor + size, visit)
            } else {
                visit(&data, type, cursor + header, cursor + size)
            }
            cursor += size
        }
    }

    // MARK: - Big-endian primitives

    static func be32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    static func be64(_ data: Data, at offset: Int) -> UInt64 {
        (UInt64(be32(data, at: offset)) << 32) | UInt64(be32(data, at: offset + 4))
    }

    static func write32(_ data: inout Data, at offset: Int, _ value: UInt32) {
        let base = data.startIndex + offset
        data[base] = UInt8(truncatingIfNeeded: value >> 24)
        data[base + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[base + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[base + 3] = UInt8(truncatingIfNeeded: value)
    }

    static func write64(_ data: inout Data, at offset: Int, _ value: UInt64) {
        write32(&data, at: offset, UInt32(truncatingIfNeeded: value >> 32))
        write32(&data, at: offset + 4, UInt32(truncatingIfNeeded: value))
    }

    static func ascii(_ data: Data, at offset: Int, length: Int) -> String? {
        let base = data.startIndex + offset
        guard base + length <= data.endIndex else { return nil }
        let bytes = data[base..<(base + length)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
