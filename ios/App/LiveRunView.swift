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
    /// ⚠ Optional, and that is the whole point of Browser watch. This screen used to be reachable
    /// only from the run card, which renders only `if let run` — so the one surface that can show
    /// whether a platform is still signed in was unreachable *except* during a run, which is the
    /// worst possible time to discover a login has expired.
    let run: RunState?
    let platforms: [PlatformState]
    /// Which worker's browser this is. Each worker has its own cookie jar, so "is ChatGPT signed in"
    /// is a question with a different answer per worker.
    let workerID: Int
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
            LivePlatformWebView(platform: selected, workerID: workerID)
                .allowsHitTesting(BrowserWatchInput.hitTestingEnabled(
                    ownerTookOver: interactive, runIsDriving: runIsDrivingThisPlatform
                ))
            takeoverBar
        }
        .background(DS.C.bg)
    }

    // MARK: - Phase strip

    private var phaseStrip: some View {
        HStack(spacing: DS.S.lg) {
            if let run {
                Text("P\(run.phase)")
                    .font(DS.F.mono(11, .semibold)).foregroundStyle(DS.C.accent)
                Text(run.phaseName).font(DS.F.label).foregroundStyle(DS.C.textSecondary)
            } else {
                Text(WorkerPicker.name(workerID))
                    .font(DS.F.mono(11, .semibold)).foregroundStyle(DS.C.accent)
                // Said plainly rather than left blank. An empty strip reads as a screen that failed
                // to load; "No runs live" reads as the true and unremarkable state it is.
                Text("No runs live").font(DS.F.label).foregroundStyle(DS.C.textSecondary)
            }
            Spacer()
            if let run {
                // ⭐ **Ticks LOCALLY, from the run's start stamp.** Rendering `run.elapsedSeconds`
                // straight from the snapshot would move the clock only when a beat lands — once
                // every twenty seconds — so it would jump 00:00 → 00:20 → 00:40 and read as broken
                // in a subtler way than being stuck. `TimelineView` redraws every second without
                // owning a timer that has to be cancelled.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = run.startedAtMillis > 0
                        ? RunState.elapsed(since: run.startedAtMillis, now: context.date)
                        : run.elapsedSeconds
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
                        .monospacedDigit()
                }
            }
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
                // With no run there is no per-agent state, so nothing is greyed out — every
                // platform is equally available to look at.
                let state = run?.agents[p.id] ?? (run == nil ? "idle" : "pending")
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

    /// Three states, not two. With no run there is nothing to interfere with, so "read-only" would be
    /// protecting against a collision that cannot happen — and would make checking a login feel like
    /// a risk. The bar says what is actually true.
    /// Is the pipeline actively driving THIS platform on THIS worker right now?
    ///
    /// Scoped to the platform, not merely to "a run exists": a run in P2 on ChatGPT is not driving
    /// the Claude tab, and enabling input there for the whole run would be a broader claim than the
    /// automation needs.
    private var runIsDrivingThisPlatform: Bool {
        guard let run else { return false }
        return run.activePlatform == selected
    }

    private var takeoverCaption: String {
        BrowserWatchInput.caption(
            ownerTookOver: interactive,
            runIsDriving: runIsDrivingThisPlatform,
            runExists: run != nil
        )
    }

    private func short(_ id: String) -> String {
        ["chatgpt": "GPT", "gemini": "GEM", "claude": "CLD", "notebooklm": "NLM"][id] ?? id
    }

    // MARK: - Watching vs taking over

    private var takeoverBar: some View {
        HStack(spacing: DS.S.lg) {
            Text(takeoverCaption)
                .font(DS.F.label)
                .foregroundStyle(interactive && run != nil ? DS.C.warn : DS.C.textTertiary)
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
    /// Keyed by worker AND platform. Keying by platform alone — as this did — meant every worker
    /// shared one web view per platform, so two concurrent runs would drive the same page.
    private var views: [String: WKWebView] = [:]

    /// The cached view for this platform, or nil — **without creating one.**
    ///
    /// ⚠ Distinct from `view(for:worker:)`, which creates on demand. The hand-off asks about a page
    /// that was on screen a moment ago; if it somehow does not exist, the right answer is "nothing to
    /// move", not "build a fresh web view and attach it to the window", which would add exactly the
    /// visibility transition the hand-off exists to avoid.
    func existing(for platform: String, worker: Int = 1) -> WKWebView? {
        views["\(worker)/\(platform)"]
    }

    func view(for platform: String, worker: Int = 1) -> WKWebView {
        let key = "\(worker)/\(platform)"
        if let existing = views[key] { return existing }
        let config = WKWebViewConfiguration()
        // This worker's own jar, so its signed-in session is the one the run drives.
        config.websiteDataStore = WorkerDataStores.store(forWorkerID: worker)
        // Ask for the desktop surface when told to.
        //
        // Not cosmetic — it decides whether P2 is possible at all. The backend's own intents say the
        // deep-research control exists on every platform (`region: form` on ChatGPT with roles
        // menuitem/menuitemradio, `region: composer` on Gemini and Claude), and at 402pt none of them
        // is reachable: Claude's composer row collapses to plus/model/send, and ChatGPT's plus menu
        // shows Camera/Photos/Files. Measured by opening each container on real signed-in accounts.
        // The controls are not missing, they are collapsed.
        if ProcessInfo.processInfo.environment["SR_DESKTOP_WEB"] == "1" {
            config.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.enableInspectionInSimulator()
        // ⛔ **Say it out loud when a page's process dies.** A WebContent process that is jetsammed
        // or crashes leaves the `WKWebView` alive and BLANK, so every selector stops resolving at
        // once and the run reports a cascade of "not found" — which reads as four selectors rotating
        // simultaneously rather than as one process death. Three WebKit process crashes were chased
        // through system logs on 2026-08-14 with nothing in the app's own log to anchor them.
        web.navigationDelegate = WebProcessWatch.shared
        views[key] = web   // registered BEFORE load, so the watcher can name it if load itself dies
        WebProcessWatch.shared.name(web, as: key)
        // ⚠ Left to WebKit in desktop mode. `.desktop` picks a matching desktop UA, and pinning the
        // iPhone one over it produces the contradiction that gets a request served the mobile page
        // anyway — the override exists for Google's embedded-web-view OAuth block, which only matters
        // while signing in.
        if ProcessInfo.processInfo.environment["SR_DESKTOP_WEB"] != "1" {
            web.customUserAgent =
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }
        web.load(URLRequest(url: LoginFlowView.url(for: platform)))
        return web
    }

    /// Put the web view in the window, behind everything.
    ///
    /// ⛔ **Without this, TEXT ENTRY CANNOT WORK — and it fails silently.** A `WKWebView` that is in
    /// no view hierarchy has an unfocused document, and WebKit's editing commands are no-ops on an
    /// unfocused document: `document.execCommand('insertText', …)` returns **true** and inserts
    /// nothing. Measured live 2026-08-14, once the runtime started reading the text back:
    ///
    ///     refused: the editor refused the text (execCommand=true, paste and beforeinput also left
    ///     it unchanged); document.hasFocus()=false (composer now: "")
    ///
    /// That `execCommand=true` is why this survived so long: every check anyone thought to write —
    /// including the `ok` flag the runtime already returned — said the insert had succeeded.
    ///
    /// ⚠ Behind every other view and non-interactive, so it changes nothing the owner sees or taps.
    /// It is NOT hidden and NOT `alpha: 0`: WebKit stops rendering a hidden view, and an unrendered
    /// composer has no layout for the editor to place a caret in. Nearly-transparent and covered by
    /// the opaque UI is the state that is both invisible and alive.
    ///
    /// ⚠ Browser watch re-parents this same view into its container when opened, which is fine —
    /// that is also inside the window. What is NOT fine is leaving the OUTGOING page in no window at
    /// all: WebKit reads that as invisible and begins suspending its WebContent process, and a
    /// suspension entered while a JS evaluation is in flight is the assert that killed a live run on
    /// 2026-08-14. `LivePlatformWebView` therefore calls this to put the outgoing page back, on its
    /// own runloop turn — see `BrowserWatchHandoff`.
    static func attachOffscreen(_ web: WKWebView) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }
        // ⛔⛔ **THIS GUARD WAS `web.superview == nil`, AND IT IS THE CRASH.** Every caller asks this
        // function to rescue a page FROM somewhere — Browser watch's container on tab-switch, and
        // again when that screen is torn down — so every one of them arrived with a superview and
        // was silently refused. The page was then left orphaned by the container's own removal,
        // WebKit read a windowless view as invisible, began suspending its WebContent process while
        // the run's JavaScript was still in flight, and `ProcessThrottlerActivity::invalidate` hit
        // its RELEASE_ASSERT. Three crashes, one inert guard — and the teardown even LOGGED
        // "returned to the window" while this returned without doing anything.
        //
        // ⚠ `insertSubview` re-parents in ONE transition: it removes the view from its old
        // superview and adds it here, so the page never passes through a windowless state. That is
        // the rule the whole file is built on, and this line is where it was being broken.
        guard web.superview !== window else { return }   // already parked
        web.frame = window.bounds
        // ⭐ **THE BLACK SCREEN.** Parked pages are near-invisible on purpose; Browser watch shows
        // this same view, so whoever presents it MUST restore the alpha. That is why it lives in
        // `BrowserWatchHandoff` as a named pair rather than as a literal in two files.
        web.alpha = BrowserWatchHandoff.parkedAlpha
        // ⚠ Interaction stays ENABLED. A view that refuses interaction cannot become first
        // responder, and first-responder is exactly what `document.hasFocus()` reflects. It is
        // safe because the view is inserted at index 0 — beneath the app's own opaque root view —
        // so no touch ever reaches it.
        window.insertSubview(web, at: 0)
    }

    /// Give the page keyboard focus, so editing commands are not no-ops.
    ///
    /// ⚠ Attaching to the window is necessary and NOT sufficient: `document.hasFocus()` follows the
    /// web view being FIRST RESPONDER, and a view merely present in the hierarchy is not. Called
    /// before each platform's phases rather than once at creation, because Browser watch, a login
    /// sheet or the keyboard can take first-responder away in between.
    static func focusForAutomation(_ web: WKWebView, platform: String, worker: Int) {
        shared.attachExclusively(web, platform: platform, worker: worker)
        web.becomeFirstResponder()
    }

    /// The one view per worker that is currently in the window.
    ///
    /// ⛔ **Attaching EVERY created view bought exactly nothing.** UIKit allows one first responder,
    /// and `focusForAutomation` runs on every page hand-off — so only the last-driven view ever has
    /// `document.hasFocus() == true` no matter how many are attached. What attach-everything DID
    /// create was a permanent-foreground fleet: up to four WebContent processes per worker, each
    /// compositing a full-screen layer (the 452MB of IOSurface in the crash report), none of them
    /// ever able to suspend.
    ///
    /// ⚠ **This is NOT claimed as the crash fix.** The identical trap — same address, same six
    /// frames — was recorded at 23:15, BEFORE any of this existed, so attachment is not necessary
    /// for it. This removes cost that has no benefit, and shrinks the window the trap lives in.
    private var attached: [Int: WKWebView] = [:]

    private func attachExclusively(_ web: WKWebView, platform: String, worker: Int) {
        if attached[worker] === web, web.superview != nil { return }
        // ⚠ Detach the PREVIOUS view before attaching the next, never mid-phase: hand-off happens
        // once per platform per phase, so a page is never pulled out from under a running step.
        if let previous = attached[worker], previous !== web {
            // ⛔ Deferred, not immediate — same rule as `updateUIView` and `detachAll`. Removing one
            // view and adding another in a single turn asks WebKit for two visibility transitions at
            // once, which is the shape that trips `ProcessThrottler`'s assert. The attach below is
            // this turn's one transition; the previous view's release gets the next.
            DispatchQueue.main.async {
                previous.removeFromSuperview()
                NSLog("[SR] detach w%d (previous view)", worker)
            }
        }
        Self.attachOffscreen(web)
        attached[worker] = web
        NSLog("[SR] attach %@/w%d inWindow=%@", platform, worker, web.window != nil ? "yes" : "NO")
    }

    /// Put the fleet back to rest. Called when a run ends, however it ends.
    ///
    /// ⚠ Detaches ONE VIEW PER RUNLOOP TURN rather than all at once. The trap this is adjacent to
    /// fires on a suspension transition entered reentrantly, and flipping several views' visibility
    /// in the same turn is the way to ask for several transitions at once.
    static func detachAll() {
        let work = {
            let views = shared.attached.values
            shared.attached.removeAll()
            for (index, view) in views.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250 * index)) {
                    view.removeFromSuperview()
                }
            }
            NSLog("[SR] detachAll — %d view(s) returning to rest", views.count)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
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
    let workerID: Int

    /// Remembers which platform this container is currently showing.
    ///
    /// ⚠ Held here rather than read back off the view tree: the outgoing view's PLATFORM is what the
    /// hand-off plan is expressed in, and a `WKWebView` does not carry its own platform id.
    final class Coordinator {
        var presented: String?
        /// Which worker's page is on screen, so the teardown can find it again. `dismantleUIView`
        /// is static and sees no properties of the representable — without this it cannot name the
        /// view it has to rescue.
        var worker: Int = 1
    }

    /// ⛔⛔ **THE STOP CRASH, 2026-08-17.** Closing this screen — by the X, or by stopping the run —
    /// tore the container down and left the run's live page in NO WINDOW. WebKit reads a windowless
    /// view as invisible and begins suspending its WebContent process; the run's JavaScript was
    /// still in flight (a response poll every 250ms), so `ProcessThrottlerActivity::invalidate` hit
    /// its RELEASE_ASSERT inside `sendPrepareToSuspendIPC` and the app died with EXC_BREAKPOINT.
    /// The relaunched process then swept the abandoned run's queue document as a zombie.
    ///
    /// The file already stated the rule — *a page the run owns is never left unparented* — and
    /// applied it when SWITCHING tabs. Nothing applied it when the screen went away, because
    /// SwiftUI does not call `updateUIView` on the way out; it calls this, and this did not exist.
    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        guard let platform = coordinator.presented,
              let view = PlatformWebViews.shared.existing(for: platform, worker: coordinator.worker)
        else { return }
        // Straight back to the offscreen window: ONE visibility transition, and the process never
        // sees a reason to suspend. Synchronous on purpose — the container is being deallocated
        // now, so a deferred re-parent would race the very orphaning it exists to prevent.
        PlatformWebViews.attachOffscreen(view)
        // ⚠ Reports what HAPPENED, not what was attempted. The first version logged "returned to
        // the window" unconditionally — and said exactly that in the run where the call was refused
        // by its own guard and the app died seconds later. A log that narrates intent rather than
        // outcome is worse than no log: it rules out the very thing that went wrong.
        NSLog("[SR] browser watch closed — %@/w%d %@",
              platform, coordinator.worker,
              view.window != nil ? "returned to the window" : "IS ORPHANED (its process will suspend)")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // ⚠ Asked for the EXISTING page first, purely to say whether there was one. `view(for:)`
        // creates a blank `WKWebView` on demand and nothing here ever navigates it — so tapping a
        // platform the run has not reached presents an empty view over a black container, which is
        // indistinguishable from a crashed page. Reported live 2026-08-17: "I clicked on the
        // highlighted platform, nothing loaded, it was just a black screen."
        let live = PlatformWebViews.shared.existing(for: platform, worker: workerID)
        let web = live ?? PlatformWebViews.shared.view(for: platform, worker: workerID)
        NSLog("[SR] browser watch: showing %@/w%d — page=%@ url=%@ loading=%@",
              platform, workerID,
              live == nil ? "NEW-BLANK (nothing to watch yet)" : "live",
              web.url?.absoluteString ?? "(none)",
              web.isLoading ? "yes" : "no")
        guard web.superview !== container else { return }

        // ⛔⛔ **THE 2026-08-14 CRASH, and this is the line it came from.** The old body was
        // `container.subviews.forEach { $0.removeFromSuperview() }` followed immediately by
        // `container.addSubview(web)`, and both halves are visibility transitions on a LIVE page:
        //
        //   * the previously-shown view was left in NO window at all — WebKit does not treat that as
        //     "moved", it treats it as invisible and starts suspending its WebContent process;
        //   * `web` itself was pulled out of the window and into the container in the same turn.
        //
        // Three WebContent processes therefore flipped background→foreground inside ONE millisecond
        // (PIDs 1401/1388/1384 in the trace, on two threads), while
        // `WebPage::runJavaScriptInFrameInScriptWorld` was in flight — and
        // `ProcessThrottlerActivity::invalidate` hit its RELEASE_ASSERT inside
        // `sendPrepareToSuspendIPC`. The app died two minutes into a run, taking P1 with it, the
        // instant the owner opened Browser watch on the platform the run was driving.
        //
        // Two rules, both required:
        //   1. **A page the run owns is never left unparented.** Anything leaving this container
        //      goes straight back to the offscreen window slot, so its process never sees a reason
        //      to suspend. `attachOffscreen` re-adds to the window, which also removes it from here.
        //   2. **One transition per runloop turn.** The trap fires on a suspension entered
        //      reentrantly, so asking for several at once is the shape to avoid — the same rule
        //      `detachAll` already follows, and which has held.
        // ⚠ The schedule comes from `BrowserWatchHandoff`, not from this file. A representable
        // cannot be unit tested, and "we changed the view and hoped" is what the previous two
        // occurrences of this crash were.
        let steps = BrowserWatchHandoff.plan(
            showing: context.coordinator.presented.map { [$0] } ?? [], target: platform
        )
        for step in steps {
            guard case .returnToWindow(let outgoing) = step.move,
                  let view = PlatformWebViews.shared.existing(for: outgoing, worker: workerID)
            else { continue }
            let delay = BrowserWatchHandoff.delayMillis(turn: step.turn)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) {
                // Back to the window rather than to nowhere. Re-parenting to a window is ONE
                // transition; orphaning is a suspend that a later attach then has to undo.
                PlatformWebViews.attachOffscreen(view)
            }
        }
        context.coordinator.presented = platform
        context.coordinator.worker = workerID
        // ⭐ **Restore the alpha, or this is a black screen.** The same view is parked at
        // `parkedAlpha` while it waits, and nothing here used to put it back — so the page the
        // owner asked to watch was rendered at one percent opacity over a black container. Reported
        // three times as "all dark, nothing loaded", with the log insisting the page was live.
        web.alpha = BrowserWatchHandoff.presentedAlpha
        web.isHidden = false
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


/// Names a WebContent process death, which is otherwise invisible from inside the app.
///
/// ⚠ One shared delegate for every platform web view rather than one each: the only thing it needs
/// to know is WHICH view died, and a side table answers that without giving each view its own
/// object to retain.
final class WebProcessWatch: NSObject, WKNavigationDelegate {
    static let shared = WebProcessWatch()

    private var names: [ObjectIdentifier: String] = [:]

    func name(_ web: WKWebView, as label: String) {
        names[ObjectIdentifier(web)] = label
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let label = names[ObjectIdentifier(webView)] ?? "unknown"
        // ⛔ The page is now BLANK. Every subsequent selector on it resolves to nothing, so without
        // this line the run reports what looks like four selectors rotating at once.
        NSLog("[SR] WEBCONTENT PROCESS DIED for %@ — the page is blank; every selector on it will "
              + "now fail until it is reloaded", label)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let label = names[ObjectIdentifier(webView)] ?? "unknown"
        NSLog("[SR] navigation FAILED for %@ — %@", label, String(describing: error))
    }
}
