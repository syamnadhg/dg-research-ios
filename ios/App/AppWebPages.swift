import Foundation
import WebKit

/// The run's view of the app's web views.
///
/// ⭐ **The same long-lived views the Browser-watch screen shows.** Not a parallel set: the sessions
/// the owner signed in with live in these jars, and a run driving a freshly created web view would
/// be driving a signed-out browser — measured previously as the whole reason the C1 gate had to move
/// inside this app rather than run beside it.
enum AppWebPages {

    /// ⚠ **Marshalled to the main thread, because `WKWebView` may only be created there.** The run
    /// loop is an async task on the cooperative pool, so a direct call would be creating a web view
    /// off-main — which is undefined behaviour that usually looks like an intermittent crash rather
    /// than a rule being broken.
    ///
    /// ⚠ `DispatchQueue.main.sync` is safe HERE specifically: the run loop never blocks the main
    /// thread, so main can always make progress. It is called a handful of times per run — once per
    /// platform — rather than per operation.
    static func page(platform: String, worker: Int) -> any WebPage {
        if Thread.isMainThread { return bridge(platform: platform, worker: worker) }
        return DispatchQueue.main.sync { bridge(platform: platform, worker: worker) }
    }

    /// Put every web view back to rest when a run ends.
    ///
    /// ⚠ Routed through the SAME main-thread hop as `page(platform:worker:)` rather than an
    /// `await MainActor.run`: the run loop is deliberately free of Swift concurrency, and a detach
    /// is a UIKit mutation like any other.
    static func releaseAll() {
        if Thread.isMainThread { PlatformWebViews.detachAll() }
        else { DispatchQueue.main.sync { PlatformWebViews.detachAll() } }
    }

    private static func bridge(platform: String, worker: Int) -> any WebPage {
        let web = PlatformWebViews.shared.view(for: platform, worker: worker)
        // ⛔ **Focus, every time a page is handed to the run.** WebKit's editing commands are no-ops
        // on an unfocused document — `execCommand('insertText', …)` returns TRUE and inserts
        // nothing — so without this every composer fill silently does nothing. Measured live
        // 2026-08-14: `document.hasFocus()=false` on all three platforms.
        PlatformWebViews.focusForAutomation(web, platform: platform, worker: worker)
        // ⚠ The NATIVE half of the focus question, logged next to the JS half the trace records.
        // `document.hasFocus()` can be false for two different reasons — the view is in no window,
        // or it is in one but not first responder — and the fix for each is different. Without both
        // numbers, a failed run only says "still false" and costs another cycle to narrow.
        NSLog("[SR] focus %@/w%d: inWindow=%@ firstResponder=%@",
              platform, worker,
              web.window != nil ? "yes" : "NO",
              web.isFirstResponder ? "yes" : "NO")
        return WebAutomationBridge(
            webView: web,
            // ⚠ The runtime is injected lazily by the bridge — on first use and again after any
            // navigation destroys it. Injecting once here would work until the first phase that
            // navigates, which is the first phase that does anything.
            runtimeJS: SRRuntime.source
        )
    }
}
