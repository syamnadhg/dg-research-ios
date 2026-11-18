import Foundation

/// Turning NotebookLM's Audio Overview into a progressively-streamable MP3.
///
/// ⭐ **A seam rather than an implementation, and the reason is a decision that is not mine.** iOS
/// ships an MP3 *decoder* and no MP3 *encoder* — AudioToolbox's converter offers AAC, ALAC, iLBC
/// and friends — so producing one on this device needs a vendored encoder (LAME being the obvious
/// one), and vendoring an LGPL encoder into a shipped app is the owner's call, flagged as such in
/// §15.3 of the recipe. What is decided is the FORMAT; what is open is the licence.
///
/// ⚠ So the default declines, and declining is a **working** outcome, not a stub: the backend's own
/// transcode is best-effort and delivers the original container when ffmpeg is missing. A run on
/// this device therefore ends with a podcast the web app plays, and the only thing lost is
/// stream-before-download for a cloud consumer.
public protocol AudioTranscoder: Sendable {
    func toMP3(_ data: Data) async -> TranscodeResult
}

/// ⚠ Two outcomes and no `throws`, deliberately. A transcode failure at the END of a
/// three-deep-research-unit run must not be able to propagate as an error that loses the audio; the
/// only question the caller may ask is "did I get an MP3 back", and the reason travels with the
/// answer so the log can say WHY it degraded rather than that it did.
public enum TranscodeResult: Equatable, Sendable {
    case encoded(Data)
    /// Carries the human-readable reason, which is the whole value of this case over `nil`.
    case unavailable(String)
}

/// The shipped default: no encoder is linked, so the original bytes are delivered.
///
/// ⛔ Its reason string names the licence decision rather than saying "not implemented", because
/// the two call for completely different responses and only one of them is a bug.
public struct UnavailableTranscoder: AudioTranscoder {
    public init() {}

    public func toMP3(_ data: Data) async -> TranscodeResult {
        .unavailable(
            "no MP3 encoder is linked into this app — iOS provides none, and vendoring one is a "
            + "licence decision (§15.3). Delivering the platform's own container, which the web "
            + "app plays; only stream-before-download for a cloud consumer is affected."
        )
    }
}
