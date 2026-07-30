import SwiftUI
import UIKit

/// The app entry point.
///
/// A UIKit `AppDelegate` hosting a SwiftUI root rather than the `@main App` protocol, because this
/// bundle is compiled by `swiftc` directly (no Xcode project, no signing identity — Simulator builds
/// are unsigned), and `UIApplicationMain` is the entry point that arrangement can actually call.
///
/// ⚠ The file **must** be named `main.swift`. In a multi-file `swiftc` invocation, top-level
/// statements are only permitted there — anywhere else the `UIApplicationMain(...)` call below fails
/// with "expressions are not allowed at the top level", which reads as a syntax problem rather than
/// a filename one.
///
/// `SR_SCREENSHOT_STATE` lets the build script render a chosen state for review. The states worth
/// looking at are the awkward ones — unpaired, bridge offline, a platform signed out — so they are
/// reachable without hand-driving the app into them.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var model: AppModel?
    let theme = ThemeManager()
    /// Retained only in C1 mode. Held so the runner and its web view outlive `didFinishLaunching`.
    var c1: C1Runner?

    /// iOS suspends a backgrounded app, which stops the heartbeat. Resuming on foreground is what makes
    /// "open the app and it is online" true rather than aspirational.
    func applicationDidBecomeActive(_ application: UIApplication) {
        model?.applicationBecameActive()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // C1 mode: run the gate INSIDE this app, sharing this app's cookie jar.
        //
        // The reason this exists at all is a jar, not a convenience. `bin/c1_in_app.sh` used to build a
        // separate bundle (`com.distributedglobal.src1`), and a separate bundle gets its own
        // `WKWebsiteDataStore` — so it is signed out of every platform, while the owner's hand-made
        // sessions live in *this* container. Measured: 168K of HTTPStorages here, none there. The gate
        // could never see a signed-in page, and the mock hid that for as long as the mock was all it ran
        // against, because a mock needs no session.
        //
        // Running it here also makes the gate exercise the PRODUCTION path: in production the run happens
        // in this app, against these web views, with this session. A harness beside the app never was.
        if let platform = ProcessInfo.processInfo.environment["SR_C1"], !platform.isEmpty {
            let runner = C1Runner(
                platform: SRManifest.platform,
                manifest: SRManifest.selectors,
                texts: SRManifest.texts,
                openers: SRManifest.openers,
                runtimeJS: SRRuntime.source,
                pageURL: SRManifest.pageURL,
                manifestSource: SRManifest.manifestSource
            )
            self.c1 = runner
            let window = UIWindow(frame: UIScreen.main.bounds)
            let controller = UIViewController()
            // On screen on purpose: an off-screen WKWebView can have its WebProcess deprioritised, and
            // phases then time out for reasons that look like a slow page.
            controller.view.addSubview(runner.web)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            self.window = window
            Task {
                await runner.run()
                exit(runner.allPassed ? 0 : 1)
            }
            return true
        }

        // Identity the frontend's Account page will show. Supplied here because the core package is
        // deliberately UIKit-free.
        RESTPairingBackend.deviceNameProvider = { UIDevice.current.name }
        RESTPairingBackend.osStringProvider = {
            "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        }

        let model = AppModel(backend: Self.chooseBackend())
        self.model = model

        // ⚠ A backend that sleeps is a backend that is offline. iOS dims and locks an idle device, which
        // suspends the app and stops the heartbeat — so a device left paired on a desk would silently
        // drop off the web app. This is exactly the trade a backend wants and an ordinary app does not.
        application.isIdleTimerDisabled = true

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(
            rootView: RootView(model: model, theme: theme)
        )
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// Real backend when the project is configured, preview backend when it is not.
    ///
    /// The choice is driven by whether `GoogleService-Info.plist` is actually in the bundle, not by a
    /// build flag: the plist is gitignored, so a fresh clone genuinely does not have one, and an app
    /// that crashed on launch in that state would be indistinguishable from a broken build. Falling
    /// back keeps every screen reviewable without credentials — which is how the UI was built.
    ///
    /// `SR_SCREENSHOT_STATE` forces the preview backend regardless, so the build script can render a
    /// chosen state for review. The states worth looking at are the awkward ones — unpaired, bridge
    /// offline, a platform signed out — and they should not require a real device in that state.
    private static func chooseBackend() -> AppBackend {
        let environment = ProcessInfo.processInfo.environment
        if let forced = environment["SR_SCREENSHOT_STATE"] {
            return PreviewBackend(paired: forced != "unpaired")
        }
        guard
            let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
            let plist = NSDictionary(contentsOfFile: path) as? [String: Any]
        else {
            NSLog("[SR] no GoogleService-Info.plist in the bundle — running on the preview backend")
            return PreviewBackend(paired: false)
        }
        // The frontend origin is overridable so the app can be pointed at a local FE during
        // development without a rebuild of the plist.
        // ⚠ VERIFIED against the backend's own default
        // (`dg-research-backend/auth/v2_flow.py`: `RESEARCH_FE_BASE_URL`, default
        // `https://superresearch.io`). My first guess was a distributedglobal.com subdomain that does
        // not resolve — pairing would have failed with a DNS error on the very first attempt, which
        // looks like a network problem rather than a wrong constant. Same env var name as the backend,
        // so one override covers both.
        let base = environment["RESEARCH_FE_BASE_URL"]
            ?? environment["SR_API_BASE_URL"]
            ?? "https://superresearch.io"
        do {
            let config = try FirebaseProjectConfig(
                plist: plist, apiBaseURL: URL(string: base)!
            )
            // Set here so the QR and the pairing POST cannot disagree about which frontend this is.
            AppConfig.frontendBaseURL = base
            return DeviceBackend(config: config)
        } catch {
            // Reported and degraded rather than fatal: a malformed plist is a configuration problem
            // the UI can state, and a crash on launch would say nothing about which key was missing.
            NSLog("[SR] GoogleService-Info.plist is unusable (\(error)) — preview backend")
            return PreviewBackend(paired: false)
        }
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
