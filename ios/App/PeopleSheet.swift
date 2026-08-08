import SwiftUI
import UIKit

/// Who can use this device, and what each of them is doing on it right now.
///
/// ⚠ **Deliberately mirrors the web app's owner "Shared with" popup** (`account/page.tsx`,
/// `SharersModalBody`), because the owner asked for the same UI/UX on the phone. Same render order:
/// explanation, legend, people tiles, then the worker pills last. Same pill semantics — `(N)` filled
/// green is running-or-free, `(N)` hollow is resting, `(#N)` amber is a queue position — and `N` and
/// `#N` are deliberately *different number spaces*: `N` is a worker slot id, `#N` is a place in the
/// global FIFO queue.
///
/// Two deliberate differences from the web app, both requested or forced:
///
/// * **No "Free workers" tile.** The owner was explicit: the pills at the end ARE the control. The
///   boxed tile the old version had is gone, exactly as the web app removed its own.
/// * **No Revoke, no Stop, no Cancel.** Those are owner-authenticated actions (`/api/devices/unshare`
///   and the owner-control queue write). This app signs in as the *device*, so shipping them would
///   ship three buttons that 403. The legend uses the web app's own non-owner wording for the same
///   reason — it already had wording for a viewer who cannot perform them.
struct PeoplePopup: View {
    let snapshot: DeviceSnapshot
    let onToggleRest: (Int, Bool) -> Void
    let onClose: () -> Void

    @Namespace private var pillSpace
    @State private var contentHeight: CGFloat = 0
    /// Which busy worker's pill is expanded to show its phase. One at a time, like the web app.
    @State private var openWorker: Int?

    // MARK: Derived state — mirrors the web app's own derivation

    /// Busy workers, from the `workers` map.
    private var busy: [WorkerState] { snapshot.workers.filter(\.isBusy) }

    private var capacity: Int { min(max(snapshot.workerCount, busy.count), 16) }

    /// Workers running for someone this device is no longer shared with.
    ///
    /// Kept visible rather than dropped: a slot that vanishes from the UI while still occupied is a
    /// slot the owner cannot account for.
    private var orphans: [WorkerState] {
        let known = Set(snapshot.users.map(\.id))
        return busy.filter { worker in
            guard let uid = worker.uid else { return true }
            return !known.contains(uid)
        }
    }

    /// The pills at the end: every slot that is NOT busy on someone's row, plus orphans.
    private var trailingPills: [(id: Int, busy: Bool)] {
        guard capacity > 0 else { return [] }
        let busyIDs = Set(busy.compactMap { Int($0.id) })
        let free = (1...capacity).filter { !busyIDs.contains($0) }.map { (id: $0, busy: false) }
        let orphaned = orphans.compactMap(\.intID).map { (id: $0, busy: true) }
        return (free + orphaned).sorted { $0.id < $1.id }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.6)
                .background(.ultraThinMaterial.opacity(0.6))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card.padding(DS.S.lg)
        }
        .transition(.opacity)
        // 15s, matching the web app: an expanded pill that never collapses hides the slot id, which
        // is the one thing every other pill in the popup is showing.
        .task(id: openWorker) {
            guard openWorker != nil else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { openWorker = nil }
        }
        // A slot reclaimed by a different run must not stay expanded describing the old one.
        .onChange(of: snapshot.workers) { _, workers in
            if let open = openWorker,
               !workers.contains(where: { $0.intID == open && $0.isBusy }) {
                openWorker = nil
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: snapshot.workers)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: snapshot.queue)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, DS.S.lg)
                    .padding(.bottom, DS.S.lg)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(maxHeight: min(contentHeight + 8, UIScreen.main.bounds.height * 0.85 - 64))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        }
        .background(DS.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.C.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("People").font(DS.F.title).foregroundStyle(DS.C.textPrimary)
                Text("\(busy.count) of \(max(capacity, 1)) workers busy")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            }
            Spacer()
            Button(action: onClose) {
                Text("Done").font(DS.F.label).foregroundStyle(DS.C.accent)
            }
            .frame(minWidth: DS.S.touch, minHeight: DS.S.touch)
        }
        .padding(.horizontal, DS.S.lg)
        .padding(.vertical, DS.S.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.border).frame(height: 1) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            explanation
            legend
            peopleTiles
            if !trailingPills.isEmpty { pillRow }
            if snapshot.users.isEmpty {
                // Below the pills, not above — centred text sitting directly on top of a tile reads
                // as that tile's heading. Same placement decision the web app made.
                Text("No one else has access.")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.S.sm)
            }
        }
        .padding(.top, DS.S.lg)
    }

    // MARK: 1 — the explanation

    /// Copy taken from the web app's own popup, which carries a "don't re-word it" note.
    ///
    /// ⚠ Its third line — about revoking and resetting the blocklist — is deliberately **not** here.
    /// This popup has no Revoke button, because the device cannot revoke anyone, and describing a
    /// control that is not on the screen is how a UI teaches someone to look for something that does
    /// not exist.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("People who can send research to ")
                .foregroundStyle(DS.C.textTertiary)
             + Text(snapshot.deviceName.isEmpty ? "this device" : snapshot.deviceName)
                .foregroundStyle(DS.C.textPrimary)
             + Text(".").foregroundStyle(DS.C.textTertiary))
                .font(DS.F.label)
            Text("Only the owner can change its settings, unpair or update it.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
    }

    // MARK: 2 — the legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            legendRow(badge: AnyView(LegendBadge(glyph: "N", style: .running))) {
                (Text("Running / Free").foregroundStyle(DS.C.ok)
                 + Text("\nWhile running: tap for phase.\nWhile free: tap to rest.")
                    .foregroundStyle(DS.C.textTertiary))
                    .font(DS.F.label)
            }
            legendRow(badge: AnyView(LegendBadge(glyph: "N", style: .resting))) {
                (Text("Resting").foregroundStyle(DS.C.textSecondary)
                 + Text(" — takes no new runs; tap to wake.\nAll resting → fired researches wait in queue.")
                    .foregroundStyle(DS.C.textTertiary))
                    .font(DS.F.label)
            }
            legendRow(badge: AnyView(LegendBadge(glyph: "#N", style: .queued))) {
                (Text("Queued").foregroundStyle(DS.C.warn)
                 + Text(" — #N is their place in line.").foregroundStyle(DS.C.textTertiary))
                    .font(DS.F.label)
            }
        }
        .padding(.horizontal, DS.S.lg)
        .padding(.vertical, DS.S.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surfaceRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.C.border, lineWidth: 1))
    }

    private func legendRow<T: View>(badge: AnyView, @ViewBuilder text: () -> T) -> some View {
        HStack(alignment: .top, spacing: DS.S.md) {
            badge
            text()
            Spacer(minLength: 0)
        }
    }

    // MARK: 3 — the people tiles

    private var peopleTiles: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            ForEach(snapshot.users) { user in
                PersonTile(
                    user: user,
                    workers: busy.filter { $0.uid == user.id },
                    queued: snapshot.queue.filter { $0.uid == user.id },
                    namespace: pillSpace,
                    openWorker: $openWorker
                )
            }
        }
    }

    // MARK: 4 — the worker pills, last, and tappable

    private var pillRow: some View {
        FlowRow(spacing: DS.S.sm) {
            ForEach(trailingPills, id: \.id) { pill in
                WorkerSlotPill(
                    id: pill.id,
                    state: pill.busy ? .busy
                        : (snapshot.restingWorkerIDs.contains(pill.id) ? .resting : .ready),
                    namespace: pillSpace,
                    // A busy pill is never tappable — a run in flight always finishes. Same rule as
                    // the web app, and for the same reason: parking a worker mid-run would either do
                    // nothing or orphan the run.
                    onTap: pill.busy ? nil : {
                        onToggleRest(pill.id, !snapshot.restingWorkerIDs.contains(pill.id))
                    }
                )
            }
        }
        .padding(.horizontal, DS.S.xs)
    }
}

// MARK: - A person

private struct PersonTile: View {
    let user: ConnectedUser
    let workers: [WorkerState]
    let queued: [QueuedRun]
    let namespace: Namespace.ID
    @Binding var openWorker: Int?

    var body: some View {
        HStack(alignment: .center, spacing: DS.S.md) {
            VStack(alignment: .leading, spacing: 3) {
                // ⚠ The name is the point of this tile and it was set in the LABEL font — the same
                // size as the captions beneath it — so a person read as a footnote. Body weight and
                // size, on its own line, with the pills below rather than competing for the row.
                Text(user.label)
                    .font(DS.F.body.weight(.medium))
                    .foregroundStyle(DS.C.textPrimary)
                    .lineLimit(1)
                    // Middle truncation only matters for an unresolved uid; a name should truncate
                    // at the end like a name.
                    .truncationMode(user.isResolved ? .tail : .middle)

                if let second = secondLine {
                    Text(second)
                        .font(DS.F.label)
                        .foregroundStyle(DS.C.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !workers.isEmpty || !queued.isEmpty {
                    FlowRow(spacing: DS.S.sm) {
                        ForEach(workers) { worker in
                            // ⚠ Tap-for-phase is the ONE web-app pill interaction a device
                            // principal can actually perform: it writes nothing. Long-press to
                            // Stop/Cancel addDoc's into devices/{id}/queue, whose `allow create`
                            // requires ownerUid or sharedWith — the synthetic device uid is
                            // neither, so those chips would 403 every time and are deliberately
                            // not here.
                            WorkerSlotPill(
                                id: worker.intID ?? 0,
                                state: .busy,
                                namespace: namespace,
                                phase: worker.phase,
                                totalPhases: worker.totalPhases,
                                expanded: openWorker == worker.intID,
                                onTap: {
                                    let id = worker.intID
                                    openWorker = (openWorker == id) ? nil : id
                                }
                            )
                        }
                        ForEach(queued) { run in
                            QueuePill(position: run.position)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.S.lg)
        .padding(.vertical, DS.S.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.C.border, lineWidth: 1))
    }

    /// Owner / their email / a warning that this is only a uid.
    private var secondLine: String? {
        if user.isOwner { return user.secondary ?? "Owner" }
        if let secondary = user.secondary { return secondary }
        // Said out loud. A bare uid on screen with no explanation looks like a bug in the app; it is
        // actually a name the server has not denormalised yet.
        return user.isResolved ? nil : "name not shared with this device"
    }
}

// MARK: - Pills

/// The `(N)` worker pill, in all three states.
///
/// `matchedGeometryEffect` on the slot id is what makes a pill *fly* between the person's row and
/// the row at the end when a run starts or finishes — the same shared-layout trick the web app uses,
/// and the reason a busy worker and a free one are the same object rather than two lookalikes.
private struct WorkerSlotPill: View {
    enum State { case busy, resting, ready }

    let id: Int
    let state: State
    let namespace: Namespace.ID
    var phase: Int? = nil
    var totalPhases: Int? = nil
    /// Busy pills expand to name their phase. Read-only — see PersonTile for why Stop is absent.
    var expanded: Bool = false
    let onTap: (() -> Void)?

    /// The web app's own short labels, so the two surfaces name a phase identically.
    private static let phaseLabels = ["Init", "Brief", "Research", "NLM", "Youtube", "Email"]

    private var total: Int { max(totalPhases ?? 6, 1) }
    private var step: Int { min((phase ?? 0) + 1, total) }
    private var label: String {
        let name = Self.phaseLabels.indices.contains(phase ?? -1)
            ? Self.phaseLabels[phase ?? 0] : "Running"
        return "\(name) · \(step)/\(total)"
    }

    var body: some View {
        // 26pt, not 22 — the owner could not read these. Still a circle when collapsed.
        let side: CGFloat = 26
        let pill = ZStack(alignment: .leading) {
            if expanded {
                GeometryReader { geo in
                    Rectangle()
                        .fill(DS.C.ok.opacity(0.55))
                        .frame(width: max(geo.size.width * CGFloat(step) / CGFloat(total), 8))
                }
            }
            Text(expanded ? label : "\(id)")
                .font(DS.F.mono(11, .semibold))
                .foregroundStyle(state == .resting ? DS.C.ok : Color.white)
                .lineLimit(1)
                .padding(.horizontal, expanded ? 9 : 0)
                .frame(minWidth: expanded ? 0 : side, alignment: expanded ? .leading : .center)
        }
        .frame(height: side)
        .frame(maxWidth: expanded ? 190 : side)
        .background(state == .resting ? Color.clear : DS.C.ok.opacity(expanded ? 0.35 : 1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(
                state == .resting ? DS.C.ok.opacity(0.8) : .clear,
                lineWidth: state == .resting ? 2 : 0
            )
        )
        .matchedGeometryEffect(id: "worker-\(id)", in: namespace)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: expanded)

        if let onTap {
            Button(action: onTap) { pill }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    state == .busy ? "Worker \(id): \(label) — tap for phase"
                        : state == .resting ? "Worker \(id) is resting — tap to wake"
                        : "Worker \(id) is ready — tap to rest"
                )
        } else {
            pill.accessibilityLabel("Worker \(id) is busy")
        }
    }
}

/// The `(#N)` queue-position pill. A different number space from the worker id, which is exactly why
/// it looks different.
private struct QueuePill: View {
    let position: Int

    var body: some View {
        Text("#\(position)")
            .font(DS.F.mono(11, .semibold))
            .foregroundStyle(DS.C.bg)
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(DS.C.warn)
            .clipShape(Capsule())
            .accessibilityLabel("Queued, position \(position)")
    }
}

private struct LegendBadge: View {
    enum Style { case running, resting, queued }
    let glyph: String
    let style: Style

    var body: some View {
        Text(glyph)
            .font(DS.F.mono(9, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, style == .queued ? 4 : 0)
            .frame(minWidth: 18, minHeight: 18)
            .background(background)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    style == .resting ? DS.C.ok.opacity(0.8) : .clear,
                    lineWidth: style == .resting ? 2 : 0
                )
            )
    }

    private var foreground: Color {
        switch style {
        case .running: return .white
        case .resting: return DS.C.ok
        case .queued: return DS.C.bg
        }
    }

    private var background: Color {
        switch style {
        case .running: return DS.C.ok
        case .resting: return .clear
        case .queued: return DS.C.warn
        }
    }
}

extension WorkerState {
    /// The slot ordinal, tolerating both `"2"` and `"worker-2"` keys the contract has carried.
    var intID: Int? { Int(id) ?? Int(id.replacingOccurrences(of: "worker-", with: "")) }
}

// MARK: - Layout

/// A wrapping row. Hand-rolled because SwiftUI has no flow layout before iOS 16's `Layout`, and the
/// pill row genuinely needs to wrap once a device has more than a handful of workers.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
