// A real iOS app that runs the automation inside its own WKWebView — phase C0's channel, proven.
//
// Why this exists as a hand-rolled bundle rather than an Xcode project: it needs no signing identity
// and no Apple Developer account, because **Simulator builds are unsigned** (ad-hoc `codesign -s -`
// is enough). The developer account is only required for a real device. So the WKWebView gate — which
// cannot run under `swift test`, since SwiftPM's harness has no app bundle or WebProcess host — is
// reachable autonomously after all, as a genuine app installed into the Simulator.
//
// It drives the same sequence the host-driven pipeline drives, against the same mock platform, using
// the same injected runtime. If both agree, the recipe's reuse guarantee is demonstrated rather than
// asserted: `WKWebView.evaluateJavaScript` really is the same channel as IWDP `Runtime.evaluate`.
//
// Results go to stdout as one JSON line, which `simctl launch --console` hands back to the host.

import Foundation
import UIKit
import WebKit

let mockURL = URL(string: "http://127.0.0.1:8901/")!

// Kept inline and minimal rather than imported: this bundle is compiled by a shell script with no
// package graph, and the only piece it needs is the handle registry plus the event recorder.
let runtimeJS = """
(function () {
  if (window.__sr && window.__sr.v === 4) { return 'already'; }
  var S = { v: 4, n: 0, m: new Map(), events: [] };
  S.reg = function (el) { if (!el) return null; var id = ++S.n; S.m.set(id, el); return id; };
  S.get = function (id) {
    var el = S.m.get(id);
    if (!el) return { err: 'no-such-handle' };
    if (!el.isConnected) return { err: 'detached' };
    return { el: el };
  };
  S.query = function (sel) { try { return S.reg(document.querySelector(sel)); } catch (e) { return null; } };
  S.queryAll = function (sel) {
    try {
      return Array.prototype.map.call(document.querySelectorAll(sel), function (el) { return S.reg(el); });
    } catch (e) { return []; }
  };
  S.textOf = function (id) { var h = S.get(id); if (h.err) return h; return { text: h.el.innerText }; };
  S.attrOf = function (id, n) { var h = S.get(id); if (h.err) return h; return { value: h.el.getAttribute(n) }; };
  S.insertText = function (id, text) {
    var h = S.get(id); if (h.err) return h;
    var el = h.el; el.focus();
    if (el.isContentEditable) { return { ok: document.execCommand('insertText', false, text), path: 'execCommand' }; }
    if ('value' in el) {
      el.value = (el.value || '') + text;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      return { ok: true, path: 'value+input' };
    }
    return { err: 'not-a-text-target' };
  };
  S.viewport = function () {
    var vv = window.visualViewport || {};
    return { innerWidth: window.innerWidth, innerHeight: window.innerHeight,
             vvHeight: vv.height, dpr: window.devicePixelRatio };
  };
  S.record = function (e) { S.events.push({ type: e.type, isTrusted: e.isTrusted }); };
  ['pointerdown', 'click'].forEach(function (t) { document.addEventListener(t, S.record, true); });
  window.__sr = S;
  return 'installed';
})()
"""

struct Check: Codable {
    let check: String
    let pass: Bool
    let detail: String
}

final class Harness: NSObject, WKNavigationDelegate {
    let web: WKWebView
    var checks: [Check] = []

    override init() {
        // The DEFAULT (persistent) data store, not .nonPersistent(): an ephemeral store loses every
        // session on teardown, which reads exactly like "the platform logged us out".
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 714), configuration: config)
        super.init()
    }

    func record(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append(Check(check: name, pass: ok, detail: detail))
    }

    func eval(_ js: String) async -> Any? {
        try? await web.evaluateJavaScript(js)
    }

    /// Evaluate and decode via a JSON string round-trip — WKWebView's own value bridging flattens
    /// nested types inconsistently, and a string round-trip behaves identically to the Python side.
    func evalJSON(_ js: String) async -> Any? {
        guard let text = await eval("JSON.stringify((function(){ return (\(js)); })())") as? String,
              let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func waitFor(_ js: String, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ok = await eval(js) as? Bool, ok { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func run() async {
        web.load(URLRequest(url: mockURL))
        // ⚠ `readyState === 'complete'` alone is NOT a load signal. `about:blank` — which a fresh
        // WKWebView is already showing — reports 'complete' immediately, so polling readyState by
        // itself passes before the intended navigation has finished, and everything afterwards runs
        // against the blank document: the runtime injects "successfully", re-injection reports
        // "already", the viewport looks plausible (the web view's own frame), and every selector
        // simply finds nothing. Assert the URL *and* a content marker as well.
        let loaded = await waitFor("""
        (document.readyState === 'complete'
         && location.href.indexOf('127.0.0.1:8901') !== -1
         && !!document.querySelector('[data-testid="composer"]'))
        """, timeout: 30)
        let href = await eval("location.href") as? String ?? "?"
        record("mock platform loaded in WKWebView", loaded, "location=\(href)")
        guard loaded else { return finish() }

        let installed = await eval(runtimeJS) as? String
        record("runtime injected via evaluateJavaScript", installed == "installed", "returned \(installed ?? "nil")")

        let again = await eval(runtimeJS) as? String
        record("re-injection is idempotent", again == "already", "returned \(again ?? "nil")")

        if let vp = await evalJSON("window.__sr.viewport()") as? [String: Any] {
            let w = vp["innerWidth"] as? Int ?? 0
            record("real mobile viewport inside the app", w > 0 && w != 1280, "\(w)x\(vp["innerHeight"] as? Int ?? 0) CSS px")
        } else {
            record("real mobile viewport inside the app", false, "viewport unreadable")
        }

        // The handle registry must survive across separate evaluateJavaScript calls, exactly as it
        // does over IWDP — that equivalence is the reuse guarantee.
        let handle = await evalJSON("window.__sr.query('[data-testid=\"composer\"]')") as? Int
        record("handle registry works across calls", (handle ?? 0) > 0, "handle=\(handle.map(String.init) ?? "nil")")

        // The composer is contenteditable and its send button is gated on the INTERNAL MODEL, so
        // only the execCommand path enables send. This is the same assertion the host-driven run makes.
        if let h = handle,
           let res = await evalJSON("window.__sr.insertText(\(h), 'in-app run')") as? [String: Any] {
            record("execCommand path used for the composer", (res["path"] as? String) == "execCommand",
                   "path=\(res["path"] as? String ?? "nil")")
        } else {
            record("execCommand path used for the composer", false, "insertText failed")
        }

        let enabled = await eval("!document.querySelector('[data-testid=\"send-button\"]').disabled") as? Bool
        record("send became enabled — the model updated", enabled == true,
               "a textContent assignment would have left it disabled")

        // ⚠ C0's real question, answered by measurement: what does WKWebView report for a
        // JS-dispatched click? If false, gated controls need a genuine input path in the app.
        let trusted = await eval("""
        (function () {
          var el = document.querySelector('[data-testid="send-button"]');
          var seen = null;
          function once(e) { seen = e.isTrusted; el.removeEventListener('click', once, true); }
          el.addEventListener('click', once, true);
          el.click();
          return seen;
        })()
        """) as? Bool
        record("MEASURED: isTrusted for a JS click in WKWebView", trusted != nil,
               "isTrusted=\(trusted.map(String.init) ?? "nil") — recorded as a finding, not a pass/fail")

        // What that finding COSTS. Every other control on this page accepts a synthetic click, so
        // measuring isTrusted alone cannot distinguish "our dispatch works" from "nothing here
        // checks". The trust-gated control checks, and the assertion is that we CANNOT move it — the
        // full realistic sequence included, since dispatching pointerdown/mousedown/mouseup/click is
        // the usual workaround and it does not change isTrusted.
        let gated = await eval("""
        (function () {
          var el = document.querySelector('[data-testid="trust-gated"]');
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function (type) {
            el.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, view: window}));
          });
          el.click();
          return el.getAttribute('aria-pressed');
        })()
        """) as? String
        record(
            "BOUNDARY: a trust-gated control cannot be driven from script in-app",
            gated == "false",
            "aria-pressed=\(gated ?? "nil") after a full event sequence + .click() — "
                + "so any real control gated on isTrusted is UNREACHABLE by in-app automation. "
                + "This is the C1 viability question and it needs a real platform to settle."
        )

        let arrived = await waitFor(
            "!!document.querySelector('[data-testid=\"response-container\"][data-state=\"complete\"]')",
            timeout: 20)
        record("response arrived after the in-app send", arrived, "")

        // Sources render as DIVs, not <a href> — the P1 shape.
        let count = await eval("document.querySelectorAll('[data-testid=\"source\"]').length") as? Int ?? 0
        let anchors = await eval("document.querySelectorAll('#sources a[href]').length") as? Int ?? -1
        record("harvested non-anchor sources in-app", count >= 3 && anchors == 0,
               "\(count) sources, \(anchors) anchors — a link-only harvest finds 0")

        let events = await evalJSON("window.__sr.events") as? [[String: Any]] ?? []
        record("the runtime's event recorder saw the interaction", !events.isEmpty,
               "\(events.count) events recorded")

        finish()
    }

    func finish() {
        let payload: [String: Any] = [
            "gate": "C0-in-app-wkwebview",
            "results": checks.map { ["check": $0.check, "pass": $0.pass, "detail": $0.detail] },
            "pass": checks.allSatisfy { $0.pass },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            print("SRHARNESS_JSON \(text)")
        }
        fflush(stdout)
        // Exit rather than idle: the host reads stdout from `simctl launch --console`, and a
        // lingering app makes that call hang waiting for output that will never come.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var harness: Harness?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let harness = Harness()
        self.harness = harness
        let window = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController()
        vc.view.addSubview(harness.web)
        harness.web.frame = vc.view.bounds
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        Task { await harness.run() }
        return true
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
