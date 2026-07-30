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
}

public enum InAppPhaseError: Error, Equatable {
    /// A selector matched nothing. Loud on purpose: a step that quietly did nothing would report
    /// success on a page it never touched.
    case unresolved(platform: String, key: String, tried: [String])
    case notLoggedIn(platform: String)
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
    private let page: WebPage

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
    @discardableResult
    private func dismissOpener(_ key: String) async throws -> Bool {
        guard openers[key] != nil else { return true }
        _ = try? await page.evaluateJSON(
            "(function(){var e=new KeyboardEvent('keydown',{key:'Escape',code:'Escape',"
                + "keyCode:27,which:27,bubbles:true,cancelable:true});"
                + "document.activeElement && document.activeElement.dispatchEvent(e);"
                + "document.dispatchEvent(e); return true;})()"
        )
        for _ in 0..<8 {
            var stillOpen = false
            for css in manifest[key] ?? [] where !stillOpen {
                if try await page.querySelector(css) != nil { stillOpen = true }
            }
            if !stillOpen, try await resolveByText(key) == nil { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
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
    private func resolve(_ key: String) async throws -> Int {
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

    private func optional(_ key: String) async throws -> Int? {
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
        let path = try await page.insertText(composer, text)
        guard let path, path != "not-a-text-target" else {
            throw InAppPhaseError.outcomeUnconfirmed(intent: "\(platform).composer")
        }
        return path
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
    public func awaitResponse(timeout: TimeInterval, now: @escaping () -> Date = { Date() },
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
                    if stableFor >= 8 { return true }   // ~2s of no change at the 0.25s poll
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
        public var deepResearchWasAlreadyOn = false
        public var status = "pending"
    }

    /// Emitted in order, so a caller can compare against the golden fixture.
    public private(set) var events: [(phase: Int, event: String)] = []

    private let driver: InAppPhaseDriver
    private let topic: String

    public init(driver: InAppPhaseDriver, topic: String) {
        self.driver = driver
        self.topic = topic
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
        responseTimeout: TimeInterval = 20
    ) async throws -> Outcome {
        var outcome = Outcome()

        for phase in 0...3 {
            if shouldStop() { outcome.status = "stopped"; return outcome }
            if shouldSkip(phase) { events.append((phase, "phase_skipped")); continue }
            if isPaused() { await awaitResume() }
            events.append((phase, "phase_start"))

            switch phase {
            case 0:
                guard try await driver.loggedIn() else {
                    throw InAppPhaseError.notLoggedIn(platform: driver.platform)
                }
            case 1:
                let alreadyOn = try await driver.enableDeepResearch() == false
                outcome.deepResearchWasAlreadyOn = alreadyOn
                _ = try await driver.fillComposer(topic)
            case 2:
                try await driver.send()
                _ = try await driver.awaitResponse(timeout: responseTimeout)
            default:
                outcome.sources = try await driver.harvestSources()
            }

            events.append((phase, "phase_complete"))
            outcome.phasesCompleted.append("complete")
        }

        outcome.status = "complete"
        return outcome
    }
}
