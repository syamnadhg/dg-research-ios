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

struct ConnectedUser: Identifiable, Hashable {
    let id: String
    let email: String
    let isOwner: Bool
}

struct PlatformState: Identifiable, Hashable {
    let id: String
    let name: String
    /// nil = never checked; the UI must not render "not signed in" for "unknown".
    let signedIn: Bool?
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

    static let unpaired = DeviceSnapshot()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: DeviceSnapshot = .unpaired
    @Published var busyOpID: String? = nil
    @Published var toast: String? = nil
    @Published var pendingConfirm: Operation? = nil

    private let backend: AppBackend

    init(backend: AppBackend) {
        self.backend = backend
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
            workerCount: 1,
            busyWorkers: 1,
            backendVersion: "0.1.12",
            bridgeReachable: false,
            users: [
                ConnectedUser(id: "u1", email: "sammy.guli@distributedglobal.com", isOwner: true),
                ConnectedUser(id: "u2", email: "eren@distributedglobal.com", isOwner: false),
            ],
            platforms: Self.platforms,
            run: RunState(
                researchTitle: "Quantum error correction, 2026 review",
                phase: 2,
                phaseName: "Deep research",
                elapsedSeconds: 134,
                agents: ["chatgpt": "done", "gemini": "active", "claude": "pending",
                         "notebooklm": "pending"]
            )
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
