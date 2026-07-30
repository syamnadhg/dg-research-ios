import Foundation
import UIKit
import WebKit

// No `import SuperResearchDeviceCore`: the core sources are compiled in directly (one swiftc
// invocation, no package graph), so the types are already in this module. An import here fails with
// "no such module", which reads as a missing dependency rather than a build-shape fact.

/// **The C1 gate's entry point**, and now only that.
///
/// The run itself moved to `ios/Shared/C1Runner.swift` so the *app* can perform it too. That was not
/// cosmetic: `bin/c1_in_app.sh` builds a separate bundle (`com.distributedglobal.src1`) which has its own
/// `WKWebsiteDataStore` and is therefore **signed out of every platform**. The owner's sessions live in
/// the SuperResearch container, so this harness can only ever drive a page that needs no session — the
/// mock — and the mock is exactly why the gap stayed invisible.
///
/// This file keeps existing because the standalone harness remains the regression test for the
/// extraction: if C1-against-the-mock still passes here, the shared runner is unchanged in behaviour.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var runner: C1Runner?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The generated constants are read HERE and passed in, rather than reached for inside the
        // runner. Only this binary's build generates them.
        let runner = C1Runner(
            platform: SRManifest.platform,
            manifest: SRManifest.selectors,
            texts: SRManifest.texts,
            runtimeJS: SRRuntime.source,
            pageURL: SRManifest.pageURL,
            manifestSource: SRManifest.manifestSource
        )
        self.runner = runner
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        // Added to the hierarchy on purpose. An off-screen WKWebView can have its WebProcess
        // deprioritised, and phases then time out for reasons that look like the page being slow.
        controller.view.addSubview(runner.web)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        Task {
            await runner.run()
            // The exit lives here, not in the runner: `exit()` inside a shared type would terminate the
            // host app when the SAME code runs in the app's C1 mode.
            exit(runner.allPassed ? 0 : 1)
        }
        return true
    }
}

UIApplicationMain(
    CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self)
)
