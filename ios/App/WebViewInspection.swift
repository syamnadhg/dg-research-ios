import WebKit

/// Makes the app's web views visible to Web Inspector — and therefore to `ios_webkit_debug_proxy`.
///
/// Since iOS 16.4 a `WKWebView` is **opt-in inspectable**: without `isInspectable = true` it does not
/// appear in the inspector's target list at all, no matter how the proxy is attached. That was
/// measured here rather than read: with the app in the foreground showing a platform login, the
/// proxy's `/json` listed five Safari tabs and none of the app's web views.
///
/// It matters more than a debugging convenience, because of an asymmetry in how the two surfaces are
/// driven. The Simulator/Safari pipeline talks to pages over the proxy, so anything it does is
/// observable by construction. The in-app pipeline drives `evaluateJavaScript` directly — which
/// *works* without the inspector, but leaves the page it is working on completely opaque. So the
/// exact case where a diagnosis is most needed, "the in-app run misbehaved against a real platform",
/// is the one case with no way to look at the DOM. That gap is what this closes.
///
/// It also settled a question no amount of reasoning would have: the app's login sheet reported
/// ChatGPT as signed in while the same URL in Safari surveyed as signed out. Two web views on one
/// device disagreeing about a session is either a false positive in the marker check or two genuinely
/// separate cookie jars, and reading the app's own DOM is the only way to tell which.
///
/// **Simulator only.** A shipped build must not expose its web views: the login sheet's page is a
/// signed-in platform session, and an inspectable web view is a way to read it. The compile-time
/// `targetEnvironment(simulator)` guard is deliberate over a runtime flag — a runtime check can be
/// flipped by a launch argument, and this one should not be reachable in a device build at all.
extension WKWebView {
    func enableInspectionInSimulator() {
        #if targetEnvironment(simulator)
        if #available(iOS 16.4, *) {
            isInspectable = true
        }
        #endif
    }
}
