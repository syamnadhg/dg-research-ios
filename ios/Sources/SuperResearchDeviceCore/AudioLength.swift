import Foundation

/// The NotebookLM audio-overview length, taken from the frontend's config rather than a constant.
///
/// ⭐ **The field is `podcastLength`, and that name is measured from the backend, not guessed.** The
/// frontend's podcasts screen displays something it calls an audio duration, which is a different,
/// derived thing — building against that name would have produced a device that reads a field the
/// backend never writes and silently falls back on every run.
///
/// Values are exactly `short` / `default` / `long`.
public enum AudioLength: String, Sendable, CaseIterable {
    case short
    case `default`
    case long

    /// ⛔ **`long`, deliberately** — the backend's own default, chosen so that runs from before the
    /// feature existed keep the historical hardcoded behaviour. A device defaulting to `default`
    /// (the tempting reading of the name) would quietly shorten every audio overview whose config
    /// predates the feature.
    public static let fallback: AudioLength = .long

    /// The FORMAT tile this length is generated from, in NotebookLM's own words.
    ///
    /// ⭐ Measured from the backend's variant table, which drives its log copy, its narration and
    /// its agent prompt from one place: `short → Brief`, `default → Deep Dive`, `long → Deep Dive`.
    ///
    /// ⛔ **`short` is not "Deep Dive, but shorter".** It is a DIFFERENT format tile, and the
    /// backend's table records that it has *"no separate length step"* — so a flow that always sets
    /// format-then-length hunts for a length control that is not on screen, and either stalls or
    /// clicks something else that is.
    public var format: String { self == .short ? "Brief" : "Deep Dive" }

    /// The length option to pick after the format, or nil when this variant has no length step.
    public var lengthOption: String? {
        switch self {
        case .short: return nil
        case .default: return "Default"
        case .long: return "Long"
        }
    }
}

/// How the length is resolved when the two sources disagree.
///
/// ⛔ **There are two sources and the LATER one wins.** The value merged onto disk when the run was
/// prepared, and a re-read of the research document at phase time. The owner can change the setting
/// after queuing a run, so a device honouring only its local copy applies a stale length — and the
/// artefact is a perfectly good audio file of the wrong duration, which nothing downstream flags.
///
/// ⚠ **The re-read is expected to FAIL for this device's identity.** The backend tolerates a
/// permission error there explicitly: the synthetic device user is denied on the user-tree research
/// document, which is exactly the identity the phone runs as. So "overlay unavailable" is a normal
/// path, not an error — it must fall back to the disk value rather than fail the phase or reset to
/// the default.
public enum AudioLengthResolver {

    /// - Parameters:
    ///   - disk: the value merged into the run's config when it was prepared.
    ///   - overlay: the value from the phase-time re-read, or nil when that read was denied or
    ///     simply carried no value.
    public static func resolve(disk: String?, overlay: String?) -> AudioLength {
        // The overlay wins when it names a VALID length, and only then. An unrecognised overlay
        // value must not knock the run down to the fallback — the disk value is still the better
        // information, and the backend's own overlay applies the same "any valid value" test.
        if let overlay, let parsed = AudioLength(rawValue: overlay) {
            return parsed
        }
        if let disk, let parsed = AudioLength(rawValue: disk) {
            return parsed
        }
        return AudioLength.fallback
    }
}
