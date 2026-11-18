import CoreImage
import SwiftUI

// MARK: - Root

struct RootView: View {
    @StateObject var model: AppModel
    @ObservedObject var theme: ThemeManager
    /// ⚠ Observed HERE, at the root, and not only inside Settings. The size multiplier is read
    /// during every body evaluation, so the view that must re-render on a change is the one that
    /// owns the whole tree — observing it only in the sheet would resize Settings and leave the
    /// dashboard behind it at the old size until something else happened to redraw it.
    @ObservedObject var size: AppSizeManager

    /// Which platform's login sheet is open, if any.
    @State private var loginTarget: PlatformState?
    /// Whether the live browser view is up, and which platform it is showing.
    @State private var watching = false
    @State private var watchSelection = "chatgpt"
    /// Which worker's browser the live view is showing. Each worker is its own profile, so this is
    /// as much a part of "what am I looking at" as the platform is.
    @State private var watchWorker = 1
    @State private var settingsOpen = false
    @State private var peopleOpen = false

    var body: some View {
        ZStack {
            DS.C.bg.ignoresSafeArea()
            // The landing page owns the whole screen, so it sits outside the dashboard's scroll view
            // and header rather than being squeezed into a card.
            if !model.snapshot.paired, model.screen == .landing, model.pairing != nil {
                LandingView(theme: theme) { model.screen = .notPaired }
            } else if !model.snapshot.paired, model.screen == .notPaired, model.pairing != nil {
                VStack(spacing: 0) {
                    Header(snapshot: model.snapshot, onSettings: nil).padding(DS.S.screen)
                    NotPairedView(
                        onPair: { model.screen = .pairing },
                        lostReason: DeviceIdentityStore.lostPairingReason,
                        lastPairedDeviceID: DeviceIdentityStore.lastPairedDeviceID
                    )
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.S.lg * 2) {
                        Header(
                            snapshot: model.snapshot,
                            onSettings: model.snapshot.paired ? { settingsOpen = true } : nil
                        )
                        if model.snapshot.paired {
                            // ⚠ Four cards. It was three, and Browser watch was the casualty: the
                            // live view existed but hung off the run card, so it only existed WHILE a
                            // run did. Checking whether a platform is still signed in is a
                            // between-runs job, so the one screen that can answer it has to be
                            // standing. Operations still live in Settings.
                            StatusCard(snapshot: model.snapshot)
                            if let run = model.snapshot.run {
                                RunCard(run: run, onWatch: {
                                    watchWorker = model.snapshot.busyWorkerIDs.min() ?? 1
                                    watching = true
                                })
                            }
                            BrowserWatchCard(
                                snapshot: model.snapshot,
                                workers: model.workers,
                                selectedWorker: $watchWorker,
                                liveTick: model.liveTick,
                                onToggleRest: { id, resting in
                                    model.setWorkerResting(id, resting: resting)
                                }
                            ) { platform in
                                watchSelection = platform
                                watching = true
                            }
                            PeopleButton(snapshot: model.snapshot) { peopleOpen = true }
                        } else if let pairing = model.pairing {
                            PairingFlowView(controller: pairing)
                        } else {
                            Text("No Firebase configuration bundled — running in preview mode.")
                                .font(DS.F.body).foregroundStyle(DS.C.textSecondary).srCard()
                        }
                        Footer(snapshot: model.snapshot)
                    }
                    .padding(DS.S.screen)
                }
            }
        }
        // Always a concrete scheme — the System option was removed, so this never defers to the OS.
        .preferredColorScheme(theme.choice.colorScheme)
        // One transition for the whole pre-pairing journey, so landing → not-paired → flow reads as
        // moving forward through a single thing rather than three unrelated screens swapping out.
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: model.screen)
        .animation(.easeInOut(duration: 0.3), value: model.snapshot.paired)
        .task { await model.refresh() }
        // ⚠ Close every modal the moment the device stops being paired. `settingsOpen` is local
        // @State that `AppModel` cannot reach, so unpairing from inside Settings used to leave the
        // sheet sitting on top of the "No user paired" screen underneath it. This also covers the
        // device being deleted from the web app while the app is open.
        .onChange(of: model.snapshot.paired) { _, paired in
            guard !paired else { return }
            settingsOpen = false
            peopleOpen = false
            watching = false
            loginTarget = nil
        }
        // ⚠ Gated on `!settingsOpen`, and the detail sheet moved into SettingsSheet entirely.
        //
        // A `.sheet` starts a NEW presentation: UIKit stacks it above the presenter's whole view,
        // so an `.overlay` composed here renders UNDERNEATH it, and a presenter that is already
        // presenting cannot present a second sheet at all. Three symptoms, one cause:
        //
        //  * the Restart confirmation appeared below the Settings page,
        //  * every toast raised from Settings was invisible,
        //  * Doctor / Version / Diagnostics set `opDetail` and their sheet NEVER APPEARED —
        //    silently, so the rows looked like they did nothing.
        //
        // Each surface now renders these in its own presentation. The state is shared @Published,
        // so exactly one copy is ever on screen.
        .overlay(alignment: .bottom) { if !settingsOpen { Toast(text: model.toast) } }
        .overlay { if !settingsOpen { ConfirmSheet(model: model) } }
        .sheet(isPresented: $settingsOpen) {
            SettingsSheet(theme: theme, size: size, model: model, onClose: { settingsOpen = false })
        }
        // An overlay rather than a `.sheet`: a sheet brings its own full-height chrome and grabber,
        // and the frontend's equivalent is a bottom-anchored card floating over a blurred backdrop.
        .overlay {
            if peopleOpen {
                PeoplePopup(
                    snapshot: model.snapshot,
                    onToggleRest: { id, resting in model.setWorkerResting(id, resting: resting) },
                    onStop: { worker in model.stopRun(onWorker: worker) },
                    onClose: { peopleOpen = false }
                )
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: peopleOpen)
        .sheet(item: $loginTarget) { p in
            LoginFlowView(platform: p, manifestMarker: nil) { _ in
                loginTarget = nil
                Task { await model.refresh() }
            }
        }
        // Full screen rather than a sheet: this is the page being automated, and a sheet's inset
        // would crop exactly the part of it worth watching.
        // ⚠ No `if let run` guard. It used to be there, and it meant tapping Watch with no run
        // presented an EMPTY full-screen cover — a black screen with no way back that reads as a
        // crash. The screen itself now handles the no-run case.
        .fullScreenCover(isPresented: $watching) {
            LiveRunView(
                // The worker's OWN run — see DeviceSnapshot.run(forWorker:). Passing the device's
                // single `run` here showed worker 1's phase strip above worker 2's browser.
                run: model.snapshot.run(forWorker: watchWorker),
                platforms: model.snapshot.platforms,
                workerID: watchWorker,
                selected: $watchSelection,
                onClose: { watching = false }
            )
        }
    }
}

/// The wordmark, in the frontend's own two tones.
///
/// ⚠ Not one colour. The web app renders `<span class="text-accent font-bold">Super</span>` then
/// `<span class="text-text-secondary font-medium">Research</span>` — so **Super** is accent and bold,
/// **Research** is secondary and medium. Painting the whole thing accent, as an earlier version did, is
/// a different mark from the one the product uses everywhere else.
struct Wordmark: View {
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            Text("Super")
                .font(DS.F.sans(size, .bold))
                .foregroundStyle(DS.C.accent)
            Text(" Research")
                .font(DS.F.sans(size, .medium))
                .foregroundStyle(DS.C.textSecondary)
        }
    }
}

private struct Header: View {
    let snapshot: DeviceSnapshot
    /// nil hides the button — there is nothing to configure before pairing.
    let onSettings: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: DS.S.md) {
                Wordmark(size: 24)
                if snapshot.paired {
                    StatusPill(
                        color: snapshot.online ? DS.C.ok : DS.C.textTertiary,
                        text: snapshot.online ? "Online" : "Offline",
                        live: snapshot.online
                    )
                } else {
                    StatusPill(color: DS.C.warn, text: "Not paired")
                }
            }
            .frame(maxWidth: .infinity)

            if let onSettings {
                // Top right, out of the way. Everything behind it is something you set once — the
                // wordmark and status stay the two things the eye lands on.
                // An SF Symbol, not the ⚙ emoji. The emoji renders in full colour and at its own
                // metrics, so it sat in this flat monochrome header looking like a sticker.
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(DS.C.textTertiary)
                }
                .frame(minWidth: DS.S.touch, minHeight: DS.S.touch)
            }
        }
    }
}

// MARK: - Status + pair code

private struct StatusCard: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                SectionLabel(text: "This device")
                Spacer()
                Text(snapshot.deviceID).font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            }

            // ⚠ Only while there IS a code. A confirmed device keeps `pairCode` empty — it is set
            // during the flow and never re-read afterwards — so this block rendered an empty line
            // labelled "Pair code" beside a blank white QR square, on a device that is already
            // paired and online. It read as a control that had failed to load, and it was the
            // largest thing on the screen.
            //
            // The code in mono at display size, hyphenated: it exists to be read off this screen
            // and typed into another, so legibility is the entire requirement.
            if !snapshot.pairCode.isEmpty {
                HStack(alignment: .center, spacing: DS.S.lg * 2) {
                    VStack(alignment: .leading, spacing: DS.S.sm) {
                        // One line, always. A wrapped pair code is materially harder to read back
                        // than a smaller one, and reading it back is the whole job of this element —
                        // so it shrinks to fit instead of breaking.
                        Text(Pairing.formatForDisplay(snapshot.pairCode))
                            .font(DS.F.codeLarge)
                            .foregroundStyle(DS.C.terminal)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Pair code").font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    }
                    Spacer(minLength: DS.S.lg)
                    QRView(code: snapshot.pairCode)
                }

                Divider().overlay(DS.C.border)
            }

            HStack(spacing: DS.S.lg * 3) {
                Metric(label: "Workers", value: "\(snapshot.busyWorkers)/\(snapshot.workerCount)")
                Metric(
                    label: "Heartbeat",
                    value: snapshot.lastHeartbeatAgo.map { "\($0)s ago" } ?? "—"
                )
                Metric(label: "Backend", value: snapshot.backendVersion.isEmpty ? "—" : snapshot.backendVersion)
            }
        }
        .srCard()
    }
}

private struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.xs) {
            Text(value).font(DS.F.mono(13)).foregroundStyle(DS.C.textPrimary)
            Text(label).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
    }
}

/// The QR, rendered at an integer scale so module edges stay sharp.
///
/// A fractional scale blurs the boundaries and a blurred QR does not decode — which looks like the
/// camera failing rather than the render being wrong.
struct QRView: View {
    let code: String
    /// Point size. The pairing flow wants it big enough to scan from a phone held at arm's length;
    /// the paired dashboard only needs a reminder of what the code was.
    var side: CGFloat = 88

    var body: some View {
        Group {
            if let image = qr {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)           // nearest-neighbour; smoothing kills the scan
                    .frame(width: side, height: side)
                    .padding(DS.S.md)
                    .background(Color.white)        // quiet zone: scanners need the light margin
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
            } else {
                RoundedRectangle(cornerRadius: DS.R.sm)
                    .stroke(DS.C.border, lineWidth: 1)
                    .frame(width: side + 12, height: side + 12)
            }
        }
    }

    private var qr: CGImage? {
        guard !code.isEmpty,
              // ⚠ Was hardcoded to `https://app.superresearch.dev`, which is not the frontend this
              // app talks to — scanning the code would have led nowhere. The unit test
              // `testTheBaseURLIsTakenNotHardcoded` passed the whole time, because the *function*
              // takes a base URL; it was the CALL SITE that hardcoded one. A parameterised API is no
              // protection if its only caller ignores the parameter.
              let ci = try? QRCode.imageForPairCode(code, baseURL: AppConfig.frontendBaseURL)
        else { return nil }
        // ⚠ `side`, not a hardcoded 88. This was the SECOND hardcoded value in this one function:
        // the raster was always sized for 88pt, so at 220pt the QR rendered at its intrinsic size and
        // floated in the middle of a much larger white card. `integerScale(for:targetPoints:)` takes
        // the target precisely so the rasterisation matches the display size.
        let scale = QRCode.integerScale(for: ci.extent.width, targetPoints: side)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - Run

private struct RunCard: View {
    let run: RunState
    let onWatch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                SectionLabel(text: "Current run")
                Spacer()
                Text(timeString).font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            }
            Text(run.researchTitle)
                .font(DS.F.body).foregroundStyle(DS.C.textPrimary).lineLimit(2)
            Text("P\(run.phase) · \(run.phaseName)")
                .font(DS.F.mono(11)).foregroundStyle(DS.C.textSecondary)

            HStack(spacing: DS.S.lg) {
                ForEach(["chatgpt", "gemini", "claude", "notebooklm"], id: \.self) { key in
                    AgentChip(key: key, state: run.agents[key] ?? "pending")
                }
            }
            // The same affordance as watching Chrome work on the desktop backend. Offered only while
            // a run exists, because there is nothing to watch otherwise.
            SRButton(title: "Watch the browser", action: onWatch)
        }
        .srCard()
    }

    private var timeString: String {
        String(format: "%02d:%02d", run.elapsedSeconds / 60, run.elapsedSeconds % 60)
    }
}

/// One agent's state. The brand colour identifies *which* agent; the glyph carries the *state*, so
/// the row is still readable without colour vision.
private struct AgentChip: View {
    let key: String
    let state: String

    var body: some View {
        VStack(spacing: DS.S.sm) {
            // The real brand mark, with the state as a small badge on it. A glyph in the platform's
            // colour was standing in for the icon, which made every agent the same shape.
            AgentIcon(id: key, size: 26)
                .saturation(state == "pending" ? 0.15 : 1)
                .opacity(state == "pending" ? 0.5 : 1)
                .overlay(alignment: .bottomTrailing) {
                    Text(glyph)
                        .font(DS.F.mono(8, .bold))
                        .foregroundStyle(state == "pending" ? DS.C.textTertiary : DS.C.platform(key))
                        .padding(1)
                        .background(DS.C.surface)
                        .clipShape(Circle())
                        .offset(x: 3, y: 3)
                }
            Text(short).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var glyph: String {
        switch state {
        case "done": return "✓"
        case "active": return "●"
        case "skipped": return "–"
        default: return "○"
        }
    }
    private var short: String {
        ["chatgpt": "GPT", "gemini": "GEM", "claude": "CLD", "notebooklm": "NLM"][key] ?? key
    }
}

// MARK: - Platforms

private struct PlatformsCard: View {
    let platforms: [PlatformState]
    @ObservedObject var model: AppModel
    let onSelect: (PlatformState) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "Platform logins")
            Text("Sign in once per platform. The session persists across restarts.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            ForEach(platforms) { p in
                // Each row opens the in-app login. This is the one step no automation can do — 2FA, a
                // password manager, a CAPTCHA — so it is a first-class tap rather than something the
                // owner has to know to go and do elsewhere.
                Button { onSelect(p) } label: {
                    HStack {
                        Circle().fill(DS.C.platform(p.id)).frame(width: 7, height: 7)
                        Text(p.name).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                        Spacer()
                        // Three states, not two. "Unknown" is rendered as unknown rather than as
                        // "not signed in" — claiming a platform is signed out when nobody has checked
                        // sends the owner to re-do a login they may not need.
                        Text(label(p.signedIn))
                            .font(DS.F.label)
                            .foregroundStyle(colour(p.signedIn))
                        Text("›").font(DS.F.body).foregroundStyle(DS.C.textTertiary)
                    }
                    .frame(minHeight: DS.S.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            SRButton(title: "Seed logins in the emulator") {
                model.invoke(Operations.byID("login")!)
            }
        }
        .srCard()
    }

    private func label(_ s: Bool?) -> String {
        guard let s else { return "not checked" }
        return s ? "signed in" : "signed out"
    }
    private func colour(_ s: Bool?) -> Color {
        guard let s else { return DS.C.textTertiary }
        return s ? DS.C.ok : DS.C.warn
    }
}

// MARK: - Workers

/// Live capacity: what each worker is doing, and how much is spare.
///
/// Read from the device doc's `workers` map, which **all** workers write — unlike the `currentRun*`
/// fields, which only worker-1 maintains. On a multi-worker device those fields describe one worker and
/// call it the device, so this is the only honest view of capacity.
private struct WorkersCard: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                SectionLabel(text: "Workers")
                Spacer()
                Text("\(snapshot.workers.filter(\.isBusy).count)/\(snapshot.workers.count) busy")
                    .font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            }

            ForEach(snapshot.workers) { worker in
                HStack(alignment: .firstTextBaseline, spacing: DS.S.lg) {
                    // Colour AND glyph, so busy/idle survives without colour vision.
                    Text(worker.isBusy ? "●" : "○")
                        .font(DS.F.mono(11, .semibold))
                        // The worker green, same as its pill — this row names a WORKER.
                        .foregroundStyle(worker.isBusy ? DS.C.worker : DS.C.textTertiary)
                    Text("w\(worker.id)")
                        .font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
                        .frame(width: 24, alignment: .leading)
                    if worker.isBusy {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(worker.title ?? "a run")
                                .font(DS.F.label).foregroundStyle(DS.C.textPrimary).lineLimit(1)
                            if let phase = worker.phase {
                                Text("phase \(phase)"
                                     + (worker.totalPhases.map { " of \($0)" } ?? ""))
                                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                            }
                        }
                    } else {
                        Text("idle").font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    }
                    Spacer()
                }
                .frame(minHeight: 26)
            }

            if !snapshot.queue.isEmpty {
                Divider().overlay(DS.C.border)
                HStack {
                    Text("Queued").font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    Spacer()
                    Text("\(snapshot.queue.count)")
                        .font(DS.F.mono(11)).foregroundStyle(DS.C.textSecondary)
                }
                ForEach(snapshot.queue) { queued in
                    HStack(spacing: DS.S.lg) {
                        Text("#\(queued.position)")
                            .font(DS.F.mono(10)).foregroundStyle(DS.C.accent)
                            .frame(width: 24, alignment: .leading)
                        Text(queued.title)
                            .font(DS.F.label).foregroundStyle(DS.C.textSecondary).lineLimit(1)
                        Spacer()
                    }
                    .frame(minHeight: 24)
                }
            }
        }
        .srCard()
    }
}

// MARK: - Browser watch

/// Every platform, for every worker, openable at any time.
///
/// ⚠ The card that was missing. `LiveRunView` was built and worked, but its only entry point was the
/// run card's Watch button — so the browsers were visible only while a run was in flight. The
/// question this card exists to answer ("is worker 2 still signed in to Claude?") is one you ask
/// *between* runs, and the answer was unreachable exactly then.
/// Every worker on this device, with what each is doing, as one row.
///
/// The unit of a run is a WORKER, not the device — the backend assigns work by ordinal and two runs
/// can be in flight at once. So the honest answer to "what is happening" is per-worker, and a
/// control that surfaces one worker at a time cannot give it.
///
/// ⚠ State precedence is BUSY > RESTING > IDLE, and the order matters. `restingWorkerIds` is an
/// intent the owner expresses; `busyWorkerIds` is what the backend is actually doing. A worker
/// parked mid-run is still running that run to completion, and showing it as "resting" would tell
/// the owner their work had stopped when it had not.
struct WorkerWatchStrip: View {
    let workers: [WorkerProfile]
    @Binding var selected: Int
    var busyWorkerIDs: Set<Int> = []
    var restingWorkerIDs: Set<Int> = []
    /// The run on a given worker, so a busy chip can name the phase instead of just saying "busy".
    var runFor: (Int) -> RunState? = { _ in nil }

    /// Park or wake, on a long press. Nil where the caller offers no rest control.
    var onToggleRest: ((Int, Bool) -> Void)?

    @Namespace private var pillSpace

    var body: some View {
        // ⭐ **The People popup's pill, not a lookalike.** This was a row of "Worker N" mini-tiles
        // that named the same worker in the same state as the popup and shared not one pixel with
        // it — so the owner had to learn the device's worker vocabulary twice. Same component now,
        // which also means a resting worker reads hollow on both screens without anyone
        // remembering to keep them in step.
        VStack(alignment: .leading, spacing: DS.S.sm) {
            FlowRow(spacing: DS.S.sm) {
                ForEach(workers) { worker in
                    WorkerSlotPill(
                        id: worker.id,
                        state: state(worker.id),
                        namespace: pillSpace,
                        // ⚠ Pulses on BUSY, matching the web app's `animate-subtle-pulse`. It used
                        // to pulse only while a platform page was live, which went still in the
                        // gaps between platforms — a worker mid-run looking idle for minutes.
                        pulsing: activity(worker.id) == .busy,
                        // ⚠ Tap SELECTS here; in the People popup it rests the worker. Different
                        // verbs on one component — which is safe only because this card has no
                        // rest affordance at all, so there is nothing to confuse it with. A busy
                        // pill stays tappable for the same reason: looking at a run cannot hurt it.
                        onTap: { selected = worker.id },
                        // ⚠ A BUSY worker is never parked — a run in flight always finishes.
                        // Same rule as the People popup and as the web app, for the same reason:
                        // parking mid-run would either do nothing or orphan the run.
                        onLongPress: activity(worker.id) == .busy ? nil : {
                            onToggleRest?(worker.id, !restingWorkerIDs.contains(worker.id))
                        }
                    )
                    .accessibilityLabel("Worker \(worker.id), \(caption(worker.id))")
                    .accessibilityAddTraits(worker.id == selected ? [.isSelected] : [])
                }
            }
            // ⚠ ONE caption, for the selected worker, rather than one under every pill. Per-pill
            // captions are what made the old row bulky, and they answered a question nobody asks
            // about four workers at once — the card shows one worker's browser at a time.
            Text(
                onToggleRest == nil
                    ? "Worker \(selected) · \(caption(selected))"
                    // Long-press is not discoverable on its own, so the caption says it. It names
                    // the state AND the way to change it, in the one line that was already here.
                    : "Worker \(selected) · \(caption(selected)) · hold to "
                        + (restingWorkerIDs.contains(selected) ? "wake" : "rest")
            )
            .font(DS.F.mono(9))
            .foregroundStyle(tone(selected))
        }
    }

    private func state(_ id: Int) -> WorkerSlotPill.State {
        switch activity(id) {
        case .busy: return .busy
        case .resting: return .resting
        case .idle: return .ready
        }
    }

    private func activity(_ id: Int) -> WorkerActivity {
        .of(id, busy: busyWorkerIDs, resting: restingWorkerIDs)
    }

    func caption(_ id: Int) -> String {
        switch activity(id) {
        case .busy:
            // Name the phase when we have it. "busy" alone is what the People popup already says;
            // the point of this card is the extra detail.
            guard let run = runFor(id) else { return "busy" }
            return "P\(run.phase) · \(run.phaseName)"
        case .resting: return "resting"
        case .idle: return "idle"
        }
    }

    func tone(_ id: Int) -> Color {
        switch activity(id) {
        case .busy: return DS.C.accent
        case .resting: return DS.C.textTertiary
        // ⚠ The PILL's green, not the generic `ok` teal. This caption sits directly under the pill
        // it describes, so two greens a few percent apart read as a rendering fault rather than as
        // two different things — which is how it was reported.
        case .idle: return DS.C.worker
        }
    }
}

struct BrowserWatchCard: View {
    let snapshot: DeviceSnapshot
    let workers: [WorkerProfile]
    @Binding var selectedWorker: Int
    /// Republished by `AppModel` so a change redraws this card.
    ///
    /// ⚠ Unused in the body ON PURPOSE — it exists so SwiftUI re-evaluates when the run moves to
    /// another platform. `LiveRunActivity` is a plain core class with no Combine, so nothing else
    /// would tell this view to redraw and the glow would freeze on the first platform touched.
    var liveTick: Int = 0
    var liveActivity: LiveRunActivity = .shared
    /// Park or wake a worker from here, so the pill means the same thing on both surfaces.
    var onToggleRest: ((Int, Bool) -> Void)?
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                SectionLabel(text: "Browser watch")
                Spacer()
                Text(activity).font(DS.F.label).foregroundStyle(
                    selectedRun == nil ? DS.C.textTertiary : DS.C.accent
                )
            }

            // A grid rather than a list: four platforms read as a set of equals, and the whole point
            // is to compare them at a glance.
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: DS.S.md),
                          GridItem(.flexible(), spacing: DS.S.md)],
                spacing: DS.S.md
            ) {
                ForEach(snapshot.platforms) { platform in
                    let live = platform.id == livePlatform
                    Button { onOpen(platform.id) } label: {
                        HStack(spacing: DS.S.md) {
                            AgentIcon(id: platform.id, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(platform.name)
                                    .font(DS.F.label.weight(.medium))
                                    .foregroundStyle(DS.C.textPrimary)
                                Text(caption(for: platform))
                                    .font(DS.F.mono(9))
                                    .foregroundStyle(tone(for: platform))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(DS.S.md)
                        .frame(maxWidth: .infinity, minHeight: DS.S.touch, alignment: .leading)
                        // ⭐ **The tile the run is typing into right now.** This is the one question
                        // Browser watch exists to answer — *which tab do I open to see it happen* —
                        // and until now the card gave four identical tiles and no way to tell.
                        .background(live ? DS.C.accent.opacity(0.14) : DS.C.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(live ? DS.C.accent : DS.C.border, lineWidth: live ? 2 : 1)
                        )
                        // ⚠ A glow, not a jitter: the tile is a TAP TARGET, and a moving one is
                        // harder to hit. The pulsing lives on the worker dot, which nobody taps.
                        .shadow(color: live ? DS.C.accent.opacity(0.45) : .clear, radius: live ? 8 : 0)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // ⚠ Every worker, always — this used to be a MENU shown only when `workers.count > 1`.
            // Two things were wrong with that. A menu shows one worker at a time, so "watch the
            // browsers" could not answer "what is each worker doing right now" without tapping
            // through them one by one; and hiding it at one worker meant a device that had just
            // added a second had no visible sign of it here. A row shows all of them at once and
            // still selects, which is what the card is for.
            //
            // ⭐ **Below the platforms, not above them.** The platforms are what this card is for
            // looking at; the workers are the filter you reach for once you have seen something
            // worth switching. Putting the filter first made the eye start on a control rather
            // than on the content it controls.
            //
            // Still no Add: this card is for looking, not configuring.
            WorkerWatchStrip(
                workers: workers,
                selected: $selectedWorker,
                // ⛔ **UNIONED with what this process is running RIGHT NOW.**
                // `snapshot.busyWorkerIDs` is read from the device document and only refreshes on
                // the 20-second beat, so a pill could not start pulsing until up to a beat after
                // the run began — and a run that failed in twelve seconds never pulsed at all,
                // which is exactly what the owner reported on 2026-08-14. `LiveRunActivity` is
                // updated by the run itself, in-process, the instant it claims a worker.
                busyWorkerIDs: snapshot.busyWorkerIDs.union(liveActivity.runs.keys),
                restingWorkerIDs: snapshot.restingWorkerIDs,
                // Same precedence for the per-worker pills: this process knows first.
                runFor: { worker in
                    if let live = liveActivity.runState(forWorker: worker) {
                        return RunState(
                            researchTitle: live.title, phase: live.phase,
                            phaseName: DeviceSnapshot.phaseName(live.phase),
                            elapsedSeconds: live.elapsedSeconds, agents: [:],
                            startedAtMillis: live.startedAtMillis
                        )
                    }
                    return snapshot.run(forWorker: worker)
                },
                onToggleRest: onToggleRest
            )

            Text(snapshot.run == nil
                 ? "Nothing is running. Open any platform to check its session or sign in again."
                 : "Open a platform to watch the run drive it. Watching never interrupts it.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
        .srCard()
    }

    /// The platform the SELECTED worker is driving this second, or nil.
    ///
    /// ⚠ Reported by the run in this process, not read back from a document. `RunState.agents` is
    /// empty on the per-worker path and the document's `currentRun*` fields describe worker 1 only,
    /// so a glow driven off either would be blank on every other worker and stale on the first.
    private var livePlatform: String? { liveActivity.platform(forWorker: selectedWorker) }

    /// The SELECTED worker's run, not the device's.
    ///
    /// ⚠ `snapshot.run` comes from the device doc's `currentRun*` fields, which only worker-1
    /// maintains. Reading it here labelled every worker with worker 1's run — so with two runs in
    /// flight the card confidently described the wrong one.
    /// ⭐ **The live fact FIRST, the document second.** The document's `workers` map is republished
    /// once per 20-second beat, so reading it alone means the strip lags the start of a run and
    /// says "No runs live" for the whole gap between a run ending and the next publish — which is
    /// what the owner saw while ChatGPT was visibly still researching. This process is the one
    /// driving the run; asking Firestore what it is doing is a round trip for its own knowledge.
    private var selectedRun: RunState? {
        if let live = liveActivity.runState(forWorker: selectedWorker) {
            return RunState(
                researchTitle: live.title,
                phase: live.phase,
                phaseName: DeviceSnapshot.phaseName(live.phase),
                elapsedSeconds: live.elapsedSeconds,
                agents: [:],
                startedAtMillis: live.startedAtMillis
            )
        }
        return snapshot.run(forWorker: selectedWorker)
    }

    /// Says "No runs live" rather than rendering nothing, so an idle device reads as idle instead of
    /// as a card that failed to load.
    private var activity: String {
        guard let run = selectedRun else {
            // With several workers, name how many ARE busy — otherwise a device running two other
            // runs reads as completely idle just because the selected worker happens to be free.
            let busy = snapshot.busyWorkerIDs.count
            if busy > 0 && workers.count > 1 {
                return "idle · \(busy) of \(workers.count) busy"
            }
            return "No runs live"
        }
        return "P\(run.phase) · \(run.phaseName)"
    }

    /// This worker's jar, not the device-wide figure.
    ///
    /// ⚠ `snapshot.platforms` is the INTERSECTION across every worker, which is the right thing to
    /// publish to the frontend and the wrong thing to show here: the card names one worker, so
    /// showing a combined verdict under that name would say worker 2 is signed out when it is
    /// worker 3 that is. Falls back to the device figure only for a worker the registry has not
    /// loaded, where a combined answer beats no answer.
    private func loginState(for platform: PlatformState) -> Bool? {
        guard let worker = workers.first(where: { $0.id == selectedWorker }) else {
            return platform.signedIn
        }
        return worker.logins[platform.id]
    }

    private func caption(for platform: PlatformState) -> String {
        // Mid-run, what the run is doing on this platform is the more useful fact; between runs, the
        // login state is the only fact that matters.
        if let state = selectedRun?.agents[platform.id], !state.isEmpty { return state }
        return loginState(for: platform).map { $0 ? "signed in" : "signed out" } ?? "not checked"
    }

    private func tone(for platform: PlatformState) -> Color {
        if let state = selectedRun?.agents[platform.id], !state.isEmpty {
            return state == "done" ? DS.C.ok
                : state == "active" ? DS.C.accent : DS.C.textTertiary
        }
        return loginState(for: platform).map { $0 ? DS.C.ok : DS.C.warn } ?? DS.C.textTertiary
    }
}

// MARK: - People

/// Who can use this device, and what each of them is doing on it right now.
///
/// The owner plus everyone in `sharedWith`. Each tile carries live state derived from `workers` and
/// `queueOwners`, because "who has access" and "who is actually using it" are different questions and
/// the second is the one you ask when a device feels busy.
private struct PeopleCard: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                SectionLabel(text: "People")
                Spacer()
                Text("\(snapshot.users.count)")
                    .font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            }
            if snapshot.users.isEmpty {
                Text("No one else has access to this device.")
                    .font(DS.F.body).foregroundStyle(DS.C.textSecondary)
            }
            ForEach(snapshot.users) { user in
                PersonRow(user: user, activity: snapshot.activity(for: user.id))
            }
        }
        .srCard()
    }
}

private struct PersonRow: View {
    let user: ConnectedUser
    let activity: DeviceSnapshot.UserActivity

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.sm) {
            HStack {
                Circle().fill(dotColour).frame(width: 7, height: 7)
                Text(user.label)
                    .font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(user.isOwner ? "owner" : "shared")
                    .font(DS.F.label)
                    .foregroundStyle(user.isOwner ? DS.C.accent : DS.C.textTertiary)
            }
            // The live line. Present only when there is something to say — an idle person does not
            // need a row telling them so twice.
            switch activity {
            case .running(let title, let phase, let total):
                HStack(spacing: DS.S.md) {
                    Text("running").font(DS.F.label).foregroundStyle(DS.C.ok)
                    Text(title).font(DS.F.label).foregroundStyle(DS.C.textSecondary).lineLimit(1)
                    if let phase {
                        Text("P\(phase)" + (total.map { "/\($0)" } ?? ""))
                            .font(DS.F.mono(10)).foregroundStyle(DS.C.textTertiary)
                    }
                }
                .padding(.leading, DS.S.lg)
            case .queued(let position, let title):
                HStack(spacing: DS.S.md) {
                    Text("queued #\(position)").font(DS.F.label).foregroundStyle(DS.C.warn)
                    Text(title).font(DS.F.label).foregroundStyle(DS.C.textSecondary).lineLimit(1)
                }
                .padding(.leading, DS.S.lg)
            case .idle:
                EmptyView()
            }
        }
        .frame(minHeight: 28)
    }

    private var dotColour: Color {
        switch activity {
        case .running: return DS.C.ok
        case .queued: return DS.C.warn
        case .idle: return DS.C.textTertiary
        }
    }
}

// MARK: - Operation rows (used by SettingsSheet)

struct OperationRow: View {
    let op: Operation
    /// Overridden so a row can carry state in its title — Version becomes "Update available — x.y.z".
    var title: String? = nil
    let busy: Bool
    /// Nil when the operation is usable. Otherwise why it is not — see `Operation.requiresSupervised`.
    var unavailable: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.S.lg) {
                VStack(alignment: .leading, spacing: DS.S.xs) {
                    Text(title ?? op.title)
                        .font(DS.F.body)
                        .foregroundStyle(
                            op.risk == .destructive ? DS.C.danger
                                : (title != nil && title != op.title) ? DS.C.warn : DS.C.textPrimary
                        )
                    // The REASON, not just a greyed-out row. "Daemon loop" dimmed with no
                    // explanation is a control that looks broken; naming the toggle that governs it
                    // turns a dead end into an instruction.
                    Text(unavailable ?? op.summary)
                        .font(DS.F.label)
                        .foregroundStyle(unavailable == nil ? DS.C.textTertiary : DS.C.warn)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if busy {
                    ProgressView().scaleEffect(0.6).tint(DS.C.accent)
                } else if unavailable == nil {
                    Text("›").font(DS.F.body).foregroundStyle(DS.C.textTertiary)
                }
            }
            .frame(minHeight: DS.S.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil || busy)
        .opacity(unavailable == nil ? 1 : 0.55)
    }
}


// MARK: - Confirmation, toast, footer

struct ConfirmSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let op = model.pendingConfirm {
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { model.cancelConfirm() }
                VStack(alignment: .leading, spacing: DS.S.lg) {
                    Text(op.title).font(DS.F.title).foregroundStyle(DS.C.textPrimary)
                    Text(op.summary).font(DS.F.body).foregroundStyle(DS.C.textSecondary)
                    if op.risk == .destructive {
                        Text("This cannot be undone.")
                            .font(DS.F.label).foregroundStyle(DS.C.danger)
                    }
                    HStack(spacing: DS.S.lg) {
                        SRButton(title: "Cancel") { model.cancelConfirm() }
                        SRButton(
                            title: "Confirm",
                            role: op.risk == .destructive ? .destructive : .primary
                        ) { model.confirm() }
                    }
                }
                .padding(DS.S.screen)
                .background(DS.C.surface)
                .overlay(RoundedRectangle(cornerRadius: DS.R.md).stroke(DS.C.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
                .padding(DS.S.screen * 2)
            }
        }
    }
}

struct Toast: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text)
                .font(DS.F.label).foregroundStyle(DS.C.textPrimary)
                .padding(DS.S.lg)
                .background(DS.C.surface)
                .overlay(RoundedRectangle(cornerRadius: DS.R.sm).stroke(DS.C.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
                .padding(.bottom, DS.S.screen * 2)
                .transition(.opacity)
        }
    }
}

private struct Footer: View {
    let snapshot: DeviceSnapshot
    var body: some View {
        HStack {
            // ⚠ This used to read "bridge offline" on every screen, permanently — a status line for
            // a Mac-side control bridge that was never built. It reported a fault that did not
            // exist, on a device that is itself the backend. What is worth stating here is whether
            // this device is actually serving.
            Text(snapshot.online ? "serving" : "not serving")
                .font(DS.F.mono(9))
                .foregroundStyle(snapshot.online ? DS.C.ok : DS.C.textTertiary)
            Spacer()
            Text("iOS backend").font(DS.F.mono(9)).foregroundStyle(DS.C.textTertiary)
        }
    }
}


// MARK: - People (a button, not a list)

/// The People summary on the main screen: who, and how busy, in one row that opens the full sheet.
///
/// A button rather than an inline list because the interesting version of this information — every
/// worker slot, whose run each one is, what is queued behind it — does not fit on a glance screen, and
/// the web app already made the same call: a "Shared with N" pill that opens a popup.
struct PeopleButton: View {
    let snapshot: DeviceSnapshot
    let onOpen: () -> Void

    private var busyCount: Int { snapshot.workers.filter(\.isBusy).count }

    /// How many people are named before the card starts counting instead.
    ///
    /// ⚠ Three, so the card cannot grow without bound on a device shared widely — this is a glance
    /// screen, and the full list is one tap away in the sheet.
    static let namedRows = 3

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: DS.S.lg) {
                HStack {
                    SectionLabel(text: "People")
                    Spacer()
                    Text("›").font(DS.F.body).foregroundStyle(DS.C.textTertiary)
                }
                HStack(spacing: DS.S.sm) {
                    // The summary a glance needs: how many people, how much of the device is in use,
                    // and whether anything is waiting.
                    Pill(
                        text: snapshot.users.count == 1
                            ? "1 person" : "\(snapshot.users.count) people",
                        tone: .neutral
                    )
                    Pill(
                        text: "\(busyCount)/\(max(snapshot.workerCount, snapshot.workers.count)) busy",
                        tone: busyCount > 0 ? .ok : .neutral
                    )
                    if !snapshot.queue.isEmpty {
                        Pill(text: "\(snapshot.queue.count) queued", tone: .violet)
                    }
                    Spacer()
                }
                // ⭐ **Named ROWS, not a comma-joined line.** The people are the point of this
                // card and they were an 11pt tertiary string at the bottom of it — smaller and
                // fainter than the numbers above them, and unreadable at a glance on a 3x screen.
                // Rows with an avatar give each person the same presence a platform tile gets in
                // the card above, which is what makes the page look like one design rather than
                // two.
                if !snapshot.users.isEmpty {
                    VStack(alignment: .leading, spacing: DS.S.md) {
                        ForEach(snapshot.users.prefix(Self.namedRows)) { user in
                            HStack(spacing: DS.S.lg) {
                                PersonAvatar(user: user, size: 28)
                                Text(user.label)
                                    .font(DS.F.body)
                                    .foregroundStyle(DS.C.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(user.isResolved ? .tail : .middle)
                                Spacer(minLength: 0)
                            }
                        }
                        // ⚠ Counted rather than truncated into the last row. "+3 more" is a fact;
                        // a name cut off mid-word is a rendering accident that looks like one.
                        if snapshot.users.count > Self.namedRows {
                            Text("+\(snapshot.users.count - Self.namedRows) more")
                                .font(DS.F.label)
                                .foregroundStyle(DS.C.textTertiary)
                                .padding(.leading, 28 + DS.S.lg)
                        }
                    }
                }
            }
            .srCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
