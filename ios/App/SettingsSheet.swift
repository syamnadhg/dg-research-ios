import SwiftUI

/// Everything you set once, off the main screen.
///
/// The main screen is something you **glance** at — is it up, what is it doing, who for. A fifteen-item
/// operations list on the same screen buries all three of those answers under things you touch once a
/// month, so they live here.
///
/// Sections follow the operation registry's **own** `group` field (`Operations.groups`: Pairing, Runtime,
/// Maintenance, Platforms) rather than a grouping invented for this screen. That matters for two
/// reasons: the registry's grouping is the one the backend already uses, and a category list derived
/// from the data cannot drift from the data.
///
/// Two things are surfaced above the operations because they are *state*, not actions: On Startup (the
/// `supervised` flag the frontend's Account toggle reads) and which API keys are present.
struct SettingsSheet: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @State private var loginTarget: PlatformState?
    /// Seeded from the device doc in `onAppear`, not defaulted to on. A toggle that shows the wrong
    /// state is worse than no toggle: it invites a tap that writes the value it was already showing.
    @State private var onStartup = false
    @State private var expanded: Set<String> = ["Platforms"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.lg * 2) {
                    appearanceSection
                    deviceSection
                    startupSection
                    keysSection
                    platformsSection
                    operationSections
                }
                .padding(DS.S.screen)
            }
        }
        .background(DS.C.bg)
        .sheet(item: $loginTarget) { platform in
            LoginFlowView(platform: platform, manifestMarker: nil) { _ in
                loginTarget = nil
                Task { await model.refresh() }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Settings").font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
            Spacer()
            Button(action: onClose) {
                Text("Done").font(DS.F.label).foregroundStyle(DS.C.accent)
            }
            .frame(minWidth: DS.S.touch, minHeight: DS.S.touch)
        }
        .padding(.horizontal, DS.S.screen)
        .padding(.vertical, DS.S.lg)
        .background(DS.C.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border).frame(height: 1) }
    }

    /// The theme control, in the app's settings — one of the two places the web app offers it.
    private var appearanceSection: some View {
        Section(title: "Appearance") {
            ThemeToggle(theme: theme)
            Text("Follows the system unless you choose. Defaults to dark, since the rest of the product's signed-in surface is.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
    }

    // MARK: - State, not actions

    private var deviceSection: some View {
        Section(title: "This device") {
            row("Device ID", model.snapshot.deviceID.isEmpty ? "—" : model.snapshot.deviceID)
            row("Backend", model.snapshot.backendVersion.isEmpty
                ? "—" : model.snapshot.backendVersion)
            if let newer = model.snapshot.updateAvailable {
                // Surfaced, not acted on: updating is a Mac operation, and the button for it is in
                // Maintenance below with its scope honestly labelled.
                HStack {
                    Text("Update available").font(DS.F.label).foregroundStyle(DS.C.warn)
                    Spacer()
                    Pill(text: newer, tone: .violet)
                }
            }
            row("Workers", "\(model.snapshot.busyWorkers)/\(model.snapshot.workerCount)")
        }
    }

    private var startupSection: some View {
        Section(title: "On Startup") {
            Toggle(isOn: $onStartup) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Come online automatically")
                        .font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                    Text("Reports this device online whenever the app is open.")
                        .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                }
            }
            .tint(DS.C.accent)
            .onAppear { onStartup = model.snapshot.supervised }
            .onChange(of: onStartup) { _, value in
                // Mirrored to the device doc, so the frontend's Account-page toggle matches. Same field
                // the terminal's stage 2 writes.
                Task { await model.setSupervised(value) }
            }
            Text("iOS cannot launch an app on its own, so the app does need to be open. The display is kept awake while it is.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
    }

    private var keysSection: some View {
        Section(title: "API keys") {
            keyRow("Anthropic", present: APIKeyStore.has(.anthropic))
            keyRow("Gemini", present: APIKeyStore.has(.gemini))
            Text("Stored in the device Keychain. Values are never displayed — a key on screen is a key in a screenshot.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
    }

    private func keyRow(_ name: String, present: Bool) -> some View {
        HStack {
            Text(name).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
            Spacer()
            Pill(text: present ? "saved" : "not set", tone: present ? .ok : .neutral)
        }
        .frame(minHeight: 30)
    }

    private var platformsSection: some View {
        Section(title: "Platform logins") {
            ForEach(model.snapshot.platforms) { platform in
                Button { loginTarget = platform } label: {
                    HStack {
                        AgentIcon(id: platform.id, size: 20)
                        Text(platform.name).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                        Spacer()
                        // Three states. "Unknown" is rendered as unknown rather than as "not signed
                        // in" — claiming a platform is signed out when nobody has checked sends the
                        // owner to redo a login they may not need.
                        Pill(
                            text: platform.signedIn.map { $0 ? "signed in" : "signed out" }
                                ?? "not checked",
                            tone: platform.signedIn.map { $0 ? .ok : .violet } ?? .neutral
                        )
                        Text("›").font(DS.F.body).foregroundStyle(DS.C.textTertiary)
                    }
                    .frame(minHeight: DS.S.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Operations, grouped by the registry's own taxonomy

    private var operationSections: some View {
        VStack(alignment: .leading, spacing: DS.S.lg * 2) {
            ForEach(Operations.groups.filter { $0 != "Platforms" }, id: \.self) { group in
                CollapsibleSection(
                    title: group,
                    isExpanded: expanded.contains(group),
                    onToggle: {
                        // Collapsed by default. These are month-scale actions, and a list of fifteen
                        // open rows is how you scroll past the two you came for.
                        if expanded.contains(group) { expanded.remove(group) }
                        else { expanded.insert(group) }
                    }
                ) {
                    ForEach(Operations.inGroup(group)) { op in
                        OperationRow(op: op, busy: model.busyOpID == op.id) {
                            model.invoke(op)
                        }
                    }
                    if group != "Pairing" {
                        BridgeNotice(reachable: model.snapshot.bridgeReachable)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            Spacer()
            Text(value).font(DS.F.mono(11)).foregroundStyle(DS.C.textPrimary)
        }
        .frame(minHeight: 26)
    }
}

/// A plain titled group.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: title)
            content
        }
        .padding(DS.S.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border, lineWidth: 1))
    }
}

/// A group that opens and closes, so a long operations list is scannable.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            Button(action: onToggle) {
                HStack {
                    SectionLabel(text: title)
                    Spacer()
                    // Rotation rather than two glyphs: the chevron turning IS the state change, so the
                    // control and its feedback are the same object.
                    // Rotation rather than two glyphs: the chevron turning IS the state change, so
                    // the control and its feedback are one object.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.C.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(minHeight: DS.S.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    // Grows the card open rather than popping content in, so the sections below slide
                    // down with it and nothing jumps.
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isExpanded)
        .padding(DS.S.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border, lineWidth: 1))
    }
}
