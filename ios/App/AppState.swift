import Foundation
import SwiftUI

/// What the app knows about itself and its backend.
///
/// Behind a protocol so the UI is complete and reviewable before Firebase is wired: the same views
/// run against `PreviewBackend` today and `FirebasePairingBackend` once the SDK resolves. That is
/// also what lets the screens be rendered and screenshotted in the Simulator, which is the only way
/// to actually check a UI rather than assert it.
protocol AppBackend {
    func loadSnapshot() async -> DeviceSnapshot
    /// Perform an operation. `.daemon`-scoped ones are relayed; `.device`-scoped ones act directly.
    func perform(_ op: Operation) async -> OpResult
}

struct OpResult {
    let ok: Bool
    let message: String
    /// True when the operation was queued for the Mac bridge rather than completed here. Surfaced
    /// because "sent" and "done" are different things and conflating them makes the UI lie.
    var relayed: Bool = false
}

extension DeviceSnapshot {
    /// What this person is doing on this device right now.
    ///
    /// Derived rather than stored: the device doc reports workers and the queue independently, and the
    /// tile wants one answer per person. Running beats queued — someone with a run in flight and
    /// another waiting is best described by the one that is moving.
    enum UserActivity: Equatable {
        case running(title: String, phase: Int?, totalPhases: Int?)
        case queued(position: Int, title: String)
        case idle
    }

    func activity(for uid: String) -> UserActivity {
        if let worker = workers.first(where: { $0.uid == uid }) {
            return .running(
                title: worker.title ?? "a run", phase: worker.phase, totalPhases: worker.totalPhases
            )
        }
        if let queued = queue.filter({ $0.uid == uid }).min(by: { $0.position < $1.position }) {
            return .queued(position: queued.position, title: queued.title)
        }
        return .idle
    }
}

struct ConnectedUser: Identifiable, Hashable {
    let id: String
    /// What to show for this person. Named `label`, not `email`, because the device tree stores **uids**
    /// — the frontend is what resolves them to addresses. Calling the field `email` invited filling it
    /// with something email-shaped that isn't one.
    let label: String
    let isOwner: Bool
}

struct PlatformState: Identifiable, Hashable {
    let id: String
    let name: String
    /// nil = never checked; the UI must not render "not signed in" for "unknown".
    let signedIn: Bool?
}

/// One worker's live state, from the device doc's `workers` map.
///
/// Keyed by worker id → the run that worker is executing. Written by **all** workers, unlike the
/// `currentRun*` fields which only worker-1 maintains — so this is the only view that sees a
/// multi-worker device honestly.
struct WorkerState: Identifiable, Hashable {
    let id: String
    /// nil = idle. An idle worker is a real, common state, not missing data.
    let uid: String?
    let title: String?
    let phase: Int?
    let totalPhases: Int?

    var isBusy: Bool { uid != nil }
}

/// One queued run, from `queueOwners` — the ordered summary rebuilt on each queue recompute.
struct QueuedRun: Identifiable, Hashable {
    let id: String       // runId
    let uid: String
    let title: String
    let position: Int
}

struct RunState: Hashable {
    let researchTitle: String
    let phase: Int
    let phaseName: String
    let elapsedSeconds: Int
    /// platform id -> one of "done" | "active" | "pending" | "skipped"
    let agents: [String: String]
}

struct DeviceSnapshot {
    var paired: Bool = false
    var deviceID: String = ""
    var pairCode: String = ""
    var online: Bool = false
    var lastHeartbeatAgo: Int? = nil
    var workerCount: Int = 1
    var busyWorkers: Int = 0
    var backendVersion: String = ""
    var bridgeReachable: Bool = false
    var users: [ConnectedUser] = []
    var platforms: [PlatformState] = []
    var run: RunState? = nil
    /// Live per-worker state. Empty when the device has never reported any.
    var workers: [WorkerState] = []
    /// Queued runs, in order.
    var queue: [QueuedRun] = []
    /// What the backend reports about itself, and whether PyPI has something newer.
    var updateAvailable: String? = nil
    /// The On Startup intent, as stored on the device doc. Read so the Settings toggle reflects reality
    /// rather than defaulting to on and quietly disagreeing with the frontend.
    var supervised = false
    /// Worker ids the OWNER has parked. A listed worker takes no new runs; the backend reads this at
    /// claim time. Read-only here — see `PeoplePopup` for why the device cannot write it.
    var restingWorkerIDs: Set<String> = []

    static let unpaired = DeviceSnapshot()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: DeviceSnapshot = .unpaired
    @Published var busyOpID: String? = nil
    @Published var toast: String? = nil
    @Published var pendingConfirm: Operation? = nil
    /// Present only for the real backend: the five-stage pairing flow. `nil` on the preview backend,
    /// which has nothing to pair against.
    @Published var pairing: PairingController? = nil
    /// Landing → not-paired → pairing. Only meaningful while unpaired; a paired device goes straight to
    /// the dashboard.
    @Published var screen: AppScreen = .landing

    private let backend: AppBackend

    init(backend: AppBackend) {
        self.backend = backend
        if let device = backend as? DeviceBackend {
            pairing = PairingController(
                backend: device,
                platforms: [
                    PlatformState(id: "chatgpt", name: "ChatGPT", signedIn: nil),
                    PlatformState(id: "gemini", name: "Gemini", signedIn: nil),
                    PlatformState(id: "claude", name: "Claude", signedIn: nil),
                    PlatformState(id: "notebooklm", name: "NotebookLM", signedIn: nil),
                ]
            )
            // An already-paired device must start beating on launch, not wait for someone to pair
            // again. Without this, relaunching the app leaves it looking offline to the web app.
            device.resumeIfPaired()
        }
    }

    /// Mirror the On Startup intent to the device doc, so the frontend's Account toggle matches.
    func setSupervised(_ enabled: Bool) async {
        await (backend as? DeviceBackend)?.setSupervised(enabled)
    }

    /// Called on foreground/background so the heartbeat matches what iOS actually permits.
    func applicationBecameActive() {
        (backend as? DeviceBackend)?.resumeIfPaired()
    }

    func refresh() async {
        snapshot = await backend.loadSnapshot()
    }

    /// Route an operation, inserting the confirmation gate for anything that is not `.safe`.
    ///
    /// The gate lives here rather than in each button so a new operation cannot be added without one
    /// — `requiresConfirmation` is derived from `risk`, so forgetting is not an available mistake.
    func invoke(_ op: Operation) {
        if op.requiresConfirmation {
            pendingConfirm = op
            return
        }
        Task { await run(op) }
    }

    func confirm() {
        guard let op = pendingConfirm else { return }
        pendingConfirm = nil
        Task { await run(op) }
    }

    func cancelConfirm() { pendingConfirm = nil }

    private func run(_ op: Operation) async {
        busyOpID = op.id
        let result = await backend.perform(op)
        busyOpID = nil
        toast = result.relayed ? "\(op.title): \(result.message)" : result.message
        await refresh()
    }
}

// MARK: - The stand-in backend

/// Drives the UI with plausible state so every screen can be built, rendered and reviewed before
/// Firebase is available.
///
/// Deliberately **not** all-green: it starts unpaired, has one platform signed out and one unknown,
/// and reports the bridge unreachable. A preview backend that shows a perfect system hides exactly
/// the states the UI exists to communicate — and those are the ones worth getting right.
final class PreviewBackend: AppBackend {
    private var paired: Bool
    init(paired: Bool = false) { self.paired = paired }

    func loadSnapshot() async -> DeviceSnapshot {
        guard paired else {
            var s = DeviceSnapshot.unpaired
            s.platforms = Self.platforms
            return s
        }
        return DeviceSnapshot(
            paired: true,
            deviceID: "dev-a91f",
            pairCode: "JPNTY4F9",
            online: true,
            lastHeartbeatAgo: 3,
            workerCount: 2,
            busyWorkers: 1,
            backendVersion: "0.1.12",
            bridgeReachable: false,
            users: [
                ConnectedUser(id: "u1", label: "sammy.guli@distributedglobal.com", isOwner: true),
                ConnectedUser(id: "u2", label: "eren@distributedglobal.com", isOwner: false),
            ],
            platforms: Self.platforms,
            run: RunState(
                researchTitle: "Quantum error correction, 2026 review",
                phase: 2,
                phaseName: "Deep research",
                elapsedSeconds: 134,
                agents: ["chatgpt": "done", "gemini": "active", "claude": "pending",
                         "notebooklm": "pending"]
            ),
            // ⚠ Deliberately NOT all-idle and not all-busy. This backend exists so every screen can be
            // reviewed without a real device, and the states worth reviewing are the mixed ones: one
            // worker running while another is idle, one person's run in flight while another waits.
            // A preview showing a quiet device hides exactly the UI that matters.
            workers: [
                WorkerState(
                    id: "1", uid: "u1", title: "Quantum error correction, 2026 review",
                    phase: 2, totalPhases: 4
                ),
                WorkerState(id: "2", uid: nil, title: nil, phase: nil, totalPhases: nil),
            ],
            queue: [
                QueuedRun(
                    id: "r-9", uid: "u2", title: "Solid-state batteries, 2026 landscape", position: 1
                )
            ],
            supervised: true,
            restingWorkerIDs: ["2"]
        )
    }

    private static let platforms = [
        PlatformState(id: "chatgpt", name: "ChatGPT", signedIn: true),
        PlatformState(id: "gemini", name: "Gemini", signedIn: true),
        PlatformState(id: "claude", name: "Claude", signedIn: false),
        PlatformState(id: "notebooklm", name: "NotebookLM", signedIn: nil),
    ]

    func perform(_ op: Operation) async -> OpResult {
        try? await Task.sleep(nanoseconds: 250_000_000)
        switch op.id {
        case "pair":
            paired = true
            return OpResult(ok: true, message: "Pair code ready — claim it in the web app")
        case "unpair", "retire":
            paired = false
            return OpResult(ok: true, message: "Device \(op.id == "retire" ? "retired" : "unpaired")")
        default:
            if op.scope == .daemon {
                return OpResult(
                    ok: false,
                    message: "queued — the Mac bridge is not running, so nothing has executed yet",
                    relayed: true
                )
            }
            return OpResult(ok: true, message: "\(op.title) done")
        }
    }
}
