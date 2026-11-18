#if canImport(WebKit)
import Foundation
import WebKit

/// The in-app automation channel for C0/C1 — `WKWebView.evaluateJavaScript`.
///
/// This is the recipe's reuse guarantee made concrete: `WKWebView.evaluateJavaScript` **is** the same
/// channel as IWDP's `Runtime.evaluate`, so the injected runtime, the handle registry and the
/// calibration surface all carry over from Stage 1 unchanged. The app build is the shell, login and
/// distribution — not a re-derivation of the automation.
///
/// ⚠ **NOT VERIFIED IN THIS ENVIRONMENT, and the reason is worth knowing before you plan C0.**
/// `WKWebView` cannot be exercised from a SwiftPM test: `swift test` has no app bundle and no
/// WebProcess host, and instantiating one fails with an `InvalidTransition` before any page loads.
/// So **C0 needs a real app target (an Xcode project or an XCUITest host), not a package test.** That
/// is a scheduling fact, not a detail — planning C0 as "add a test to the package" does not work.
///
/// What *is* already proven, against a real Simulator through the Python side: the runtime payload
/// itself, its handle registry, its calibration surface, and its idempotent re-injection. Only the
/// ~40 lines of `evaluateJavaScript` plumbing below are unexercised.
///
/// ⚠ **The `isTrusted` constraint does not disappear in your own web view.** You get more input
/// latitude than in isolated MobileSafari, but a JS-dispatched event still reports
/// `isTrusted === false`, and the chat SPAs reject exactly those. Measuring what `WKWebView`
/// actually reports is part of C0's job — :func:`WebAutomationBridge.probeTrustedDispatch` exists to
/// answer it directly rather than by assumption.
public final class WebAutomationBridge {

    /// The injected runtime, kept byte-identical to the Python side's payload.
    ///
    /// Passed in rather than duplicated here on purpose: two copies of the runtime would drift, and
    /// the Simulator-tested one is the copy with evidence behind it. Load it from
    /// `emubackend/substrate/runtime_js.py`'s `RUNTIME_JS` at build time, or ship it as a resource.
    public let runtimeJS: String
    private let webView: WKWebView

    public init(webView: WKWebView, runtimeJS: String) {
        self.webView = webView
        self.runtimeJS = runtimeJS
    }

    /// Wait until the document is ready.
    ///
    /// Polls rather than using a navigation delegate because a single-page app finishes its
    /// navigation long before its content exists — the delegate fires and there is nothing to talk
    /// to yet. Polling `readyState` plus a content check is what actually corresponds to "usable".
    /// ⚠ **`readyState` alone is not "loaded", and this returned true on `about:blank`.**
    ///
    /// A fresh `WKWebView` starts on `about:blank`, which reports `readyState == "complete"`
    /// immediately — so a poll on `readyState` alone succeeds *before* the requested page has begun
    /// loading. The C1 gate then ran every phase against a three-node empty document and reported nine
    /// consecutive failures that looked like broken selectors. This function's own doc comment already
    /// claimed a content check; the check was never there.
    ///
    /// Now three conditions, all necessary: the document is complete, it is not `about:blank`, and it
    /// has actual content. `expecting` additionally pins it to the intended URL, which is what
    /// distinguishes "a page loaded" from "the page I asked for loaded".
    @discardableResult
    public func waitForReady(timeout: TimeInterval = 30, expecting: String? = nil) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = try? await evaluate("document.readyState") as? String
            let href = try? await evaluate("location.href") as? String
            let children = try? await evaluate("document.body ? document.body.children.length : 0")
                as? Int
            if Self.isLoaded(
                readyState: state ?? nil, href: href ?? nil, bodyChildren: children ?? nil,
                expecting: expecting
            ) {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    /// The loaded predicate, as a pure function so it is testable without a `WKWebView`.
    ///
    /// Extracted deliberately: the bug above lived in a condition that no test could reach, because the
    /// only way to reach it was to host a real web view. A pure predicate is checkable under
    /// `swift test`, and `about:blank` is now a named case rather than an oversight.
    public static func isLoaded(
        readyState: String?, href: String?, bodyChildren: Int?, expecting: String? = nil
    ) -> Bool {
        guard readyState == "complete" else { return false }
        guard let href, !href.isEmpty, href != "about:blank" else { return false }
        // Content, not just a document. An error page or a stub can be "complete" and empty.
        guard let bodyChildren, bodyChildren > 0 else { return false }
        if let expecting, !href.hasPrefix(expecting) { return false }
        return true
    }

    /// Inject the runtime. Idempotent — safe and cheap to call after every navigation.
    ///
    /// Called unconditionally rather than guarded by a "did we navigate" check, because there is no
    /// such signal worth trusting in a SPA: history manipulation replaces the document's contents
    /// without any navigation event a host can observe.
    @discardableResult
    public func injectRuntime() async throws -> String {
        (try await evaluate(runtimeJS) as? String) ?? "unknown"
    }

    /// Evaluate an expression and decode its JSON result.
    ///
    /// Wrapped in `JSON.stringify` and decoded here rather than relying on `WKWebView`'s own value
    /// bridging, which flattens or drops nested types inconsistently. A string round-trip behaves
    /// identically everywhere, and it matches what the Python side does — so one runtime serves both
    /// hosts without per-host special cases.
    public func evaluateJSON<T: Decodable>(_ expression: String, as type: T.Type) async throws -> T? {
        let wrapped = "JSON.stringify((function(){ return (\(expression)); })())"
        guard let text = try await evaluate(wrapped) as? String,
              let data = text.data(using: .utf8)
        else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func evaluate(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    /// Evaluate and decode to an untyped JSON value.
    ///
    /// The untyped sibling of ``evaluateJSON(_:as:)``, for the runtime's small result envelopes where a
    /// `Decodable` type per shape would be more ceremony than the shapes are worth. Same string
    /// round-trip, for the same reason.
    func evaluateDecoded(_ expression: String) async throws -> Any? {
        do {
            return try await decodedOnce(expression)
        } catch {
            // ⛔ **A NAVIGATION WIPES THE INJECTED RUNTIME, and a run navigates several times.**
            // `window.__sr` lives in the page's JS context, which is destroyed and rebuilt on every
            // document load — and enabling deep research navigates (the URL gains a conversation
            // id), as does confirming Gemini's research plan. The runtime was injected exactly once,
            // at the top, so every call after the first navigation threw
            // "undefined is not an object" — which surfaces as a WebKit error on a selector that is
            // perfectly correct, at a point that looks like the platform's fault.
            //
            // ⚠ Re-injected only on FAILURE, so the healthy path pays nothing: no probe, no extra
            // round trip. And only for expressions that actually need the runtime — a genuine page
            // error in someone else's JS must still be reported as itself rather than being retried
            // behind an unrelated injection.
            guard Self.shouldReinject(expression: expression) else { throw error }
            _ = try? await injectRuntime()
            return try await decodedOnce(expression)
        }
    }

    /// Is this expression one whose failure could be a lost runtime?
    ///
    /// Extracted as a pure function because the surrounding plumbing needs a real `WKWebView` and so
    /// cannot be unit-tested at all — this is the part of the decision that can be.
    static func shouldReinject(expression: String) -> Bool {
        expression.contains("window.__sr")
    }

    private func decodedOnce(_ expression: String) async throws -> Any? {
        let wrapped = "JSON.stringify((function(){ return (\(expression)); })())"
        guard let text = try await evaluate(wrapped) as? String,
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Ask the page what a JS-dispatched click reports for `isTrusted`.
    ///
    /// C0's real question, answered by measurement. If this returns `false` — which is what the spec
    /// says and what MobileSafari does — then the app needs a genuine input path for gated controls,
    /// and any flow relying on a synthetic click is not viable inside the WebView. Better to learn
    /// that from one probe than from a phase that mysteriously never advances.
    public func probeTrustedDispatch(selector: String) async throws -> Bool? {
        let js = """
        (function () {
          var el = document.querySelector(\(Self.jsString(selector)));
          if (!el) return null;
          var seen = null;
          function once(e) { seen = e.isTrusted; el.removeEventListener('click', once, true); }
          el.addEventListener('click', once, true);
          el.click();
          return seen;
        })()
        """
        return try await evaluate(js) as? Bool
    }

    /// Persist cookies across relaunch by using the default (non-ephemeral) data store.
    ///
    /// ⚠ A `WKWebView` built with `.nonPersistent()` loses every session on teardown, which reads
    /// exactly like "the platform logged us out" — the same symptom class as the Simulator
    /// flush-before-shutdown trap, and just as hard to attribute.
    public static func persistentConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return config
    }

}
#endif

// MARK: - WebPage over WKWebView

/// `WebPage` backed by a real `WKWebView`, via the injected runtime's handle registry.
///
/// Handles rather than selectors across the boundary: a selector re-queried per operation can resolve
/// to a *different* node between calls on a live SPA, so "read the attribute of the thing I just
/// clicked" silently becomes "of whatever matches now". The registry pins the node, and `S.get`
/// reports `detached` if it leaves the document — which is a real answer rather than a stale one.
///
/// ⚠ Every call goes through `JSON.stringify`. `WKWebView`'s own value bridging flattens nested types
/// inconsistently; the string round-trip behaves identically to the Python side's, which is what keeps
/// the two implementations comparable.
extension WebAutomationBridge: WebPage {

    public func evaluateJSON(_ expression: String) async throws -> Any? {
        try await evaluateDecoded(expression)
    }

    public func querySelector(_ css: String) async throws -> Int? {
        try await evaluateDecoded("window.__sr.query(\(Self.jsString(css)))") as? Int
    }

    public func querySelectorAll(_ css: String) async throws -> [Int] {
        (try await evaluateDecoded("window.__sr.queryAll(\(Self.jsString(css)))") as? [Any])?
            .compactMap { $0 as? Int } ?? []
    }

    public func attribute(_ handle: Int, _ name: String) async throws -> String? {
        let result = try await evaluateDecoded(
            "window.__sr.attrOf(\(handle), \(Self.jsString(name)))"
        ) as? [String: Any]
        // `value` absent means the attribute is absent; an `err` key means the handle is gone. Both
        // return nil, but they are different facts — the caller's predicate treats "no attribute" as
        // not-pressed, which is correct for either.
        return result?["value"] as? String
    }

    public func innerText(_ handle: Int) async throws -> String? {
        (try await evaluateDecoded("window.__sr.textOf(\(handle))") as? [String: Any])?["text"]
            as? String
    }

    public func click(_ handle: Int) async throws {
        // ⚠ MEASURED: this reports `isTrusted === false`, and a control gated on it cannot be driven
        // this way at all — see artifacts/apphost/verdict.json's BOUNDARY check. The full realistic
        // event sequence does not change that, so it is not attempted here; a caller must treat an
        // unconfirmed outcome as a real failure rather than retrying in a different shape.
        _ = try await evaluateDecoded(
            "(function(){ var h = window.__sr.get(\(handle)); if (h.err) return h;"
                + " h.el.click(); return {ok: true}; })()"
        )
    }

    /// Press a named key at the focused element.
    ///
    /// ⚠ Dispatched in-page rather than through the HID channel, and that is forced rather than
    /// chosen: while Browser watch is showing a platform the app sets `allowsHitTesting(false)`, so
    /// AXe keystrokes never reach the web view. An in-page `keydown` cannot be `isTrusted`, and for
    /// this one caller that is acceptable — the composer's Backspace handler is its own code
    /// reacting to its own model, not a browser-gated control.
    public func key(_ name: String) async throws {
        _ = try await evaluateDecoded(
            "(function(){ var el = document.activeElement || document.body;"
                + " var opts = {key: \(Self.jsString(name)), bubbles: true, cancelable: true};"
                + " el.dispatchEvent(new KeyboardEvent('keydown', opts));"
                + " el.dispatchEvent(new KeyboardEvent('keyup', opts));"
                + " return {ok: true}; })()"
        )
    }

    public func insertText(_ handle: Int, _ text: String) async throws -> String? {
        let result = try await evaluateDecoded(
            "window.__sr.insertText(\(handle), \(Self.jsString(text)))"
        ) as? [String: Any]
        return Self.readInsertResult(result)
    }

    /// Turn the runtime's insert envelope into the caller's answer.
    ///
    /// ⛔ **`ok` used to be read by nothing at all.** The runtime returned `{ok, path}`, this method
    /// consulted only `err` and `path`, and so `execCommand` returning **false** — the editor
    /// refusing the text outright — was byte-for-byte indistinguishable from success. The composer
    /// stayed empty, and ChatGPT's send button, which exists only while the composer is non-empty,
    /// was then reported as an `unresolved` selector. A whole run lost to a status nobody read.
    ///
    /// Extracted as a pure function because the surrounding plumbing needs a real `WKWebView` and
    /// cannot be unit-tested — this is the part of the decision that can be.
    static func readInsertResult(_ result: [String: Any]?) -> String? {
        guard let result else { return nil }
        if let err = result["err"] as? String, result["ok"] == nil {
            // A structural miss — not a text target, or a stale handle.
            return err == "not-a-text-target" ? "not-a-text-target" : "refused: \(err)"
        }
        // ⚠ Absent `ok` is treated as REFUSED, not as success. A runtime that changed shape must
        // fail loudly here rather than resume reporting every fill as fine.
        guard let ok = result["ok"] as? Bool, ok else {
            let why = (result["err"] as? String) ?? "the editor did not take the text"
            let after = (result["after"] as? String).map { " (composer now: \"\($0)\")" } ?? ""
            // ⚠ `no-caret` is kept as its own word. "No range inside an editable root" and "the
            // editor took the selection and refused the text" are different faults with different
            // fixes, and reporting both as `refused` is what made the last run ambiguous.
            let kind = (result["path"] as? String) == "no-caret" ? "no-caret" : "refused"
            return "\(kind): \(why)\(after)"
        }
        return result["path"] as? String
    }

    /// JSON-encode a string for embedding in JS source.
    ///
    /// Via `JSONSerialization` rather than hand-escaping: a research topic is arbitrary user text, and
    /// quote/backslash/newline handling done by hand is how a prompt containing an apostrophe becomes a
    /// syntax error in an injected script.
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
