import SwiftUI
import WebKit

/// Walks the user through signing in to each platform, inside the app.
///
/// This is the step no automation can do — 2FA, a password manager, a CAPTCHA — so the app's job is
/// to make it a guided one-time task rather than a mystery. Three things make that work:
///
/// 1. **A persistent data store.** `WKWebsiteDataStore.default()`, never `.nonPersistent()`. An
///    ephemeral store loses the session on teardown, which reads exactly like the platform having
///    logged you out — the same symptom class as shutting a Simulator down before its cookie flush.
/// 2. **Confirmation by observation, not by assumption.** The sheet does not close because the user
///    tapped something; it closes when the platform's own logged-in marker appears in the DOM.
///    Trusting the tap is how a half-finished 2FA gets recorded as success.
/// 3. **A Safari-like user agent.** Google refuses OAuth inside embedded web views
///    (`disallowed_useragent`), so Gemini and NotebookLM are the likely casualties. The override is
///    the documented mitigation; if it still fails, that platform is genuinely desktop-only and the
///    UI says so instead of looping.
struct LoginFlowView: View {
    let platform: PlatformState
    let manifestMarker: String?
    /// Which worker's cookie jar this login lands in. Defaults to worker 1, which is the device's
    /// original single profile — see `WorkerDataStores`.
    var workerID: Int = 1
    let onFinished: (Bool) -> Void

    @State private var status: Status = .loading
    @State private var attempts = 0

    enum Status: Equatable {
        case loading
        case awaitingUser
        case signedIn
        /// The embedded-web-view block. A distinct state because the remedy is different: nothing
        /// the user does in this sheet will fix it.
        case blockedByPlatform(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            LoginWebView(
                url: Self.url(for: platform.id),
                marker: manifestMarker ?? Self.candidateMarkers(for: platform.id),
                workerID: workerID,
                onStatus: { status = $0 }
            )
            footer
        }
        .background(DS.C.bg)
    }

    /// Fallback markers, used when the manifest has no captured selector for this platform yet.
    ///
    /// Comma-joined so one `querySelector` matches *any* candidate — a login check is a
    /// does-a-composer-exist question, and being generous about which composer is the right trade
    /// here. It is only ever used to *confirm* a login, never to assert one is absent, so a candidate
    /// that has gone stale delays detection rather than producing a false positive.
    ///
    /// These are the mobile markers from `bin/capture_selectors.py`, deliberately not the desktop
    /// sidebar ones — those collapse on a phone and would never match.
    ///
    /// ⚠ Every value below is now one that was **measured to be absent when signed out**, by
    /// surveying each platform twice on the same device — signed in through the app, signed out in
    /// Safari — and diffing. That check overturned two of the four original guesses:
    ///
    /// * **Gemini** shipped `rich-textarea, div[contenteditable=true]`, and Gemini's signed-out page
    ///   has *both*: `textarea-inner`, `textarea-wrapper`, `chat-app` and `bard-mode-menu-button` are
    ///   all present before you log in. It would have reported every signed-out session as signed in
    ///   — and a login the app believes it already has is a login the owner never gets prompted for,
    ///   so the first symptom would have been a run failing on a login page.
    /// * **NotebookLM** shipped `[aria-label*=Notebook]`, which matches its marketing copy.
    ///
    /// Both are replaced with markers that only exist behind a session (`new-chat-button`,
    /// `Create new notebook`). ChatGPT's and Claude's originals survived the check unchanged.
    ///
    /// Generosity is fine *within* this set — comma-joined so any candidate matching is enough — but
    /// generosity about what counts as signed-in is not, which is the whole point of the diff.
    static func candidateMarkers(for platform: String) -> String {
        switch platform {
        case "chatgpt": return "#prompt-textarea, [data-testid=composer-plus-btn]"
        // ⚠ `data-test-id`, hyphenated. Gemini spells it differently from ChatGPT and Claude, and
        // `[data-testid]` matches **zero** elements on its page — measured: 0 vs 41. These three
        // exist once each when signed in and not at all when signed out; none has a visible rect at
        // 402pt (the sidebar is collapsed), which is fine here because the check below asks
        // `querySelector`, not "can I see it".
        case "gemini":
            return "[data-test-id=new-chat-button], [data-test-id=all-conversations], "
                + "[data-test-id=my-stuff-side-nav-entry-button]"
        case "claude": return "[data-testid=user-menu-button], div.ProseMirror"
        case "notebooklm":
            return "button[aria-label=\"Create new notebook\"], #mat-button-toggle-1-button"
        default: return ""
        }
    }

    private var header: some View {
        HStack(spacing: DS.S.lg) {
            AgentIcon(id: platform.id, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sign in to \(platform.name)")
                    .font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
                Text(hint).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            }
            Spacer()
            Button { onFinished(status == .signedIn) } label: {
                Text("Close").font(DS.F.label).foregroundStyle(DS.C.textSecondary)
            }
            .frame(minWidth: DS.S.touch, minHeight: DS.S.touch)
        }
        .padding(.horizontal, DS.S.screen)
        .padding(.vertical, DS.S.lg)
        .background(DS.C.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border).frame(height: 1) }
    }

    private var hint: String {
        switch status {
        case .loading: return "loading…"
        case .awaitingUser: return "sign in as you normally would — 2FA included"
        case .signedIn: return "signed in — this session persists"
        case .blockedByPlatform(let why): return why
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: DS.S.lg) {
            switch status {
            case .signedIn:
                HStack(spacing: DS.S.md) {
                    Text("✓").foregroundStyle(DS.C.ok).font(DS.F.body.weight(.semibold))
                    Text("Detected a signed-in session. You only need to do this once.")
                        .font(DS.F.label).foregroundStyle(DS.C.textSecondary)
                }
                SRButton(title: "Done", role: .primary) { onFinished(true) }

            case .blockedByPlatform(let why):
                // Said outright rather than left as a spinner. This platform cannot be signed into
                // here, and pretending otherwise wastes the user's time on a loop that cannot end.
                VStack(alignment: .leading, spacing: DS.S.md) {
                    Text("This platform blocks sign-in inside an app")
                        .font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.warn)
                    Text("\(why) Use the desktop backend for \(platform.name), or sign in through Safari in the Simulator instead.")
                        .font(DS.F.label).foregroundStyle(DS.C.textSecondary)
                }
                SRButton(title: "Skip \(platform.name)") { onFinished(false) }

            default:
                Text("Waiting for a signed-in session. Nothing is recorded until the platform's own signed-in state is visible.")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DS.S.screen)
        .background(DS.C.surface)
        .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
    }

    static func url(for platform: String) -> URL {
        switch platform {
        case "chatgpt": return URL(string: "https://chatgpt.com")!
        case "gemini": return URL(string: "https://gemini.google.com")!
        case "claude": return URL(string: "https://claude.ai")!
        case "notebooklm": return URL(string: "https://notebooklm.google.com")!
        default: return URL(string: "https://example.com")!
        }
    }
}

/// The web view the user signs in through, plus the polling that decides when they have.
private struct LoginWebView: UIViewRepresentable {
    let url: URL
    let marker: String?
    let workerID: Int
    let onStatus: (LoginFlowView.Status) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(marker: marker, onStatus: onStatus) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent, so the session survives app relaunch. This is the point of doing the login
        // in-app at all — and per-worker, so signing worker 2 in does not just re-sign worker 1.
        config.websiteDataStore = WorkerDataStores.store(forWorkerID: workerID)
        let web = WKWebView(frame: .zero, configuration: config)
        web.enableInspectionInSimulator()
        // The documented mitigation for the embedded-web-view OAuth block. Not a guarantee —
        // Google's check is heuristic — but it is the difference between "usually works" and
        // "never works".
        web.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        context.coordinator.start(web)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let marker: String?
        private let onStatus: (LoginFlowView.Status) -> Void
        private var timer: Timer?

        init(marker: String?, onStatus: @escaping (LoginFlowView.Status) -> Void) {
            self.marker = marker
            self.onStatus = onStatus
        }

        func start(_ web: WKWebView) {
            // Polling rather than a navigation delegate: these are single-page apps that finish
            // navigating long before a session exists, and sign-in completes without a navigation
            // at all. The delegate would fire at all the wrong moments.
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak web] _ in
                guard let web else { return }
                Task { @MainActor in await self.check(web) }
            }
        }

        @MainActor private func check(_ web: WKWebView) async {
            // The embedded-web-view refusal is detected by its own text, because Google serves an
            // ordinary page rather than an error status — so there is nothing to catch, only
            // something to read.
            let blocked = (try? await web.evaluateJavaScript(
                "(document.body && document.body.innerText || '').indexOf('disallowed_useragent') !== -1"
                + " || (document.body && document.body.innerText || '').indexOf('browser or app may not be secure') !== -1"
            )) as? Bool
            if blocked == true {
                timer?.invalidate()
                onStatus(.blockedByPlatform("Google refuses OAuth inside embedded web views."))
                return
            }

            guard let marker, !marker.isEmpty else {
                // No captured marker for this platform yet, so we genuinely cannot tell. Reported as
                // "awaiting" rather than guessed — asserting a login we cannot observe is how a
                // half-finished 2FA gets recorded as success.
                onStatus(.awaitingUser)
                return
            }
            let present = (try? await web.evaluateJavaScript(
                "!!document.querySelector(\(jsString(marker)))"
            )) as? Bool
            if present == true {
                timer?.invalidate()
                onStatus(.signedIn)
            } else {
                onStatus(.awaitingUser)
            }
        }

        private func jsString(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'\(escaped)'"
        }

        deinit { timer?.invalidate() }
    }
}
