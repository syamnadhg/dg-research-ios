import SwiftUI
import UIKit

/// The People sheet — the same UX as the web app's "Shared with" popup, which its own code calls the
/// **worker rest/wake control center**.
///
/// The design rule that makes it work, taken from `account/page.tsx` rather than guessed:
///
/// > *"every known worker slot is visible at ALL times. Busy slots render as green pills on the
/// > owner/sharer row that holds them (uid join); idle slots park as neutral pills in the 'Free workers'
/// > tile; a busy slot whose runner has NO rendered row shows as a green ORPHAN pill — so no slot can
/// > ever vanish."*
///
/// Three consequences worth stating, because each one is a bug if you skip it:
///
/// * **A slot can never disappear.** If a worker is busy for a uid nobody shares with, it still shows —
///   as an orphan. Dropping it would make capacity silently unaccountable, which is exactly when you go
///   looking at this screen.
/// * **Pills move rather than appear.** `matchedGeometryEffect` is the app's equivalent of the web's
///   shared `layoutId`: the same pill flies from the free tile to a person's row when their run starts.
///   A pill that vanished in one place and appeared in another would read as two different workers.
/// * **Capacity is clamped.** The web clamps to 16; a bad `workerCount` off the wire must not size a
///   render loop.
///
/// Queued runs get pills too, on the row of whoever is waiting, so "who is using this device" and "who
/// is about to" are answerable in the same glance.
/// Presented as a **popup**, not a page — matching the frontend's modal chrome exactly:
/// `bg-black/60 backdrop-blur-sm` behind, `items-end` on mobile so the card is bottom-anchored,
/// `max-w-sm rounded-2xl bg-surface border border-border p-5 max-h-[85dvh] overflow-y-auto`.
///
/// ⚠ The height cap and inner scroll are load-bearing, and the frontend says why in its own comment: a
/// bottom-anchored sheet **clips off the TOP first**, so an over-tall card loses its title rather than
/// its footer. A full-screen page was the first attempt here and it lost the sense of a thing floating
/// over the device you were just looking at.
struct PeoplePopup: View {
    let snapshot: DeviceSnapshot
    let onClose: () -> Void

    @Namespace private var pillSpace
    /// Measured content height, so the card can hug it. See `card`.
    @State private var contentHeight: CGFloat = 0

    /// Declared capacity, clamped exactly as the web app clamps it.
    ///
    /// ⚠ Takes the max of the declared count and the number actually busy. A busy worker id above
    /// `workerCount` is real — the FE notes it "still tracks (row or orphan pill)" — so counting only
    /// the declared number would report "1 of 1 busy" on a device running two, which is the one number
    /// on this screen nobody should have to double-check.
    ///
    /// Free-slot generation deliberately does NOT use this: see `freeSlots`.
    private var capacity: Int { min(max(snapshot.workerCount, busy.count), 16) }

    /// The DECLARED capacity, used only to mint free slots.
    private var declaredCapacity: Int { min(max(snapshot.workerCount, 0), 16) }

    private var busy: [WorkerState] { snapshot.workers.filter(\.isBusy) }

    /// Busy workers whose uid has no row to sit on. Rendered rather than dropped.
    private var orphans: [WorkerState] {
        let known = Set(snapshot.users.map(\.id))
        return busy.filter { worker in worker.uid.map { !known.contains($0) } ?? false }
    }

    /// Idle slots, as ids. Derived from capacity rather than from the map, because the map only carries
    /// busy workers — the free slots are precisely the ones it does not mention.
    private var freeSlots: [String] {
        // Declared capacity, not the adjusted one — the web app is explicit that the free universe "is
        // only the declared capacity", so a busy id above it "never mints phantom intermediate free
        // slots". Using `capacity` here would invent an idle worker to sit beside an over-count one.
        guard declaredCapacity > 0 else { return [] }
        let busyIDs = Set(busy.map(\.id))
        return (1...declaredCapacity).map(String.init).filter { !busyIDs.contains($0) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tapping outside closes, as it does on the web. The backdrop is a button rather than a
            // gesture so it is reachable to assistive tech too.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .background(.ultraThinMaterial.opacity(0.6))
                .onTapGesture(perform: onClose)

            card
                .padding(DS.S.lg)
        }
        .transition(.opacity)
        // The pill flight between the free tile and a person's row is only visible if the change is
        // animated — matchedGeometryEffect interpolates, it does not schedule.
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: snapshot.workers)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: snapshot.queue)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                content
                    // ⚠ Measured, because neither a bare ScrollView nor `ViewThatFits` hugs here. A
                    // ScrollView claims every point it is offered, and a VStack handed surplus height
                    // CENTRES its children — which is why the first two attempts produced a full-height
                    // card with the content floating in the middle of it.
                    //
                    // Measuring the content and clamping to it reproduces what the web app gets for
                    // free from `max-h` on a normal-flow div: hug the content, scroll only past the cap.
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ContentHeightKey.self, value: proxy.size.height
                            )
                        }
                    )
            }
            .frame(height: min(contentHeight, UIScreen.main.bounds.height * 0.85 - 64))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        }
        .background(DS.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.C.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            peopleRows
            if !orphans.isEmpty { orphanTile }
            if !snapshot.queue.isEmpty { queueTile }
            // Last, as on the web app's popup: the free-worker tray is the resting place a pill
            // returns to, so it belongs below the rows pills fly up to.
            freeWorkersTile
        }
        .padding(DS.S.lg)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("People").font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
                Text("\(busy.count) of \(capacity) workers busy")
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

    private var peopleRows: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "Who can use this device")
            ForEach(snapshot.users) { user in
                VStack(alignment: .leading, spacing: DS.S.md) {
                    HStack {
                        Text(user.label)
                            .font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Pill(text: user.isOwner ? "owner" : "shared",
                             tone: user.isOwner ? .accent : .neutral)
                    }
                    // Their busy workers, as green pills on their row — the uid join.
                    let theirs = busy.filter { $0.uid == user.id }
                    let queued = snapshot.queue.filter { $0.uid == user.id }
                    if theirs.isEmpty && queued.isEmpty {
                        Text("nothing running")
                            .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    } else {
                        VStack(alignment: .leading, spacing: DS.S.sm) {
                            ForEach(theirs) { worker in
                                WorkerPill(worker: worker, namespace: pillSpace)
                            }
                            ForEach(queued) { run in
                                HStack(spacing: DS.S.md) {
                                    Pill(text: "queued #\(run.position)", tone: .queued)
                                    Text(run.title)
                                        .font(DS.F.label).foregroundStyle(DS.C.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .padding(DS.S.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.C.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border, lineWidth: 1))
            }
            if snapshot.users.isEmpty {
                Text("No one has access to this device yet.")
                    .font(DS.F.body).foregroundStyle(DS.C.textSecondary)
            }
        }
    }

    /// Busy workers with nobody to attribute them to.
    ///
    /// Shown rather than hidden. A slot that vanished because its runner is not in `sharedWith` would
    /// make the busy count disagree with the visible pills, and this screen is where someone comes to
    /// find out why a device is busy.
    private var orphanTile: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            SectionLabel(text: "Busy, runner not listed")
            ForEach(orphans) { worker in
                WorkerPill(worker: worker, namespace: pillSpace)
            }
            Text("A worker is running for someone this device is no longer shared with.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
        .padding(DS.S.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.warn.opacity(0.3), lineWidth: 1))
    }

    private var freeWorkersTile: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            HStack {
                SectionLabel(text: "Free workers")
                Spacer()
                Text("\(freeSlots.count)")
                    .font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            }
            if freeSlots.isEmpty {
                Text("Every worker is busy.")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            } else {
                // Wrapped rather than a single row: capacity can be up to 16 and a horizontal row would
                // push slots off a 402pt screen — the one thing this tile must never do.
                FlowRow(spacing: DS.S.sm) {
                    ForEach(freeSlots, id: \.self) { id in
                        IdleWorkerPill(
                            id: id,
                            resting: snapshot.restingWorkerIDs.contains(id),
                            namespace: pillSpace
                        )
                    }
                }
                // ⚠ Read-only, and the reason is in the rules rather than a decision made here:
                // `restingWorkerIds` is **owner-only** — *"owner-only worker rest/wake from the
                // Shared-With popup … sharers can read it but never write it."* This app signs in as
                // the synthetic DEVICE, not as the owner, so a tap here would 403 every time.
                //
                // Shipping a toggle that always fails would be worse than shipping none, so the state
                // is shown and the place it can be changed is named.
                Text("Resting workers take no new runs. Rest and wake are owner-only — the rules allow only the account owner to write them, and this app signs in as the device. Toggle them in the web app's Shared-with popup.")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            }
        }
        .padding(DS.S.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border, lineWidth: 1))
    }

    private var queueTile: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            HStack {
                SectionLabel(text: "Queue")
                Spacer()
                Text("\(snapshot.queue.count)")
                    .font(DS.F.mono(11)).foregroundStyle(DS.C.textTertiary)
            }
            ForEach(snapshot.queue) { run in
                HStack(spacing: DS.S.md) {
                    Pill(text: "#\(run.position)", tone: .queued)
                    Text(run.title)
                        .font(DS.F.label).foregroundStyle(DS.C.textSecondary).lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(DS.S.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border, lineWidth: 1))
    }
}

/// A busy worker: green pill, plus what it is running.
private struct WorkerPill: View {
    let worker: WorkerState
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: DS.S.md) {
            Text("w\(worker.id)")
                .font(DS.F.mono(10, .medium))
                .foregroundStyle(DS.C.ok)
                .padding(.horizontal, DS.S.lg)
                .padding(.vertical, DS.S.sm)
                .background(DS.C.ok.opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DS.C.ok.opacity(0.4), lineWidth: 1))
                // The same id as the free-slot pill, so the pill FLIES between the tile and this row
                // when a run starts or ends instead of vanishing here and appearing there.
                .matchedGeometryEffect(id: "worker-\(worker.id)", in: namespace)
            VStack(alignment: .leading, spacing: 0) {
                Text(worker.title ?? "a run")
                    .font(DS.F.label).foregroundStyle(DS.C.textPrimary).lineLimit(1)
                if let phase = worker.phase {
                    Text("phase \(phase)" + (worker.totalPhases.map { " of \($0)" } ?? ""))
                        .font(DS.F.mono(9)).foregroundStyle(DS.C.textTertiary)
                }
            }
            Spacer()
        }
    }
}

/// A wrapping row, because capacity can reach 16 and a `HStack` would push pills off screen.
///
/// Hand-rolled rather than `LazyVGrid`: a grid forces equal column widths, and these pills are
/// intentionally content-sized.
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


/// An idle worker slot. Hollow green border when the owner has parked it, neutral when it is
/// idle-and-ready — the same two states the web app's popup shows.
private struct IdleWorkerPill: View {
    let id: String
    let resting: Bool
    let namespace: Namespace.ID

    var body: some View {
        Text("w\(id)")
            .font(DS.F.mono(10, .medium))
            .foregroundStyle(resting ? DS.C.ok : DS.C.textTertiary)
            .padding(.horizontal, DS.S.lg)
            .padding(.vertical, DS.S.sm)
            // Hollow when resting: the colour says "this slot is green-lit but parked", and the empty
            // fill says it is not carrying anything. A filled green pill would read as busy.
            .background(resting ? Color.clear : DS.C.surfaceRaised)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    resting ? DS.C.ok.opacity(0.6) : DS.C.border,
                    lineWidth: resting ? 1.5 : 1
                )
            )
            .matchedGeometryEffect(id: "worker-\(id)", in: namespace)
    }
}


/// Carries the popup's measured content height up to the card.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
