import Foundation

/// The account's pipeline Settings, as they apply to one run.
///
/// ⭐ **This device is a backend, so it owes the owner the same obedience the desktop one does.**
/// Every field here already exists in the product: the web app's Settings → Pipeline writes them,
/// `agent/facade/bridge.py::_config_from_settings` resolves them, and `research.py` reads them. The
/// device read exactly ONE of them — `podcastLength` — and silently invented its own answer for the
/// rest, which is not a smaller feature but a different product wearing the same settings screen.
///
/// ⛔ **The defaults are the backend's, not the ones that look safe.** `skipInitVerify` defaults to
/// TRUE — verification is opt-in, and the reason is in the backend's own README: proactive verify
/// navigations are the strongest bot-score signal on a fresh profile. Defaulting to "verify, to be
/// careful" is not the cautious choice; it is the choice that makes the run look like a bot and then
/// fails it on the result.
public struct RunConfig: Equatable, Sendable {

    /// Skip the P0 login walk. **Opt-out, and TRUE by default** — mirrors
    /// `research.py`'s `bool(pipeline_config.get("skipInitVerify", True))`.
    ///
    /// The Settings field the owner actually sees is `verifyLogins`, which is the INVERSE and is
    /// resolved into this one before it ever reaches a backend. Both spellings are accepted here for
    /// the same reason the backend renamed it: a stale auto-saved `false` under the old name must not
    /// quietly turn verification back on.
    public var skipInitVerify: Bool

    /// Which P2 agents the owner left switched on.
    ///
    /// ⚠ Absent means ON. A settings-less account runs all three, which is what the web app's own
    /// `DEFAULT_SETTINGS` does — so an account that never opened Settings behaves identically on
    /// every backend it owns.
    public var agents: [String: Bool]

    /// Phases the owner switched off, already normalised.
    public var skipPhases: Set<Int>

    public var videoEnabled: Bool
    public var emailEnabled: Bool

    /// `short` / `default` / `long`, or nil when the owner never chose.
    public var podcastLength: String?

    /// What an account with no Settings at all gets.
    public static let `default` = RunConfig(
        skipInitVerify: true,
        agents: ["chatgpt": true, "gemini": true, "claude": true],
        skipPhases: [],
        videoEnabled: true,
        emailEnabled: true,
        podcastLength: nil
    )

    public init(
        skipInitVerify: Bool = true,
        agents: [String: Bool] = ["chatgpt": true, "gemini": true, "claude": true],
        skipPhases: Set<Int> = [],
        videoEnabled: Bool = true,
        emailEnabled: Bool = true,
        podcastLength: String? = nil
    ) {
        self.skipInitVerify = skipInitVerify
        self.agents = agents
        self.skipPhases = skipPhases
        self.videoEnabled = videoEnabled
        self.emailEnabled = emailEnabled
        self.podcastLength = podcastLength
    }

    /// Is this agent switched on? Unknown keys are ON, matching the backend's `.get(k, True)`.
    public func runsAgent(_ platform: String) -> Bool {
        agents[platform] ?? true
    }

    /// The P2 platforms this run should actually drive, in the pipeline's order.
    public var enabledPlatforms: [String] {
        Prompts.p2Platforms.filter { runsAgent($0) }
    }

    /// Should this phase be skipped?
    ///
    /// ⚠ Phase 0 is answered by `skipInitVerify` rather than by `skipPhases`. The two are separate
    /// fields in the product — one is a Settings toggle about bot-score risk, the other is about
    /// which work the owner wants done — and folding them together would let "skip the brief" also
    /// disable login verification.
    public func skips(phase: Int) -> Bool {
        if phase == 0 { return skipInitVerify }
        return skipPhases.contains(phase)
    }

    /// Decode the `config` map the web app writes onto the queue document.
    ///
    /// ⭐ **The QUEUE document, because it is the one this device can always read.** The research
    /// document's `pipelineConfig` is the same data and is behind a membership check — the existing
    /// `podcastLength` read already learned this. A settings read that may be refused is a settings
    /// read that silently reverts the owner's choices.
    public static func decode(_ value: FirestoreValue?) -> RunConfig {
        guard case .map(let config)? = value else { return .default }
        var out = RunConfig.default

        // ⚠ Resolved BE-name-first, then the Settings name, and the Settings name is INVERTED.
        // `verifyLogins` was renamed and flipped from `skipInitVerify` precisely so stale saved
        // values under the old name stop applying, so reading either one as if it meant the other
        // reintroduces the bug the rename fixed.
        if case .boolean(let skip)? = config["skipInitVerify"] {
            out.skipInitVerify = skip
        } else if case .boolean(let verify)? = config["verifyLogins"] {
            out.skipInitVerify = !verify
        }

        if case .map(let agents)? = config["agents"] {
            for (key, value) in agents {
                if case .boolean(let on) = value { out.agents[key] = on }
            }
        }

        // ⛔ **BOTH spellings, because the two halves of the product disagree.** The web app writes
        // `skippedPhases` and the backend writes `skipPhases`; `research.py`'s own overlay accepts
        // either for exactly this reason. Reading only one silently ignores whichever half wrote
        // the other, and the symptom is a phase running that the owner switched off.
        let rawPhases = config["skippedPhases"] ?? config["skipPhases"]
        if case .array(let items)? = rawPhases {
            for item in items {
                switch item {
                case .integer(let phase): out.skipPhases.insert(Int(phase))
                case .double(let phase): out.skipPhases.insert(Int(phase))
                // Firestore carries integers as strings on the wire, and a REST decode that only
                // matched `.integer` would drop every phase it was handed.
                case .string(let phase): if let n = Int(phase) { out.skipPhases.insert(n) }
                default: break
                }
            }
        }

        if case .boolean(let video)? = config["videoEnabled"] { out.videoEnabled = video }
        if case .boolean(let email)? = config["emailEnabled"] { out.emailEnabled = email }

        // ⚠ Validated rather than passed through. The backend narrows to the three it knows and
        // falls back to `long`; an unrecognised value reaching P3 would be handed to the length
        // picker, which has no row for it.
        if case .string(let length)? = config["podcastLength"],
           ["short", "default", "long"].contains(length) {
            out.podcastLength = length
        }

        return out.normalised()
    }

    /// Apply the cross-field rules the backend applies, so no caller has to remember them.
    ///
    /// ⚠ **Skipping the podcast skips the video too** — `research.py`: `if 3 in sp: sp.add(4)`. P4
    /// makes a video *of the podcast*, so a run configured to produce no podcast and then asked for
    /// a video would hand the cloud an empty document to film.
    func normalised() -> RunConfig {
        var out = self
        if out.skipPhases.contains(3) { out.skipPhases.insert(4) }
        // All three agents off means there is no research phase to run — the same conclusion
        // `_config_from_settings` reaches, reached here so both halves cannot drift.
        if Prompts.p2Platforms.allSatisfy({ out.agents[$0] == false }) { out.skipPhases.insert(2) }
        if !out.videoEnabled { out.skipPhases.insert(4) }
        return out
    }
}
