import SwiftUI
import UIKit

/// The five-stage pairing flow, in the app, matching what `superresearch --pair` does in a terminal.
///
/// Parity is the requirement, so the stages, their order, their names and their semantics are taken
/// from the backend rather than invented:
///
/// | # | Stage      | What it does                                                     |
/// |---|------------|------------------------------------------------------------------|
/// | 1 | Pair       | pollSecret → server mints the code → claim → **atomic confirm**  |
/// | 2 | On Startup | ask, and mirror the intent to the device doc as `supervised`      |
/// | 3 | API keys   | Anthropic + Gemini, each independently skippable                  |
/// | 4 | Logins     | the four platforms — **partial or zero still completes the pair** |
/// | 5 | Ready      | arm per the On Startup choice; the device goes online             |
///
/// Three details that are easy to get wrong and are load-bearing:
///
/// * **Stage 2 only records the intent; stage 5 acts on it.** The backend defers arming for a reason —
///   a failure while arming must not strand a device that is otherwise correctly paired.
/// * **Stage 4 never blocks completion.** The backend says so explicitly: *"a stuck Stage-4 login must
///   not strand pairing… an armed backend just idles until a run needs a logged-in tab."* An app that
///   demanded four green ticks would be stricter than the product and would trap the user.
/// * **The whole arc is shown before stage 1 starts**, as the terminal does. Five prompts arriving one
///   at a time with no map is what makes a setup feel endless.
enum PairingStage: Int, CaseIterable, Identifiable {
    case pair = 1, onStartup, apiKeys, logins, ready

    var id: Int { rawValue }

    /// The terminal's own labels, so a user who has paired a Mac recognises this.
    var title: String {
        switch self {
        case .pair: return "Pair"
        case .onStartup: return "On Startup"
        case .apiKeys: return "API keys"
        case .logins: return "Logins"
        case .ready: return "Ready"
        }
    }

    var blurb: String {
        switch self {
        case .pair: return "Link this device to your account"
        case .onStartup: return "Come online automatically"
        case .apiKeys: return "Anthropic and Gemini — optional"
        case .logins: return "Sign in to each platform once"
        case .ready: return "Start serving runs"
        }
    }
}

@MainActor
final class PairingController: ObservableObject {
    @Published var stage: PairingStage = .pair
    @Published var started = false

    // Stage 1
    @Published var pairCode = ""
    @Published var deviceID = ""
    @Published var status = "Ready when you are."
    @Published var busy = false
    /// Seconds left in the five-minute confirm window, once the claim lands.
    @Published var confirmWindow: Int?

    // Stage 2
    @Published var onStartup = true

    // Stage 3 — presence only. The values go straight to the Keychain and are never held here.
    @Published var anthropicSaved = false
    @Published var geminiSaved = false

    // Stage 4
    @Published var loginState: [String: Bool] = [:]
    @Published var loginTarget: PlatformState?

    private let backend: DeviceBackend
    let platforms: [PlatformState]

    init(backend: DeviceBackend, platforms: [PlatformState]) {
        self.backend = backend
        self.platforms = platforms
    }

    // MARK: Stage 1

    func beginPairing() async {
        busy = true
        status = "Requesting a pair code…"
        let result = await backend.startPairing(
            onCode: { [weak self] code, id in
                Task { @MainActor in
                    self?.pairCode = code
                    self?.deviceID = id
                    self?.status = "Enter this code on the web app's Account page."
                }
            },
            onClaimed: { [weak self] in
                Task { @MainActor in
                    // Surfaced because the window is real and invisible otherwise: past five minutes
                    // the device document is TTL-deleted and pairing silently undoes itself.
                    self?.status = "Claimed — confirming before the 5-minute window closes…"
                }
            }
        )
        busy = false
        switch result {
        case .success:
            status = "Paired."
            advance()
        case .failure(let message):
            status = message
        }
    }

    /// Throw away this attempt and request a fresh code.
    ///
    /// Also clears any local identity: an interrupted flow can leave one for a device that was never
    /// confirmed, and heartbeating a document that does not exist gets nobody anywhere.
    func restart() async {
        backend.resetPairing()
        pairCode = ""
        deviceID = ""
        stage = .pair
        await beginPairing()
    }

    // MARK: Stage 2

    func chooseOnStartup(_ enabled: Bool) async {
        onStartup = enabled
        busy = true
        // Mirrored to the device doc immediately, exactly as the backend does, so the frontend's
        // Account-page toggle reflects the choice in real time. Best-effort: a failure here must not
        // block a pair that is otherwise complete.
        await backend.setSupervised(enabled)
        busy = false
        advance()
    }

    // MARK: Stage 3

    func saveKey(_ kind: APIKeyStore.Kind, _ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        APIKeyStore.save(kind, value)
        switch kind {
        case .anthropic: anthropicSaved = true
        case .gemini: geminiSaved = true
        }
    }

    // MARK: Stage 4

    func finishLogin(_ platform: PlatformState, signedIn: Bool) {
        loginState[platform.id] = signedIn
        loginTarget = nil
        // Reported to the device doc's `logins` map so the frontend shows the same per-platform state
        // the app does. Device-writable per the rules' synth allow-list.
        Task { await backend.reportLogins(loginState) }
    }

    // MARK: Stage 5

    func finish() async {
        busy = true
        // Arming happens HERE, not in stage 2 — deferred exactly as the backend defers it, so a failure
        // to arm cannot strand an otherwise-correct pair.
        await backend.goOnline(supervised: onStartup)
        busy = false
        stage = .ready
    }

    var signedInCount: Int { loginState.values.filter { $0 }.count }

    private func advance() {
        if let next = PairingStage(rawValue: stage.rawValue + 1) { stage = next }
    }
}

// MARK: - The view

struct PairingFlowView: View {
    @ObservedObject var controller: PairingController

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg * 2) {
            if !controller.started {
                arcPreview
            } else {
                stageHeader
                // Slides forward, because progress has a DIRECTION. A cross-fade would make stage 3
                // and stage 2 feel interchangeable, when the whole point of the [n/5] header is that
                // you are moving through something.
                Group {
                    switch controller.stage {
                    case .pair: pairStage
                    case .onStartup: onStartupStage
                    case .apiKeys: apiKeysStage
                    case .logins: loginsStage
                    case .ready: readyStage
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
                .id(controller.stage)
            }
        }
        // One spring for the whole flow, so every stage change and rail fill share a feel rather than
        // each easing differently.
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: controller.stage)
        .animation(.easeInOut(duration: 0.25), value: controller.started)
        .sheet(item: Binding(
            get: { controller.loginTarget },
            set: { if $0 == nil { controller.loginTarget = nil } }
        )) { platform in
            LoginFlowView(platform: platform, manifestMarker: nil) { signedIn in
                controller.finishLogin(platform, signedIn: signedIn)
            }
        }
    }

    /// The whole arc, before stage 1 — as the terminal prints it.
    ///
    /// Five prompts arriving one at a time with no map is what makes setup feel endless; the terminal
    /// shows the arc first for exactly that reason, so the app does too.
    private var arcPreview: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "Set up this device")
            Text("This iPhone becomes a Super Research backend — the same thing the desktop app is. Five steps, the same five the terminal walks through.")
                .font(DS.F.body).foregroundStyle(DS.C.textSecondary)

            VStack(alignment: .leading, spacing: DS.S.md) {
                ForEach(PairingStage.allCases) { stage in
                    HStack(alignment: .firstTextBaseline, spacing: DS.S.lg) {
                        Text("\(stage.rawValue)")
                            .font(DS.F.mono(11, .semibold))
                            .foregroundStyle(DS.C.textTertiary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stage.title)
                                .font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                            Text(stage.blurb)
                                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                        }
                    }
                }
            }

            SRButton(title: "Start", role: .primary) {
                controller.started = true
                Task { await controller.beginPairing() }
            }
        }
        .srCard()
    }

    private var stageHeader: some View {
        VStack(alignment: .leading, spacing: DS.S.sm) {
            HStack {
                Text("[\(controller.stage.rawValue)/5]")
                    .font(DS.F.mono(11, .semibold)).foregroundStyle(DS.C.accent)
                Text(controller.stage.title.uppercased())
                    .font(DS.F.mono(11, .semibold)).foregroundStyle(DS.C.textSecondary)
                Spacer()
            }
            // A rule per stage rather than a percentage: five discrete steps are what the user is
            // actually counting.
            HStack(spacing: DS.S.xs) {
                ForEach(PairingStage.allCases) { stage in
                    // Fills left to right as you advance — the rail IS the progress, so it should
                    // move rather than redraw.
                    Rectangle()
                        .fill(stage.rawValue <= controller.stage.rawValue ? DS.C.accent : DS.C.border)
                        .frame(height: 2)
                        .animation(
                            .easeOut(duration: 0.3).delay(Double(stage.rawValue) * 0.04),
                            value: controller.stage
                        )
                }
            }
        }
    }

    // MARK: Stage 1

    private var pairStage: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            if controller.pairCode.isEmpty {
                Text(controller.status).font(DS.F.body).foregroundStyle(DS.C.textSecondary)
                if controller.busy { ProgressView().tint(DS.C.accent) }
            } else {
                // Stacked, not side by side: sharing the row forced the QR down to 88pt, which is
                // small enough that a phone camera has to be held close and steady. Both elements
                // exist to be read off this screen, so both get the full width.
                VStack(spacing: DS.S.lg) {
                    VStack(spacing: DS.S.sm) {
                        Text(Pairing.formatForDisplay(controller.pairCode))
                            .font(DS.F.codeLarge)
                            .foregroundStyle(DS.C.terminal)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("Pair code").font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    }
                    QRView(code: controller.pairCode, side: 220)
                }
                .frame(maxWidth: .infinity)
                Text(controller.status).font(DS.F.label).foregroundStyle(DS.C.textSecondary)
                Text("Web app → Account → Add device. Or scan the code.")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                // An escape hatch, because a code can expire, a claim can go to the wrong account, or
                // the app can be interrupted mid-flow. Without it the only way out is deleting the app.
                Button { Task { await controller.restart() } } label: {
                    Text("Start over with a new code")
                        .font(DS.F.label).foregroundStyle(DS.C.accent)
                }
                .frame(minHeight: DS.S.touch)
            }
        }
        .srCard()
    }

    // MARK: Stage 2 — the answer to "how does startup work"

    private var onStartupStage: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            Text("Come online automatically?")
                .font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
            Text("With this on, the device reports itself online whenever the app is open, so the web app can fire runs at it without you doing anything here.")
                .font(DS.F.label).foregroundStyle(DS.C.textSecondary)
            // Stated rather than glossed: iOS will not launch an app by itself, and pretending
            // otherwise would have the user wondering why runs never start.
            Text("iOS cannot launch an app on its own, so the app does need to be open. On the Simulator you can have the Mac do it for you — see On Startup in Controls once you're paired.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)

            HStack(spacing: DS.S.lg) {
                SRButton(title: "Yes, enable", role: .primary) {
                    Task { await controller.chooseOnStartup(true) }
                }
                SRButton(title: "Skip") {
                    Task { await controller.chooseOnStartup(false) }
                }
            }
        }
        .srCard()
    }

    // MARK: Stage 3

    private var apiKeysStage: some View {
        APIKeysStageView(controller: controller)
    }

    // MARK: Stage 4

    private var loginsStage: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            Text("Sign in to each platform")
                .font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
            Text("Once each. The session persists across restarts, so this is a one-time job.")
                .font(DS.F.label).foregroundStyle(DS.C.textSecondary)

            ForEach(controller.platforms) { platform in
                Button { controller.loginTarget = platform } label: {
                    HStack {
                        AgentIcon(id: platform.id, size: 20)
                        Text(platform.name).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                        Spacer()
                        let state = controller.loginState[platform.id]
                        Text(state == true ? "signed in" : state == false ? "skipped" : "sign in")
                            .font(DS.F.label)
                            .foregroundStyle(
                                state == true ? DS.C.ok : state == false ? DS.C.warn : DS.C.accent
                            )
                        Text("›").font(DS.F.body).foregroundStyle(DS.C.textTertiary)
                    }
                    .frame(minHeight: DS.S.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // ⚠ Always available, whatever the login count. The backend is explicit that partial or
            // zero logins still complete the pair — a stuck login must not strand the device. An app
            // that required four ticks would be stricter than the product.
            SRButton(
                title: controller.signedInCount == controller.platforms.count
                    ? "Continue" : "Continue without the rest",
                role: .primary
            ) {
                Task { await controller.finish() }
            }
            if controller.signedInCount < controller.platforms.count {
                Text("You can sign the others in later. A run only needs the platforms it uses.")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            }
        }
        .srCard()
    }

    // MARK: Stage 5

    private var readyStage: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack(spacing: DS.S.md) {
                Text("✓").font(DS.F.body.weight(.semibold)).foregroundStyle(DS.C.ok)
                Text("Paired and online").font(DS.F.body.weight(.medium))
                    .foregroundStyle(DS.C.textPrimary)
            }
            VStack(alignment: .leading, spacing: DS.S.sm) {
                summary("Device", controller.deviceID.isEmpty ? "—" : controller.deviceID)
                summary("On Startup", controller.onStartup ? "enabled" : "off")
                summary(
                    "Platforms",
                    "\(controller.signedInCount)/\(controller.platforms.count) signed in"
                )
                summary(
                    "API keys",
                    [controller.anthropicSaved ? "Anthropic" : nil,
                     controller.geminiSaved ? "Gemini" : nil]
                        .compactMap { $0 }.joined(separator: ", ").ifEmpty("none")
                )
            }
            Text("The web app can fire runs at this device while the app is open.")
                .font(DS.F.label).foregroundStyle(DS.C.textSecondary)
        }
        .srCard()
    }

    private func summary(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            Spacer()
            Text(value).font(DS.F.mono(11)).foregroundStyle(DS.C.textPrimary)
        }
    }
}

/// Stage 3, split out because a `SecureField` needs its own local state.
private struct APIKeysStageView: View {
    @ObservedObject var controller: PairingController
    @State private var anthropic = ""
    @State private var gemini = ""
    @State private var revealAnthropic = false
    @State private var revealGemini = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            Text("API keys")
                .font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
            Text("Both optional and independently skippable, as in the terminal. Anthropic powers the supervisor that keeps runs alive when a platform's UI changes; Gemini is used for some research paths.")
                .font(DS.F.label).foregroundStyle(DS.C.textSecondary)

            keyRow("Anthropic", placeholder: "sk-ant-…", text: $anthropic,
                   saved: controller.anthropicSaved, kind: .anthropic, revealed: $revealAnthropic)
            keyRow("Gemini", placeholder: "AIza…", text: $gemini,
                   saved: controller.geminiSaved, kind: .gemini, revealed: $revealGemini)

            // Stored in the Keychain with kSecAttrAccessibleAfterFirstUnlock, not UserDefaults: a
            // plist in the app container is readable by anything that can read the container and is
            // included in unencrypted backups.
            Text("Stored in the device Keychain. Never written to a file or sent anywhere but the API.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)

            SRButton(title: "Continue", role: .primary) {
                controller.saveKey(.anthropic, anthropic)
                controller.saveKey(.gemini, gemini)
                anthropic = ""; gemini = ""       // cleared from memory once handed to the Keychain
                Task { await MainActor.run { controller.stage = .logins } }
            }
        }
        .srCard()
    }

    private func keyRow(
        _ name: String, placeholder: String, text: Binding<String>, saved: Bool,
        kind: APIKeyStore.Kind, revealed: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.S.sm) {
            HStack {
                Text(name).font(DS.F.label).foregroundStyle(DS.C.textSecondary)
                Spacer()
                if saved || APIKeyStore.has(kind) {
                    Text("saved").font(DS.F.label).foregroundStyle(DS.C.ok)
                }
            }
            HStack(spacing: DS.S.md) {
                // ⚠ A plain `TextField` with `isSecure` styling rather than `SecureField`, plus an
                // explicit Paste button.
                //
                // `SecureField` suppresses the system paste affordance in ways that bite hardest
                // exactly here: an API key is far too long to type, the Simulator's long-press menu is
                // unreliable, and iOS blocks programmatic pasteboard reads that the user did not
                // initiate. So the paste is made an explicit, user-initiated tap — which is both the
                // supported path and the one that actually works on a Simulator.
                Group {
                    if revealed.wrappedValue {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)   // stops iOS offering to autofill something unrelated
                .font(DS.F.mono(12))
                .foregroundStyle(DS.C.textPrimary)

                Button { revealed.wrappedValue.toggle() } label: {
                    Text(revealed.wrappedValue ? "hide" : "show")
                        .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                }
                Button {
                    // User-initiated, so iOS permits the read without a prompt loop.
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        text.wrappedValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Text("Paste").font(DS.F.label.weight(.medium)).foregroundStyle(DS.C.accent)
                }
            }
            .padding(DS.S.md)
            .background(DS.C.bg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.C.border, lineWidth: 1))
            .frame(minHeight: DS.S.touch)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
