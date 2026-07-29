import SwiftUI
import WebKit

/// Watch the run happen — the app showing its own browser while the pipeline drives it.
///
/// On the Mac you watch a separate Chrome window. In the app the automation channel **is** this web
/// view (`evaluateJavaScript` is the same channel as IWDP's `Runtime.evaluate`), so showing it is not
/// a mirror or a screencast — it is the actual surface being driven. Nothing is duplicated and
/// nothing can drift out of sync with what the run is really doing.
///
/// Three decisions that follow from it being live rather than a preview:
///
/// * **One web view per platform, kept alive.** They are created once and retained, because a run
///   drives all of them concurrently and tearing one down to show another would abort its work.
///   Switching tabs changes what you *see*, never what is *running*.
/// * **Read-only by default.** Your taps would be trusted input arriving mid-automation, competing
///   with the run for the same composer. The overlay makes the view non-interactive until you
///   explicitly take over, so watching cannot accidentally become interfering.
/// * **A phase strip that names the step.** A page mid-automation is hard to read — things move
///   without explanation. The strip says which phase and which intent, so what you are watching is
///   legible rather than mysterious.
struct LiveRunView: View {
    let run: RunState
    let platforms: [PlatformState]
    @Binding var selected: String
    let onClose: () -> Void
    @State private var interactive = false

    var body: some View {
        VStack(spacing: 0) {
            phaseStrip
            tabs
            // No overlay badge here. An earlier version floated a "watching" chip top-trailing; the
            // Simulator showed it landing squarely on the platform's own controls, and the bar below
            // already says the same thing permanently. Covering the page you came to watch to tell
            // you that you are watching it is the wrong trade.
            LivePlatformWebView(platform: selected)
                .allowsHitTesting(interactive)
            takeoverBar
        }
        .background(DS.C.bg)
    }

    // MARK: - Phase strip

    private var phaseStrip: some View {
        HStack(spacing: DS.S.lg) {
            Text("P\(run.phase)")
                .font(DS.F.mono(11, .semibold)).foregroundStyle(DS.C.accent)
            Text(run.phaseName).font(DS.F.label).foregroundStyle(DS.C.textSecondary)
            Spacer()
            Text(String(format: "%02d:%02d", run.elapsedSeconds / 60, run.elapsedSeconds % 60))
                .font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            // "Done" rather than "Stop": leaving the live view must not read as stopping the run, and
            // the web views outlive this screen precisely so it doesn't.
            Button(action: onClose) {
                Text("Done").font(DS.F.label).foregroundStyle(DS.C.accent)
            }
            .frame(minHeight: DS.S.touch)
        }
        .padding(.horizontal, DS.S.screen)
        .padding(.vertical, DS.S.md)
        .background(DS.C.surface)
    }

    // MARK: - Per-platform tabs

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(platforms) { p in
                let state = run.agents[p.id] ?? "pending"
                Button { selected = p.id } label: {
                    VStack(spacing: DS.S.sm) {
                        HStack(spacing: DS.S.sm) {
                            AgentIcon(id: p.id, size: 14)
                                .saturation(state == "pending" ? 0.15 : 1)
                                .opacity(state == "pending" ? 0.5 : 1)
                            Text(short(p.id))
                                .font(DS.F.mono(10, .semibold))
                                .foregroundStyle(
                                    selected == p.id ? DS.C.textPrimary : DS.C.textTertiary
                                )
                        }
                        // The selected tab is marked by a rule, not by colour alone — the tab
                        // colours already encode which platform, so reusing colour for selection
                        // would overload it.
                        Rectangle()
                            .fill(selected == p.id ? DS.C.accent : .clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 34)
                }
                .buttonStyle(.plain)
            }
        }
        .background(DS.C.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border).frame(height: 1) }
    }

    private func short(_ id: String) -> String {
        ["chatgpt": "GPT", "gemini": "GEM", "claude": "CLD", "notebooklm": "NLM"][id] ?? id
    }

    // MARK: - Watching vs taking over

    private var takeoverBar: some View {
        HStack(spacing: DS.S.lg) {
            Text(interactive
                 ? "You are driving. The run is paused on this platform."
                 : "Read-only while the run drives this page.")
                .font(DS.F.label)
                .foregroundStyle(interactive ? DS.C.warn : DS.C.textTertiary)
            Spacer()
            // Taking over is explicit and reversible. A tap arriving mid-automation is trusted
            // input competing with the run for the same composer, so it must be a decision rather
            // than an accident.
            Button { interactive.toggle() } label: {
                Text(interactive ? "Hand back" : "Take over")
                    .font(DS.F.label.weight(.medium))
                    .foregroundStyle(DS.C.accent)
            }
            .frame(minHeight: DS.S.touch)
        }
        .padding(.horizontal, DS.S.screen)
        .background(DS.C.surface)
        .overlay(alignment: .top) { Rectangle().fill(DS.C.border).frame(height: 1) }
    }
}

/// Holds one long-lived `WKWebView` per platform.
///
/// A cache rather than a fresh view per appearance: these are the web views the run is *driving*, so
/// recreating one on a tab switch would destroy a session mid-phase. Static because the run outlives
/// any particular screen — navigating away from the live view must not stop the work.
final class PlatformWebViews {
    static let shared = PlatformWebViews()
    private var views: [String: WKWebView] = [:]

    func view(for platform: String) -> WKWebView {
        if let existing = views[platform] { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // the signed-in session lives here
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        web.load(URLRequest(url: LoginFlowView.url(for: platform)))
        views[platform] = web
        return web
    }
}

/// Shows whichever cached web view the selected tab names.
///
/// A **container** that re-parents the cached view, rather than a representable that *is* the web
/// view. The obvious version — `makeUIView` returning `PlatformWebViews.shared.view(for: platform)` —
/// silently never switches tabs: SwiftUI calls `makeUIView` once per representable identity and then
/// only `updateUIView`, so changing `platform` changed nothing on screen. Tapping GEM in the
/// Simulator kept showing ChatGPT, which is how this was found; it does not reproduce in a unit test
/// because the bug is in SwiftUI's lifecycle, not in the logic.
///
/// Re-parenting is safe because the cache holds the strong reference: `removeFromSuperview()` detaches
/// the view without tearing down its web content, so the run keeps driving the page while it is off
/// screen.
private struct LivePlatformWebView: UIViewRepresentable {
    let platform: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let web = PlatformWebViews.shared.view(for: platform)
        guard web.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        // Pinned rather than autoresized so a rotation or keyboard inset resizes the page instead of
        // clipping it — the same class of mistake as reading `innerHeight` when the keyboard is up.
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
