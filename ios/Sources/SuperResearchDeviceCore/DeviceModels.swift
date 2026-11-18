import Foundation

// Everything the app knows about a device, and the protocol the UI talks to — with **no** SwiftUI.
//
// ⚠ This file used to live in `ios/App/AppState.swift` next to `AppModel`. That single `import
// SwiftUI` at the top of the file was enough to keep the whole model layer out of the SPM target,
// because `ios/App` is not a package target at all: `swift test` never compiled a line of it. So
// the pairing snapshot, the operation catalogue, the release path and the heartbeat — the parts
// most worth testing — had zero coverage while the suite reported 104 green tests.
//
// The split is the fix: types that do not import a UI framework live here and are compiled by
// `swift test`; `ios/App` holds views only. `AppLayerBoundaryTests` enforces that mechanically, so
// a future pure-logic file cannot quietly reappear on the untested side of the line.

/// What the app knows about itself and its backend.
///
/// Behind a protocol so the UI is complete and reviewable before Firebase is wired: the same views
/// run against `PreviewBackend` today and `DeviceBackend` against the real project. That is also
/// what lets the screens be rendered and screenshotted in the Simulator, which is the only way to
/// actually check a UI rather than assert it.
protocol AppBackend {
    func loadSnapshot() async -> DeviceSnapshot
    /// Perform an operation. Every operation acts on THIS device — there is no relay.
    func perform(_ op: Operation) async -> OpResult
}

struct OpResult {
    let ok: Bool
    /// The one-line outcome, shown as a toast.
    let message: String
    /// The full output, when there is more than a line of it — a doctor report, a version, a
    /// diagnostics bundle. Separate from `message` because a toast cannot hold a report, and
    /// truncating one into a toast is how "Doctor" became a button that told you nothing.
    ///
    /// ⚠ This replaced a `relayed` flag that meant "queued for the Mac bridge". The bridge never
    /// existed, so the flag's only job was to soften a lie.
    var detail: String? = nil
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

    /// What a SPECIFIC worker is running, as a RunState the live view can render.
    ///
    /// ⚠ `run` describes worker 1 only — it comes from the device doc's `currentRun*` fields, which
    /// the contract says only worker-1 maintains. With several workers busy it therefore describes
    /// one of them and silently mislabels the rest. The `workers` map is written by ALL workers, so
    /// it is the only honest source once more than one is running.
    func run(forWorker id: Int, now: Date = Date()) -> RunState? {
        guard let worker = workers.first(where: { Int($0.id) == id }), worker.isBusy else {
            // Worker 1 falls back to the document's own view, which carries the phase name and
            // elapsed time the per-worker map does not.
            return id == 1 ? run : nil
        }
        return RunState(
            researchTitle: worker.title ?? "a run",
            phase: worker.platformPhase ?? worker.phase ?? 0,
            // ⛔ The PLATFORM's phase when the device published one. The executor's counter cannot
            // move while a platform is inside its own P1→P2→P3, so reading it here is what made the
            // strip say "Research brief" through forty minutes of deep research.
            phaseName: Self.phaseName(worker.platformPhase ?? worker.phase),
            // ⛔ **This was the literal `0`, and it is why the timer never moved.** The map had no
            // start time to derive from, so the one number the screen exists to count was hard-coded
            // to nothing — and a clock stuck at 00:00 beside a live run reads as a frozen app.
            elapsedSeconds: RunState.elapsed(since: worker.startedAtMillis, now: now),
            agents: [:],
            startedAtMillis: worker.startedAtMillis
        )
    }

    /// The pipeline's own phase names, so a per-worker run reads the same as the document's.
    static func phaseName(_ phase: Int?) -> String {
        switch phase {
        case 0: return "Init"
        case 1: return "Research brief"
        case 2: return "Deep research"
        case 3: return "NotebookLM + audio"
        case 4: return "YouTube upload"
        case 5: return "Doc + email"
        default: return "Running"
        }
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
    /// Their display name or email when the server has denormalised one onto the device document,
    /// and a truncated uid when it has not. See `DeviceBackend.users(from:)` for why the device
    /// cannot resolve a uid itself.
    let label: String
    let isOwner: Bool
    /// The email, when `label` is a name. Nil when `label` IS the email, so the tile never prints
    /// the same string twice.
    var secondary: String? = nil
    /// False when `label` is a shortened uid. The UI renders that case differently — a partial
    /// identity that looks like a confirmed one is worse than one that looks partial.
    var isResolved: Bool = false

    /// The single character an avatar shows for this person.
    ///
    /// ⛔ **A `?` when the identity is unresolved, never a letter.** `label` is a truncated uid in
    /// that case, so taking its first character puts a confident-looking initial — pulled out of a
    /// hex string — on a person the device could not actually identify. This file already warns
    /// that "a partial identity that looks like a confirmed one is worse than one that looks
    /// partial"; an avatar is exactly where that goes wrong, because a glyph carries no caveat.
    ///
    /// ⚠ The first LETTER OR DIGIT, not the first character: a label may lead with a quote, an
    /// accent-stripping artefact, or an emoji, and a punctuation mark in a circle reads as a
    /// rendering fault rather than as a person.
    var avatarGlyph: String {
        guard isResolved, let first = label.first(where: { $0.isLetter || $0.isNumber })
        else { return "?" }
        return String(first).uppercased()
    }
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
    /// When the run on this worker was claimed, epoch millis. Zero when unknown — an older document,
    /// or a worker that is idle.
    var startedAtMillis: Int64 = 0
    /// The phase the PLATFORM is in, when the device published one. Nil on an older document.
    var platformPhase: Int? = nil

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

    /// When the run started, epoch millis — 0 when the document does not say.
    ///
    /// ⚠ Carried IN ADDITION to `elapsedSeconds` so the screen can tick locally. The snapshot
    /// arrives once per 20-second beat; a timer redrawn only when it lands would jump in
    /// twenty-second steps, which looks broken in a different way from being stuck.
    var startedAtMillis: Int64 = 0

    /// Seconds between a start stamp and now, floored at zero.
    ///
    /// ⚠ Zero for an unknown or future stamp, never a negative or a huge number: a device whose
    /// clock disagrees with the server's by a few seconds would otherwise render "-3" or a count
    /// since 1970, and both read as a bug in something else entirely.
    static func elapsed(since startedAtMillis: Int64, now: Date = Date()) -> Int {
        guard startedAtMillis > 0 else { return 0 }
        let seconds = Int(now.timeIntervalSince1970) - Int(startedAtMillis / 1000)
        return max(0, seconds)
    }

    /// Which platform the run is driving right now, if any.
    ///
    /// ⚠ Exactly one, and nil when the answer is ambiguous. Two platforms reporting "active" means
    /// the device state is mid-update or genuinely wrong, and the caller uses this to decide
    /// whether to hand INPUT to the automation — so guessing between them is the one thing it must
    /// not do.
    var activePlatform: String? {
        let active = agents.filter { $0.value == "active" }.map(\.key)
        return active.count == 1 ? active[0] : nil
    }
}

struct DeviceSnapshot {
    var paired: Bool = false
    var deviceID: String = ""
    /// What the owner named this device on the Account page. Shown in the People popup's opening
    /// line, exactly as the web app's own shared-with popup does.
    var deviceName: String = ""
    var pairCode: String = ""
    var online: Bool = false
    var lastHeartbeatAgo: Int? = nil
    var workerCount: Int = 1
    var busyWorkers: Int = 0
    /// Which worker ordinals are running something right now, from `busyWorkerIds`.
    ///
    /// The count alone is not enough: Remove worker has to know whether *that specific* worker is
    /// mid-run, and "2 of 3 busy" cannot answer it.
    var busyWorkerIDs: Set<Int> = []
    var backendVersion: String = ""
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
    /// Worker ordinals parked so they take no new runs; the backend reads this at claim time.
    ///
    /// ⚠ `Set<Int>`, not `Set<String>`. The web app types this field `number[]` and filters reads
    /// with `typeof n === "number"` — so a string entry is invisible to it, while the backend's
    /// `_worker_is_resting` accepts digit-strings and honours it. Writing strings therefore parked
    /// the worker for real while the web app showed full capacity: the device would silently stop
    /// taking work and nothing on screen would explain why.
    var restingWorkerIDs: Set<Int> = []

    /// The account that owns this device, as the document states it.
    ///
    /// ⚠ Carried for DIAGNOSIS rather than for display. Every owner-only control in the web app is
    /// gated on `device.ownerUid === user.uid`, and when that comparison is false the controls are
    /// not disabled or explained — they are rendered without a click handler at all. A pill that
    /// does nothing, silently, is indistinguishable from a pill whose write is being rejected, and
    /// the phone is the only place both sides of that comparison can be seen at once.
    var ownerUID: String = ""

    /// Which READ produced this snapshot — monotonically increasing, stamped when the load STARTS.
    ///
    /// ⛔ **Completion order is not issue order, and the difference is now visible.** Two things
    /// load snapshots: the owner's own actions and the 20-second beat. A beat load that started a
    /// second before the owner parked a worker can finish a second AFTER the toggle's own refresh,
    /// and a bare `snapshot = await load()` would then put the stale value back — the pill flips,
    /// then flips back, for a whole beat. Stamping at issue time lets the consumer drop anything
    /// older than what it has already shown.
    ///
    /// 0 means "unsequenced" — only the hand-built `.unpaired` and test fixtures carry that.
    var sequence: UInt64 = 0

    static let unpaired = DeviceSnapshot()
}

// MARK: - The stand-in backend

/// Drives the UI with plausible state so every screen can be built, rendered and reviewed before
/// Firebase is available.
///
/// Deliberately **not** all-green: it starts unpaired and has one platform signed out and one
/// unknown. A preview backend that shows a perfect system hides exactly the states the UI exists to
/// communicate — and those are the ones worth getting right.
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
            restingWorkerIDs: [2]
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
        case "unpair":
            paired = false
            return OpResult(ok: true, message: "Unpaired")
        case "version":
            return OpResult(ok: true, message: "Super Research 0.1.12 (preview)",
                            detail: "Backend version   0.1.12\nBuild             preview")
        default:
            return OpResult(ok: true, message: "\(op.title) done")
        }
    }
}
