import CoreImage
import SwiftUI

// MARK: - Root

struct RootView: View {
    @StateObject var model: AppModel
    @ObservedObject var theme: ThemeManager

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
                                selectedWorker: $watchWorker
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
        .overlay(alignment: .bottom) { Toast(text: model.toast) }
        .overlay { ConfirmSheet(model: model) }
        .sheet(item: Binding(
            get: { model.opDetail },
            set: { if $0 == nil { model.opDetail = nil } }
        )) { detail in
            OpDetailSheet(title: detail.title, body_: detail.body) { model.opDetail = nil }
        }
        .sheet(isPresented: $settingsOpen) {
            SettingsSheet(theme: theme, model: model, onClose: { settingsOpen = false })
        }
        // An overlay rather than a `.sheet`: a sheet brings its own full-height chrome and grabber,
        // and the frontend's equivalent is a bottom-anchored card floating over a blurred backdrop.
        .overlay {
            if peopleOpen {
                PeoplePopup(
                    snapshot: model.snapshot,
                    onToggleRest: { id, resting in model.setWorkerResting(id, resting: resting) },
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
                run: model.snapshot.run,
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

            // The pair code in mono at display size, hyphenated — it exists to be read off this
            // screen and typed into another, so legibility is the entire requirement.
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
                        .foregroundStyle(worker.isBusy ? DS.C.ok : DS.C.textTertiary)
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
struct BrowserWatchCard: View {
    let snapshot: DeviceSnapshot
    let workers: [WorkerProfile]
    @Binding var selectedWorker: Int
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                SectionLabel(text: "Browser watch")
                Spacer()
                Text(activity).font(DS.F.label).foregroundStyle(
                    snapshot.run == nil ? DS.C.textTertiary : DS.C.accent
                )
            }

            // Only when there is a choice to make. One worker plus a picker offering one option is
            // furniture that asks a question with a single answer. Adding workers belongs in
            // Settings and in the pair flow, not here — this card is for looking, not configuring.
            if workers.count > 1 {
                WorkerPicker(
                    workers: workers,
                    selected: $selectedWorker,
                    busyWorkerIDs: snapshot.busyWorkerIDs,
                    onAdd: {}
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
                        .background(DS.C.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(DS.C.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(snapshot.run == nil
                 ? "Nothing is running. Open any platform to check its session or sign in again."
                 : "Open a platform to watch the run drive it. Watching never interrupts it.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
        .srCard()
    }

    /// Says "No runs live" rather than rendering nothing, so an idle device reads as idle instead of
    /// as a card that failed to load.
    private var activity: String {
        guard let run = snapshot.run else { return "No runs live" }
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
        if let state = snapshot.run?.agents[platform.id] { return state }
        return loginState(for: platform).map { $0 ? "signed in" : "signed out" } ?? "not checked"
    }

    private func tone(for platform: PlatformState) -> Color {
        if let state = snapshot.run?.agents[platform.id] {
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
    let busy: Bool
    /// Nil when the operation is usable. Otherwise why it is not — see `Operation.requiresSupervised`.
    var unavailable: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.S.lg) {
                VStack(alignment: .leading, spacing: DS.S.xs) {
                    Text(op.title)
                        .font(DS.F.body)
                        .foregroundStyle(op.risk == .destructive ? DS.C.danger : DS.C.textPrimary)
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

private struct ConfirmSheet: View {
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

private struct Toast: View {
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
                // Named faces, so the card is not purely numeric — the point of it is the people.
                if !snapshot.users.isEmpty {
                    Text(snapshot.users.map(\.label).joined(separator: ", "))
                        .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .srCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
