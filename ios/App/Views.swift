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
                        UsersCard(users: model.snapshot.users)
                        ControlsCard(model: model)
                    } else {
                        OnboardingCard(model: model)
                        PlatformsCard(
                            platforms: model.snapshot.platforms,
                            model: model,
                            onSelect: { loginTarget = $0 }
                        )
                    }
                    Footer(snapshot: model.snapshot)
                }
                .padding(DS.S.screen)
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

private struct Header: View {
    let snapshot: DeviceSnapshot
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Super Research").font(DS.F.title).foregroundStyle(DS.C.textPrimary)
            Spacer()
            if snapshot.paired {
                StatusPill(
                    color: snapshot.online ? DS.C.ok : DS.C.textTertiary,
                    text: snapshot.online ? "Online" : "Offline"
                )
            } else {
                StatusPill(color: DS.C.warn, text: "Not paired")
            }
        }
    }
}

// MARK: - Onboarding (the first-run path the owner asked about)

private struct OnboardingCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "Set up this device")
            Text("This device becomes a Super Research backend. Pair it, then fire research at it from the web app or the chat agent.")
                .font(DS.F.body).foregroundStyle(DS.C.textSecondary)

            // Ordered, numbered, and honest about which steps are not ours to do. An onboarding
            // that hides the human steps just moves the confusion to the moment they are needed.
            VStack(alignment: .leading, spacing: DS.S.md) {
                Step(n: 1, text: "Get a pair code", done: false)
                Step(n: 2, text: "Enter it on the web app's Account page", done: false)
                Step(n: 3, text: "Sign in to each platform once", done: false)
            }

            SRButton(title: "Get pair code", role: .primary) {
                model.invoke(Operations.byID("pair")!)
            }
        }
        .srCard()
    }
}

private struct Step: View {
    let n: Int
    let text: String
    let done: Bool
    var body: some View {
        HStack(spacing: DS.S.lg) {
            Text("\(n)")
                .font(DS.F.mono(11, .semibold))
                .foregroundStyle(done ? DS.C.ok : DS.C.textTertiary)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(done ? DS.C.ok : DS.C.border, lineWidth: 1))
            Text(text).font(DS.F.body).foregroundStyle(DS.C.textSecondary)
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
private struct QRView: View {
    let code: String

    var body: some View {
        Group {
            if let image = qr {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)           // nearest-neighbour; smoothing kills the scan
                    .frame(width: 88, height: 88)
                    .padding(DS.S.md)
                    .background(Color.white)        // quiet zone: scanners need the light margin
                    .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
            } else {
                RoundedRectangle(cornerRadius: DS.R.sm)
                    .stroke(DS.C.border, lineWidth: 1)
                    .frame(width: 100, height: 100)
            }
        }
    }

    private var qr: CGImage? {
        guard !code.isEmpty,
              let ci = try? QRCode.imageForPairCode(code, baseURL: "https://app.superresearch.dev")
        else { return nil }
        let scale = QRCode.integerScale(for: ci.extent.width, targetPoints: 88)
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

// MARK: - Connected users

private struct UsersCard: View {
    let users: [ConnectedUser]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                SectionLabel(text: "Connected")
                Spacer()
                Text("\(users.count)").font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            }
            if users.isEmpty {
                Text("No one else has access to this device.")
                    .font(DS.F.body).foregroundStyle(DS.C.textSecondary)
            }
            ForEach(users) { u in
                HStack {
                    Text(u.email)
                        .font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(u.isOwner ? "owner" : "shared")
                        .font(DS.F.label)
                        .foregroundStyle(u.isOwner ? DS.C.accent : DS.C.textTertiary)
                }
                .frame(minHeight: 28)
            }
        }
        .srCard()
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
