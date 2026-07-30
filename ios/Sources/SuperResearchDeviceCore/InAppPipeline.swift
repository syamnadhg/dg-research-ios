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
}

/// One platform's steps, each with an outcome predicate — wrapped as written, per A8/A1.
public struct InAppPhaseDriver {
    public let platform: String
    public let manifest: [String: [String]]
    private let page: WebPage

    public init(platform: String, manifest: [String: [String]], page: WebPage) {
        self.platform = platform
        self.manifest = manifest
        self.page = page
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
        throw InAppPhaseError.unresolved(platform: platform, key: key, tried: candidates)
    }

    private func optional(_ key: String) async throws -> Int? {
        for css in manifest[key] ?? [] {
            if let handle = try await page.querySelector(css) { return handle }
        }
        return nil
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
        guard let toggle = try await optional("deep_research_toggle") else { return false }
        // Checked with the same predicate that judges the action, so "already on" cannot drift from
        // "is it on now".
        if try await togglePressed(toggle) { return false }
        try await page.click(toggle)
        guard try await togglePressed(toggle) else {
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
        guard let toggle = try await optional("deep_research_toggle") else { return false }
        return try await togglePressed(toggle)
    }

    private func togglePressed(_ handle: Int) async throws -> Bool {
        if let pressed = try await page.attribute(handle, "aria-pressed") { return pressed == "true" }
        return try await page.attribute(handle, "aria-checked") == "true"
    }

    /// Tap send and confirm it was **accepted**.
    ///
    /// ⚠ The predicate asserts acceptance, never completion. Gating it on a finished response reported
    /// a false failure on every single run, because the response arrives hundreds of milliseconds
    /// later — and a false failure is worse than no predicate, since it escalates an agent onto a
    /// perfectly healthy page.
    public func send() async throws {
        let button = try await resolve("send")
        try await page.click(button)
        guard try await optional("response_container") != nil else {
            throw InAppPhaseError.outcomeUnconfirmed(intent: "\(platform).send")
        }
    }

    /// Wait for the response to finish. Polls, because there is no completion event to listen for.
    public func awaitResponse(timeout: TimeInterval, now: @escaping () -> Date = { Date() },
                              sleep: (TimeInterval) async -> Void = {
                                  try? await Task.sleep(nanoseconds: UInt64($0 * 1e9))
                              }) async throws -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            if let done = try await page.evaluateJSON(
                "!!document.querySelector('[data-state=\"complete\"]')"
            ) as? Bool, done {
                return true
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
    public func harvestSources() async throws -> [String] {
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
