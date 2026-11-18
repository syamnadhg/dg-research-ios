import Foundation

/// The P0–P3 orchestrator that runs **inside the app**, driving its own web view.
///
/// The Swift counterpart of `emubackend/phases.py` + `emubackend/pipeline.py`. It exists because
/// compiled Python cannot run on iOS, so Stage 2 needs the orchestration in Swift — but only the
/// orchestration: the browser layer stays **data-driven**, so what would otherwise be thousands of
/// lines of per-platform automation is a manifest of selectors plus the sequence below.
///
/// ⚠ **This is a second implementation of semantics that already exist in Python, which means it can
/// drift.** Two guards, because "be careful" is not one: the phase ordering invariants are asserted by
/// tests on both sides, and `emubackend/tests/test_inapp_parity.py` reads *this file* to check the
/// properties that were expensive to learn are still present here. The one that matters most is
/// toggle idempotence — the Python side shipped that bug, and a fresh implementation is exactly where
/// it would reappear.
///
/// Deliberately free of WebKit: it talks to a `WebPage`, so its logic is testable under `swift test`,
/// which cannot host a `WKWebView` at all.
public protocol WebPage: Sendable {
    /// Evaluate an expression and return its JSON-decoded result.
    func evaluateJSON(_ expression: String) async throws -> Any?
    /// Register the first match and return its handle id, or nil.
    func querySelector(_ css: String) async throws -> Int?
    /// How many nodes match.
    func querySelectorAll(_ css: String) async throws -> [Int]
    func attribute(_ handle: Int, _ name: String) async throws -> String?
    func innerText(_ handle: Int) async throws -> String?
    func click(_ handle: Int) async throws
    /// Type into a target, going through the path that updates the editor's **model**.
    func insertText(_ handle: Int, _ text: String) async throws -> String?
    /// Press a named key at the focused element.
    ///
    /// ⚠ Added for exactly one caller — turning deep research OFF, which the platform says must be
    /// done with Backspace in an empty composer rather than by tapping the tool again (a second tap
    /// ADDS a tool). Without a key press there is no way to perform that instruction at all.
    func key(_ name: String) async throws
}

public enum InAppPhaseError: Error, Equatable {
    /// A selector matched nothing. Loud on purpose: a step that quietly did nothing would report
    /// success on a page it never touched.
    case unresolved(platform: String, key: String, tried: [String])
    /// No usable session on this platform.
    ///
    /// ⚠ Carries the EVIDENCE, because "not logged in" was reported for two very different things
    /// and only one of them was true: a page that had genuinely signed out, and a page that had not
    /// finished loading when it was asked. The reason names which — the sign-in control that was
    /// actually on screen, or the marker that never resolved.
    case notLoggedIn(platform: String, reason: String)
    /// A mutating step ran and its predicate did not confirm the outcome.
    case outcomeUnconfirmed(intent: String)
    /// The page changed underneath a long wait in a way no further waiting fixes — the session ended, a
    /// verification prompt appeared, or a quota wall dropped.
    ///
    /// Distinct from a timeout on purpose. A timeout says "still waiting", which invites a longer timeout;
    /// this says "stop and tell someone", and it carries the reason because "the wait was interrupted" is
    /// not actionable while "the session ended mid-wait" is. The difference in practice is reporting it in
    /// two minutes instead of at the forty-five-minute deadline.
    case waitInterrupted(platform: String, reason: String)
    /// An opener's popup would not close, and the caller must NOT carry on.
    ///
    /// ⛔ **This case exists because the result was previously discarded.** Dismissal returned a Bool
    /// that every call site ignored, so a menu that refused to close was tolerated silently — and an
    /// open menu COVERS THE COMPOSER, so the next phase's send taps the overlay and fails for a
    /// reason that points at send. Found by mutation: breaking the dismissal check changed no test,
    /// because nothing consulted its answer. A guard nobody reads is not a guard.
    case menuWouldNotClose(platform: String, key: String)

    /// The owner pressed Stop. Not a fault, and it must not be reported as one.
    ///
    /// ⚠ Distinct from every other case here so the executor can tell "this run was cancelled" from
    /// "this run broke". Folding it into a generic failure would blame the platforms for doing
    /// exactly what they were told, and would spend the rest of the run's agents finding out.
    case stoppedByOwner(platform: String)
}

/// Things that end a wait early because no amount of waiting will fix them.
///
/// Returns a REASON string rather than a bool, because "the wait was interrupted" is not actionable and
/// "the session ended mid-wait" is. Each of these needs a human, and the difference between reporting it in
/// two minutes and reporting a timeout in forty-five is the whole value.
///
/// Anchored the same way `classify_response`'s auth check is: a CONTROL inviting you to sign in, never prose,
/// so a signed-in page's own copy about logging in cannot trip it.
let WAIT_INTERRUPTION_JS = """
(function () {
  var vis = function (el) { var r = el.getBoundingClientRect(); return !!(r.width && r.height); };
  var name = function (el) {
    return (el.getAttribute('aria-label') || (el.innerText || '')).replace(/\\s+/g, ' ').trim();
  };
  var AUTH = /^(log ?in|sign ?in|continue with (google|apple|microsoft))\\b/i;
  var controls = document.querySelectorAll('button, [role=button], a');
  for (var i = 0; i < controls.length; i++) {
    if (vis(controls[i]) && AUTH.test(name(controls[i]))) {
      return 'the session ended mid-wait — a sign-in control appeared: ' + name(controls[i]).slice(0, 40);
    }
  }
  var body = (document.body ? (document.body.innerText || '') : '').toLowerCase();
  var WALLS = [
    ['verify you are human', 'a human-verification prompt appeared'],
    ['are you a robot', 'a human-verification prompt appeared'],
    ['unusual activity', 'a human-verification prompt appeared'],
    ["you've reached your limit", 'a usage limit was hit mid-wait'],
    ['usage limit', 'a usage limit was hit mid-wait'],
    ['rate limit', 'a rate limit was hit mid-wait'],
    ['upgrade to continue', 'a paywall appeared mid-wait']
  ];
  for (var j = 0; j < WALLS.length; j++) {
    if (body.indexOf(WALLS[j][0]) >= 0) { return WALLS[j][1] + ' ("' + WALLS[j][0] + '")'; }
  }
  return '';
})()
"""

/// One platform's steps, each with an outcome predicate — wrapped as written, per A8/A1.
public struct InAppPhaseDriver {
    public let platform: String
    public let manifest: [String: [String]]
    /// Text fallbacks, keyed the same way. A key may appear ONLY here — ChatGPT's
    /// `deep_research_toggle` carries no css on purpose, because css is tried first and a broad
    /// `[role=menuitem]` matches "Camera", the first of nineteen menu items.
    public let texts: [String: String]
    /// Controls that must be TAPPED before the keyed entry can resolve.
    ///
    /// Two real-platform failures turned out to be one missing capability: ChatGPT's deep-research item and
    /// its Web-search tool both sit inside the composer's plus menu, so neither entry can resolve while the
    /// menu is shut. The phase should not have to know that, which is why the opener is a property of the
    /// TARGET rather than a step in the pipeline.
    public let openers: [String: String]
    /// ⚠ Internal rather than private: the NotebookLM phase composes this driver instead of
    /// reimplementing resolve/tap, and a second copy of those is a second place for them to drift.
    let page: WebPage

    public init(
        platform: String, manifest: [String: [String]], texts: [String: String] = [:],
        openers: [String: String] = [:], page: WebPage
    ) {
        self.platform = platform
        self.manifest = manifest
        self.texts = texts
        self.openers = openers
        self.page = page
    }

    /// What the page is doing before any phase touches it.
    public enum PageReadiness: Equatable, Sendable {
        /// Loaded, hydrated, and the composer exists.
        case ready
        /// A sign-in control is on screen. No amount of waiting fixes this one.
        case signedOut(String)
        /// The document never completed, or the composer never hydrated.
        case notReady(String)
    }

    /// Wait for the web view to be a live page before the run drives it.
    ///
    /// ⛔ **The run had no gate at all, and it cost a whole run on 2026-08-14.** The app creates one
    /// web view per (worker, platform) LAZILY and calls `load()` on it, which returns immediately —
    /// so the first phase of the first run gets handed a view whose navigation has barely started.
    /// The trace is unambiguous: Gemini was asked for its login marker **418ms** after the run
    /// began, answered "not found" because nothing had rendered, and the run was abandoned four
    /// seconds after it started. It looked exactly like three signed-out platforms.
    ///
    /// ⚠ **Required even when the login walk is skipped**, which is the normal configuration. P1
    /// types into the composer; a composer that has not hydrated cannot be typed into. Gating on
    /// login alone would have moved the same failure one phase later and made it look like a
    /// selector problem.
    ///
    /// ⭐ Waits for the **composer**, not merely for the document — `C1Runner` measured why, and the
    /// measurement is worth repeating: on ChatGPT's splash shell `readyState` is `complete`, the
    /// plus button exists, and `#prompt-textarea` does not. A readiness signal weaker than the thing
    /// depending on it is not a gate.
    ///
    /// Returns rather than throws, because the three outcomes need different errors and only the
    /// caller knows which phase it is in.
    public func awaitPageReady(
        timeout: TimeInterval = 90,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> PageReadiness {
        var waited: TimeInterval = 0
        var lastSeen = "nothing was evaluated"
        while waited < timeout {
            // One round trip for all three facts rather than three, because they must describe the
            // SAME moment: a page can finish loading between two separate reads, and a predicate
            // built from a mixture of before and after is true of no page that ever existed.
            let state = try? await page.evaluateJSON(
                "(function(){ return {r: document.readyState, h: location.href, "
                + "c: document.body ? document.body.children.length : 0}; })()"
            )
            let fields = state as? [String: Any]
            let readyState = fields?["r"] as? String
            let href = fields?["h"] as? String
            let children = fields?["c"] as? Int
            lastSeen = "readyState=\(readyState ?? "?") href=\(href ?? "?") "
                + "bodyChildren=\(children.map(String.init) ?? "?")"

            // ⚠ The SAME predicate the bridge's own loaded-check uses, called rather than copied.
            // Two spellings of "is this page up" drift, and the one that drifts is always the one
            // without the `about:blank` case.
            if WebAutomationBridge.isLoaded(
                readyState: readyState, href: href, bodyChildren: children
            ) {
                if try await optional("composer") != nil { return .ready }
                // ⛔ Asked only once the document is up, and that order is the point. A signed-in
                // page mid-load has no composer AND no sign-in control, so asking this too early
                // learns nothing; asking it after the document settled is what distinguishes "still
                // hydrating" from "this account is signed out", and only one of those is worth
                // waiting another eighty seconds for.
                if let reason = try? await page.evaluateJSON(WAIT_INTERRUPTION_JS) as? String,
                   !reason.isEmpty {
                    return .signedOut(reason)
                }
            }
            try? await sleep(.milliseconds(500))
            waited += 0.5
        }
        return .notReady("the composer never appeared within \(Int(timeout))s — last saw \(lastSeen)")
    }

    /// Wait for the composer to be usable again after a step that may have NAVIGATED.
    ///
    /// Readiness is not a one-time fact. The gate waits for the composer before the phases run, and then a
    /// step navigates and invalidates it — enabling deep research changes the URL to /c/<id> and the composer
    /// re-mounts. Measured: the run saw `promptTextarea: 0` at fill time and the very same element was
    /// present 8s later, unchanged. So the failure was never the selector; the wait simply never happened
    /// again after the thing that made it necessary.
    ///
    /// Public so a caller that knows it navigated can re-establish readiness explicitly, which is preferable
    /// to a blanket sleep after every step.
    @discardableResult
    public func awaitComposerReady(timeout: TimeInterval = 20) async throws -> Bool {
        var waited: TimeInterval = 0
        while waited < timeout {
            if try await optional("composer") != nil { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 0.5
        }
        return false
    }

    /// Close whatever an opener opened, and VERIFY it closed.
    ///
    /// An opener is a modal interaction, so it needs a way out. Skipping this is not a tidiness issue: the
    /// menu stays over the composer and the NEXT phase cannot act — measured, `send` failed and the
    /// pipeline threw on a run whose only change was declaring an opener.
    ///
    /// Escape rather than a second tap on the trigger, because re-tapping a toggle-style trigger is
    /// ambiguous (some reopen, some do nothing) while Escape is what every menu implementation honours.
    /// Verified rather than assumed — a dismissal that silently fails reintroduces exactly the bug it is
    /// here to prevent, and it would present as an unrelated failure one phase later.
    /// ⛔ **The question is asked of the OPENER, never of the target, and the first version got that
    /// wrong in the way real ChatGPT exposes immediately.** It tested "is the target still findable"
    /// as a proxy for "is the menu still open" — but activating the deep-research item CREATES a
    /// matching pill in the composer, and this platform's entry is a text match with no CSS. So the
    /// proxy stayed true forever: the run's own SUCCESS signal was read as evidence of failure, and
    /// the phase aborted after correctly doing everything it was asked to do.
    ///
    /// The opener has a real answer. Measured on the live page: the composer's plus button carries
    /// `aria-expanded` (false/true) and `data-state` (closed/open), plus `aria-controls` naming the
    /// popup. Those describe the popup itself rather than standing in for it. This mirrors the
    /// backend half exactly — the two are a parity pair and drifting them is how one side silently
    /// keeps the bug.
    /// ⚠ Throws rather than returning a Bool nobody reads. The previous signature was
    /// `@discardableResult -> Bool` and every call site discarded it, so the check could not fail
    /// the run no matter what it concluded.
    private func dismissOpener(_ key: String) async throws {
        guard try await dismissedOpener(key) else {
            throw InAppPhaseError.menuWouldNotClose(platform: platform, key: key)
        }
    }

    private func dismissedOpener(_ key: String) async throws -> Bool {
        guard let openerCSS = openers[key] else { return true }
        _ = try? await page.evaluateJSON(
            "(function(){var e=new KeyboardEvent('keydown',{key:'Escape',code:'Escape',"
                + "keyCode:27,which:27,bubbles:true,cancelable:true});"
                + "document.activeElement && document.activeElement.dispatchEvent(e);"
                + "document.dispatchEvent(e); return true;})()"
        )
        for _ in 0..<8 {
            if try await popupIsOpen(openerCSS) == false { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Is the popup this opener controls currently open?
    ///
    /// ⚠ The ordering is deliberate and matches the backend's: a NEGATIVE state attribute is
    /// decisive and is checked FIRST, because the generic fallback ("is any popup container on
    /// screen") is the weakest signal and would otherwise report a *different* component's open
    /// dialog as this opener's menu.
    ///
    /// Returns nil when the page cannot be asked at all, which the caller treats as "keep waiting"
    /// rather than as a dismissal — a guard that cannot run must never report success.
    private func popupIsOpen(_ openerCSS: String) async throws -> Bool? {
        let escaped = openerCSS.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
          var op = document.querySelector('\(escaped)');
          if (!op) return {open:false};
          var expanded = op.getAttribute('aria-expanded');
          var state = op.getAttribute('data-state');
          if (expanded === 'false' || state === 'closed') return {open:false};
          if (expanded === 'true' || state === 'open') return {open:true};
          var id = op.getAttribute('aria-controls');
          var popup = id ? document.getElementById(id) : null;
          if (popup) return {open: !!popup.offsetParent};
          var containers = [].slice.call(
            document.querySelectorAll('[role=menu],[role=listbox],[role=dialog]')
          ).filter(function(m){ return !!m.offsetParent; });
          return {open: containers.length > 0};
        })()
        """
        guard let raw = try? await page.evaluateJSON(js),
              let dict = raw as? [String: Any],
              let open = dict["open"] as? Bool
        else { return nil }
        return open
    }

    /// Tap this key's opener, then wait for the target to appear.
    ///
    /// ⚠ The wait is not optional and its length is measured, not guessed. ChatGPT's plus menu renders in
    /// TWO passes: the attachment rows arrive immediately and the tools/plugins section a moment later. A
    /// fixed short sample sees 3 items where 19 exist, and "Deep research" is the 7th — so a probe that
    /// looked once concluded the control did not exist. It does; it had not painted.
    private func openThenFind(_ key: String) async throws -> Int? {
        guard let openerCSS = openers[key],
              let opener = try await page.querySelector(openerCSS) else { return nil }
        try await page.click(opener)
        var waited = 0
        while waited < 12 {
            for css in manifest[key] ?? [] {
                if let handle = try await page.querySelector(css) { return handle }
            }
            if let handle = try await resolveByText(key) { return handle }
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        return nil
    }

    /// Roles searched when falling back to text — the SAME list the Python `resolve()` uses.
    ///
    /// Menu roles are included for a measured reason: ChatGPT's deep-research control is a
    /// `[role=menuitem]`, which `button, a, [role=button]` does not match, so a hand-found selector
    /// would still have reported "no selector". Divergence between the two lists is divergence between
    /// the two surfaces, which is the thing this file exists to prevent.
    static let textFallbackRoles =
        "button, a, [role=button], [role=menuitem], [role=menuitemradio], [role=option]"

    /// Find a handle by visible text, case-insensitively, as the last resort.
    private func resolveByText(_ key: String) async throws -> Int? {
        guard let needle = texts[key]?.lowercased(), !needle.isEmpty else { return nil }
        for handle in try await page.querySelectorAll(Self.textFallbackRoles) {
            if let text = try await page.innerText(handle),
               text.lowercased().contains(needle) {
                return handle
            }
        }
        return nil
    }

    /// Resolve a manifest key to a live handle, trying each candidate in order.
    ///
    /// A fallback chain rather than one selector because platforms A/B-test their DOM, and the first
    /// candidate failing is normal rather than exceptional.
    func resolve(_ key: String) async throws -> Int {
        let candidates = manifest[key] ?? []
        for css in candidates {
            if let handle = try await page.querySelector(css) { return handle }
        }
        // Text LAST, matching the Python side's order: matching on copy is fragile in the opposite
        // direction, so it is the fallback rather than the first choice.
        if let handle = try await resolveByText(key) { return handle }
        // Last: the target may be behind an opener that has not been tapped yet.
        if let handle = try await openThenFind(key) { return handle }
        throw InAppPhaseError.unresolved(platform: platform, key: key, tried: candidates)
    }

    func optional(_ key: String) async throws -> Int? {
        for css in manifest[key] ?? [] {
            if let handle = try await page.querySelector(css) { return handle }
        }
        if let handle = try await resolveByText(key) { return handle }
        return try await openThenFind(key)
    }

    // MARK: - P0

    public func loggedIn() async throws -> Bool {
        try await optional("logged_in_marker") != nil
    }

    // MARK: - P1/P2 composition

    /// Put the prompt in the composer, via the path that updates the editor's MODEL.
    ///
    /// ⚠ Assigning `textContent` leaves the send button **disabled**: these editors gate send on their
    /// internal model, not on the DOM text. The symptom is a page that appears to ignore you, and it
    /// looks like a broken selector rather than a wrong write path.
    @discardableResult
    public func fillComposer(_ text: String) async throws -> String {
        let composer = try await resolve("composer")
        // ⛔ **A modal over the page makes the composer unfillable, silently.** Measured live
        // 2026-08-14 on ChatGPT: `hasFocus=true`, the composer rendered at 308x276, and
        // `inert=true` — a dialog was open, and `inert`/`aria-hidden` content is neither
        // focusable nor editable, so `focus()` no-ops and every synthetic event is ignored. The
        // fill then fails for a reason that points at the editor rather than at the thing on top
        // of it.
        //
        // ⚠ Attempted, then RE-CHECKED. Escape is what dismisses a modal, but a dialog that
        // refuses to close must not be reported as cleared — the whole point is that the next
        // failure names the blocker instead of the composer.
        try await clearBlockingOverlay(composer)
        let path = try await page.insertText(composer, text)
        // ⛔ **A refusal is now a failure, and it is named where it happened.** This guard used to
        // test the path STRING only, so `{ok:false, path:"execCommand"}` sailed through it: the
        // composer was empty, the fill reported success, and the run died at `send` — a selector
        // that was perfectly correct. The failure is reported at the composer, which is where it is.
        guard let path, path != "not-a-text-target",
              !path.hasPrefix("refused"), !path.hasPrefix("no-caret") else {
            let detail = (path.map { $0.hasPrefix("refused") || $0.hasPrefix("no-caret") } == true)
                ? " — \(path!)" : ""
            throw InAppPhaseError.outcomeUnconfirmed(intent: "\(platform).composer\(detail)")
        }
        return path
    }

    /// Dismiss anything modal that is neutralising the composer.
    ///
    /// ⚠ Best-effort by design: it reports what it saw and does not throw. A page with no overlay
    /// is the normal case and must cost nothing, and a dialog that will not close is better
    /// reported by the fill's own `no-caret` verdict — which now names the blocking element —
    /// than by a second error competing to describe the same moment.
    @discardableResult
    public func clearBlockingOverlay(_ composer: Int) async throws -> Bool {
        guard let result = try await page.evaluateJSON("window.__sr.clearOverlay(\(composer))")
                as? [String: Any] else { return false }
        guard let blocker = result["blocker"] as? [String: Any] else { return true }
        let note = (result["note"] as? String) ?? "?"
        // ⚠ An ADVISORY finding is not a block, and saying so is the whole point. ChatGPT's composer
        // carries `aria-hidden` in its normal markup; calling that "blocked, Escape did not dismiss
        // it" is a confident wrong answer that sends the next session hunting a modal that is not
        // there. Logged at a different level of claim, and reported as clear.
        if (result["advisory"] as? Bool) == true {
            NSLog("[SR] %@: composer carries %@ — not a block, proceeding", platform, note)
            return true
        }
        let cleared = (result["cleared"] as? Bool) ?? false
        NSLog("[SR] %@: composer was blocked by %@ — %@", platform, String(describing: blocker), note)
        return cleared
    }

    /// Ensure deep research is ON. **Idempotent — not "tap the toggle".**
    ///
    /// ⚠ The Python implementation shipped exactly this bug, and it is worth restating because a
    /// reimplementation is precisely where it comes back. Toggle state **persists across sessions**,
    /// and persistent login is this whole track's premise, so every run after the first finds the
    /// toggle already on. An unconditional tap then switches it OFF, the predicate correctly fails,
    /// escalation is correctly refused, nothing recovers it, and a full P0–P3 completes with deep
    /// research disabled *while reporting success*. The output is a shallow answer that looks normal.
    ///
    /// Returns whether a tap was needed, so a caller can tell "enabled it" from "already was".
    @discardableResult
    public func enableDeepResearch() async throws -> Bool {
        if try await deepResearchOn("deep_research_toggle") {
            try await dismissOpener("deep_research_toggle")
            return false
        }
        // Resolved only AFTER the already-on check, and the order is deliberate: `optional` may TAP an
        // opener to find the item, and opening a menu to ask a question the page had already answered is
        // both wasteful and a state change nobody asked for.
        guard let toggle = try await optional("deep_research_toggle") else { return false }
        try await page.click(toggle)
        try await dismissOpener("deep_research_toggle")
        try await awaitComposerReady()
        // Judged by the PAGE, not by a handle that the activation may have destroyed.
        let confirmed = try await deepResearchOn("deep_research_toggle")
        guard confirmed else {
            throw InAppPhaseError.outcomeUnconfirmed(intent: "\(platform).deep_research_toggle")
        }
        return true
    }

    /// Ensure deep research is OFF, for P1. **Idempotent, and NOT a second tap.**
    ///
    /// ⛔ **Tapping the toggle again ADDS A SECOND TOOL.** The backend's own hotspot hint says it in
    /// as many words: *"REMOVE it by pressing Backspace in the empty message box; do NOT click the
    /// 'Deep research' tool (clicking adds a second one)"*. A mirror of `enableDeepResearch` leaves
    /// P1 in a worse state than it started, and every symptom is downstream and confusing.
    ///
    /// ⚠ **This is a live bug, not a gap.** Toggle state persists across sessions — that is this
    /// track's premise — so run 2's P1 begins with deep research still on from run 1's P2, and a P1
    /// in deep-research mode returns a 30-minute report where a brief was wanted. Nothing fails; the
    /// run produces the wrong artefact and carries on.
    ///
    /// Returns whether anything had to be done.
    @discardableResult
    public func disableDeepResearch(attempts: Int = 3) async throws -> Bool {
        guard try await deepResearchOn("deep_research_toggle") else { return false }
        // The composer must be EMPTY: with text present the keystroke deletes a character of the
        // prompt instead of the pill, which looks like nothing happening and quietly corrupts what
        // gets sent.
        // Focus by clicking the composer: `key` goes to whatever holds focus, and a Backspace sent
        // at the document does nothing at all — which would read as "the pill will not go away".
        let composer = try await resolve("composer")
        try await page.click(composer)
        for _ in 0..<attempts {
            try await page.key("Backspace")
            if try await deepResearchOn("deep_research_toggle") == false { return true }
        }
        // ⛔ Deliberately NOT falling back to a tap — a tap adds a second tool rather than removing
        // this one, so the fallback is worse than the failure.
        throw InAppPhaseError.outcomeUnconfirmed(intent: "\(platform).deep_research_toggle.disable")
    }

    /// P1's product: the assistant's answer as text.
    ///
    /// ⚠ **The P1 path only, and a different mechanism from P2's.** With deep research OFF the
    /// answer is an ordinary chat turn in the main document, so reading the response container is
    /// right. With it ON the answer is not in the main document at all — gate zero measured 499
    /// chars of chrome with the report in a cross-origin frame — and `extractReport` fetches it
    /// instead. One extractor for both would work in testing, where the composer is driven with
    /// deep research off, and return a speaker prefix in production.
    /// Is the platform still producing the answer? Its own controls decide, not our text reading.
    ///
    /// ⛔ **VISIBILITY, not mere presence.** Measured on a COMPLETED deep-research page: the
    /// platform said "I've completed your research", the finished report was in the DOM, and a
    /// `Stop response` button was **still present at height 0**. A selector-only check reports
    /// in-flight forever — the wait can never complete and the run spends its whole timeout on a
    /// report already sitting there, then reports a timeout, which invites raising the budget for
    /// something no waiting fixes.
    ///
    /// ⚠ Rendered-size test rather than `offsetParent`: a `position: fixed` control has a null
    /// `offsetParent` while being perfectly visible, and stop buttons are routinely fixed.
    ///
    /// ⚠ Unknown means NOT generating. This is consulted only to *veto* a completion that content
    /// stability already accepted, so a probe that cannot answer must not be able to stall a
    /// finished run forever — the failure this whole method exists to prevent.
    /// Where each panel reading goes. Nil on every path that has no run to report to — the C1 gate,
    /// the tests that only care about phase order — so the scrape costs nothing there.
    public var onActivity: ((Int, ActivityPanel.Snapshot) -> Void)?

    // ⚠ The phase travels as an ARGUMENT rather than as state on the driver. The frontend files
    // narration per PHASE — phase 2's emits must not land in the slot phase 1's dropdown reads —
    // and a stored property would have to be set correctly by every future caller, which is the
    // kind of join that goes missing at the fifth call site.

    /// Open the panel if it is not open, then read it.
    ///
    /// ⚠ **Re-opens rather than assuming.** The panel closes on its own — a navigation, a re-render,
    /// the owner tapping the page in Browser watch — and a poller that pressed once and trusted it
    /// would go quiet for the rest of a forty-minute phase with nothing saying why. Cheap to
    /// re-check: when it IS open the scrape answers on its own and no press is attempted.
    private func pumpActivity(polls: Int, phase: Int) async {
        let snapshot = await readActivity()
        if snapshot.panelFound {
            onActivity?(phase, snapshot)
            return
        }
        // ⚠ Press at most once every ~10s. The strip is a toggle: pressing it while the panel is
        // already opening CLOSES it, and a 4Hz retry loop would flicker it shut on every tick.
        guard polls % 40 == 0 else { return }
        await openActivityPanel()
        // Report whatever the press produced, even when it produced nothing — a run that cannot
        // open its own panel is a fact worth having in the trace rather than silence.
        onActivity?(phase, await readActivity())
    }

    private func readActivity() async -> ActivityPanel.Snapshot {
        guard let raw = (try? await page.evaluateJSON(ActivityPanel.scrapeJS)) as? [String: Any]
        else { return ActivityPanel.Snapshot() }
        var snapshot = ActivityPanel.Snapshot()
        snapshot.panelFound = (raw["panelFound"] as? Bool) ?? false
        snapshot.steps = (raw["steps"] as? [String]) ?? []
        snapshot.progress = (raw["progress"] as? String) ?? ""
        snapshot.sources = ((raw["sources"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            return ActivityPanel.Source(url: url, title: (item["title"] as? String) ?? "")
        }
        return snapshot
    }

    /// Mark the shimmering strip in JS, then press it through the page's own click path.
    ///
    /// ⛔ Never `el.click()`. Measured on this device's corpus: a synthetic click opened ChatGPT's
    /// React overlays 0 times in 7 attempts, because their handlers listen on `pointerdown`.
    private func openActivityPanel() async {
        guard let hit = (try? await page.evaluateJSON(ActivityPanel.markStripJS)) as? [String: Any],
              (hit["found"] as? Bool) == true,
              let strip = (try? await page.querySelector("[\(ActivityPanel.stripMark)]")) ?? nil
        else { return }
        NSLog("[SR] %@: opening the activity panel — strip %@", platform,
              String(describing: hit["text"] ?? "?"))
        try? await page.click(strip)
    }

    public func isGenerating() async throws -> Bool {
        let css = Self.generatingSelector(for: platform)
        let js = """
        (() => [...document.querySelectorAll('\(css)')].some(e => {
          const r = e.getBoundingClientRect();
          const s = getComputedStyle(e);
          return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
        }))()
        """
        guard let raw = try? await page.evaluateJSON(js), let busy = raw as? Bool else { return false }
        return busy
    }

    /// The in-flight control per platform, ported from the backend half rather than invented.
    ///
    /// ⚠ Gemini's is deliberately broader, carrying the backend's own caveat: its collapsed composer
    /// often shows NO stop button mid-run, so a stop-button-only check reads a live deep-research
    /// run as finished.
    static func generatingSelector(for platform: String) -> String {
        switch platform {
        case "chatgpt":
            return "button[data-testid=\\\"stop-button\\\"], button[aria-label*=\\\"Stop\\\"], [data-testid*=\\\"loading\\\"]"
        case "gemini":
            return "button[aria-label*=\\\"Stop\\\"], .stop-icon, progress-indicator, [data-test-id*=\\\"loading\\\"]"
        default:
            return "button[aria-label*=\\\"Stop\\\"]"
        }
    }

    /// Press the plan-confirmation control, if this platform puts one in the way.
    ///
    /// ⛔ **Measured on a live deep-research run, 2026-08-09.** Sending does not start Gemini's
    /// deep research: it replies with a ~1,200-character research PLAN and stops. Generation ends,
    /// the text is stable and entirely plausible, so the wait completes and the extractor harvests
    /// the plan as the report — a document about what it was going to research, shipped as research.
    ///
    /// ⚠ **Polled, not read once.** The plan takes tens of seconds to render, so a single look
    /// straight after send finds nothing and concludes the platform has no such step — which is
    /// exactly why this went unnoticed until a run was watched end to end.
    ///
    /// ⚠ **Absence is not failure.** Platforms that start on send have no entry and return false.
    @discardableResult
    public func startResearchIfOffered(
        attempts: Int = 45,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Bool {
        guard manifest["start_research"] != nil || openers["start_research"] != nil else {
            return false
        }
        for _ in 0..<attempts {
            if let handle = try await optional("start_research") {
                // ⚠ Pressing it NAVIGATES — the page gains a conversation id and the web view's
                // bridge can tear down underneath the call. That is the success path, so a throw
                // here is not treated as a failure to confirm.
                do { try await page.click(handle) } catch {}
                return true
            }
            try? await sleep(.milliseconds(2000))
        }
        return false
    }

    public func extractBrief() async throws -> String {
        guard let container = try await optional("response_container") else { return "" }
        let raw = ((try await page.innerText(container)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return strippingSpeakerPrefix(raw)
    }

    /// Remove the "Claude responded:" / "ChatGPT said:" label the turn renders above its content.
    ///
    /// ⛔ **Measured live 2026-08-14: the brief began `Claude responded: Deep Research Brief:`** —
    /// the speaker label was captured as part of the product and carried into P2's prompt and into
    /// the saved document. `extractReport`'s own comment had predicted exactly this ("would return
    /// a speaker prefix in production"); nothing acted on the prediction.
    ///
    /// ⚠ Anchored to the start AND to THIS PLATFORM'S OWN NAME, never a general pattern.
    ///
    /// ⛔ The first version matched "any one or two words, then said/responded, then a colon" — and
    /// its own test caught it stripping `The paper said:` from the opening of a report. A research
    /// document is arbitrary prose; a rule loose enough to edit it will eventually edit it, and
    /// silently. Naming the speaker we are actually reading makes that impossible.
    static func speakerLabels(for platform: String) -> [String] {
        switch platform {
        case "chatgpt": return ["ChatGPT"]
        case "claude": return ["Claude"]
        case "gemini": return ["Gemini"]
        default: return []
        }
    }

    func strippingSpeakerPrefix(_ text: String) -> String {
        Self.strippingSpeakerPrefix(text, platform: platform)
    }

    static func strippingSpeakerPrefix(_ text: String, platform: String) -> String {
        for name in speakerLabels(for: platform) {
            for verb in ["said", "responded", "replied"] {
                let label = "\(name) \(verb):"
                if text.lowercased().hasPrefix(label.lowercased()) {
                    return String(text.dropFirst(label.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return text
    }

    /// P2's product: the full markdown report.
    ///
    /// ⭐ ChatGPT takes the conversation fetch (gate zero: with deep research on, the report is not
    /// in the main document at all — 499 chars of chrome, the report in a cross-origin frame). The
    /// other platforms keep the DOM read, which is an **unmeasured assumption** and written down as
    /// one: if their reports also live out of reach, this returns something short and the floor
    /// rejects it, which is a visible failure rather than a plausible wrong report.
    public func extractReport(
        pollInterval: Duration = .seconds(1), timeout: Duration = .seconds(45),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> String {
        if platform == "chatgpt" {
            return try await ReportExtract.extract(
                from: page, pollInterval: pollInterval, timeout: timeout, sleep: sleep
            )
        }
        guard let container = try await optional("response_container") else { return "" }
        return (try await page.innerText(container)) ?? ""
    }

    /// Is deep research on, judged by the SAME predicate the phase uses?
    ///
    /// Public so the C1 gate can assert idempotence without naming a selector of its own. It used to
    /// read `[data-testid="deep-research-toggle"]` directly — the MOCK's id — which meant that check
    /// could never pass on a real platform however correct the pipeline was. A gate that hardcodes the
    /// fixture is measuring the fixture.
    public func deepResearchIsOn() async throws -> Bool {
        try await deepResearchOn("deep_research_toggle")
    }

    /// The deep-research state, read the way the PYTHON side reads it.
    ///
    /// ⚠ This used to be `togglePressed`, reading only the handle's `aria-pressed`/`aria-checked`. That is the
    /// narrow predicate the backend's own comment warns about — from `research.py::_GEMINI_DR_STATE_JS`:
    /// *"the DR pill's class carries NO reliable pressed marker, so a pressed-class-only check
    /// false-negatived an ACTIVE pill last E2E and the CUA fallback then toggled the working DR OFF."*
    ///
    /// It bit here in a second way the Python side never sees: on ChatGPT the control lives inside a menu that
    /// CLOSES on activation and the page then navigates, so a post-tap read of the handle lands on a stale
    /// item and returns false — `enableDeepResearch` threw `outcomeUnconfirmed` on an activation that had
    /// plainly worked (`tapped=true, still on=false`).
    ///
    /// Three signals, each the only one available somewhere. Measured on real ChatGPT: the pill appears while
    /// `pressed` stays FALSE throughout, so a pressed-only read sees no change across an activation.
    private func deepResearchOn(_ key: String) async throws -> Bool {
        let name = platform == "claude" ? "research" : "deep research"
        let js = """
        (function (name) {
          var norm = function (s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); };
          var target = norm(name);
          var ce = document.querySelector('rich-textarea div[contenteditable="true"]')
                || document.querySelector('#prompt-textarea')
                || document.querySelector('[data-testid="chat-input"]');
          var placeholder = ce ? norm(ce.getAttribute('data-placeholder')
                || ce.getAttribute('placeholder') || ce.getAttribute('aria-label')) : '';
          var research = placeholder.indexOf('research') >= 0
                || placeholder.indexOf('what do you want to') >= 0;
          var scope = (ce && ce.closest('form')) || document.querySelector('form') || document.body;
          var pill = null;
          var nodes = scope.querySelectorAll('button, [role="button"], span, div');
          for (var i = 0; i < nodes.length; i++) {
            var p = nodes[i];
            if (!p.offsetParent) continue;
            // An INDICATOR has no toggle state; a CONTROL does. Without this the toggle becomes its own
            // on-signal and `enable_deep_research` never taps.
            if (p.hasAttribute('aria-pressed') || p.hasAttribute('aria-checked')
                || p.hasAttribute('aria-selected')) continue;
            if (norm(p.textContent) === target) { pill = p; break; }
          }
          return !!pill || research;
        })(%@)
        """.replacingOccurrences(of: "%@", with: "'\(name)'")
        if let on = try await page.evaluateJSON(js) as? Bool, on { return true }
        // The control's own state, last: a well-behaved toggle reports it, and a page whose only signal is
        // that attribute would otherwise have no signal at all.
        if let handle = try await optional(key) {
            if let pressed = try await page.attribute(handle, "aria-pressed") { return pressed == "true" }
            if let checked = try await page.attribute(handle, "aria-checked") { return checked == "true" }
        }
        return false
    }

    /// Tap send and confirm it was **accepted**.
    ///
    /// ⚠ The predicate asserts acceptance, never completion. Gating it on a finished response reported
    /// a false failure on every single run, because the response arrives hundreds of milliseconds
    /// later — and a false failure is worse than no predicate, since it escalates an agent onto a
    /// perfectly healthy page.
    public func send(
        acceptanceWindow: TimeInterval = 10,
        sleep: (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1e9))
        }
    ) async throws {
        let button = try await resolve("send")
        try await page.click(button)
        // POLLED, not checked once.
        //
        // The predicate is right — acceptance, never completion — but it was evaluated with zero
        // tolerance for a render tick, and the container does not exist the instant the click returns.
        // The mock is synchronous enough to hide that; real ChatGPT is not, and the symptom was
        // `outcomeUnconfirmed` on a send that had in fact been accepted. A false failure on a healthy page
        // is the failure this codebase treats as worse than a crash, so the window is the fix rather than
        // dropping the assertion.
        //
        // Bounded deliberately: this waits for the response to START, not to finish. `awaitResponse` is
        // the separate, longer wait, because a deep-research answer can take 45 minutes and an acceptance
        // predicate that waited that long would stop being one.
        var waited: TimeInterval = 0
        while waited < acceptanceWindow {
            if try await optional("response_container") != nil { return }
            await sleep(0.5)
            waited += 0.5
        }
        throw InAppPhaseError.outcomeUnconfirmed(intent: "\(platform).send")
    }

    /// Wait for the response to finish. Polls, because there is no completion event to listen for.
    public func awaitResponse(phase: Int = 1, timeout: TimeInterval,
                              now: @escaping () -> Date = { Date() },
                              shouldStop: () -> Bool = { false },
                              sleep: (TimeInterval) async -> Void = {
                                  try? await Task.sleep(nanoseconds: UInt64($0 * 1e9))
                              }) async throws -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        var lastText: String?
        var stableFor = 0
        // Two accepted signals, and the ORDER is the point.
        //
        // ⚠ This used to poll ONLY `[data-state="complete"]` — an attribute the MOCK FIXTURE sets and no
        // real platform does. So the wait could never succeed off the fixture: 240s made no difference
        // because it was never a timeout problem, and the failure cascaded into `sources: 0`, which then
        // reads as a harvest bug. Third mock-only signal found in this pipeline; the pattern is that
        // anything the mock alone can satisfy is a check that cannot fail on the fixture and cannot pass on
        // a platform.
        //
        // CONTENT STABILITY is the general signal, because it asks about the thing we actually want —
        // "has the answer stopped growing" — rather than about a vendor's private markup. It works on every
        // platform including the fixture, and it needs no per-platform capture. Requiring several
        // consecutive identical reads is what keeps a mid-stream pause from reading as completion.
        var polls = 0
        while now() < deadline {
            // ⛔ **The owner's Stop, checked INSIDE the long wait.** This is the wait that made Stop
            // look broken: a deep-research response is allowed 40 minutes, and a stop honoured only
            // between phases would sit here for the rest of it while the worker pill — correctly —
            // kept saying busy. Checked first, before any page work, so a stop costs no round trip.
            if shouldStop() { throw InAppPhaseError.stoppedByOwner(platform: platform) }
            // Watch for the page changing UNDERNEATH the wait, not just for the answer.
            //
            // A 45-minute wait is long enough for the session to end, a verification prompt to appear, or a
            // quota wall to drop — and the naive behaviour is the worst available: keep polling a page that
            // will never produce an answer, then report a timeout, which says nothing about why. Each of these
            // needs a human, so the run should say so in minutes rather than at the deadline.
            //
            // Checked every ~5s rather than every poll: it is three `querySelectorAll`s, and paying that at
            // 4Hz for 45 minutes to catch an event that takes seconds to matter is the wrong trade.
            polls += 1
            if polls % 20 == 0 {
                if let blocked = try await page.evaluateJSON(WAIT_INTERRUPTION_JS) as? String,
                   !blocked.isEmpty {
                    throw InAppPhaseError.waitInterrupted(platform: platform, reason: blocked)
                }
            }
            // ⚠ A HEARTBEAT for the longest thing the run does. This loop polls at 4Hz for up to
            // forty minutes and used to print nothing at all, so "deep research is working" and
            // "the app died twenty minutes ago" produced identical output: none. Every ~60s is
            // often enough to see progress and rare enough not to flood the system log.
            //
            // It reports the two numbers that distinguish the failure modes: how much text is on
            // the page (0 means the container is resolving but empty — the six-minute silent-fail
            // shape) and how long it has been unchanged (climbing means settling, stuck at 0 means
            // still streaming).
            if polls % 240 == 0 {
                NSLog("[SR] %@: waiting for the response — %dm elapsed, %d chars, stable for %d polls",
                      platform, polls / 240, (lastText ?? "").count, stableFor)
            }
            // ⭐ **The activity panel, every ~2s.** With Pro selected the response container holds a
            // placeholder for minutes at a time — 45 characters, unchanged for 1250 polls, measured
            // live — so this is the only channel that can say what the run is doing. It is also
            // what the frontend's narration strip and raw-activity panel render from.
            if polls % 8 == 0, onActivity != nil {
                await pumpActivity(polls: polls, phase: phase)
            }
            if let done = try await page.evaluateJSON(
                "!!document.querySelector('[data-state=\"complete\"]')"
            ) as? Bool, done {
                return true
            }
            if let handle = try await optional("response_container"),
               let text = try await page.innerText(handle) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // An EMPTY container is not a finished answer. Measured on real ChatGPT: the turn
                // resolves, visibly, and stays empty for six minutes after a failed deep-research start —
                // stability alone would have called that complete.
                if !trimmed.isEmpty, trimmed == lastText {
                    stableFor += 1
                    // ⛔ STABILITY IS NECESSARY, NEVER SUFFICIENT — and this half had no second
                    // opinion at all until now. Measured on live ChatGPT: the assistant turn read
                    // `Pro thinking` — 27 characters — and held it, perfectly stable, for well over
                    // six seconds while the platform was still working. Stability alone accepts
                    // that as the answer, the harvest finds nothing in it, and the run reports read
                    // drift about selectors that are correct.
                    //
                    // So before believing the text has settled, ask the PLATFORM whether it has
                    // stopped. Only its own control can answer that.
                    if stableFor >= 8, !(try await isGenerating()) { return true }
                } else {
                    stableFor = 0
                }
                lastText = trimmed
            }
            await sleep(0.25)
        }
        return false
    }

    /// Collect sources by **text**, not by `href`.
    ///
    /// ⚠ The P1 incident this guards against: the panel renders sources as non-anchor nodes, so a
    /// link-only harvest returned zero for an entire run while every click landed and the run reported
    /// success. Extraction failures are the dominant silent class, which is why this returns the count
    /// for a caller to judge rather than swallowing an empty result.
    public func harvestSources(
        settleWindow: TimeInterval = 12,
        sleep: (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1e9))
        }
    ) async throws -> [String] {
        // Retried within a short window, because CITATIONS ATTACH AFTER THE PROSE.
        //
        // Content stability is the right completion signal — it asks whether the answer stopped growing —
        // and it is nonetheless too eager for this one consumer: on real ChatGPT the text settles and the
        // citations paint a moment later, so a single harvest at completion legitimately found zero.
        //
        // Fixed HERE rather than by making the wait later, so there stays one honest completion signal
        // instead of one tuned per consumer. The retry is bounded and it never fabricates: an empty result
        // after the window is still returned empty, for the caller to judge.
        var attempts = 0
        let maxAttempts = max(1, Int(settleWindow / 1.5))
        while true {
            let found = try await harvestOnce()
            if !found.isEmpty || attempts >= maxAttempts { return found }
            attempts += 1
            await sleep(1.5)
        }
    }

    // MARK: - ChatGPT's effort tier

    /// What a tier selection established. A closed set — the caller keys on these.
    public enum EffortTierVerdict: Equatable, Sendable {
        /// The trigger already names the tier. **Nothing was clicked**, and no menu was opened.
        case already(String)
        /// A row was clicked and the trigger then named the tier.
        case selected(String)
        /// The menu mounted and offered no row naming the tier. The honest no-subscription signal.
        case noTarget(String)
        /// A row was clicked and the trigger did NOT move.
        ///
        /// ⛔ Never reported as success. "The click didn't throw" is not evidence, and a silent
        /// downgrade presented as a pick is the single worst outcome this path can produce.
        case unverified(String)
        /// Nothing readable or openable. Says so rather than guessing.
        case unsure(String)

        /// Is the tier established? Only two of five verdicts qualify, and neither is "we tried".
        public var isOnTier: Bool {
            switch self {
            case .already, .selected: return true
            case .noTarget, .unverified, .unsure: return false
            }
        }

        /// One line for the run log and the phase note, so the owner reads what actually happened.
        public var detail: String {
            switch self {
            case .already(let t): return "already on tier (trigger reads \(t))"
            case .selected(let t): return "selected (trigger now reads \(t))"
            case .noTarget(let d): return "NOT on tier — no row named it (\(d))"
            case .unverified(let d): return "NOT confirmed on tier — \(d)"
            case .unsure(let d): return "tier unknown — \(d)"
            }
        }
    }

    /// The attribute stamped on the element about to be pressed.
    ///
    /// It exists because the SEARCH must happen in JS — the ordered hook groups and the `avoid` rule
    /// live there — while the PRESS must happen through the page's own click path, which takes a
    /// handle. Marking is how one hands the other an element without re-running the search against a
    /// wider set than the read ranked.
    static let clickMark = "data-sr-click-target"

    /// The model/effort trigger's hooks, most durable first. Ported from the backend's captured set.
    static let modelTriggerGroups: [(name: String, css: String)] = [
        ("testid", "button[data-testid*=\"model\" i], [role=\"button\"][data-testid*=\"model\" i]"),
        ("aria", "button[aria-label*=\"model\" i], [role=\"button\"][aria-label*=\"model\" i]"),
        ("pill", "button.__composer-pill, [role=\"button\"].__composer-pill"),
        // ⛔ **None of the three above matched anything on 2026-08-17** — the tier step reported
        // `trigger read (nothing)` three milliseconds into P1, so the run could not even READ which
        // model was selected, let alone confirm Pro. The three hooks were captured from the DESKTOP
        // site; this backend drives the phone layout, where the switcher is the header control that
        // names the current model rather than a button labelled "model".
        //
        // ⚠ Ordered last on purpose. It is the widest of the four — a header control carrying an
        // expandable menu — so it must only answer when the specific hooks have already failed, and
        // `avoid` still keeps Deep Research out of the ranking.
        ("header", "header button[aria-haspopup], header [role=\"button\"][aria-haspopup],"
            + " button[aria-haspopup=\"menu\"], [role=\"button\"][aria-haspopup=\"menu\"]"),
    ]

    /// The model menu's rows.
    ///
    /// ⚠ **ORDERED, not merged**, and the trade-off is deliberate. Merging would make the pick
    /// survive an effort row that turned into a plain `menuitem` — but it would also put the "other
    /// models" submenu ENTRY into the same ranking pool, where something named like `GPT-5.6 Pro`
    /// both names the tier and carries a version, so it would outrank the real `Pro` row and be
    /// clicked to open a submenu rather than select anything.
    ///
    /// The class group sits LAST because a role is more durable than a class wherever a role exists —
    /// and it is reached only when neither role group matched anything at all.
    static let modelRowGroups: [(name: String, css: String)] = [
        ("radio", "[role=\"menuitemradio\"]"),
        ("menuitem", "[role=\"menuitem\"], [role=\"option\"]"),
        ("menu-item-class", ".__menu-item"),
    ]

    /// Put ChatGPT on the policy effort tier before P1 writes the brief.
    ///
    /// ⭐ **Read first, and open nothing when the answer is already right.** ChatGPT persists the tier
    /// per account, so on every run after the first this is a single read that clicks nothing. That
    /// is the invariant, not an optimisation: never open a popover you have nothing to do in — an
    /// open menu COVERS THE COMPOSER, and the next phase's send then taps the overlay.
    ///
    /// ⛔ **Both arms of the row filter are the 2026-08-05 incident, brought over rather than
    /// re-learned.** A row was located by the bare class `.__menu-item` matched against `document`;
    /// ChatGPT's sidebar lists recent conversations as `<a href>`, one was titled "Deep research
    /// request", the sidebar precedes the composer in document order, and the press NAVIGATED THE
    /// TAB — proven from Chrome's History DB, twice, in the same second as the press. So: (1) a
    /// composer row is never a link, absolutely; (2) a row must be NEW since the menu opened. Arm 1
    /// can never cost a real row so it always applies; arm 2 could, so when the census leaves nothing
    /// the read retries without it and says so.
    ///
    /// ⚠ **The press here is a scripted click, and that is a measured weakness rather than a
    /// choice.** The corpus is explicit: ChatGPT's composer menus are React overlays whose triggers
    /// listen on POINTERDOWN, and a synthetic `el.click()` dispatches a click event and nothing else
    /// — the model menu opened 0 of 1 times and the tools row 0 of 6. In-app there is no trusted-tap
    /// channel to reach for. So this method is built to **report** rather than to assume: when the
    /// menu does not mount, the verdict is `unsure`, the caller records that P1 did not run on the
    /// tier, and the fix available to the owner is real and one-time — select the tier by hand once
    /// on this device, after which the read alone answers `already` on every future run.
    public func selectEffortTier(
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> EffortTierVerdict {
        let pre = try await readEffortTier()
        if ChatGPTModelPolicy.triggerIsOnTarget(pre.text) {
            return .already(quoted(pre.text))
        }

        // The pre-open census. Taken BEFORE the press, because "new since the menu opened" is the
        // whole point of it.
        let seen = (try? await page.evaluateJSON(rowsSeenJS)) as? [String] ?? []

        guard try await markModelTrigger() else {
            // ⛔ **Say what IS there.** On 2026-08-17 this returned "no model trigger to open
            // (trigger read (nothing))" and that was the end of it — four hooks missed, and the
            // verdict named none of the controls the page actually has, so the only way to learn
            // the right selector was another run. A census of the candidates costs one evaluate on
            // a path that has already given up, and turns the next failure into the answer.
            let census = (try? await page.evaluateJSON(triggerCensusJS)) as? [String] ?? []
            let shown = census.prefix(8).joined(separator: " | ")
            return .unsure("no model trigger to open (trigger read \(quoted(pre.text)))"
                + (census.isEmpty ? " — and the page offered no popup controls at all"
                   : " — page offers: \(shown)"))
        }
        guard let trigger = try await page.querySelector("[\(Self.clickMark)=\"model-trigger\"]")
        else {
            return .unsure("the marked model trigger could not be resolved")
        }
        try await page.click(trigger)

        // POLL, don't sleep once. A single fixed wait has to be right about an animation AND about a
        // page that may be seconds old, and when it is wrong the verdict is indistinguishable from a
        // rotated hook. Waiting for the OUTCOME is also what makes "opened" mean the menu is open.
        var rows: [String] = []
        var via = ""
        var seenUsed = seen
        var censusIgnored = false
        for attempt in 0..<10 {
            if attempt > 0 { try? await sleep(.milliseconds(350)) }
            let snap = (try? await page.evaluateJSON(menuRowsJS(seen: seen))) as? [String: Any]
            rows = (snap?["rows"] as? [String]) ?? []
            via = (snap?["via"] as? String) ?? ""
            seenUsed = (snap?["seen_used"] as? [String]) ?? seen
            censusIgnored = (snap?["census_ignored"] as? Bool) ?? false
            if !rows.isEmpty { break }
        }
        if rows.isEmpty {
            try? await page.key("Escape")
            return .unsure(
                "the model menu mounted no rows within 3.5s after a scripted press — a React "
                    + "overlay listening on pointerdown does not open for one; select the tier by "
                    + "hand once on this device and it persists"
            )
        }

        guard let pick = ChatGPTModelPolicy.pickEffortTier(labels: rows) else {
            try? await page.key("Escape")
            // ⛔ Deliberately NOT "take the best row we can find" — nothing names the tier, which on
            // this platform means the plan does not offer it, and quietly selecting the next tier
            // down would mask exactly that.
            //
            // …but `noTarget` is a STRONG claim, read as "this account has no Pro", and it must not
            // rest on the weakest hook. The class group is shared with the TOOLS menu, whose rows
            // name no tier either — so a class-group read finding no tier cannot tell "no Pro on
            // this plan" from "that was the wrong menu".
            if via == "menu-item-class" {
                return .unsure(
                    "no row named the tier, but the rows came from the class fallback — that may "
                        + "not be the model menu at all, so this is NOT a no-tier verdict"
                )
            }
            let shown = rows.prefix(5).map { String($0.prefix(24)) }.joined(separator: " | ")
            return .noTarget("\(rows.count) rows offered\(censusIgnored ? " (census ignored)" : "")"
                + ": \(shown)")
        }

        let clicked = (try? await page.evaluateJSON(
            clickRowJS(via: via, index: pick.index, expect: pick.label, seen: seenUsed)
        )) as? [String: Any]
        guard (clicked?["clicked"] as? Bool) == true,
              let row = try await page.querySelector("[\(Self.clickMark)=\"model-row\"]")
        else {
            try? await page.key("Escape")
            let why = (clicked?["reason"] as? String) ?? "the row could not be marked"
            return .unsure("did not press \(quoted(pick.label)) — \(why)")
        }
        try await page.click(row)
        try? await sleep(.milliseconds(1200))
        try? await page.key("Escape")

        let post = try await readEffortTier()
        if ChatGPTModelPolicy.triggerIsOnTarget(post.text) {
            return .selected(quoted(post.text))
        }
        return .unverified(
            "pressed \(quoted(pick.label)) and the trigger still reads \(quoted(post.text))"
        )
    }

    /// Read the model/effort trigger's own label. Never throws — an unreadable trigger is a fact the
    /// caller handles, not an error that ends a phase.
    func readEffortTier() async throws -> (found: Bool, via: String, text: String) {
        let res = (try? await page.evaluateJSON(modelTriggerJS)) as? [String: Any]
        return (
            found: (res?["found"] as? Bool) ?? false,
            via: (res?["via"] as? String) ?? "",
            text: (res?["text"] as? String) ?? ""
        )
    }

    private func quoted(_ s: String) -> String { s.isEmpty ? "(nothing)" : "\"\(s)\"" }

    private func markModelTrigger() async throws -> Bool {
        let res = (try? await page.evaluateJSON(markModelTriggerJS)) as? [String: Any]
        return (res?["marked"] as? Bool) ?? false
    }

    // MARK: - The JS these four steps run

    /// Emitted once and shared by every body below, so the read can never rank against a wider set
    /// than the click re-resolves. Two identically-typed filters is how the backend's drifted.
    private static let rowFilterJS = """
      var _rowOk = function (el, t, seen) {
        if (!el.offsetParent) return false;
        if (!t) return false;
        if (el.tagName === 'A' && el.getAttribute('href')) return false;
        if (el.closest && el.closest('a[href]')) return false;
        return (seen || []).indexOf(t) === -1;
      };
    """

    private static let jsPreamble = """
      var norm = function (s) { return (s || '').replace(/\\s+/g, ' ').trim(); };
      var vis = function (el) { return el.getClientRects().length > 0 || !!el.offsetParent; };
      var inOverlay = function (el) {
        return !!el.closest('[role="menu"], [role="listbox"], [role="dialog"]');
      };
    """

    private static func groupsLiteral(_ groups: [(name: String, css: String)]) -> String {
        "[" + groups.map { "{name: \(jsString($0.name)), sel: \(jsString($0.css))}" }
            .joined(separator: ", ") + "]"
    }

    /// A JS string literal. Routed through `JSONSerialization` rather than hand-escaped, because a
    /// row label is page-controlled text and hand-escaping it is an injection waiting to happen.
    static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    private static func jsArray(_ items: [String]) -> String {
        "[" + items.map { jsString($0) }.joined(separator: ", ") + "]"
    }

    private var modelTriggerJS: String {
        """
        (function(){
        \(Self.jsPreamble)
          var groups = \(Self.groupsLiteral(Self.modelTriggerGroups));
          var avoid = \(Self.jsString(ChatGPTModelPolicy.avoidWord));
          for (var g = 0; g < groups.length; g++) {
            var els = document.querySelectorAll(groups[g].sel);
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              if (!vis(el) || inOverlay(el)) continue;
              var t = norm(el.textContent);
              // A trigger is a short chip. The cap also stops a wrapper whose textContent
              // concatenates the whole composer from posing as one.
              if (!t || t.length > 40) continue;
              if (avoid && t.toLowerCase().indexOf(avoid) !== -1) continue;
              return {found: true, via: groups[g].name, text: t.slice(0, 60)};
            }
          }
          return {found: false, via: '', text: ''};
        })()
        """
    }

    private var markModelTriggerJS: String {
        """
        (function(){
        \(Self.jsPreamble)
          var attr = \(Self.jsString(Self.clickMark));
          var old = document.querySelectorAll('[' + attr + ']');
          for (var k = 0; k < old.length; k++) { old[k].removeAttribute(attr); }
          var groups = \(Self.groupsLiteral(Self.modelTriggerGroups));
          var avoid = \(Self.jsString(ChatGPTModelPolicy.avoidWord));
          for (var g = 0; g < groups.length; g++) {
            var els = document.querySelectorAll(groups[g].sel);
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              if (!vis(el) || inOverlay(el)) continue;
              var t = norm(el.textContent);
              if (!t || t.length > 40) continue;
              if (avoid && t.toLowerCase().indexOf(avoid) !== -1) continue;
              el.setAttribute(attr, 'model-trigger');
              return {marked: true, via: groups[g].name, text: t.slice(0, 60)};
            }
          }
          return {marked: false, reason: 'no_trigger'};
        })()
        """
    }

    /// Every control on the page that could plausibly BE the model switcher, described.
    ///
    /// ⛔ Runs only when all four hook groups have already missed. The point is not to guess a
    /// selector at runtime — it is to make the failure carry the evidence that fixes it, instead of
    /// costing another live run to learn what the page is made of. Each entry is
    /// `tag[testid|aria-label|class]="text"`, which is enough to write the hook from.
    private var triggerCensusJS: String {
        """
        (function(){
        \(Self.jsPreamble)
          var out = [];
          var els = document.querySelectorAll(
            'button, [role="button"], [aria-haspopup], [aria-expanded]'
          );
          for (var i = 0; i < els.length && out.length < 24; i++) {
            var e = els[i];
            // On screen only: an off-screen control is not the one the owner would tap either.
            if (!e.offsetParent) continue;
            var id = e.getAttribute('data-testid') || '';
            var al = e.getAttribute('aria-label') || '';
            var cls = (e.className && String(e.className).slice(0, 30)) || '';
            var t = norm(e.textContent).slice(0, 28);
            // Skip the anonymous icon buttons that every page has dozens of — they name nothing, so
            // they cannot become a hook and would crowd out the entries that can.
            if (!id && !al && !t) continue;
            out.push(e.tagName.toLowerCase() + '[' + (id || al || cls) + ']="' + t + '"');
          }
          return out;
        })()
        """
    }

    private var rowsSeenJS: String {
        """
        (function(){
        \(Self.jsPreamble)
          var groups = \(Self.groupsLiteral(Self.modelRowGroups));
          var out = [];
          // Group-agnostic on purpose — it unions ALL groups rather than stopping at the first
          // match, because the read afterwards may answer on a different group than this would.
          for (var g = 0; g < groups.length; g++) {
            var els = document.querySelectorAll(groups[g].sel);
            for (var i = 0; i < els.length; i++) {
              if (!els[i].offsetParent) continue;
              var t = norm(els[i].textContent).slice(0, 120);
              if (t && out.indexOf(t) === -1) out.push(t);
            }
          }
          return out;
        })()
        """
    }

    private func menuRowsJS(seen: [String]) -> String {
        """
        (function(){
        \(Self.jsPreamble)
        \(Self.rowFilterJS)
          var groups = \(Self.groupsLiteral(Self.modelRowGroups));
          var scan = function (seen) {
            for (var g = 0; g < groups.length; g++) {
              var rows = [];
              var els = document.querySelectorAll(groups[g].sel);
              for (var i = 0; i < els.length; i++) {
                var t = norm(els[i].textContent).slice(0, 120);
                if (!_rowOk(els[i], t, seen)) continue;
                rows.push(t);
              }
              if (rows.length) return {via: groups[g].name, rows: rows, seen_used: seen};
            }
            return {via: '', rows: [], seen_used: seen};
          };
          var seen = \(Self.jsArray(seen));
          var withCensus = scan(seen);
          if (withCensus.rows.length || !seen.length) return withCensus;
          // The census emptied the candidate set. Retry without it — arm 1 still applies, so a
          // conversation link stays unreachable either way. A durability measure that can break a
          // working path is not a durability measure.
          var without = scan([]);
          if (!without.rows.length) return withCensus;
          without.census_ignored = true;
          return without;
        })()
        """
    }

    private func clickRowJS(via: String, index: Int, expect: String, seen: [String]) -> String {
        """
        (function(){
        \(Self.jsPreamble)
        \(Self.rowFilterJS)
          var attr = \(Self.jsString(Self.clickMark));
          var old = document.querySelectorAll('[' + attr + ']');
          for (var k = 0; k < old.length; k++) { old[k].removeAttribute(attr); }
          var groups = \(Self.groupsLiteral(Self.modelRowGroups));
          var g = null;
          for (var i = 0; i < groups.length; i++) {
            if (groups[i].name === \(Self.jsString(via))) { g = groups[i]; }
          }
          if (!g) return {clicked: false, reason: 'group_gone'};
          var seen = \(Self.jsArray(seen));
          var rows = [];
          var els = document.querySelectorAll(g.sel);
          for (var j = 0; j < els.length; j++) {
            var t = norm(els[j].textContent).slice(0, 120);
            if (!_rowOk(els[j], t, seen)) continue;
            rows.push(els[j]);
          }
          var el = rows[\(index)];
          if (!el) return {clicked: false, reason: 'index_gone'};
          // IDENTITY DECIDES, not position: ranking happened between two evaluates, and if the menu
          // re-rendered in that gap the index now points at a different row.
          var text = norm(el.textContent).slice(0, 120);
          if (text !== \(Self.jsString(expect))) {
            return {clicked: false, reason: 'label_changed'};
          }
          el.setAttribute(attr, 'model-row');
          return {clicked: true};
        })()
        """
    }

    private func harvestOnce() async throws -> [String] {
        var out: [String] = []
        for css in manifest["sources"] ?? [] {
            let handles = try await page.querySelectorAll(css)
            if handles.isEmpty { continue }
            for handle in handles {
                if let text = try await page.innerText(handle), !text.isEmpty { out.append(text) }
            }
            break
        }
        return out
    }
}

/// The P0–P3 loop, with the ordering invariants the production backend paid for.
public struct InAppPipeline {
    public struct Outcome: Equatable {
        public var phasesCompleted: [String] = []
        public var sources: [String] = []
        /// P1's product and P2's input. Empty until P1 has captured it.
        public var brief = ""
        /// P2's product: the markdown report. THE thing a run exists to produce.
        public var report = ""
        public var deepResearchWasAlreadyOn = false
        /// Did this platform put a research PLAN in the way, and did we confirm it?
        ///
        /// Recorded rather than inferred: "the report is long" cannot distinguish a confirmed run
        /// from a plan harvested as the report, and the plan is the more plausible-looking of the
        /// two.
        public var planWasConfirmed = false
        /// What P1's effort-tier step established, in words. Empty when P1 did not run.
        ///
        /// ⛔ A **string of the verdict, not a Bool**, because "did P1 run on the tier" has five
        /// answers and only two of them are yes. Collapsing "the trigger already said Pro" and "the
        /// menu never opened so we do not know" into one flag is how a run reports a brief as
        /// written on Pro when it was written on Instant.
        public var effortTier = ""
        public var status = "pending"
    }

    /// Are these two reads the same text, allowing for a re-render?
    ///
    /// ⚠ A prefix comparison, deliberately. Two reads of one turn taken seconds apart routinely
    /// differ by a trailing character, a collapsed space or a citation marker appearing — enough to
    /// make `==` answer "different" about text that is plainly identical.
    static func isSameText(_ lhs: String, as rhs: String, probe: Int = 400) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Lengths within a hair of each other AND the same opening is what makes it the same turn;
        // either alone is too weak — a report legitimately starts by restating the brief's title.
        guard abs(a.count - b.count) <= max(8, min(a.count, b.count) / 100) else { return false }
        let n = min(probe, min(a.count, b.count))
        return a.prefix(n) == b.prefix(n)
    }

    /// Emitted in order, so a caller can compare against the golden fixture.
    public private(set) var events: [(phase: Int, event: String)] = []

    /// Called the MOMENT an event happens, in addition to being buffered above.
    ///
    /// ⛔ **The buffer alone made a 30-to-90-minute run a black hole.** `events` was flushed to the
    /// durable trace only after the platform finished or threw, so a crash mid-run — which is
    /// exactly what happened twice on 2026-08-14 — left a four-line trace file ending at
    /// `<platform>.start`, and the whole question "how far did it get?" was unanswerable. A log you
    /// only get when the run ends cleanly is a log for the case that needed no log.
    var onEvent: ((Int, String) -> Void)?

    /// Called with P1's brief as soon as P1 has one, whatever happens later.
    ///
    /// ⚠ **`async`, and AWAITED at the phase boundary.** The owner's requirement is an order, not a
    /// notification: the brief document has to be written and streamed BEFORE phase 2 begins, so
    /// the web app can complete its phase-1 tile instead of sitting on it for the forty minutes of
    /// deep research that follow. A fire-and-forget callback would satisfy the letter of "report
    /// the brief" and none of that.
    var onBriefProduced: ((String) async -> Void)?

    /// Panel readings, forwarded to the driver that takes them.
    ///
    /// ⚠ Set THROUGH the pipeline rather than on the driver directly: the driver is a `let` inside
    /// this struct, so a caller that reached for it would be setting a copy — the classic value-type
    /// join that compiles, runs, and reports nothing.
    var driverActivity: ((Int, ActivityPanel.Snapshot) -> Void)? {
        get { driver.onActivity }
        set { driver.onActivity = newValue }
    }

    /// A PHASE-BOUNDARY event: buffered AND emitted live.
    ///
    /// ⚠ The buffer is a contract — the golden fixture compares this exact sequence — so only the
    /// five phase words belong here. Step detail goes to `note`.
    private mutating func record(_ phase: Int, _ event: String) {
        events.append((phase, event))
        onEvent?(phase, event)
    }

    /// A STEP-LEVEL note: emitted live, never buffered.
    ///
    /// ⛔ Deliberately not in `events`. The first version of this put "composer_filled", "sent" and
    /// the tier verdict into the same array, which broke the golden phase-sequence fixture — and
    /// rightly: that fixture is how the two implementations of the pipeline are kept in step, and
    /// widening it to carry diagnostics would mean every new log line is a contract change. The
    /// trace wants both; the contract wants only the phases.
    private func note(_ phase: Int, _ event: String) {
        onEvent?(phase, event)
    }

    private var driver: InAppPhaseDriver
    private let topic: String
    /// A brief supplied by the OWNER instead of produced by P1.
    ///
    /// ⭐ Real product behaviour, not a test affordance: the web app's start payload carries
    /// `briefText` for the flow where P1 is skipped because the owner pasted their own brief. So
    /// "P1 was skipped" must NOT mean "P2 has no input" — it means the input came from elsewhere.
    /// Without this, skipping P1 makes P2 refuse and a supported flow kills the run.
    private let providedBrief: String

    public init(driver: InAppPhaseDriver, topic: String, providedBrief: String = "") {
        self.driver = driver
        self.topic = topic
        self.providedBrief = providedBrief
    }

    /// Run P0 through P3.
    ///
    /// Ordering is load-bearing and mirrors `emubackend/pipeline.py`:
    ///
    /// * **the stop check precedes the skip check** — a stop requested while a phase is skippable must
    ///   stop, not be swallowed by the skip;
    /// * **`phase_start` is emitted after the pause gate**, never before, or a paused run advertises a
    ///   phase it has not begun and the frontend shows progress that is not happening.
    public mutating func run(
        shouldStop: () -> Bool = { false },
        shouldSkip: (Int) -> Bool = { _ in false },
        awaitResume: () async -> Void = {},
        isPaused: () -> Bool = { false },
        responseTimeout: TimeInterval = 20,
        extractionTimeout: Duration = .seconds(45),
        pageReadyTimeout: TimeInterval = 90,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Outcome {
        var outcome = Outcome()
        outcome.brief = providedBrief

        // ⛔ **Before phase 0, and before the stop/skip checks can excuse it.** The web view may
        // have been created microseconds ago; every phase below assumes a live page, and the one
        // that runs first is whichever the config left enabled. Gating inside phase 0 would leave
        // the normal configuration — verification skipped — driving an empty document.
        switch try await driver.awaitPageReady(timeout: pageReadyTimeout, sleep: sleep) {
        case .ready:
            break
        case .signedOut(let reason):
            // The same conclusion P0 exists to reach, reached from evidence rather than from a
            // selector that had not rendered yet. Recorded as an event so the trace says WHY.
            record(0, "not_signed_in")
            throw InAppPhaseError.notLoggedIn(platform: driver.platform, reason: reason)
        case .notReady(let reason):
            record(0, "page_never_ready")
            throw InAppPhaseError.waitInterrupted(platform: driver.platform, reason: reason)
        }

        for phase in 0...3 {
            if shouldStop() { outcome.status = "stopped"; return outcome }
            if shouldSkip(phase) { record(phase, "phase_skipped"); continue }
            if isPaused() { await awaitResume() }
            record(phase, "phase_start")

            switch phase {
            case 0:
                guard try await driver.loggedIn() else {
                    throw InAppPhaseError.notLoggedIn(
                        platform: driver.platform,
                        reason: "the logged_in_marker did not resolve on a page that had already "
                            + "loaded and hydrated its composer"
                    )
                }
            case 1 where !outcome.brief.isEmpty:
                // ⭐ The brief is ALREADY IN HAND, so P1 has nothing to produce.
                //
                // ⚠ Not an optimisation. Without it, a run driving three platforms re-derives the
                // brief on each one and OVERWRITES the supplied value — three first phases spent,
                // and three agents that were supposed to answer ONE brief each answering a
                // different one. Caught by the adapter's test, which passed a brief in and got a
                // different one back.
                record(phase, "phase_skipped")
            case 1:
                // ⭐ P1 is the BRIEF, with deep research OFF — reconciled to §5's contract.
                //
                // ⚠ This phase used to enable deep research and type the bare topic, and P2 used to
                // be "send and wait". That is a different pipeline wearing the same phase numbers,
                // and it was the recipe's §15.4 open question. Three separate wrong products came
                // out of it: a chat answer instead of a brief, a P1 that ran in deep-research mode
                // on every run after the first, and nothing captured at all.
                // ⭐ The tier BEFORE the tool state, matching the backend's own order: selecting a
                // model can re-render the composer, and clearing deep research afterwards then
                // re-establishes readiness for the fill either way.
                //
                // ⚠ Recorded, never enforced. Refusing to run P1 because the tier could not be
                // *verified* would brick the device for anyone whose ChatGPT is not already on the
                // tier — and the read cannot always tell "not on it" from "could not look". So the
                // run proceeds and the verdict is carried out with it: the one thing that must never
                // happen is reporting a brief as written on the tier when it was not.
                if driver.platform == RunExecutor.briefPlatform {
                    outcome.effortTier = try await driver.selectEffortTier(sleep: sleep).detail
                    // ⚠ LOGGED, not just recorded. The first live run put this only in the outcome,
                    // where nothing surfaced it until the run finished — so the one question the
                    // step exists to answer ("did the brief get written on the policy tier?") was
                    // unanswerable while watching, and the run died before the outcome existed.
                    NSLog("[SR] %@: effort tier — %@", driver.platform, outcome.effortTier)
                    note(phase, "effort_tier:\(outcome.effortTier)")
                }
                _ = try await driver.disableDeepResearch()
                // ⛔ The Bool is READ now. `awaitComposerReady` returns false on timeout, and all
                // three call sites discarded it — so a composer that never appeared was typed into
                // anyway, and the run failed later at a step that was working.
                guard try await driver.awaitComposerReady() else {
                    throw InAppPhaseError.outcomeUnconfirmed(
                        intent: "\(driver.platform).composer-never-ready"
                    )
                }
                // ⚠ The write PATH is logged on success, not only on failure. `insertText` falls
                // back execCommand → synthetic paste → beforeinput, and which rung answered is the
                // difference between "the composer is healthy" and "we are one WebKit change from
                // typing nothing" — a distinction that was invisible on every successful run.
                let fillPath = try await driver.fillComposer(Prompts.briefPrompt(topic: topic))
                note(phase, "composer_filled:\(fillPath ?? "unknown")")
                try await driver.send()
                note(phase, "sent")
                // ⛔ **The Bool is READ.** It was discarded at both call sites, so a deadline hit
                // while the page was still generating fell straight through to extraction — and a
                // truncated answer that clears the length floor ships as a finished one. "Still
                // writing when we gave up" and "finished" are not the same page.
                guard try await driver.awaitResponse(
                    phase: phase, timeout: responseTimeout, shouldStop: shouldStop
                ) else {
                    note(phase, "response_timeout")
                    throw InAppPhaseError.outcomeUnconfirmed(
                        intent: "\(driver.platform).response-timeout after \(Int(responseTimeout))s"
                            + " — the page was still changing, so anything extracted now is partial"
                    )
                }
                note(phase, "response_settled")
                let brief = try await driver.extractBrief()
                guard brief.count >= Prompts.briefFloorChars else {
                    // Refused rather than carried forward: feeding a stub to three deep-research
                    // agents spends three units of a hard monthly cap on nothing.
                    throw InAppPhaseError.outcomeUnconfirmed(
                        intent: "\(driver.platform).brief(\(brief.count) chars)"
                    )
                }
                outcome.brief = brief
                // ⛔⛔ **Reported the MOMENT it exists, because a later phase can destroy it.**
                // Measured live 2026-08-17: P1 spent fifteen minutes producing a brief, ChatGPT's
                // P2 then threw — and the throw discarded the whole outcome, brief included. The
                // executor saw an empty brief, concluded phase 1 had produced nothing, and
                // abandoned the run before Gemini or Claude were driven at all. Fifteen minutes of
                // Pro thinking, thrown away by a failure in the phase AFTER it.
                await onBriefProduced?(brief)
            case 2:
                // P2 is the REPORT, with deep research ON, fed the brief — never the topic.
                guard !outcome.brief.isEmpty else {
                    throw InAppPhaseError.outcomeUnconfirmed(intent: "p2.brief-missing")
                }
                let alreadyOn = try await driver.enableDeepResearch() == false
                outcome.deepResearchWasAlreadyOn = alreadyOn
                // ⛔ The Bool is READ now. `awaitComposerReady` returns false on timeout, and all
                // three call sites discarded it — so a composer that never appeared was typed into
                // anyway, and the run failed later at a step that was working.
                guard try await driver.awaitComposerReady() else {
                    throw InAppPhaseError.outcomeUnconfirmed(
                        intent: "\(driver.platform).composer-never-ready"
                    )
                }
                let fillPath = try await driver.fillComposer(outcome.brief)
                note(phase, "composer_filled:\(fillPath ?? "unknown")")
                try await driver.send()
                note(phase, "sent")
                // ⛔ Sending is not starting, on at least one platform. Measured live 2026-08-09:
                // Gemini's deep research replies with a ~1,200-character research PLAN and STOPS.
                // Generation ends, the text is stable and reads like a good answer, so the wait
                // below completes and the extractor takes the plan as the report — a document
                // about what it was GOING to research, shipped as research. Nothing fails.
                outcome.planWasConfirmed = try await driver.startResearchIfOffered(sleep: sleep)
                guard try await driver.awaitResponse(
                    phase: phase, timeout: responseTimeout, shouldStop: shouldStop
                ) else {
                    note(phase, "response_timeout")
                    throw InAppPhaseError.outcomeUnconfirmed(
                        intent: "\(driver.platform).response-timeout after \(Int(responseTimeout))s"
                            + " — deep research was still running, so the report would be partial"
                    )
                }
                note(phase, "response_settled")
                let report = try await driver.extractReport(
                    timeout: extractionTimeout, sleep: sleep
                )
                // ⛔ **A REPORT THAT IS THE BRIEF IS NOT A REPORT.** Measured live 2026-08-14:
                // Claude's brief was 11,969 chars and its "report" 11,970 — the same text. The old
                // turn was still on screen and stable, so the response wait returned at once and
                // the extractor harvested the message P1 had already produced. Nothing failed:
                // the run wrote its documents, handed off, and the cloud built a podcast out of
                // the brief.
                //
                // ⚠ Compared on a PREFIX rather than by equality. The two reads are seconds apart
                // and differ by a trailing character or a re-render, which is exactly enough to
                // defeat `==` while being the same text to any reader.
                if !outcome.brief.isEmpty, Self.isSameText(report, as: outcome.brief) {
                    throw InAppPhaseError.outcomeUnconfirmed(
                        intent: "\(driver.platform).report-is-the-brief "
                            + "(\(report.count) vs \(outcome.brief.count) chars) — the response "
                            + "wait returned on the turn P1 had already produced"
                    )
                }
                outcome.report = report
            default:
                // The source harvest stays, as TELEMETRY. It is not the product — the product is
                // the report above — and the recipe's §12 item 9 says exactly that.
                outcome.sources = try await driver.harvestSources()
            }

            record(phase, "phase_complete")
            outcome.phasesCompleted.append("complete")
        }

        outcome.status = "complete"
        return outcome
    }
}
