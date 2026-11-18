import Foundation

/// P3's last step: get the Audio Overview into Storage and tell the frontend where it is.
///
/// ⭐ **MP3 is preferred and the fallback is the original container — measured from the backend,
/// not chosen here.** The backend transcodes with ffmpeg/libmp3lame and its own docstring says the
/// transcode is *"best-effort and non-raising: on a missing ffmpeg, a non-zero exit, or any
/// exception, returns the ORIGINAL path unchanged so the podcast is never lost"*. The reason it
/// wants MP3 is specific: NotebookLM's `.m4a` keeps its `moov` atom at the END of the file, so an
/// agent that STREAMS the URL cannot begin playback, while a constant-bitrate MP3 is progressively
/// streamable everywhere.
///
/// ⛔ **An earlier version of this file refused to upload anything that was not an MP3.** That is
/// stricter than the thing it was copying, and strictly worse: it turns "the podcast streams
/// awkwardly" into "there is no podcast", at the end of a run that has already spent three
/// deep-research units. The guard that survives is the one that was actually load-bearing — the
/// name must never disagree with the bytes — and it is now enforced by DERIVING the extension from
/// the bytes rather than by refusing.
public enum AudioDelivery {

    public enum DeliveryError: Error, Equatable {
        case emptyAudio
        case noURL
        /// The bytes are not the format the filename claims. Carries both so the message names the
        /// mismatch rather than saying "upload failed".
        ///
        /// ⚠ Now reachable only when a caller passes an explicit extension that contradicts the
        /// bytes. The normal path cannot produce it, because the normal path reads the extension
        /// off the bytes.
        case formatMismatch(claimed: String, actual: String)
    }

    /// What the upload actually delivered.
    ///
    /// ⚠ `degraded` is recorded rather than inferred from the extension, because "it is an m4a"
    /// does not distinguish *the encoder was unavailable* from *the platform served an m4a and we
    /// never wanted to transcode*. Only the first is worth a human's attention.
    public struct Delivered: Equatable, Sendable {
        public let url: String
        public let format: String
        public let degraded: Bool
        public let reason: String
        /// Can a consumer that STREAMS the URL begin playback without downloading it all first?
        ///
        /// ⭐ The property the desktop's MP3 transcode actually buys, recorded as its own fact
        /// rather than inferred from the extension: an `.m4a` may or may not have it depending on
        /// where its index sits, and that is precisely what cannot be read off a filename.
        public let streamable: Bool

        public init(
            url: String, format: String, degraded: Bool, reason: String, streamable: Bool = true
        ) {
            self.url = url
            self.format = format
            self.degraded = degraded
            self.reason = reason
            self.streamable = streamable
        }
    }

    /// The object filename for a run's podcast.
    ///
    /// ⚠ Derived from the research id rather than from NotebookLM's own download name, which is
    /// title-derived and therefore arbitrary, non-unique, and occasionally full of characters that
    /// need escaping in a URL. Two runs on the same topic would otherwise collide in Storage.
    public static func filename(researchID: String, fileExtension: String = "mp3") -> String {
        "podcast-\(researchID).\(fileExtension)"
    }

    /// What the bytes actually are, read from the container's own header.
    ///
    /// ⛔ **Because renaming is not converting.** The owner asked for MP3. The cheap move is to
    /// change the extension and upload the same AAC bytes — the object then has a `.mp3` name, the
    /// URL works, the frontend's player may even play it, and the file is not an MP3. Every
    /// consumer that actually inspects it (a transcoder, a podcast feed, the video step) fails on
    /// something that looks correct everywhere else.
    public enum AudioFormat: String, Sendable {
        case mp3
        case m4a
        case unknown

        /// ⚠ Sniffed, never inferred from the filename — the filename is the thing being checked.
        public static func sniff(_ data: Data) -> AudioFormat {
            let bytes = [UInt8](data.prefix(12))
            guard bytes.count >= 4 else { return .unknown }
            // ID3v2 tag, or a raw MPEG frame sync (11 set bits).
            if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return .mp3 }
            if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return .mp3 }
            // ISO base media: a `ftyp` box at offset 4 — MP4/M4A and friends.
            if bytes.count >= 8, bytes[4] == 0x66, bytes[5] == 0x74,
               bytes[6] == 0x79, bytes[7] == 0x70 {
                return .m4a
            }
            return .unknown
        }
    }

    /// Transcode to MP3, then upload — degrading to the original bytes exactly as the backend does.
    ///
    /// ⚠ **The transcode may not run at all on this device and that is a shipped, working state.**
    /// iOS has no system MP3 *encoder* (AVFoundation and AudioToolbox decode MP3 and encode AAC),
    /// so producing one needs a vendored encoder whose licence is the owner's decision — §15.3. The
    /// default transcoder therefore declines, this returns the platform's own container, and the
    /// run finishes with a podcast the web app plays. Deciding the licence swaps one type and
    /// changes nothing else here.
    public static func deliver(
        audio: Data, ownerUID: String, researchID: String, storage: FirebaseStorage,
        transcoder: AudioTranscoder = UnavailableTranscoder()
    ) async throws -> Delivered {
        guard !audio.isEmpty else { throw DeliveryError.emptyAudio }

        var bytes = audio
        var degraded = false
        var reason = ""
        if AudioFormat.sniff(audio) == .mp3 {
            // Idempotent, matching the backend's own first line: input already MP3 is returned
            // untouched rather than re-encoded, which would cost a generation of quality for nothing.
            reason = "the platform served MP3"
        } else {
            let result = await transcoder.toMP3(audio)
            switch result {
            case .encoded(let mp3) where AudioFormat.sniff(mp3) == .mp3 && !mp3.isEmpty:
                bytes = mp3
                reason = "transcoded to MP3"
            case .encoded:
                // ⛔ An encoder that returns something that is not an MP3 must NOT be believed. The
                // failure it prevents is the one this whole file is organised around: bytes shipped
                // under a name that lies about them.
                degraded = true
                reason = "the transcoder returned bytes that are not MP3 — delivering the original"
            case .unavailable(let why):
                degraded = true
                reason = why
            }
        }

        // ⭐ **The index goes to the front — the fix the MP3 transcode was standing in for.**
        // NotebookLM writes an `.m4a` whose `moov` index sits AFTER the samples, so a consumer that
        // streams gets megabytes of audio with no map of it and cannot start. Moving the index is
        // lossless, needs no encoder, and keeps the container every measured consumer already
        // accepts — while re-encoding to MP3 costs a quality generation and a vendored library to
        // achieve the same thing by accident.
        //
        // ⚠ Skipped entirely for MP3, which has no index to move: every frame describes itself.
        var streamable = true
        if AudioFormat.sniff(bytes) == .m4a {
            switch AudioFaststart.apply(bytes) {
            case .moved(let rearranged):
                bytes = rearranged
                reason += reason.isEmpty ? "index moved to the front" : "; index moved to the front"
            case .alreadyStreamable:
                break
            case .notApplicable(let why), .refused(let why):
                // ⚠ Delivered anyway. A podcast that needs downloading before it plays is a far
                // smaller problem than no podcast, and the web app downloads either way.
                streamable = false
                reason += reason.isEmpty ? why : "; \(why)"
            }
        }

        let actual = AudioFormat.sniff(bytes)
        // ⚠ The extension is DERIVED, so the name cannot disagree with the content. An unknown
        // container keeps the platform's own default rather than being guessed at.
        let ext = actual == .unknown ? "m4a" : actual.rawValue
        let url = try await storage.upload(
            data: bytes, ownerUID: ownerUID, researchID: researchID,
            filename: filename(researchID: researchID, fileExtension: ext)
        )
        guard !url.isEmpty else { throw DeliveryError.noURL }
        return Delivered(
            url: url, format: ext, degraded: degraded, reason: reason, streamable: streamable
        )
    }

    /// The research-document patch that points the frontend at the audio.
    ///
    /// ⛔ **`links.audio_file`, and it is NOT `links.audio`.** They are different fields with
    /// different consumers: `links.audio` is the NotebookLM *share page* — a web page, not a media
    /// file — which the generated Doc renders as "Audio Overview", while `links.audio_file` is the
    /// downloadable object the frontend's YouTube step fetches. Writing the share page into
    /// `audio_file` gives P4 an HTML page to upload as a video.
    ///
    /// ⛔ **A MAP, not a string.** The frontend reads `links.audio_file?.url` — measured in its own
    /// source, three separate call sites including the P3-handoff gate. A bare string leaves that
    /// read undefined, so the run hands off with `beDone` and the cloud takes the "no usable audio"
    /// fast path: P4 skipped, P5 completes, and the finished research has no podcast and no error.
    public static func linkPatch(url: String) -> [String: FirestoreValue] {
        [
            "links.audio_file": .map([
                "url": .string(url),
                // The same label the backend writes, because the Doc composer renders it verbatim.
                "label": .string("Podcast Audio (Storage)"),
                "phase": .integer(3),
                "verified": .boolean(true),
            ])
        ]
    }

    /// The patch for the NotebookLM page links.
    ///
    /// Two slots, written together because they come from one flow and the frontend consumes them
    /// differently: `notebooklm` is the "Open NotebookLM" row on the P3 tile, `audio` is what the
    /// generated Doc renders as "Audio Overview".
    ///
    /// ⚠ `verified` carries the PUBLIC-ACCESS verdict, not "we got a URL". A private notebook's URL
    /// is well-formed and looks identical to a public one — the recipient of the P5 email gets
    /// "Request access" instead of a notebook, and nothing upstream can tell.
    public static func notebookLinkPatch(
        url: String, publicVerified: Bool
    ) -> [String: FirestoreValue] {
        let record: FirestoreValue = .map([
            "url": .string(url),
            "label": .string("NotebookLM Notebook"),
            "phase": .integer(3),
            "verified": .boolean(publicVerified),
        ])
        return [
            "links.notebooklm": record,
            "links.audio": .map([
                "url": .string(url),
                "label": .string("Audio Overview"),
                "phase": .integer(3),
                "verified": .boolean(publicVerified),
            ]),
        ]
    }
}
