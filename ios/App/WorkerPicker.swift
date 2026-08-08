import SwiftUI

/// Choose which worker (browser profile) you are looking at, and add another.
///
/// One component, used in both places the owner asked for it: the pair flow's login stage and
/// Settings' Workers tile. Shared rather than duplicated because the two must agree about what a
/// worker *is* — a separate cookie jar, signed in separately — and two copies of that explanation
/// drift within a release.
///
/// A `Menu` rather than a segmented control: worker count is unbounded, and a segmented control with
/// six items on a 402pt screen is unreadable long before six workers is unreasonable.
struct WorkerPicker: View {
    let workers: [WorkerProfile]
    @Binding var selected: Int
    /// Worker ordinals running something right now. Rendered, because "why can't I remove this one"
    /// is the first question a refusal raises.
    var busyWorkerIDs: Set<Int> = []
    /// Nil where adding makes no sense — Browser watch is for looking, not configuring. A menu
    /// row that does nothing reads as a broken control.
    var onAdd: (() -> Void)? = nil
    /// Absent in the pair flow — you cannot remove a profile you are still setting up.
    var onRemove: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: DS.S.md) {
            Menu {
                ForEach(workers) { worker in
                    Button {
                        selected = worker.id
                    } label: {
                        // The checkmark is SwiftUI's own selected-row affordance in a Menu; drawing
                        // our own next to it would show two.
                        if worker.id == selected {
                            Label(Self.name(worker.id), systemImage: "checkmark")
                        } else {
                            Text(Self.name(worker.id))
                        }
                    }
                }
                if let onAdd {
                    Divider()
                    Button {
                        onAdd()
                    } label: {
                        Label("Add worker", systemImage: "plus")
                    }
                }
                if let onRemove, let last = workers.last, workers.count > 1 {
                    Button(role: .destructive) {
                        onRemove(last.id)
                    } label: {
                        Label("Remove \(Self.name(last.id))", systemImage: "minus")
                    }
                    // Disabled rather than hidden: a control that vanishes reads as a bug, and the
                    // reason it cannot be used right now is worth showing.
                    .disabled(busyWorkerIDs.contains(last.id))
                }
            } label: {
                HStack(spacing: DS.S.sm) {
                    Text(Self.name(selected))
                        .font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                    if busyWorkerIDs.contains(selected) {
                        Pill(text: "running", tone: .violet)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.textTertiary)
                }
                .frame(minHeight: DS.S.touch)
                .contentShape(Rectangle())
            }
            Spacer()
            Text("\(workers.count) profile\(workers.count == 1 ? "" : "s")")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
    }

    static func name(_ id: Int) -> String { "Worker \(id)" }
}

/// The one-line explanation of what a worker is, used wherever the picker appears.
///
/// Written once because both surfaces need it and because the concept is genuinely non-obvious: a
/// "worker" sounds like a thread, and the thing that actually matters is that it holds its own
/// logins.
struct WorkerExplainer: View {
    var body: some View {
        Text("A worker is its own browser profile with its own logins, so two runs can go at once. Each one signs in separately.")
            .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
    }
}
