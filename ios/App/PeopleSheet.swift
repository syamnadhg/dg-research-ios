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
/// * **No Revoke.** That is an owner-authenticated action (`/api/devices/unshare`), and this app
///   signs in as the *device*, so the button would 403 every time. The legend uses the web app's own
///   non-owner wording for the same reason — it already had wording for a viewer who cannot do it.
///
/// ⭐ **Stop DOES exist here now, and the reasoning that excluded it has changed rather than been
/// overruled.** It was excluded because stopping meant an addDoc into `devices/{id}/queue`, whose
/// `allow create` requires ownerUid or sharedWith — neither of which the synthetic device uid is.
/// That is still true of that route, and it is no longer the route: a run claimed by this device
/// executes *inside this process*, so holding its pill stops it with no Firestore write at all.
/// Cancelling a QUEUED run is still absent, because that one really would need the write.
struct PeoplePopup: View {
    let snapshot: DeviceSnapshot
    let onToggleRest: (Int, Bool) -> Void
    /// Stop the run on a worker. Hold a busy pill.
    var onStop: (Int) -> Void = { _ in }
    let onClose: () -> Void

    @Namespace private var pillSpace
    @State private var contentHeight: CGFloat = 0
    /// Which busy worker's pill is expanded to show its phase. One at a time, like the web app.
    @State private var openWorker: Int?

    // MARK: Derived state — mirrors the web app's own derivation

    /// Busy workers, from the `workers` map.
    /// Busy workers — from the device document, plus whatever this process is running RIGHT NOW.
    ///
    /// ⛔ **The document half lags by up to a beat (20s).** `workers` is published from the
    /// heartbeat, so a run that has just been claimed has no entry yet — and a run that fails
    /// quickly never gets one at all. The owner watched a run start and finish without a single
    /// pill appearing on anyone's tile (2026-08-14). The live half is written by the run itself, in
    /// this process, the instant it claims a worker.
    ///
    /// ⚠ The LIVE entry wins on conflict. Both describe the same worker, and the in-process one is
    /// strictly fresher — the document is a copy of it that is at most one beat old.
    private var busy: [WorkerState] {
        let live = LiveRunActivity.shared.runs
        var merged: [String: WorkerState] = [:]
        for worker in snapshot.workers where worker.isBusy { merged[worker.id] = worker }
        for (id, facts) in live {
            merged[String(id)] = WorkerState(
                id: String(id), uid: facts.uid, title: facts.title,
                phase: facts.phase, totalPhases: facts.totalPhases
            )
        }
        return merged.values.sorted { ($0.intID ?? 0) < ($1.intID ?? 0) }
    }

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
                (Text("Running / Free").foregroundStyle(DS.C.worker)
                 // Says BOTH gestures, because a long press is invisible until someone tries it.
                 + Text("\nWhile running: tap for phase, hold to stop.\nWhile free: tap to rest.")
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
        VStack(alignment: .leading, spacing: DS.S.lg) {
            ForEach(snapshot.users) { user in
                PersonTile(
                    user: user,
                    workers: busy.filter { $0.uid == user.id },
                    queued: snapshot.queue.filter { $0.uid == user.id },
                    namespace: pillSpace,
                    openWorker: $openWorker,
                    onStop: onStop
                )
            }
        }
    }

    // MARK: 4 — the worker pills, last, and tappable

    /// The worker slots nobody is using, as bare pills under the tiles.
    ///
    /// ⚠ **No heading.** An earlier version boxed and labelled these — which read fine in isolation
    /// and was redundant on the page: the legend directly above already says what a green pill is
    /// and that tapping it rests the worker. A second explanation of the same glyph is noise, and
    /// it gave the pills more weight than the people they sit beneath.
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
    }
}

// MARK: - A person

private struct PersonTile: View {
    let user: ConnectedUser
    let workers: [WorkerState]
    let queued: [QueuedRun]
    let namespace: Namespace.ID
    @Binding var openWorker: Int?
    var onStop: (Int) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: DS.S.lg) {
            // ⛔ **No avatar here, deliberately — and it is a consistency decision, not a style
            // one.** The web app's "Shared with" popup lists people as name-over-email with no
            // badge, and this popup is the same surface for the same people: a circled initial
            // here and none there makes one product look like two. The main-screen CARD keeps its
            // avatar, because there the rows are a glance summary competing with platform tiles
            // for attention rather than a list being read.
            VStack(alignment: .leading, spacing: DS.S.sm) {
                // ⚠ The name is the point of this tile. It was BODY size sitting above an 11pt
                // email, which read as a caption with a heading rather than as a person; at title
                // size the hierarchy matches what the tile is about.
                Text(user.label)
                    .font(DS.F.title)
                    .foregroundStyle(DS.C.textPrimary)
                    .lineLimit(1)
                    // Middle truncation only matters for an unresolved uid; a name should truncate
                    // at the end like a name.
                    .truncationMode(user.isResolved ? .tail : .middle)

                if let second = secondLine {
                    // ⚠ Body, not label. An email at 11pt on a 3x screen is legible only to
                    // someone who already knows what it says — and telling two people apart is
                    // precisely what this line is for.
                    Text(second)
                        .font(DS.F.body)
                        .foregroundStyle(DS.C.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !workers.isEmpty || !queued.isEmpty {
                    FlowRow(spacing: DS.S.sm) {
                        ForEach(workers) { worker in
                            // ⭐ Tap shows the phase; HOLD stops the run — the same two gestures
                            // the web app's own pill offers.
                            //
                            // ⚠ The old note here said Stop could not exist because stopping meant
                            // an addDoc into `devices/{id}/queue`, whose `allow create` requires
                            // ownerUid or sharedWith — which the synthetic device uid is not, so
                            // the chip would 403 every time. That reasoning was right about THAT
                            // route and is simply not the route any more: this run is executing
                            // inside this process, so stopping it writes nothing at all.
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
                                },
                                onLongPress: { onStop(worker.intID ?? 0) }
                            )
                        }
                        ForEach(queued) { run in
                            QueuePill(position: run.position)
                        }
                    }
                    .padding(.top, DS.S.xs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surfaceRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border, lineWidth: 1))
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
/// Make whatever it wraps breathe, while `active`.
///
/// ⛔ **A child view rather than modifiers on the pill, and that is a compiler constraint rather
/// than a preference.** The pill builds itself into a local `let` before deciding whether to wrap
/// it in a Button — and a closure created inside a local binding captures `self` immutably, so
/// `onAppear { breathing = true }` will not compile there however the state is declared. Owning the
/// state in a child is the same shape `PulsingDot` already uses, for the same reason.
private struct Breathing<Content: View>: View {
    let active: Bool
    @ViewBuilder var content: () -> Content

    @State private var on = false

    var body: some View {
        content()
            // ⭐ The web app's `animate-subtle-pulse`: a gentle opacity breath, nothing else.
            //
            // ⛔ **No glow and no scale.** Both were tried and both read as a RING drawn around the
            // pill rather than as the pill itself pulsing — which is not what the web app does and
            // not what a worker pill is. Subtlety is the point: this runs for ninety minutes.
            .opacity(active && on ? 0.55 : 1)
            .animation(
                active ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                value: on
            )
            .onAppear { if active { on = true } }
            // ⚠ Reset on the way DOWN too. Without this the pill keeps breathing after the run
            // ends — a worker that looks busy for ever is worse than one that never animated.
            .onChange(of: active) { _, live in on = live }
    }
}

/// ⚠ **Shared with Browser watch, deliberately.** It was private, and Browser watch grew its own
/// "Worker N" mini-tile that meant the same thing and looked nothing like it — so the same worker
/// in the same state read as two different objects on two screens. One component, so the two
/// surfaces cannot drift.
struct WorkerSlotPill: View {
    enum State { case busy, resting, ready }

    let id: Int
    let state: State
    let namespace: Namespace.ID
    var phase: Int? = nil
    var totalPhases: Int? = nil
    /// Busy pills expand to name their phase. Read-only — see PersonTile for why Stop is absent.
    var expanded: Bool = false
    /// Pulse, because this worker is running something.
    ///
    /// ⚠ Matches the web app exactly: `animate-subtle-pulse` is on the BUSY pill and on no other.
    /// An earlier version pulsed only while a platform page was live, which went still during the
    /// gaps between platforms — a worker mid-run looking idle for minutes at a time.
    var pulsing: Bool = false
    let onTap: (() -> Void)?
    /// Park or wake, where `onTap` is already spoken for. Nil means this surface offers no rest.
    var onLongPress: (() -> Void)? = nil

    private var restHint: String {
        state == .resting ? "Wake worker \(id)" : "Rest worker \(id)"
    }

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
        let pill = Breathing(active: pulsing) { ZStack(alignment: .leading) {
            if expanded {
                GeometryReader { geo in
                    Rectangle()
                        .fill(DS.C.worker.opacity(0.55))
                        .frame(width: max(geo.size.width * CGFloat(step) / CGFloat(total), 8))
                }
            }
            Text(expanded ? label : "\(id)")
                .font(DS.F.mono(11, .semibold))
                .foregroundStyle(state == .resting ? DS.C.worker : Color.white)
                .lineLimit(1)
                .padding(.horizontal, expanded ? 9 : 0)
                .frame(minWidth: expanded ? 0 : side, alignment: expanded ? .leading : .center)
        }
        .frame(height: side)
        .frame(maxWidth: expanded ? 190 : side)
        // ⭐ **The web app's three states, transcribed rather than approximated.**
        // `account/page.tsx`: busy and ready are both `bg-green-500 text-white`; resting is
        // `bg-transparent border-2 border-green-500/80 text-green-500`. There is no fourth state
        // and no ring for anything else — a halo for "this is the one Browser watch is showing"
        // was an invention, and it read as a circle drawn around the pill.
        .background(state == .resting ? Color.clear : DS.C.worker.opacity(expanded ? 0.35 : 1))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(
                state == .resting ? DS.C.worker.opacity(0.8) : .clear,
                lineWidth: state == .resting ? 2 : 0
            )
        ) }
        .matchedGeometryEffect(id: "worker-\(id)", in: namespace)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: expanded)

        if let onLongPress {
            // ⛔ **A plain view with GESTURES, not a Button — and this is why hold did nothing.**
            // `Button` installs its own recogniser, which claims the touch sequence; an
            // `.onLongPressGesture` attached to the outside of it never reaches the threshold,
            // so the press was silently swallowed and the pill just looked unresponsive. Attaching
            // both gestures to a plain view lets SwiftUI arbitrate between them properly.
            //
            // ⚠ The long press is declared BEFORE the tap. Declared after, the tap recogniser wins
            // the moment the finger lifts and the hold never completes — the same failure in a
            // different costume.
            pill
                .contentShape(Capsule())
                .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
                .onTapGesture { onTap?() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(
                    state == .resting ? "Worker \(id) is resting" : "Worker \(id) is ready"
                )
                .accessibilityHint("Hold to \(state == .resting ? "wake" : "rest")")
                // Named so VoiceOver can reach rest without performing a long press, which it
                // cannot do reliably.
                .accessibilityAction(named: restHint) { onLongPress() }
        } else if let onTap {
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
                    style == .resting ? DS.C.worker.opacity(0.8) : .clear,
                    lineWidth: style == .resting ? 2 : 0
                )
            )
    }

    private var foreground: Color {
        switch style {
        case .running: return .white
        case .resting: return DS.C.worker
        case .queued: return DS.C.bg
        }
    }

    private var background: Color {
        switch style {
        case .running: return DS.C.worker
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

// MARK: - A person's avatar

/// The initial in a circle — the visual anchor a person row needs.
///
/// ⭐ **Shared by the sheet and the main-screen card on purpose.** Both are showing the same people,
/// and two different treatments of one person read as two different kinds of thing. The web app
/// anchors its own rows the same way.
///
/// ⚠ The glyph rule lives on `ConnectedUser` in the core, not here: an unresolved uid must get a
/// neutral marker rather than a letter pulled out of a hex string, and **nothing in `ios/App` is
/// compiled by `swift test`** — a decision that matters cannot live where no test can reach it.
struct PersonAvatar: View {
    let user: ConnectedUser
    var size: CGFloat = 34

    private var tint: Color { user.isOwner ? DS.C.accent : DS.C.accent2 }

    var body: some View {
        Text(user.avatarGlyph)
            .font(DS.F.sans(size * 0.42, .semibold))
            .foregroundStyle(user.isResolved ? .white : DS.C.textTertiary)
            .frame(width: size, height: size)
            .background(user.isResolved ? tint : DS.C.surfaceHigh)
            .clipShape(Circle())
            .overlay(
                Circle().stroke(
                    user.isResolved ? .clear : DS.C.border,
                    lineWidth: user.isResolved ? 0 : 1
                )
            )
            .accessibilityHidden(true)
    }
}
