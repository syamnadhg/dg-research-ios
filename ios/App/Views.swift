import CoreImage
import SwiftUI

// MARK: - Root

struct RootView: View {
    @StateObject var model: AppModel

    /// Which platform's login sheet is open, if any.
    @State private var loginTarget: PlatformState?
    /// Whether the live browser view is up, and which platform it is showing.
    @State private var watching = false
    @State private var watchSelection = "chatgpt"

    var body: some View {
        ZStack {
            DS.C.bg.ignoresSafeArea()
            // The landing page owns the whole screen, so it sits outside the dashboard's scroll view
            // and header rather than being squeezed into a card.
            if !model.snapshot.paired, model.screen == .landing, model.pairing != nil {
                LandingView { model.screen = .notPaired }
            } else if !model.snapshot.paired, model.screen == .notPaired, model.pairing != nil {
                VStack(spacing: 0) {
                    Header(snapshot: model.snapshot).padding(DS.S.screen)
                    NotPairedView { model.screen = .pairing }
                }
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.lg * 2) {
                    Header(snapshot: model.snapshot)
                    if model.snapshot.paired {
                        StatusCard(snapshot: model.snapshot)
                        if let run = model.snapshot.run {
                            RunCard(run: run, onWatch: { watching = true })
                        }
                        PlatformsCard(
                            platforms: model.snapshot.platforms,
                            model: model,
                            onSelect: { loginTarget = $0 }
                        )
                        WorkersCard(snapshot: model.snapshot)
                        PeopleCard(snapshot: model.snapshot)
                        ControlsCard(model: model)
                    } else if let pairing = model.pairing {
                        // The five-stage flow, matching `superresearch --pair` stage for stage. It
                        // replaces the old three-bullet card, which described the steps without
                        // walking anyone through them.
                        PairingFlowView(controller: pairing)
                    } else {
                        // Only reachable on the preview backend, which has nothing to pair against.
                        Text("No Firebase configuration bundled — running in preview mode.")
                            .font(DS.F.body).foregroundStyle(DS.C.textSecondary).srCard()
                    }
                    Footer(snapshot: model.snapshot)
                }
                .padding(DS.S.screen)
            }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.refresh() }
        .overlay(alignment: .bottom) { Toast(text: model.toast) }
        .overlay { ConfirmSheet(model: model) }
        .sheet(item: $loginTarget) { p in
            LoginFlowView(platform: p, manifestMarker: nil) { _ in
                loginTarget = nil
                Task { await model.refresh() }
            }
        }
        // Full screen rather than a sheet: this is the page being automated, and a sheet's inset
        // would crop exactly the part of it worth watching.
        .fullScreenCover(isPresented: $watching) {
            if let run = model.snapshot.run {
                LiveRunView(
                    run: run,
                    platforms: model.snapshot.platforms,
                    selected: $watchSelection,
                    onClose: { watching = false }
                )
            }
        }
    }
}

/// The wordmark, matching the web app's own.
///
/// The frontend renders it `text-2xl font-bold text-accent`, centered — so 24pt, bold, and in the
/// accent blue rather than white. It was left-aligned in white here, which is a different brand.
/// The wordmark, in the frontend's own two tones.
///
/// ⚠ Not one colour. The web app renders it as `<span class="text-accent font-bold">Super</span>` then
/// `<span class="text-text-secondary font-medium">Research</span>` — so **Super** is accent and bold,
/// **Research** is secondary and medium. Painting the whole thing accent, as the first version did, is
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
    var body: some View {
        VStack(spacing: DS.S.md) {
            Wordmark(size: 24)
            if snapshot.paired {
                StatusPill(
                    color: snapshot.online ? DS.C.ok : DS.C.textTertiary,
                    text: snapshot.online ? "Online" : "Offline"
                )
            } else {
                StatusPill(color: DS.C.warn, text: "Not paired")
            }
        }
        .frame(maxWidth: .infinity)
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
            Text(glyph)
                .font(DS.F.mono(12, .semibold))
                .foregroundStyle(state == "pending" ? DS.C.textTertiary : DS.C.platform(key))
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

// MARK: - Controls (full terminal parity)

private struct ControlsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "Backend controls")

            if !model.snapshot.bridgeReachable {
                // Said plainly and up front. A control that silently does nothing is worse than one
                // that is visibly unavailable, and these act on the Mac — not on the phone.
                BridgeNotice()
            }

            ForEach(Operations.groups, id: \.self) { group in
                let ops = Operations.inGroup(group).filter { $0.id != "pair" && $0.id != "login" }
                if !ops.isEmpty {
                    Text(group).font(DS.F.label).foregroundStyle(DS.C.textSecondary)
                    ForEach(ops) { op in
                        OpRow(op: op, model: model)
                    }
                }
            }
        }
        .srCard()
    }
}

private struct BridgeNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.S.lg) {
            Text("!")
                .font(DS.F.mono(11, .semibold)).foregroundStyle(DS.C.warn)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(DS.C.warn, lineWidth: 1))
            Text("The Mac bridge is not running. Actions marked **mac** will be queued, not executed.")
                .font(DS.F.label).foregroundStyle(DS.C.textSecondary)
        }
        .padding(DS.S.lg)
        .background(DS.C.warn.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
    }
}

private struct OpRow: View {
    let op: Operation
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.invoke(op) } label: {
            HStack(spacing: DS.S.lg) {
                VStack(alignment: .leading, spacing: DS.S.xs) {
                    HStack(spacing: DS.S.md) {
                        Text(op.title)
                            .font(DS.F.body)
                            .foregroundStyle(op.risk == .destructive ? DS.C.danger : DS.C.textPrimary)
                        if op.scope == .daemon { ScopeTag() }
                    }
                    Text(op.summary)
                        .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if model.busyOpID == op.id {
                    ProgressView().scaleEffect(0.6).tint(DS.C.accent)
                } else {
                    Text("›").font(DS.F.body).foregroundStyle(DS.C.textTertiary)
                }
            }
            .frame(minHeight: DS.S.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busyOpID != nil)
    }
}

/// Marks an action that runs on the Mac rather than the phone. Present because the distinction is
/// invisible otherwise, and a user who taps "Restart" deserves to know what is being restarted.
private struct ScopeTag: View {
    var body: some View {
        Text("mac")
            .font(DS.F.mono(9, .semibold))
            .foregroundStyle(DS.C.textTertiary)
            .padding(.horizontal, DS.S.sm)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(DS.C.border, lineWidth: 1))
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
            Text(snapshot.bridgeReachable ? "bridge connected" : "bridge offline")
                .font(DS.F.mono(9))
                .foregroundStyle(snapshot.bridgeReachable ? DS.C.ok : DS.C.textTertiary)
            Spacer()
            Text("iOS backend").font(DS.F.mono(9)).foregroundStyle(DS.C.textTertiary)
        }
    }
}
