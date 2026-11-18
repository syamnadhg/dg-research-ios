import Foundation

/// Which ChatGPT effort tier Phase 1 must run on, and how to recognise it in a menu.
///
/// ⭐ **ChatGPT has NO separate thinking control — effort and model are ONE menu.** The captured menu
/// is `Instant 5.5 / Medium / High / Extra High / Pro`, all `menuitemradio` in a single list, so
/// choosing the tier IS choosing the reasoning level. Both the backend's vision hint and its CUA
/// mission once spent steps hunting an "extended thinking" toggle that does not exist on this
/// platform; the fact is recorded here so this port does not repeat the hunt.
///
/// ⚠ **Ported from the backend's `P1_MODEL_POLICY` and `pick_effort_tier`, deliberately as data plus
/// one pure function.** The DOM walk that consumes it lives in the pipeline, where it needs a page;
/// the ranking rule does not, and keeping the rule free of a page is what makes it testable against
/// the exact row labels the live menu produced rather than against a fake.
public enum ChatGPTModelPolicy {

    /// The subscription tier P1 targets. Stable — this is the plan name, not a model.
    ///
    /// ⛔ Never a hardcoded "Pro" at a call site. The backend learned this on the Claude side, where a
    /// frozen literal in a hover helper drifted from the ranker and the two disagreed about which
    /// model had been chosen. One list, read by everything.
    public static let tierWords = ["pro"]

    /// Reasoning-mode words, any one of which — **together with** a tier word — marks the high-effort
    /// mode. Add to this on a rename; never remove `pro` from `tierWords`.
    public static let thinkingWords = ["extended", "thinking", "reasoning"]

    /// Names of the LOW-effort default modes. A closed list by necessity — there is no shape to test
    /// for "this mode is the cheap one" — but a miss here only makes the tier read *unknown*, which
    /// is reported rather than assumed.
    public static let downgradeWords = ["instant", "auto", "fast", "standard"]

    /// An "Upgrade to Pro" call-to-action contains the tier word without being evidence of the tier.
    /// These verbs disqualify a match.
    public static let upgradeVerbs = ["upgrade", "subscribe", "get", "try"]

    /// ⛔ The Deep-Research pill and the model pill are BOTH `__composer-pill` buttons sitting side by
    /// side, with the same tag, class and parent — no structural discriminator exists. Clicking the
    /// DR pill does not open a menu, it **adds a second Deep Research**, so the tool's own label is
    /// the only thing that tells them apart and getting it wrong is destructive rather than merely
    /// unhelpful. Any trigger whose text contains this word is skipped.
    public static let avoidWord = "deep research"

    // MARK: - Word matching

    /// ASCII-only, matching the backend character for character.
    ///
    /// ⚠ Swift's `isLetter`/`isNumber` are Unicode-aware and the backend's `_alnum` is explicitly not,
    /// *because its own JS mirror is ASCII*. On a CJK or accented UI a Unicode-aware boundary and an
    /// ASCII one disagree at exactly the character that decides a match — the backend documents both
    /// mirror-image failures. Copying the narrow rule keeps this port answering what the page does.
    static func isASCIIAlnum(_ c: Character) -> Bool {
        ("a"..."z").contains(c) || ("0"..."9").contains(c)
    }

    /// Does `text` name any of `terms`, at word boundaries?
    ///
    /// A term matches when it starts at a word boundary and — unless it ends in `*` — also ends at
    /// one: `"pro"` matches `"3.1 pro"` but not `"productivity"`; `"lite*"` matches
    /// `"flash-litefastest"` but not `"elite"`.
    ///
    /// ⛔ Deliberately regex-free, and that is the backend's scar rather than a style preference: this
    /// rule is mirrored into a JS string where a lone `\b` once became a literal backspace and
    /// silently disabled a gate for months. A plain scan cannot be mis-escaped.
    public static func hasTerm(_ text: String, _ terms: [String]) -> Bool {
        let t = Array(text.lowercased())
        for raw in terms {
            var term = raw.lowercased()
            let prefixOnly = term.hasSuffix("*")
            if prefixOnly { term.removeLast() }
            if term.isEmpty { continue }
            let needle = Array(term)
            guard needle.count <= t.count else { continue }
            for i in 0...(t.count - needle.count) where Array(t[i..<(i + needle.count)]) == needle {
                let leftOK = i == 0 || !isASCIIAlnum(t[i - 1])
                let end = i + needle.count
                let rightOK = prefixOnly || end >= t.count || !isASCIIAlnum(t[end])
                if leftOK && rightOK { return true }
            }
        }
        return false
    }

    /// A version number sitting **adjacent** to `family`, in either order: `"pro 5.5"` and
    /// `"5.5 pro"` both give 5.5.
    ///
    /// ⭐⭐ **Adjacency is the whole rule, and the order matters.** A menu WRAPPER's text concatenates
    /// every row it contains, so a loose pattern lets a sibling row's number attach to our word —
    /// the wrapper then outranks the real leaf, gets clicked, changes nothing (a click on an ancestor
    /// never reaches the row's handler) and is reported as a successful pick. Two constraints stop
    /// that: family-first is tried first, and the separator may only be a couple of plain characters,
    /// never another word. A letter-only exclusion is not enough — `"3.6 Flash, 2x faster"` would
    /// read as 2, because a comma is not a letter.
    ///
    /// ⚠ `[0-9]`, not `\d`: `\d` is Unicode-aware in some engines and ASCII in others, and a mirror
    /// that parses a row the browser cannot is not a mirror.
    public static func familyVersion(in text: String, family: String) -> Double? {
        let t = text.lowercased()
        let fam = NSRegularExpression.escapedPattern(for: family.lowercased())
        let num = "([0-9]+(?:\\.[0-9]+)?)"
        let sep = "[ ._/()-]{0,3}"
        for pattern in ["\(fam)\(sep)\(num)", "\(num)\(sep)\(fam)"] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(t.startIndex..<t.endIndex, in: t)
            guard let m = re.firstMatch(in: t, range: range),
                  let captured = Range(m.range(at: 1), in: t) else { continue }
            if let v = Double(t[captured]) { return v }
        }
        return nil
    }

    // MARK: - Ranking

    public struct Pick: Equatable, Sendable {
        /// Index into the labels **as they were given**, so the caller can re-resolve identity.
        public let index: Int
        /// The version adjacent to the tier word, when the row carries one.
        public let version: Double?
        /// The row's label, trimmed. Re-checked before the click — identity decides, not position.
        public let label: String
    }

    /// Pick the row naming the target effort tier, or `nil`.
    ///
    /// ⭐ **A different rule from "highest version wins", and the difference is the platform's rather
    /// than a preference.** Claude and Gemini list MODELS: every row carries a version and "highest
    /// offered" is decidable from the numbers. ChatGPT lists EFFORT AND MODEL together, and only the
    /// *cheapest* row carries a number at all — so ranking this menu by version picks `Instant 5.5`
    /// over `Pro`. The highest number is the LOWEST tier. The target is therefore a NAMED tier, and a
    /// version only ever breaks a tie between rows that already name it.
    ///
    /// ⛔ **No fallback to a lower tier.** If nothing names the tier this returns `nil` and the caller
    /// says so. Quietly settling for the next tier down is the silent downgrade the post-select
    /// confirm exists to catch — it would present a lapsed subscription as a successful pick.
    ///
    /// Among rows that DO name the tier: highest adjacent version first (`Pro 5.5` beats `Pro`), then
    /// SHORTEST label. The tie-break is the leaf rule — a container that concatenates several rows
    /// carries the tier word too, and clicking an ancestor never reaches the row's handler.
    public static func pickEffortTier(
        labels: [String],
        tierWords: [String] = ChatGPTModelPolicy.tierWords,
        upgradeVerbs: [String] = ChatGPTModelPolicy.upgradeVerbs
    ) -> Pick? {
        // ⚠ No `if tierWords.isEmpty { return nil }` guard. It looks like the safe thing to write and
        // is DEAD — `hasTerm(_, [])` is false for every row, so an empty list already selects
        // nothing. The backend found this exact line by mutating it and watching the mutant survive.
        // The caller's own "no tier words configured" check is real, because it separates *unsure*
        // from *no target* BEFORE any menu is opened.
        let tiers = tierWords.map { $0.lowercased() }
        let verbs = upgradeVerbs.map { $0.lowercased() }
        var best: Pick?
        var bestRank: (Int, Double) = (0, 0)
        var bestLen = 0
        for (i, raw) in labels.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.isEmpty { continue }
            if !verbs.isEmpty && hasTerm(t, verbs) { continue }
            if !hasTerm(t, tiers) { continue }
            var version: Double?
            for term in tiers {
                version = familyVersion(in: t, family: term)
                if version != nil { break }
            }
            let rank: (Int, Double) = version.map { (1, $0) } ?? (0, 0)
            let better = best == nil
                || rank > bestRank
                || (rank == bestRank && t.count < bestLen)
            if better {
                best = Pick(
                    index: i, version: version,
                    label: raw.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                bestRank = rank
                bestLen = t.count
            }
        }
        return best
    }

    /// Does a trigger's own label say the tier is already in effect?
    ///
    /// Requires the tier word AND the absence of an upgrade verb — "Upgrade to Pro" names the tier
    /// while being proof of its absence.
    public static func triggerIsOnTarget(_ text: String) -> Bool {
        hasTerm(text, tierWords) && !hasTerm(text, upgradeVerbs)
    }

    /// Does a label mark the high-effort mode — a thinking word AND a tier word, with no upgrade verb?
    public static func marksHighEffort(_ text: String) -> Bool {
        hasTerm(text, thinkingWords) && hasTerm(text, tierWords) && !hasTerm(text, upgradeVerbs)
    }
}
