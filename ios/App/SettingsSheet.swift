import SwiftUI

/// Everything you set once, off the main screen.
///
/// The main screen is something you **glance** at — is it up, what is it doing, who for. A fifteen-item
/// operations list on the same screen buries all three of those answers under things you touch once a
/// month, so they live here.
///
/// Sections follow the operation registry's **own** `group` field rather than a grouping invented
/// for this screen, so a category list cannot drift from the data. There is one group now: Runtime
/// absorbed Maintenance, because splitting them put Restart and Reset in different sections despite
/// being the same kind of act on the same loop.
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
    /// ⚠ Runtime opens by default. It was collapsed when there were several groups and a long
    /// list; now that Maintenance is folded in there is exactly ONE group, and collapsing it means
    /// a Settings page whose entire operations section is a single closed row. API keys stay shut —
    /// those really are set-once.
    @State private var expanded: Set<String> = ["Runtime"]
    /// Which worker's logins the Workers tile is showing.
    @State private var selectedWorker = 1
    /// Which API key is being added or replaced.
    @State private var editingKey: APIKeyStore.Kind?
    /// Bumped after a key is written, purely to force the presence pills to re-read the Keychain.
    @State private var keyEpoch = 0
    /// The live supervisor view. Daemon loop is a thing you WATCH, not a one-shot.
    @State private var daemonOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.lg * 2) {
                    appearanceSection
                    deviceSection
                    startupSection
                    // Workers before API keys — owner request. Workers is the section you open to
                    // add a browser profile or fix a login, which is a far more frequent visit than
                    // pasting a key.
                    workersSection
                    keysSection
                    operationSections
                }
                .padding(DS.S.screen)
            }
        }
        .background(DS.C.bg)
        // ⚠ The sheet declares its OWN color scheme. `.preferredColorScheme` applies to the nearest
        // enclosing PRESENTATION, and a `.sheet` is a new one — so RootView's copy styled the root
        // window and never reached here. The palette resolves off the UIKit trait
        // (`DS.C.dyn` reads `traits.userInterfaceStyle`), which only flips where a hosting
        // controller has an override installed. That is why the theme looked stuck until Settings
        // was closed and reopened: reopening re-presented it, inheriting the by-then-current trait.
        .preferredColorScheme(theme.choice.colorScheme)
        // ⚠ Rendered HERE, not on RootView. UIKit stacks a presented sheet above the presenter's
        // entire view, so the root's copies of these sat underneath this page: the Restart
        // confirmation was unreachable, and every toast raised from Settings was invisible.
        .overlay { ConfirmSheet(model: model) }
        .overlay(alignment: .bottom) { Toast(text: model.toast) }
        // ⚠ Likewise the detail sheet. It used to live on RootView — which is already presenting
        // THIS sheet — and a view controller can only present one modal, so Doctor, Version and
        // Diagnostics set `opDetail` and nothing ever appeared. Those three are reachable only from
        // this screen, so this is where the sheet belongs.
        .sheet(item: Binding(
            get: { model.opDetail },
            set: { if $0 == nil { model.opDetail = nil } }
        )) { detail in
            OpDetailSheet(title: detail.title, body_: detail.body) { model.opDetail = nil }
                .preferredColorScheme(theme.choice.colorScheme)
        }
        .sheet(item: $loginTarget) { platform in
            LoginFlowView(
                platform: platform, manifestMarker: nil, workerID: selectedWorker
            ) { signedIn in
                loginTarget = nil
                // Recorded against the worker whose jar was actually used — not the device — then
                // republished as the intersection across every worker.
                Task {
                    await model.reportLogin(
                        platform: platform.id, signedIn: signedIn, worker: selectedWorker
                    )
                    await model.refresh()
                }
            }
        }
        .sheet(isPresented: $daemonOpen) {
            DaemonLoopView(model: model) { daemonOpen = false }
                .preferredColorScheme(theme.choice.colorScheme)
        }
        .sheet(item: $editingKey) { kind in
            APIKeyEditor(kind: kind) {
                editingKey = nil
                keyEpoch += 1
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
            Text("Defaults to dark, since the rest of the product's signed-in surface is.")
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
                // Surfaced here as state; the Version row in Runtime below is where you act on it,
                // and its title carries the same signal so the list shows it without being opened.
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

    /// ⚠ Editable, which it was not. The rows reported presence and nothing else, so a key that had
    /// rotated could be *seen* to be stale and not replaced from anywhere in the app — the only route
    /// was Clear state, which also destroys the pairing.
    ///
    /// The no-display rule is kept: the editor writes a new value, it never reads the old one back.
    private var keysSection: some View {
        // Collapsible, like the operation groups — owner request. Keys are set once and then only
        // touched when one rotates, so an always-open section costs scroll on every visit.
        CollapsibleSection(
            title: "API keys",
            isExpanded: expanded.contains("API keys"),
            onToggle: { toggle("API keys") }
        ) {
            keyRow("Anthropic", kind: .anthropic)
            keyRow("Gemini", kind: .gemini)
            Text("Stored in the device Keychain. Values are never shown again once saved — a key on screen is a key in a screenshot — so replacing one means pasting it again.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
    }

    private func keyRow(_ name: String, kind: APIKeyStore.Kind) -> some View {
        // `keyEpoch` is what forces the presence pill to re-read the Keychain after an edit.
        // `APIKeyStore.has` is not observable, so without it a key saved in the sheet still showed
        // "not set" until the whole screen was rebuilt.
        let present = keyEpoch >= 0 && APIKeyStore.has(kind)
        return Button { editingKey = kind } label: {
            HStack {
                Text(name).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                Spacer()
                Pill(text: present ? "saved" : "not set", tone: present ? .ok : .neutral)
                Text(present ? "replace ›" : "add ›")
                    .font(DS.F.label).foregroundStyle(DS.C.accent)
            }
            .frame(minHeight: DS.S.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Workers, with each worker's platform logins folded inside it.
    ///
    /// ⚠ This replaced a flat "Platform logins" list, which could only ever describe ONE browser
    /// profile — and silently described the device as a whole while actually showing worker 1. With
    /// more than one profile that list was not just incomplete, it was wrong.
    private var workersSection: some View {
        Section(title: "Workers") {
            WorkerPicker(
                workers: model.workers,
                selected: $selectedWorker,
                busyWorkerIDs: model.snapshot.busyWorkerIDs,
                onAdd: {
                    if let added = model.addWorker() { selectedWorker = added.id }
                },
                onRemove: { id in
                    if model.removeWorker(id: id) == nil {
                        selectedWorker = model.workers.last?.id ?? 1
                    }
                }
            )
            WorkerExplainer()

            Divider().background(DS.C.border)

            Text("Platform logins for \(WorkerPicker.name(selectedWorker))")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)

            ForEach(model.snapshot.platforms) { platform in
                Button { loginTarget = platform } label: {
                    HStack {
                        AgentIcon(id: platform.id, size: 20)
                        Text(platform.name).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                        Spacer()
                        // Three states, read from THIS worker's jar. "Unknown" is rendered as unknown
                        // rather than as "not signed in" — claiming a platform is signed out when
                        // nobody has checked sends the owner to redo a login they may not need.
                        let state = model.workerRegistry?
                            .worker(id: selectedWorker)?.logins[platform.id]
                        Pill(
                            text: state.map { $0 ? "signed in" : "signed out" } ?? "not checked",
                            tone: state.map { $0 ? .ok : .violet } ?? .neutral
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
            ForEach(Operations.groups, id: \.self) { group in
                CollapsibleSection(
                    title: group,
                    isExpanded: expanded.contains(group),
                    onToggle: { toggle(group) }
                ) {
                    ForEach(Operations.inGroup(group)) { op in
                        // ⚠ Gated on the LIVE toggle value, not on the snapshot's. `onStartup` is
                        // what the switch above is showing right now; `snapshot.supervised` only
                        // catches up after the write and the next refresh, so reading it here would
                        // leave Daemon loop disabled for a beat after the owner enables On Startup —
                        // which reads as the toggle not having worked.
                        OperationRow(
                            op: op,
                            // Version reads "Update available — 0.1.14" when there is one, so the
                            // owner sees it while scanning rather than after tapping.
                            title: op.title(updateAvailable: model.snapshot.updateAvailable),
                            busy: model.busyOpID == op.id,
                            unavailable: op.unavailableReason(supervised: onStartup)
                        ) {
                            // ⚠ Daemon loop opens the live view instead of firing a toast. It still
                            // performs the operation — the view is what supervising LOOKS like, and
                            // a sentence in a toast could never be that.
                            if op.id == "daemon-loop" {
                                model.invoke(op)
                                daemonOpen = true
                            } else {
                                model.invoke(op)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ group: String) {
        // Collapsed by default. These are month-scale actions, and a list of open rows is how you
        // scroll past the two you came for.
        if expanded.contains(group) { expanded.remove(group) } else { expanded.insert(group) }
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
