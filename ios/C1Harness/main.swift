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

/// The platform under test and its selectors, both GENERATED at build time.
///
/// ⚠ Previously the mock's manifest was inlined here, which quietly capped C1 at one platform: the
/// coverage gate could demand "run C1 against chatgpt" and there would be no way to do it without
/// editing Swift. Generating both from the real manifest (`bin/c1_in_app.sh <UDID> [platform]`) is what
/// makes the gate's demand satisfiable — the owner supplies selectors, and C1 runs against that
/// platform with no code change at all.
let PLATFORM = SRManifest.platform
let MANIFEST = SRManifest.selectors

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
        let url = URL(string: SRManifest.pageURL)!
        web.load(URLRequest(url: url))

        let bridge = WebAutomationBridge(webView: web, runtimeJS: RUNTIME_JS)
        let ready = (try? await bridge.waitForReady(timeout: 30, expecting: url.absoluteString)) ?? false
        record("mock platform loaded in the app's web view", ready, "")

        let injected = (try? await bridge.injectRuntime()) ?? "failed"
        record("runtime injected", injected == "installed" || injected == "already", injected)

        let driver = InAppPhaseDriver(platform: PLATFORM, manifest: MANIFEST, page: bridge)

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

        // --- the contract writes, against the real rules ---------------------------
        //
        // The half that pairing alone does not cover: a device that pairs, goes online and then never
        // reports anything is not a working backend. Emitted against the Firestore emulator so the
        // committed rules evaluate every write, and diffed against the golden fixture by the gate
        // script — with no e2e in existence that diff is the only mechanical proof this second
        // implementation of the contract is faithful rather than merely plausible.
        if let emulator = ProcessInfo.processInfo.environment["SR_EMULATOR_HOST"],
           let customToken = ProcessInfo.processInfo.environment["SR_CUSTOM_TOKEN"],
           let uid = ProcessInfo.processInfo.environment["SR_UID"],
           let researchId = ProcessInfo.processInfo.environment["SR_RESEARCH_ID"],
           let deviceId = ProcessInfo.processInfo.environment["SR_DEVICE_ID"] {
            let config = FirebaseProjectConfig(
                projectID: "demo-sr", apiKey: "emulator-key",
                apiBaseURL: URL(string: "http://127.0.0.1:8907")!, emulatorHost: emulator
            )
            let client = FirestoreREST(config: config, transport: URLSessionTransport())
            var signedIn = true
            do { try await client.signIn(customToken: customToken) } catch { signedIn = false }
            record("contract: signed in as the synthetic device", signedIn, "")

            let emitter = ContractEmitter(
                client: client, uid: uid, researchId: researchId,
                deviceId: deviceId, runId: "run-c1"
            )
            var contractOK = true
            var failure = ""
            do {
                try await emitter.startRun()
                for phase in 0...3 {
                    try await emitter.emit(type: "phase_start", phase: phase)
                    try await emitter.emit(type: "phase_complete", phase: phase)
                }
                try await emitter.finishRun(status: "complete")
            } catch {
                contractOK = false
                failure = "\(error)"
            }
            record("contract: the full P0-P3 write sequence was ACCEPTED by the real rules",
                   contractOK, failure)

            let log = await emitter.writeLog()
            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                // Printed for the gate script to diff against fixtures/golden/p0_p3_happy_path.jsonl.
                print("WRITE_LOG=\(text)")
            }
        }

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
            "platform": PLATFORM,
            // Travels to the coverage gate, which credits a platform ONLY for a run that
            // used the real manifest. A wiring-proof run must not count as coverage.
            "manifest_source": SRManifest.manifestSource,
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
