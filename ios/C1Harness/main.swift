import Foundation
import UIKit
import WebKit

// No `import SuperResearchDeviceCore`: the core sources are compiled in directly (one swiftc
// invocation, no package graph), so the types are already in this module. An import here fails with
// "no such module", which reads as a missing dependency rather than a build-shape fact.

/// **The C1 gate.** A full P0–P3 run inside the native app, driving the app's own `WKWebView`.
///
/// This is the clause the C0 harness does *not* establish. C0 answered "can the app talk to a page at
/// all" — inject a runtime, read the DOM, write the composer, measure `isTrusted`. This runs the actual
/// orchestrator: the same phase sequence, the same predicates, the same ordering invariants, against the
/// same mock platform the Simulator gate uses, with the pipeline code that would drive a real one.
///
/// Why it must be an app and not a package test: `swift test` has no app bundle and no WebProcess host,
/// so instantiating a `WKWebView` fails before any page loads. The logic is unit-tested against a fake
/// page under `swift test`; what *this* adds is the real WebKit host, which is the part that cannot be
/// faked.
///
/// ⚠ **Scope, stated so the verdict is not over-read.** This proves the orchestrator runs in-app against
/// a platform that cleared C0 — which is the mock. It does **not** prove a real platform works in-app:
/// that needs the 25 captured selectors (#82) and it needs the `isTrusted` question settled, because a
/// control gated on trust is unreachable from here by any script (measured, same fixture).
let RUNTIME_JS = SRRuntime.source   // generated from emubackend/substrate/runtime_js.py at build time

struct Check: Codable {
    let check: String
    let pass: Bool
    let detail: String
}

/// The mock's selectors, mirroring `fixtures/mockplatform/selectors_mock.json`.
///
/// Inlined rather than read from disk: the app is sandboxed and the fixture lives in the repo, so
/// bundling it would mean a resource pipeline for a build that deliberately has none. The parity test
/// `emubackend/tests/test_inapp_parity.py` compares these against the JSON so they cannot drift.
let MOCK_MANIFEST: [String: [String]] = [
    "logged_in_marker": ["#signed-in-marker"],
    "composer": ["[data-testid=\"composer\"]", "div[contenteditable=true]"],
    "send": ["[data-testid=\"send-button\"]"],
    "deep_research_toggle": ["[data-testid=\"deep-research-toggle\"]"],
    "activity_panel": ["#response"],
    "sources": ["[data-testid=\"source\"]"],
    "response_container": ["[data-testid=\"response-container\"][data-state]"],
]

final class C1Harness: NSObject {
    let web: WKWebView
    var checks: [Check] = []

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent, as everywhere else: an ephemeral store loses the session on teardown, which
        // presents identically to the platform having signed you out.
        config.websiteDataStore = .default()
        web = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 402, height: 714), configuration: config
        )
        super.init()
    }

    func record(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append(Check(check: name, pass: ok, detail: detail))
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    func run() async {
        let url = URL(string: "http://127.0.0.1:8901/")!
        web.load(URLRequest(url: url))

        let bridge = WebAutomationBridge(webView: web, runtimeJS: RUNTIME_JS)
        let ready = (try? await bridge.waitForReady(timeout: 30, expecting: url.absoluteString)) ?? false
        record("mock platform loaded in the app's web view", ready, "")

        let injected = (try? await bridge.injectRuntime()) ?? "failed"
        record("runtime injected", injected == "installed" || injected == "already", injected)

        let driver = InAppPhaseDriver(platform: "chatgpt", manifest: MOCK_MANIFEST, page: bridge)

        // Each phase is also asserted individually, because "the run completed" alone cannot
        // distinguish a real pass from a pipeline that skipped everything.
        let loggedIn = (try? await driver.loggedIn()) ?? false
        record("P0: logged-in marker found in-app", loggedIn, "")

        // The idempotence property, exercised for real rather than against a fake: run it twice and
        // require deep research to still be ON afterwards. An unconditional tap fails this second call
        // — which is precisely the bug the Python side shipped.
        let firstTap = (try? await driver.enableDeepResearch()) ?? false
        let secondTap = (try? await driver.enableDeepResearch()) ?? true
        let stillOn = (try? await bridge.evaluateJSON(
            "document.querySelector('[data-testid=\"deep-research-toggle\"]')"
                + ".getAttribute('aria-pressed') === 'true'"
        )) as? Bool ?? false
        record(
            "P1: enabling deep research TWICE leaves it enabled (idempotent)",
            firstTap && !secondTap && stillOn,
            "first call tapped=\(firstTap), second call tapped=\(secondTap), still on=\(stillOn)"
        )

        let path = (try? await driver.fillComposer("quantum error correction, 2026 review")) ?? ""
        record(
            "P1: composer written through the MODEL-updating path", path == "execCommand",
            "path=\(path) — a textContent assignment would leave send disabled"
        )

        var sendOK = true
        do { try await driver.send() } catch { sendOK = false }
        record("P2: send accepted and its predicate confirmed", sendOK, "")

        let arrived = (try? await driver.awaitResponse(timeout: 20)) ?? false
        record("P2: response arrived (late, as on a real platform)", arrived, "")

        let sources = (try? await driver.harvestSources()) ?? []
        record(
            "P3: sources harvested by TEXT, not href", sources.count >= 3,
            "\(sources.count) sources — a link-only harvest finds 0 here"
        )

        // --- and now the whole thing, through the pipeline ------------------------
        //
        // Re-run from the top so the ordering invariants are exercised by the real loop rather than by
        // this script calling phases in an order it chose itself.
        var pipeline = InAppPipeline(driver: driver, topic: "quantum error correction, 2026 review")
        var outcome: InAppPipeline.Outcome?
        do { outcome = try await pipeline.run(responseTimeout: 20) } catch { outcome = nil }
        record(
            "FULL P0-P3 RUN COMPLETED INSIDE THE NATIVE APP",
            outcome?.status == "complete" && outcome?.phasesCompleted.count == 4,
            "status=\(outcome?.status ?? "threw"), phases=\(outcome?.phasesCompleted.count ?? 0), "
                + "deepResearchWasAlreadyOn=\(outcome?.deepResearchWasAlreadyOn ?? false)"
        )
        record(
            "the phase event sequence is start/complete per phase, in order",
            pipeline.events.map(\.event) == Array(
                repeating: ["phase_start", "phase_complete"], count: 4
            ).flatMap { $0 },
            pipeline.events.map { "P\($0.phase).\($0.event)" }.joined(separator: " ")
        )

        // The boundary, restated in the run's own verdict so it cannot be read as a full C1 pass.
        let gated = (try? await bridge.evaluateJSON(
            "(function(){ var el = document.querySelector('[data-testid=\"trust-gated\"]');"
                + " el.click(); return el.getAttribute('aria-pressed'); })()"
        )) as? String
        record(
            "BOUNDARY (not a regression): a trust-gated control stays unreachable in-app",
            gated == "false",
            "aria-pressed=\(gated ?? "nil") — so a real platform gating any needed control on "
                + "isTrusted makes the app a thin client for that step. Owner checkpoint."
        )

        writeVerdict()
        exit(checks.allSatisfy(\.pass) ? 0 : 1)
    }

    private func writeVerdict() {
        let verdict: [String: Any] = [
            "gate": "C1-in-app",
            "what": "a full P0-P3 run inside the native app, driving the app's own WKWebView",
            "platform": "mockplatform (the only platform that has cleared C0)",
            "results": checks.map { ["check": $0.check, "pass": $0.pass, "detail": $0.detail] },
            "pass": checks.allSatisfy(\.pass),
            "not_established": [
                "that a REAL platform runs in-app — needs the 25 captured selectors (#82)",
                "that controls gated on isTrusted can be driven in-app — measured as NO",
            ],
        ]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-c1")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("verdict.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: verdict, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: path)
            print("VERDICT_PATH=\(path.path)")
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var harness: C1Harness?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let harness = C1Harness()
        self.harness = harness
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        // Added to the hierarchy on purpose. An off-screen WKWebView can have its WebProcess
        // deprioritised, and phases then time out for reasons that look like the page being slow.
        controller.view.addSubview(harness.web)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        Task { await harness.run() }
        return true
    }
}

UIApplicationMain(
    CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self)
)
