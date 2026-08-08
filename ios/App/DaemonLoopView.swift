import SwiftUI

/// The supervisor and its workers, live.
///
/// ⚠ "Daemon loop" was a row that ran once and printed a sentence. On a desktop backend the daemon
/// loop is something you *watch* — it is the surface that tells you the supervisor is up and which
/// worker is doing what. A one-shot toast cannot be that, and the owner asked for the real thing.
///
/// Everything here is read from state the device already maintains, refreshed on a timer. There is
/// no separate "supervisor" process to query — on iOS the supervisor IS this app holding the screen
/// awake and beating, so the honest thing to show is those two facts plus the per-worker map.
struct DaemonLoopView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    /// Seconds the view has been open. Drives the elapsed column without a second timer.
    @State private var ticks = 0

    private var snapshot: DeviceSnapshot { model.snapshot }

    /// Supervising means: the screen is held awake and the device is beating.
    private var supervising: Bool { snapshot.supervised && snapshot.online }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            header
            supervisorRow
            Divider().background(DS.C.border)
            workerList
            Spacer(minLength: 0)
            footnote
        }
        .padding(DS.S.screen)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.bg)
        .presentationDetents([.medium, .large])
        // ⚠ A real timer, not a one-shot. The whole point is that this reflects the device WHILE you
        // look at it; a snapshot taken on open would be the toast again, in a bigger box.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                ticks += 2
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Daemon loop").font(DS.F.title).foregroundStyle(DS.C.textPrimary)
                Text(supervising ? "Supervising — live" : "Not supervising")
                    .font(DS.F.label)
                    .foregroundStyle(supervising ? DS.C.ok : DS.C.warn)
            }
            Spacer()
            Button(action: onClose) {
                Text("Done").font(DS.F.label).foregroundStyle(DS.C.accent)
            }
            .frame(minWidth: DS.S.touch, minHeight: DS.S.touch)
        }
    }

    private var supervisorRow: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            SectionLabel(text: "Supervisor")
            HStack(spacing: DS.S.lg * 2) {
                stat("Screen", supervising ? "awake" : "may sleep", ok: supervising)
                stat(
                    "Heartbeat",
                    snapshot.lastHeartbeatAgo.map { "\($0)s ago" } ?? "—",
                    // The frontend calls a device offline at 30s, so that is the threshold worth
                    // colouring against rather than an invented one.
                    ok: (snapshot.lastHeartbeatAgo ?? 999) < 30
                )
                stat("Capacity", "\(snapshot.busyWorkers)/\(snapshot.workerCount)", ok: true)
            }
        }
    }

    private var workerList: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            SectionLabel(text: "Workers")
            if model.workers.isEmpty {
                Text("No browser profiles.").font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            }
            ForEach(model.workers) { profile in
                WorkerRow(
                    id: profile.id,
                    state: state(for: profile.id),
                    run: snapshot.run(forWorker: profile.id)
                )
            }
        }
    }

    private func state(for id: Int) -> WorkerRow.State {
        if snapshot.busyWorkerIDs.contains(id) { return .running }
        if snapshot.restingWorkerIDs.contains(id) { return .resting }
        return .idle
    }

    /// ⚠ Says what iOS actually permits. A supervisor that claimed to survive the app closing would
    /// be the same lie the Mac-bridge rows used to tell.
    private var footnote: some View {
        Text("iOS cannot keep a backend running once the app is closed, so supervising means the screen is held awake and this device keeps beating while the app is open.")
            .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
    }

    private func stat(_ label: String, _ value: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.S.xs) {
            Text(label).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            Text(value)
                .font(DS.F.mono(12))
                .foregroundStyle(ok ? DS.C.ok : DS.C.warn)
        }
    }
}

/// One worker, and what it is doing right now.
private struct WorkerRow: View {
    enum State { case running, idle, resting }

    let id: Int
    let state: State
    let run: RunState?

    var body: some View {
        HStack(alignment: .center, spacing: DS.S.md) {
            Text("\(id)")
                .font(DS.F.mono(11, .semibold))
                .foregroundStyle(state == .resting ? DS.C.ok : .white)
                .frame(width: 26, height: 26)
                .background(state == .resting ? Color.clear : (state == .running ? DS.C.ok : DS.C.textTertiary))
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        state == .resting ? DS.C.ok.opacity(0.8) : .clear,
                        lineWidth: state == .resting ? 2 : 0
                    )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(DS.F.label.weight(.medium))
                    .foregroundStyle(DS.C.textPrimary)
                    .lineLimit(1)
                if let run {
                    Text("P\(run.phase) · \(run.phaseName)")
                        .font(DS.F.mono(9))
                        .foregroundStyle(DS.C.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.S.sm)
    }

    private var caption: String {
        switch state {
        case .running: return run?.researchTitle ?? "a run"
        case .resting: return "Resting — takes no new runs"
        case .idle: return "Idle — ready for work"
        }
    }
}
