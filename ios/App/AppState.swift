import Foundation
import SwiftUI

// The observable UI layer, and nothing else.
//
// ⚠ Every type this file used to also declare — `AppBackend`, `DeviceSnapshot`, `ConnectedUser`,
// `WorkerState`, `QueuedRun`, `RunState`, `OpResult`, `PreviewBackend` — now lives in
// `ios/Sources/SuperResearchDeviceCore/DeviceModels.swift`. They were unreachable from `swift test`
// here, because `ios/App` is not a package target: one `import SwiftUI` at the top of the file was
// enough to leave the whole model layer uncompiled by the suite. See that file's header.

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
    /// The device's browser profiles, mirrored so SwiftUI redraws when one is added or removed.
    /// `WorkerRegistry` is a plain class on purpose — it is core logic and `swift test` compiles it —
    /// so the observable copy lives here rather than making the core import Combine.
    @Published var workers: [WorkerProfile] = []
    /// The full output of the last operation that produced one — a doctor report, a version, a
    /// diagnostics bundle. Nil when there is nothing more than the toast already said.
    @Published var opDetail: OpDetail? = nil

    struct OpDetail: Identifiable {
        let title: String
        let body: String
        var id: String { title }
    }

    private let backend: AppBackend

    /// The registry itself, for the surfaces that need to write to it. `nil` on the preview backend.
    var workerRegistry: WorkerRegistry? { (backend as? DeviceBackend)?.workers }

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
            // Stage 5's Finish hands control back here, rather than the flow waiting for `paired` to
            // flip on some later poll.
            pairing?.onFinished = { [weak self] in
                await self?.refresh()
                self?.screen = .landing
            }
            // An already-paired device must start beating on launch, not wait for someone to pair
            // again. Without this, relaunching the app leaves it looking offline to the web app.
            device.resumeIfPaired()
        }
        workers = workerRegistry?.workers ?? []
    }

    // MARK: - Workers (browser profiles)

    @discardableResult
    func addWorker() -> WorkerProfile? {
        guard let registry = workerRegistry else { return nil }
        let added = registry.addWorker()
        workers = registry.workers
        // Report the new capacity now rather than on the next 20-second beat, so the frontend and the
        // app agree immediately. Without this the web app keeps handing out one run at a time until
        // the next tick, which looks exactly like Add worker having done nothing.
        Task { await refresh() }
        return added
    }

    /// Returns the reason it was refused, or `nil` on success.
    @discardableResult
    func removeWorker(id: Int) -> WorkerRemovalRefusal? {
        guard let registry = workerRegistry else { return .lastRemainingWorker }
        // The busy set comes from the device document, which is the only place that knows what the
        // backend has actually assigned. Asking the registry would be asking the wrong object.
        if let refusal = registry.removalRefusal(for: id, busyWorkerIDs: snapshot.busyWorkerIDs) {
            toast = Self.explain(refusal)
            return refusal
        }
        let refusal = registry.removeLastWorker(busyWorkerIDs: snapshot.busyWorkerIDs)
        workers = registry.workers
        if let refusal { toast = Self.explain(refusal) }
        Task { await refresh() }
        return refusal
    }

    /// Park or wake a worker from the People popup.
    ///
    /// Fire-and-forget like the web app's own `toggleRest`, but with the failure SURFACED: the
    /// device's write of `restingWorkerIds` needs the deployed rules to include it in the synthetic
    /// device allow-list, and until they do this 403s. A silent catch here would make the pill
    /// simply not respond, which is indistinguishable from a dead tap target.
    func setWorkerResting(_ id: Int, resting: Bool) {
        guard let device = backend as? DeviceBackend else { return }
        Task {
            let result = await device.setWorkerResting(
                id, resting: resting, current: snapshot.restingWorkerIDs
            )
            if !result.ok { toast = result.message }
            await refresh()
        }
    }

    /// Record a login observation against the worker whose jar was used, and republish.
    func reportLogin(platform: String, signedIn: Bool, worker: Int) async {
        await (backend as? DeviceBackend)?
            .reportLogins([platform: signedIn], forWorker: worker)
    }

    static func explain(_ refusal: WorkerRemovalRefusal) -> String {
        switch refusal {
        case .lastRemainingWorker:
            return "A device needs at least one browser profile."
        case .notTheLastWorker(let highest):
            return "Only Worker \(highest) can be removed — removing one from the middle would "
                + "renumber the others mid-run."
        case .busy(let id):
            return "Worker \(id) is running something right now."
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
        toast = result.message
        // Doctor, Version, Update and Collect all produce more than a toast can hold. Showing the
        // report is the difference between "Doctor: 2 problems found" and knowing which two.
        if let detail = result.detail, !detail.isEmpty {
            opDetail = OpDetail(title: op.title, body: detail)
        }
        await refresh()

        // ⚠ A successful unpair has to move the SCREEN too, and this is the only place that can.
        // `screen` was previously assigned in exactly two places — its initial value and the end of
        // the pairing flow — so after unpairing, `snapshot.paired` went false while `screen` was
        // still `.landing`, and the app dropped the owner onto the marketing splash rather than onto
        // "No user paired". Worse, the Settings sheet it was invoked from stayed open on top of it.
        if op.id == "unpair", result.ok {
            screen = .notPaired
            workers = workerRegistry?.workers ?? []
        }
    }
}
