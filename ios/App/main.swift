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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let paired = ProcessInfo.processInfo.environment["SR_SCREENSHOT_STATE"] != "unpaired"
        let model = AppModel(backend: PreviewBackend(paired: paired))

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: RootView(model: model))
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
