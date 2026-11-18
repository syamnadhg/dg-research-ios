import Foundation

// No `import SuperResearchDeviceCore`: the app build compiles the core sources in directly (one
// `swiftc` invocation, no package graph), so the types are already in this module. An import here
// fails with "no such module" — which reads as a missing dependency rather than a build-shape fact.

/// The real `AppBackend`: pairs and reports state against Firestore, with no SDK.
///
/// Deliberately conservative about what it claims to know. It maps **only** device-document fields the
/// rules gate actually exercised (`bin/rules_verify.py`, 14/14) — `status`, `lastHeartbeat`,
/// `workerCount`, `busyWorkerIds`, `ownerUid`, `sharedWith`, `logins`. Anything else reports as unknown
/// rather than being guessed at, because a fabricated field reads as working software right up to the
/// point where the write is rejected by `hasOnly()` with a 403 that names nothing.
///
/// The same conservatism applies to the operations: device-scoped ones act here, and daemon-scoped ones
/// are reported as **not sent** rather than silently swallowed, because the control bridge's transport
/// is not wired yet. Saying "queued" for something that went nowhere is the failure mode worth avoiding.
/// Everything `DeviceBackend` needs from its transport.
///
/// `PairingBackend` covers the writes; the device also has to *read* its own document (to notice a
/// pairing that no longer exists). Bundling both behind one protocol is what makes the release path,
/// the heartbeat and the reported worker count testable at all — previously `DeviceBackend`
/// constructed a concrete `RESTPairingBackend` in its initialiser, so no test could observe what it
/// actually wrote.
protocol DeviceTransport: PairingBackend {
    /// Returns `nil` **only** for a genuine 404. Anything else throws — see `resumeIfPaired`.
    func readDocument(path: String) async throws -> [String: FirestoreValue]?
    /// `POST /api/devices/unpair-self` as the synthetic device user.
    func unpairSelf(deviceId: String) async throws -> String
    /// `POST /api/devices/cancel-pair` — for a pair that never got as far as a session.
    func cancelPair(deviceId: String, pollSecret: String) async throws -> String
    /// List a collection. The device's command queue is a subcollection, so this is what makes the
    /// web app's Online-pill reset reachable at all.
    func listDocuments(collectionPath: String) async throws -> [FirestoreREST.ListedDocument]
    func deleteDocument(path: String) async throws
    func patchDocument(path: String, set: [String: FirestoreValue]) async throws
    /// A **conditional** patch: applies only if the document is still at `ifUpdateTime`.
    ///
    /// Separate from the unconditional one rather than an optional parameter on it, so that every
    /// existing caller keeps the unconditional semantics it was written for and a claim cannot be
    /// written by accident without its precondition.
    func patchDocument(
        path: String, set: [String: FirestoreValue], ifUpdateTime: String
    ) async throws
    /// A patch that also REMOVES fields.
    ///
    /// ⚠ Its own method rather than a defaulted parameter, and deliberately not defaulted in a
    /// protocol extension either: a default that quietly dropped the deletions would leave a stale
    /// "queued behind <a run that finished an hour ago>" on screen and report success.
    func patchDocument(
        path: String, set: [String: FirestoreValue], delete: [String]
    ) async throws
    /// The persisted half of the auth session.
    func sessionRefreshToken() async -> String?
    func restoreSession(refreshToken: String) async
    func hasSession() async -> Bool
}

extension RESTPairingBackend: DeviceTransport {
    func readDocument(path: String) async throws -> [String: FirestoreValue]? {
        try await firestore.getDocument(path: path)
    }

    func listDocuments(collectionPath: String) async throws -> [FirestoreREST.ListedDocument] {
        try await firestore.listDocuments(collectionPath: collectionPath)
    }

    func deleteDocument(path: String) async throws {
        try await firestore.deleteDocument(path: path)
    }

    func patchDocument(path: String, set: [String: FirestoreValue]) async throws {
        try await firestore.patchDocument(path: path, set: set)
    }

    func patchDocument(
        path: String, set: [String: FirestoreValue], ifUpdateTime: String
    ) async throws {
        try await firestore.patchDocument(path: path, set: set, ifUpdateTime: ifUpdateTime)
    }

    func patchDocument(
        path: String, set: [String: FirestoreValue], delete: [String]
    ) async throws {
        try await firestore.patchDocument(path: path, set: set, delete: delete)
    }
}

final class DeviceBackend: AppBackend {
    private let pairing: DeviceTransport
    private let store: DeviceIdentityStore
    /// The device's browser profiles. The single source of truth for how many workers it has —
    /// `workerCount` used to be the literal `1` at both the confirm and every heartbeat.
    let workers: WorkerRegistry

    private var deviceID: String?
    private var pairCode: String = ""
    /// The poll secret of a pair that is IN FLIGHT — held only between `initiatePair` and either a
    /// completed pair or a cancel.
    ///
    /// ⚠ Needed because cancelling before the claim is the one moment the device has no session and
    /// cannot authenticate anything. The secret is the only proof it owns the half-made pair, which
    /// is exactly what `/api/devices/cancel-pair` asks for.
    private var inFlightSecret: String?
    /// Retained so the heartbeat keeps using the same claim clock the confirm used.
    private var coordinator: PairingCoordinator?
    private var heartbeatTask: Task<Void, Never>?
    /// Pushed a fresh device snapshot, once per beat.
    ///
    /// ⛔ **This is the FE→device direction, and without it that direction does not exist.** The web
    /// app's Shared-with popup parks a worker by writing `restingWorkerIds` straight onto
    /// `devices/{id}` — no command document, nothing addressed to this device — so the ONLY way the
    /// phone can learn about it is by looking at the document again. It never did: `refresh()` runs
    /// on explicit actions only, so a worker parked from the web app stayed awake on the phone until
    /// the owner happened to tap something. The reverse direction always worked, which is what made
    /// it look like a one-way bug rather than a missing read.
    ///
    /// ⚠ Modelled on `LiveRunActivity.onChange`, the one existing core→UI channel, rather than
    /// inventing a second shape.
    var onSnapshot: ((DeviceSnapshot) -> Void)?

    /// Where the once-per-beat state line goes. `NSLog` in the app; a collector in the suite.
    ///
    /// ⛔ **A line only on change is not a liveness signal.** The first version of the beat push
    /// logged the resting set only when it differed, which reads well and is useless in exactly the
    /// situation it was built for: when the owner toggles a pill on the laptop and nothing happens
    /// on the phone, silence is ambiguous — the beat may be dead, the read may be failing, or the
    /// document may genuinely be unchanged, and all three look identical. One line per tick makes
    /// the beat's own heartbeat visible and turns "nothing arrived" into a statement about the
    /// document rather than about the app.
    var beatLogger: ((String) -> Void)? = { NSLog("[SR] %@", $0) }

    /// Who runs a claimed research. Nil until one is installed — intake still claims, sweeps and
    /// reports correctly without one, which is what makes it verifiable on its own.
    ///
    /// ⚠ **Held STRONGLY, and it was weak.** A weak reference is right for a delegate the caller
    /// keeps alive, and wrong here: the executor is a collaborator the backend owns for the life of
    /// the pairing, and nothing else retains it. Weak, it deallocated the moment the caller's local
    /// went out of scope — so `pollQueue` claimed a run, called through an already-nil reference,
    /// and the run silently never started. The claim would still be stamped on the queue document,
    /// so the next backend to look would treat it as someone else's work.
    var launcher: (any RunLauncher)?

    /// Builds the launcher once the device id exists.
    ///
    /// ⛔ **Deferred rather than injected at init, because at init there is no device id.** The app
    /// constructs this backend before pairing; the launcher needs the id to stamp every research
    /// write (`request.resource.data.deviceId == request.auth.token.deviceId`), so attaching a
    /// launcher at construction would bake in `nil` and every write would 403.
    private var makeLauncher: ((String) -> any RunLauncher)?

    /// Give this backend the ability to actually RUN what it claims.
    ///
    /// ⛔ **Nothing called this, because it did not exist — and `launcher` was never assigned by
    /// anything.** Every piece downstream of a claim was built and tested (the pipeline, the
    /// emitter, P3, the handoff) and the line joining them was missing, so `pollQueue` claimed a
    /// run — stamping the queue document so no sibling backend would take it — and then called
    /// through a nil reference. The run sat `ongoing` for ever and the owner's next run queued
    /// behind it.
    func attachRunLauncher(
        apiBaseURL: URL,
        storageBucket: String,
        pages: @escaping InAppRunLauncher.PageProvider,
        releasePages: @escaping @Sendable () -> Void = {},
        manifest: [String: [String: [String]]],
        texts: [String: [String: String]],
        openers: [String: [String: String]]
    ) {
        guard let rest = pairing as? RESTPairingBackend else {
            // ⚠ Stated rather than silent. The preview backend has no Firestore session, so a run
            // could not be driven anyway — but a device that quietly cannot run is exactly the
            // failure this whole method exists to end.
            NSLog("[SR] run launcher NOT attached: this backend has no REST session (preview mode)")
            return
        }
        makeLauncher = { deviceID in
            InAppRunLauncher(
                client: rest.firestore, deviceID: deviceID, apiBaseURL: apiBaseURL,
                storageBucket: storageBucket, pages: pages, releasePages: releasePages,
                manifest: manifest, texts: texts, openers: openers
            )
        }
    }

    /// The launcher for *deviceID*, built on first use.
    ///
    /// ⚠ Cached, because a launcher per claim would be harmless but a new `FirebaseStorage` and a
    /// new token closure per run are not free — and the id cannot change without a re-pair, which
    /// rebuilds this object anyway.
    func launcher(for deviceID: String) -> (any RunLauncher)? {
        if let launcher { return launcher }
        guard let makeLauncher else { return nil }
        let built = makeLauncher(deviceID)
        launcher = built
        return built
    }

    convenience init(
        config: FirebaseProjectConfig,
        store: DeviceIdentityStore = .keychain,
        workers: WorkerRegistry = .shared
    ) {
        self.init(transport: RESTPairingBackend(config: config), store: store, workers: workers)
    }

    init(
        transport: DeviceTransport,
        store: DeviceIdentityStore = .keychain,
        workers: WorkerRegistry = .shared
    ) {
        self.pairing = transport
        self.store = store
        self.workers = workers
        self.deviceID = store.deviceID
    }

    // MARK: - Snapshot

    /// Hands out the ordering stamp. Lock-guarded because the beat task and the main actor both
    /// call `loadSnapshot()`, and a torn read of the counter would hand two loads the same number —
    /// at which point the newer one is indistinguishable from the older and gets dropped.
    private let sequenceLock = NSLock()
    private var snapshotSequence: UInt64 = 0

    private func nextSnapshotSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        snapshotSequence += 1
        return snapshotSequence
    }

    func loadSnapshot() async -> DeviceSnapshot {
        // ⚠ Taken BEFORE the await, not after. The whole point is to record when this read was
        // ISSUED — a stamp taken on completion would be in completion order, which is the order the
        // guard exists to stop trusting.
        let sequence = nextSnapshotSequence()
        guard let deviceID else {
            var snapshot = DeviceSnapshot.unpaired
            snapshot.platforms = Self.unknownPlatforms
            snapshot.sequence = sequence
            return snapshot
        }

        var snapshot = DeviceSnapshot()
        snapshot.sequence = sequence
        snapshot.deviceID = deviceID
        snapshot.pairCode = pairCode
        snapshot.platforms = Self.unknownPlatforms
        // ⛔ **The comment below used to claim this, and the code did the OPPOSITE.** `paired` is
        // false on a fresh `DeviceSnapshot`, so every non-404 read failure returned an UNPAIRED
        // snapshot — and an unpaired snapshot is destructive rather than cosmetic: it swaps the root
        // screen to "No user paired" and force-closes every open sheet (Views.swift's
        // `onChange(of: snapshot.paired)`). It was survivable only because nothing refreshed on a
        // timer. The moment a beat pushes a snapshot every 20s, one dropped read — a tunnel, a
        // token mid-refresh — throws the owner out of whatever they were doing.
        //
        // Having a device id at all IS the pairing evidence: it is only ever set by a completed
        // pairing and only ever cleared by unpair/reset. So say so up front, and let the document
        // downgrade it (404 ⇒ genuinely unpaired), never a transport error.
        snapshot.paired = true
        // ⚠ Re-arm the session first, as `doctor` and `versionAndUpdate` already do and this did
        // not. A refresh issued before `restoreSession` lands throws `notAuthenticated`, which is
        // exactly the "read failure" branch above — so on a timer this produced a periodic, entirely
        // spurious unpair.
        await restoreSessionIfNeeded()

        guard let fields = try? await pairing.readDocument(path: "devices/\(deviceID)")
        else {
            // Unreadable is NOT unpaired. Offline, and paired.
            NSLog("[SR] snapshot: devices/%@ unreadable this tick — reporting offline, still paired",
                  String(deviceID.prefix(8)))
            return snapshot
        }

        snapshot.paired = fields["pairConfirmedAt"] != nil
        if case .string(let name)? = fields["name"], !name.isEmpty { snapshot.deviceName = name }
        if case .string(let status)? = fields["status"] {
            snapshot.online = status == "active" || status == "online"
        }
        if case .integer(let millis)? = fields["lastHeartbeat"] {
            let seconds = Int(Date().timeIntervalSince1970) - Int(millis / 1000)
            snapshot.lastHeartbeatAgo = max(0, seconds)
        }
        // ⚠ The REGISTRY, not the document. The device is the only writer of `workerCount`, so the
        // registry is the truth and the document is a copy that lags by up to one heartbeat. Reading
        // it back would make a worker the owner just added vanish from Settings for 20 seconds,
        // which reads as "Add worker didn't work" and invites a second tap.
        snapshot.workerCount = workers.count
        if case .array(let busy)? = fields["busyWorkerIds"] { snapshot.busyWorkers = busy.count }
        snapshot.busyWorkerIDs = Self.busyWorkerIDs(from: fields)

        snapshot.workers = Self.workers(from: fields, workerCount: snapshot.workerCount)
        snapshot.queue = Self.queue(from: fields)
        if case .string(let version)? = fields["version"] { snapshot.backendVersion = version }
        if case .string(let newer)? = fields["updateAvailable"] { snapshot.updateAvailable = newer }
        if case .boolean(let supervised)? = fields["supervised"] { snapshot.supervised = supervised }
        // ⚠ Both shapes. The web app writes NUMBERS; this used to parse only strings, so a worker
        // the owner parked from the web app was invisible on the phone — the pill rendered awake
        // and tapping it "woke" an already-awake worker.
        snapshot.restingWorkerIDs = Self.workerIDs(from: fields["restingWorkerIds"])
        if case .string(let owner)? = fields["ownerUid"] { snapshot.ownerUID = owner }
        snapshot.users = Self.users(from: fields)
        if let logins = Self.platforms(from: fields) { snapshot.platforms = logins }
        return snapshot
    }

    /// Owner plus anyone the device is shared with, by **name** where a name is available.
    ///
    /// ⚠ The device cannot resolve a uid itself, and this is by design rather than by omission:
    /// `match /users/{userId}` is `allow read, write: if request.auth.uid == userId`, and the device
    /// signs in as `device-{deviceId}`, which can never equal a human uid. Even the web app does not
    /// read Firestore for this — it calls an Admin-SDK route, because `getUsers()` is the only thing
    /// that can resolve them.
    ///
    /// So names have to be **denormalised onto the device document** by a server that already holds
    /// admin credentials. Two sources, in order:
    ///
    /// 1. `people` — `map<uid, {displayName, email}>`, written by the claim/share route for owner
    ///    **and** sharers.
    /// 2. `ownerDisplayName` / `ownerEmail` — already written today by the claim route's initial-pair
    ///    and re-pair branches, so the owner's real name works with no frontend change at all.
    ///
    /// Falls back to a truncated uid, and says so via `isResolved`, so a partial identity is rendered
    /// as partial rather than as a confirmed one.
    static func users(from fields: [String: FirestoreValue]) -> [ConnectedUser] {
        var people: [String: (name: String?, email: String?)] = [:]
        if case .map(let map)? = fields["people"] {
            for (uid, value) in map {
                guard case .map(let entry) = value else { continue }
                people[uid] = (string(entry["displayName"]), string(entry["email"]))
            }
        }

        func resolve(_ uid: String, ownerFallback: Bool) -> ConnectedUser {
            let entry = people[uid]
            let name = entry?.name
                ?? (ownerFallback ? string(fields["ownerDisplayName"]) : nil)
            let email = entry?.email
                ?? (ownerFallback ? string(fields["ownerEmail"]) : nil)
            // Name first, then email, then the uid. An email is a real identity; a uid is not.
            if let label = name ?? email {
                return ConnectedUser(
                    id: uid, label: label, isOwner: ownerFallback,
                    secondary: (name != nil) ? email : nil, isResolved: true
                )
            }
            return ConnectedUser(id: uid, label: short(uid), isOwner: ownerFallback,
                                 secondary: nil, isResolved: false)
        }

        var users: [ConnectedUser] = []
        if case .string(let owner)? = fields["ownerUid"] {
            users.append(resolve(owner, ownerFallback: true))
        }
        if case .array(let shared)? = fields["sharedWith"] {
            for entry in shared {
                if case .string(let uid) = entry {
                    users.append(resolve(uid, ownerFallback: false))
                }
            }
        }
        return users
    }

    /// Per-worker live state from the `workers` map, padded out to `workerCount`.
    ///
    /// Padded on purpose: the map only carries BUSY workers, so a device with two workers and one run
    /// reports a single entry. Rendering just that entry would make a half-busy device look
    /// fully-occupied — the idle capacity is exactly what a viewer wants to see.
    private static func workers(
        from fields: [String: FirestoreValue], workerCount: Int
    ) -> [WorkerState] {
        var busy: [String: WorkerState] = [:]
        if case .map(let map)? = fields["workers"] {
            for (id, value) in map {
                guard case .map(let run) = value else { continue }
                // `_dead: true` is how the supervisor marks a worker it had to give up on. Reported as
                // idle rather than dropped, because a dead worker is capacity that is NOT available.
                busy[id] = WorkerState(
                    id: id,
                    uid: string(run["uid"]),
                    title: string(run["title"]),
                    phase: integer(run["phase"]).map(Int.init),
                    totalPhases: integer(run["totalPhases"]).map(Int.init),
                    startedAtMillis: integer(run["startedAt"]) ?? 0,
                    platformPhase: integer(run["platformPhase"]).map(Int.init)
                )
            }
        }
        // Worker ids are conventionally 1-based in this contract.
        return (1...max(workerCount, busy.count, 1)).map { index in
            busy["\(index)"] ?? busy["worker-\(index)"]
                ?? WorkerState(id: "\(index)", uid: nil, title: nil, phase: nil, totalPhases: nil)
        }
    }

    /// Queued runs from `queueOwners`, ordered by position.
    private static func queue(from fields: [String: FirestoreValue]) -> [QueuedRun] {
        guard case .array(let entries)? = fields["queueOwners"] else { return [] }
        return entries.compactMap { entry -> QueuedRun? in
            guard case .map(let run) = entry,
                  let uid = string(run["uid"]),
                  let runId = string(run["runId"])
            else { return nil }
            return QueuedRun(
                id: runId,
                uid: uid,
                title: string(run["title"]) ?? "a run",
                position: integer(run["position"]).map(Int.init) ?? 0
            )
        }
        .sorted { $0.position < $1.position }
    }

    /// Which worker ordinals are running something, from `busyWorkerIds`.
    ///
    /// Tolerates both shapes the contract has carried: integers, and the string ids the `workers`
    /// map is keyed by. Parsing only one of them would silently return an empty set — and an empty
    /// busy set is exactly what lets Remove worker delete a worker mid-run.
    static func busyWorkerIDs(from fields: [String: FirestoreValue]) -> Set<Int> {
        workerIDs(from: fields["busyWorkerIds"])
    }

    /// Parse a worker-ordinal array, tolerating every shape the contract has carried.
    ///
    /// ⚠ Integers AND digit-strings AND `worker-N`. The two writers disagree: the web app writes
    /// numbers, the backend accepts either. Parsing only one silently yields an EMPTY set — which
    /// is what lets Remove worker delete a busy worker, and what made a web-app rest invisible here.
    static func workerIDs(from value: FirestoreValue?) -> Set<Int> {
        guard case .array(let entries)? = value else { return [] }
        return Set(entries.compactMap { entry -> Int? in
            switch entry {
            case .integer(let number): return Int(number)
            case .string(let text):
                return Int(text) ?? Int(text.replacingOccurrences(of: "worker-", with: ""))
            default: return nil
            }
        })
    }

    private static func string(_ value: FirestoreValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        return nil
    }

    private static func integer(_ value: FirestoreValue?) -> Int64? {
        if case .integer(let number)? = value { return number }
        return nil
    }

    private static func short(_ uid: String) -> String {
        uid.count <= 12 ? uid : "\(uid.prefix(8))…\(uid.suffix(4))"
    }

    /// Platform login state from the device document's `logins` map, when it has one.
    ///
    /// Returns `nil` — not "all signed out" — when the field is absent, so the UI keeps saying "not
    /// checked". Reporting a login as absent because nobody recorded it sends the owner to redo work
    /// they may not need to.
    private static func platforms(from fields: [String: FirestoreValue]) -> [PlatformState]? {
        guard case .map(let logins)? = fields["logins"] else { return nil }
        return Self.unknownPlatforms.map { platform in
            guard case .boolean(let signedIn)? = logins[platform.id] else { return platform }
            return PlatformState(id: platform.id, name: platform.name, signedIn: signedIn)
        }
    }

    private static let unknownPlatforms = [
        PlatformState(id: "chatgpt", name: "ChatGPT", signedIn: nil),
        PlatformState(id: "gemini", name: "Gemini", signedIn: nil),
        PlatformState(id: "claude", name: "Claude", signedIn: nil),
        PlatformState(id: "notebooklm", name: "NotebookLM", signedIn: nil),
    ]

    // MARK: - Operations

    /// Every operation acts on THIS device.
    ///
    /// ⚠ There is no `default:` that reports "queued". The old one relayed to a Mac bridge whose
    /// transport was never built, so most of this list did nothing at all. A `switch` over the
    /// catalogue with no fallback means adding an operation without implementing it fails to
    /// compile, rather than shipping a row that silently does nothing.
    func perform(_ op: Operation) async -> OpResult {
        switch op.id {
        case "serve": return await startServing()
        case "restart": return await restartServing()
        case "daemon-loop": return await runDaemonLoop()
        case "doctor": return await doctor()
        case "version": return await versionAndUpdate()
        case "collect": return await collectDiagnostics()
        case "reset": return await resetState()
        case "unpair": return await release(op)
        default:
            // Only reachable if the catalogue and this switch drift apart, which is a bug in this
            // file rather than a state the owner can produce.
            return OpResult(ok: false, message: "\(op.title) has no implementation")
        }
    }

    // MARK: - Runtime

    /// Come online now: re-arm the session if needed, then start beating.
    private func startServing() async -> OpResult {
        guard deviceID != nil else { return OpResult(ok: false, message: "Not paired") }
        await restoreSessionIfNeeded()
        if coordinator == nil { coordinator = PairingCoordinator(backend: pairing) }
        startHeartbeat()
        return OpResult(ok: true, message: "Serving — this device is online and accepting runs")
    }

    /// Publish the truth about what this device is running: at boot, nothing.
    ///
    /// ⛔ **Without this a killed run BRICKS the device for every future run.** `markBusy` publishes
    /// `busyWorkerIds` when a run is claimed and clears it when the run ends — so a process that
    /// dies in between (crash, force-quit, iOS reclaiming a backgrounded app, or the owner stopping
    /// a run that this build could not stop) leaves the field saying "worker 1 is busy" for ever.
    /// `workerState` unions that stale set into the live one, `firstFreeWorker` then finds no free
    /// worker, and every subsequent claim is declined — silently, because declining to claim is
    /// also what a legitimately busy device does. Measured on 2026-08-14.
    ///
    /// ⚠ Safe precisely because ONE process drives one device's workers. Nothing else can be
    /// running this device's runs at the moment this process starts, so "nothing is busy" is not an
    /// assumption — it is the only thing that can be true.
    private func reconcileBusyWorkers() async {
        guard let deviceID else { return }
        // ⛔ **Publishes what this process IS running — NOT an empty set.** At boot that is nothing,
        // which is the whole point. But this also runs from `startHeartbeat()`, and `bounceForReset`
        // calls that after its pause — potentially while a run is still in flight. Publishing empty
        // there would tell the device every worker is free, and `firstFreeWorker` would hand a
        // second run to the worker already driving one: two runs, one set of web views. That is the
        // exact hazard `workerState` unions `locallyBusyWorkers` in to avoid, and clearing the set
        // here would have defeated it from the other end.
        // Best-effort, like `markBusy`: a failed publish costs a stale pill, and refusing to serve
        // over it would turn a cosmetic problem into an outage.
        try? await pairing.patchDocument(
            path: "devices/\(deviceID)",
            set: ["busyWorkerIds": .array(Self.busyIDsToPublish(locallyBusy: locallyBusyWorkers))]
        )
    }

    /// What the device should say it is running.
    ///
    /// Extracted as a pure function for the reason the rest of this codebase extracts them: the
    /// surrounding method needs a paired device and a live session, so the DECISION would otherwise
    /// only be reachable through an integration test that cannot construct the busy case at all.
    static func busyIDsToPublish(locallyBusy: Set<Int>) -> [FirestoreValue] {
        // ⚠ Sorted, so the wire form is stable and a no-op reconciliation does not look like a
        // change to anything diffing the document.
        locallyBusy.sorted().map { FirestoreValue.integer(Int64($0)) }
    }

    private func restartServing() async -> OpResult {
        guard deviceID != nil else { return OpResult(ok: false, message: "Not paired") }
        stopHeartbeat()
        await restoreSessionIfNeeded()
        // A fresh coordinator, not the retained one: restart exists precisely for the case where the
        // existing one is wedged, and reusing it would carry the wedge across the restart.
        coordinator = PairingCoordinator(backend: pairing)
        startHeartbeat()
        return OpResult(ok: true, message: "Restarted — the worker loop was stopped and brought back up")
    }

    /// The supervisor, as it can honestly exist on a phone.
    ///
    /// ⚠ iOS cannot launch an app on its own and will suspend a backgrounded one, so there is no
    /// equivalent of a launchd unit. What *is* achievable is refusing to let the screen lock while
    /// the app is open, which is what keeps a foregrounded device serving — and that is exactly what
    /// the Settings copy already promises. Anything more would be a claim the OS does not permit.
    private func runDaemonLoop() async -> OpResult {
        guard deviceID != nil else { return OpResult(ok: false, message: "Not paired") }
        await restoreSessionIfNeeded()
        keepAwake?(true)
        startHeartbeat()
        return OpResult(
            ok: true,
            message: "Supervising — the screen stays awake and this device keeps serving while the "
                + "app is open"
        )
    }

    /// Installed by the app so the core stays UIKit-free. Nil in tests and in the package build.
    nonisolated(unsafe) static var keepAwakeHook: (@Sendable (Bool) -> Void)?
    private var keepAwake: (@Sendable (Bool) -> Void)? { Self.keepAwakeHook }

    private func restoreSessionIfNeeded() async {
        guard await !pairing.hasSession(), let token = store.refreshToken else { return }
        await pairing.restoreSession(refreshToken: token)
    }

    // MARK: - Device commands (the web app's Online-pill reset)

    /// How stale a command may be before it is skipped rather than run.
    ///
    /// 30s, matching the desktop backend. A command that has been sitting because the device was
    /// asleep describes a world that no longer exists — running it late is worse than not running
    /// it, because "reset my backend" issued ten minutes ago may now kill a run started since.
    private static let commandStaleMillis: Int64 = 30_000

    /// Poll and execute this device's command queue.
    ///
    /// ⚠ **This did not exist, and its absence was invisible from both ends.** Tapping a device's
    /// Online pill in the web app writes `{action, processed: false, timestamp, submittedBy}` into
    /// `devices/{id}/commands`. The desktop backend has a snapshot listener for it; the phone had
    /// nothing — not even the ability to enumerate a collection. So the document was written,
    /// accepted by the rules, and never read. The web app then waited for the device to go offline
    /// (its proof the backend bounced), never saw it, sat on "Resetting…" for the full 90-second
    /// failsafe and silently gave up. Nothing on the phone had happened, and nothing said so.
    ///
    /// A poll rather than a listener because Firestore's `Listen` is gRPC-only and this client is
    /// REST. Folded into the heartbeat so there is one timer, not two.
    func pollCommands() async {
        guard let deviceID else { return }
        let path = "devices/\(deviceID)/commands"
        guard let docs = try? await pairing.listDocuments(collectionPath: path) else { return }

        for doc in docs {
            // Already handled. The desktop sweeps these at startup; here the delete below is the
            // normal path and this is the guard for one that failed to delete.
            if case .boolean(true)? = doc.fields["processed"] { continue }
            // ⛔ **And already handled BY THIS PROCESS**, which the line above cannot answer.
            //
            // Measured 2026-08-14: one Online-pill reset bounced the device SEVEN times, in two
            // bursts eleven seconds apart — the length of the bounce's own pause — and stopped only
            // when the command aged past the staleness window. Every remote marker here is written
            // with `try?`, so if the ack does not land the device re-reads the same command on
            // every poll and bounces again, and each bounce restarts the loop that re-reads it.
            //
            // A LOCAL memory breaks that cycle without depending on a write succeeding. Firestore
            // is the shared record; this is the thing this process actually knows.
            if seenDeviceCommands.contains(doc.id) {
                NSLog("[SR] command %@ was already handled by this process — not running it again",
                      doc.id)
                continue
            }
            guard case .string(let action)? = doc.fields["action"] else { continue }

            let issued: Int64
            if case .integer(let millis)? = doc.fields["timestamp"] { issued = millis } else { issued = 0 }
            let age = Int64(Date().timeIntervalSince1970 * 1000) - issued
            if issued > 0, age > Self.commandStaleMillis {
                // ⛔ `Int32(age)` was a TRAPPING conversion on an Int64 millisecond age — it kills
                // the process for any command older than ~24.8 days, and for any whose `timestamp`
                // was written in seconds rather than milliseconds (which makes `age` enormous). A
                // diagnostic that can crash the thing it is diagnosing is worse than no diagnostic.
                NSLog("[SR] command %@ is %@ms old — skipping as stale", action, String(age))
                try? await pairing.patchDocument(
                    path: "\(path)/\(doc.id)",
                    set: ["processed": .boolean(true), "staleSkipped": .boolean(true)]
                )
                continue
            }

            // ⛔ Remembered BEFORE anything else can fail. The handler stops the heartbeat — the
            // very task this loop runs in — so everything after it executes under cancellation and
            // may not complete. Recording the id first is the one step guaranteed to happen.
            seenDeviceCommands.append(doc.id)
            if seenDeviceCommands.count > 50 { seenDeviceCommands.removeFirst() }

            // ⚠ Marked processed BEFORE running it, as the desktop does for hard_reset. The handler
            // stops the heartbeat, and a crash mid-handler must not leave a command that re-runs on
            // every poll forever — a reset loop would be far worse than a reset that half-ran.
            //
            // ⚠ And the outcome is REPORTED. Both of these were `try?` with no else, so a denied or
            // cancelled ack was perfectly silent — which is why a seven-times reset could only be
            // diagnosed by counting log lines from the handler.
            do {
                try await pairing.patchDocument(
                    path: "\(path)/\(doc.id)", set: ["processed": .boolean(true)]
                )
            } catch {
                NSLog("[SR] command %@: could not mark it processed (%@) — the local guard is now "
                      + "the only thing stopping a re-run", doc.id, String(describing: error))
            }
            await handle(command: action, deviceID: deviceID)
            // Deleting is the ACK. `/api/devices/reset-pair-code` polls 5s for exactly this.
            //
            // ⛔ **Handed to an UNSTRUCTURED task, because by this line the current one is already
            // cancelled.** `handle` for `hard_reset` calls `stopHeartbeat()`, which cancels the very
            // task `pollCommands` runs in — and an inline `await` inherits that cancellation, so
            // URLSession kills the request. Measured live on 2026-08-14, the moment the failure was
            // finally logged rather than swallowed: `NSURLErrorDomain Code=-999 "cancelled"` on
            // every single reset. The ack never landed and nothing said so.
            //
            // ⚠ The load-bearing part is STRUCTURED vs UNSTRUCTURED, not `Task` vs `Task.detached`:
            // an unstructured task does not inherit cancellation either way. `detached` is chosen
            // only to avoid hopping back onto an actor that is being torn down. Swapping the two
            // therefore changes nothing, which is why no mutation guards this line — it is verified
            // by the live log above, and it is honest to say so rather than to claim a test.
            //
            // ⭐ Order matches the desktop exactly (`research.py`: mark `processed` upfront, delete
            // at the END so "the route's ack lands only after sharedWith-dependent writes are
            // done"). The command is already marked processed, so a failure here costs a leftover
            // document rather than a re-run.
            let ackPath = "\(path)/\(doc.id)"
            Task.detached { [pairing] in
                do {
                    try await pairing.deleteDocument(path: ackPath)
                } catch {
                    NSLog("[SR] command ack delete failed for %@ (%@) — it is marked processed, so "
                          + "it will not re-run, but the document is left behind",
                          ackPath, String(describing: error))
                }
            }
        }
    }

    // MARK: - Run intake (the owner presses go in the web app)

    /// Poll `devices/{id}/queue` and claim what belongs to this device.
    ///
    /// ⛔ **Not `commands`.** `pollCommands` above reads `devices/{id}/commands`, which is device
    /// *operations* — restart, update, ping. This reads the *research lifecycle* channel, which
    /// nothing on this phone has ever read, and which is the only way a topic submitted in the web
    /// app becomes work here.
    ///
    /// A poll rather than a listener because Firestore's `Listen` is gRPC-only and this client is
    /// REST — the desktop's `on_snapshot` start-listener has no equivalent. Folded into the same
    /// 20-second beat as the commands poll, so there is still one timer: a run may wait up to a
    /// beat, which is invisible next to a pipeline measured in tens of minutes, and a second timer
    /// would cost battery for nothing.
    func pollQueue() async {
        guard let deviceID else { return }
        let path = "devices/\(deviceID)/queue"
        // ⛔ The failure is NAMED now. This was `try?` with no else, so a 403 on the queue listing —
        // the classic missing-`deviceId`-custom-claim failure — presented as a healthy device that
        // simply never picked anything up. There is no other symptom to go on: the heartbeat keeps
        // beating, the pills stay green, and the owner's run sits queued forever.
        let docs: [FirestoreREST.ListedDocument]
        do {
            docs = try await pairing.listDocuments(collectionPath: path)
        } catch {
            NSLog("[SR] queue: could not list %@ — %@", path, String(describing: error))
            return
        }
        // ⛔ Publish the EMPTY queue rather than returning. The last run leaving is exactly when the
        // badges have to disappear, and an early return here left the previous `queueOwners` array
        // on the device document for ever — the owner's popup kept showing a run that had finished.
        if docs.isEmpty {
            await publishDeferredQueue(
                deviceID: deviceID, queuePath: path, workersResting: false, deferred: []
            )
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let state = await workerState(deviceID: deviceID)

        // ⛔ **FIFO, because a listing is not a queue.** `listDocuments` returns documents ordered
        // by document NAME, which has nothing to do with submission order — so with two runs
        // waiting and one worker free, the device claimed whichever id happened to sort first. From
        // the outside that is indistinguishable from the queue being ignored, and it is the same
        // ordering the desktop backend applies before it claims.
        let entries = RunQueuePolicy.fifoOrdered(docs.compactMap(QueueEntry.decode))

        // ⛔ **Workers claimed during THIS pass.** `state` is read once, so it cannot see a claim
        // made moments ago in this same loop — and a one-worker device with two queued documents
        // claimed both onto worker 1, which made the FIFO order above irrelevant because the queue
        // was not being respected at all. Pass-local rather than published: a claim reserves the
        // worker immediately, while `busyWorkerIds` should only ever say a run is actually running.
        var reserved: Set<Int> = []
        // ⛔ Everything this pass took off the queue — claimed or deleted. A document claimed a
        // moment ago still carries no `assignedWorker` in the copy held here (the claim went to the
        // server, not to this array), so without this the run that just STARTED would be published
        // as the one waiting at position 1.
        var settled: Set<String> = []

        for entry in entries {
            // ⛔ **Never sweep the run THIS process is executing.** The zombie grace is 30 seconds
            // and a run takes 30 to 90 minutes, so from the second beat onwards our own claim looks
            // exactly like a dead sibling's — and the sweep would delete the queue entry of a run
            // that is progressing perfectly well, then say "stale-skip ZOMBIE" about ourselves in
            // the log. Now that the run is detached this is reachable on every single run.
            if activeRuns.values.contains(where: { $0.researchID == entry.researchId }) {
                continue
            }
            switch RunQueuePolicy.decide(entry, now: now, workerIsResting: !state.resting.isEmpty) {
            case .ignore, .waitOutGrace:
                continue
            case .unsupported(let raw):
                NSLog("[SR] queue action %@ is not supported on an iOS backend — skipped", raw)
                continue
            case .sweepZombie:
                NSLog("[SR] queue: stale-skip ZOMBIE %@ — deleting", entry.researchId.prefix(8).description)
                try? await pairing.deleteDocument(path: "\(path)/\(entry.id)")
                settled.insert(entry.id)
            case .sweepAbandoned(let needsHealthCheck):
                if needsHealthCheck, await runIsStillWanted(entry) {
                    NSLog("[SR] queue: stale-skip ABANDONED exempt — research doc still queued")
                    continue
                }
                NSLog("[SR] queue: stale-skip ABANDONED %@ — deleting", entry.researchId.prefix(8).description)
                try? await pairing.deleteDocument(path: "\(path)/\(entry.id)")
                settled.insert(entry.id)
            case .claim:
                if let worker = await claimAndRun(
                    entry, queuePath: path, state: state, reserved: reserved
                ) {
                    reserved.insert(worker)
                    settled.insert(entry.id)
                }
            }
        }

        // ⭐ **LAST, and it happens on every pass including the ones that claimed nothing.** This is
        // where a parked worker becomes visible: the runs it is not taking are published as a queue
        // with positions, which is what the desktop backend does and what both apps already draw.
        await publishDeferredQueue(
            deviceID: deviceID,
            queuePath: path,
            workersResting: !state.resting.isEmpty,
            deferred: RunQueuePolicy.deferredRuns(entries.filter { !settled.contains($0.id) })
        )
    }

    /// The waiting queue as of the last publish, so an unchanged queue costs no writes.
    private var lastPublishedDeferred: [DeferredRun] = []
    /// What each waiting run was last told about its own position, keyed by research id.
    private var lastPublishedPosition: [String: DeferredRun] = [:]

    /// Publish the waiting queue to the two places the apps read it from.
    ///
    /// ⚠ **On change only, and the change is compared against what was actually accepted.** A queue
    /// that has not moved is the normal state of a parked device — republishing it every 20 seconds
    /// would cost a write per beat per waiting run, for ever, to say nothing. The cache is updated
    /// only after the write succeeds, so a failed publish is retried on the next beat rather than
    /// remembered as done.
    private func publishDeferredQueue(
        deviceID: String, queuePath: String, workersResting: Bool, deferred: [DeferredRun]
    ) async {
        if deferred != lastPublishedDeferred {
            let owners: [FirestoreValue] = deferred.map { run in
                .map([
                    "uid": .string(run.uid),
                    "runId": .string(run.researchID),
                    "title": .string(run.title),
                    "position": .integer(Int64(run.position)),
                ])
            }
            do {
                // A full-array overwrite, like the desktop's. Positions shift as the queue drains,
                // so merging entries would leave a stale position behind every time one leaves.
                try await pairing.patchDocument(
                    path: "devices/\(deviceID)", set: ["queueOwners": .array(owners)]
                )
                NSLog("[SR] queue: published %@ waiting run(s) — %@",
                      String(deferred.count),
                      String(describing: deferred.map { "#\($0.position) \($0.researchID.prefix(8))" }))
                lastPublishedDeferred = deferred
            } catch {
                NSLog("[SR] queue: queueOwners publish FAILED (no queue badge anywhere) — %@",
                      String(describing: error))
            }
        }
        // ⚠ Pruned to the runs still waiting, or a device that has served a hundred runs carries a
        // hundred remembered positions for the life of the process.
        lastPublishedPosition = lastPublishedPosition.filter { key, _ in
            deferred.contains { $0.researchID == key }
        }
        for run in deferred where lastPublishedPosition[run.researchID] != run {
            await publishQueuePosition(run, deviceID: deviceID)
        }
        // ⭐ The keep-alive stamp, and it is what makes parking a worker over a weekend safe. See
        // `RunQueuePolicy.needsRestStamp`: the sweep ages a rest-deferred document from this field
        // once the workers are awake again, and nothing here had ever written it.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for run in deferred
        where RunQueuePolicy.needsRestStamp(run, workersResting: workersResting, now: now) {
            // Best-effort, like every other beat write: the next pass re-stamps.
            try? await pairing.patchDocument(
                path: "\(queuePath)/\(run.queueDocID)", set: ["restDeferredAt": .integer(now)]
            )
        }
    }

    /// Tell one waiting run where it stands, on its own research document.
    ///
    /// ⛔ **`deviceId` travels in the same patch, and without it this is a 403.** The rule is
    /// `request.resource.data.deviceId == request.auth.token.deviceId`, judged on the PAYLOAD — a
    /// patch that names only the queue fields is refused however long the document has carried this
    /// device's stamp. Same trap the finish patch hit.
    ///
    /// ⚠ No ETA. The desktop estimates one from the head run's phase and the moment that phase
    /// started, neither of which this backend publishes; a number derived from nothing would be
    /// worse than the FE's own "no estimate yet", which is what an absent field already means.
    private func publishQueuePosition(_ run: DeferredRun, deviceID: String) async {
        var set: [String: FirestoreValue] = [
            "deviceId": .string(deviceID),
            "queuePosition": .integer(Int64(run.position)),
            "queueTotalAhead": .integer(Int64(run.position - 1)),
            "queueAheadFromSelf": .integer(Int64(run.aheadFromSelf)),
            "queueAheadFromOthers": .integer(Int64(run.aheadFromOthers)),
        ]
        var delete: [String] = []
        if run.behindRunID.isEmpty {
            // ⚠ Cleared rather than left. At the head of the queue the run ahead is the one
            // RUNNING, and a stale "behind <finished run>" renders as waiting on something that
            // ended an hour ago.
            delete = ["queuedBehindRunId", "queuedBehindTitle"]
        } else {
            set["queuedBehindRunId"] = .string(run.behindRunID)
            set["queuedBehindTitle"] = .string(run.behindTitle)
        }
        do {
            try await pairing.patchDocument(
                path: "users/\(run.uid)/researches/\(run.researchID)", set: set, delete: delete
            )
            lastPublishedPosition[run.researchID] = run
        } catch {
            NSLog("[SR] queue: position publish FAILED for %@ (its banner will show no place in "
                  + "the queue) — %@", run.researchID.prefix(8).description,
                  String(describing: error))
        }
    }

    // MARK: - Run control (the owner presses Stop in the web app)

    /// The runs this device is executing, **keyed by worker** — set when a claimed run is launched.
    /// Run control is scoped to these: there is no point polling a research nobody here is running.
    ///
    /// ⛔ **This was a single optional, and that made the second worker a lie.** The device
    /// advertises one worker per browser profile and the owner can add profiles, so a second run
    /// could be claimed onto worker 2 — at which point it overwrote the one field naming the active
    /// run. The first run kept going, invisibly: `pollRunCommands` polled only the survivor, so the
    /// owner's Stop on run 1 reached nothing, and the reset path could only ever kill one of them.
    /// Advertising capacity you cannot track is the same defect the desktop backend fixed by
    /// publishing what it can actually run; the answer here is to make the capacity true instead.
    var activeRuns: [Int: (uid: String, researchID: String)] = [:]

    /// Who can actually stop a run. Held strongly for the same reason as `launcher` — a weakly
    /// held controller deallocates and the owner's Stop then reaches nothing, silently.
    ///
    /// ⛔ **This was never set, and `RunController`'s only conformer in the whole repository was a
    /// TEST SPY.** So `pollRunCommands` read the owner's Stop, classified it correctly, acked it,
    /// and called `stopRun` on nil. Measured 2026-08-14: Stop was pressed, the run continued into a
    /// 40-minute `awaitResponse`, and the worker pill kept pulsing because it was genuinely still
    /// busy. Exactly the shape of the missing `launcher` join — built, unit-tested against a
    /// double, never connected to anything real.
    var controller: (any RunController)?

    /// Make this backend its own run controller.
    ///
    /// ⚠ Assigned where the run loop starts rather than at init: `self` cannot be handed out during
    /// initialisation, and a controller attached later is a controller that is absent for exactly
    /// the window in which the first run can be claimed.
    private func attachRunController() {
        if controller == nil { controller = InAppRunController() }
    }

    /// Stop a run this device is executing, from the app's own UI.
    ///
    /// ⚠ Goes through the SAME controller the web app's Stop reaches, rather than poking the signal
    /// directly. One path means the two cannot behave differently — and the phone's Stop is the one
    /// that gets exercised most, so it is the one most likely to hide a divergence.
    func stopActiveRun(researchID: String) async {
        attachRunController()
        await controller?.stopRun(researchID: researchID)
    }

    /// Device commands this PROCESS has already acted on.
    ///
    /// ⛔ Separate from the document's own `processed` marker, and not a duplicate of it. That
    /// marker is a remote write that can fail — and when it does, the device re-reads the same
    /// command on every poll. For `hard_reset` each re-read bounces the loop that does the
    /// re-reading, which is a self-feeding cycle: measured at seven bounces from one press.
    private var seenDeviceCommands: [String] = []

    private var seenRunCommands: [String] = []
    /// Researches whose command subcollection this process has already attached to, so "first poll"
    /// is a fact about a RUN rather than about the process.
    private var runCommandsAttached: Set<String> = []

    /// Poll `users/{uid}/researches/{rid}/commands` for the run in flight.
    ///
    /// ⛔ **The third channel.** `pollCommands` reads device operations, `pollQueue` reads the
    /// research lifecycle, and this reads **run control** — Stop, Pause, Resume. The web app's Stop
    /// button writes here and nowhere else, so without this the owner has a run they cannot stop,
    /// which is the one thing they said explicitly is not parity.
    func pollRunCommands() async {
        // ⛔ EVERY active run, not one. Polling a single run meant that the moment a second was
        // claimed, the first became unstoppable — the owner's Stop wrote to a subcollection nobody
        // was reading. Snapshotted first: a `stop` handled below can clear the dictionary.
        for (_, active) in activeRuns { await pollRunCommands(for: active) }
    }

    private func pollRunCommands(for active: (uid: String, researchID: String)) async {
        let path = "users/\(active.uid)/researches/\(active.researchID)/commands"
        guard let docs = try? await pairing.listDocuments(collectionPath: path) else { return }

        // ⚠ Per RUN, not per process. "First poll" is what decides whether a command predates this
        // session and must be acked rather than obeyed — and a second run's first poll is its own
        // moment. A process-wide flag made every later run skip the stale check entirely, so a
        // command left over from a previous session would execute against a brand-new run.
        let isFirstPoll = !runCommandsAttached.contains(active.researchID)
        runCommandsAttached.insert(active.researchID)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        for doc in docs {
            guard let entry = RunCommandEntry.decode(doc) else { continue }
            // ⚠ Scoped by research. `dedupeKey` falls back to the DOCUMENT id, which is only unique
            // inside one research's subcollection — unscoped, one run's handled command can mark a
            // different run's command as already-seen, and that one is then silently never obeyed.
            let key = "\(active.researchID)/\(entry.dedupeKey)"
            let decision = RunControlPolicy.decide(
                entry, now: now, isFirstPoll: isFirstPoll,
                alreadySeen: Set(seenRunCommands), key: key
            )
            switch decision {
            case .ignore:
                continue
            case .skipStale:
                NSLog("[SR] run command %@ is from a previous session — acking without running it",
                      String(describing: entry.command))
                await ack(path: path, id: entry.id, staleSkipped: true)
            case .unsupported(let raw):
                NSLog("[SR] run command %@ is not supported on an iOS backend — skipped", raw)
                await ack(path: path, id: entry.id, staleSkipped: false)
            case .execute:
                RunControlPolicy.remember(key, in: &seenRunCommands)
                // Acked BEFORE running, as the desktop does for its terminal commands: `stop` tears
                // down the very loop this code is running in, and a crash mid-handler must not leave
                // a command that re-executes on every poll for the life of the run.
                await ack(path: path, id: entry.id, staleSkipped: false)
                switch entry.command {
                case .stop: await controller?.stopRun(researchID: active.researchID)
                case .pause: await controller?.pauseRun(researchID: active.researchID)
                case .resume: await controller?.resumeRun(researchID: active.researchID)
                default: break
                }
            }
        }
    }

    private func ack(path: String, id: String, staleSkipped: Bool) async {
        var fields: [String: FirestoreValue] = ["processed": .boolean(true)]
        if staleSkipped { fields["staleSkipped"] = .boolean(true) }
        try? await pairing.patchDocument(path: "\(path)/\(id)", set: fields)
        // Deleting is the ack the frontend's own catch-up looks for; `processed` alone leaves the
        // subcollection growing across runs, and every later attach replays the lot.
        try? await pairing.deleteDocument(path: "\(path)/\(id)")
    }

    /// Which worker ordinals are busy and which are resting, read fresh from the device document.
    ///
    /// Fresh rather than from a cached snapshot, and read **once per poll** rather than per entry.
    /// Fresh because placing a run on a worker that another backend marked busy a moment ago is the
    /// same defect the claim protocol exists to prevent, one level down. Once because a queue with
    /// five documents should not cost five reads.
    ///
    /// ⚠ A read failure reports **every** worker busy, so nothing is placed. The safe direction is
    /// to do no work, never to assume a worker is free.
    private func workerState(deviceID: String) async -> (busy: Set<Int>, resting: Set<Int>) {
        do {
            guard let fields = try await pairing.readDocument(path: "devices/\(deviceID)") else {
                return (Set(1...max(workers.count, 1)), [])
            }
            // ⛔ UNIONED with what this process is actually running. The document's `busyWorkerIds`
            // is the only busy signal there was, and **nothing on this device ever wrote it** — so
            // with the run now detached, the very next beat would see every worker free and claim a
            // second entry onto the worker already driving one. Two runs, one set of web views.
            return (Self.busyWorkerIDs(from: fields).union(locallyBusyWorkers),
                    Self.workerIDs(from: fields["restingWorkerIds"]))
        } catch {
            return (Set(1...max(workers.count, 1)), [])
        }
    }

    /// Workers this process is driving a run on, right now.
    private(set) var locallyBusyWorkers: Set<Int> = []

    /// The detached runs, keyed by worker, held so the loop can tell whether any is in flight.
    private var runTasks: [Int: Task<Void, Never>] = [:]

    /// Wait for every run in flight.
    ///
    /// ⚠ Exists because the runs are now DETACHED: without a way to join them, a caller — a test, or
    /// an orderly shutdown — cannot tell "the run has not started" from "the run has not finished".
    /// ⛔ Snapshotted before awaiting: each task clears its own entry on completion, so iterating the
    /// live dictionary mutates it mid-await.
    func awaitRunInFlight() async {
        for task in runTasks.values { await task.value }
    }

    /// Mark a worker busy or free, locally AND on the device document.
    ///
    /// ⚠ Published as well as tracked: the web app's worker pills read `busyWorkerIds`, so a device
    /// that knows it is busy and never says so shows an idle worker for the whole run — which is
    /// exactly the "did my run even start" question this wave exists to answer.
    private func markBusy(_ worker: Int, running: Bool) {
        if running { locallyBusyWorkers.insert(worker) } else { locallyBusyWorkers.remove(worker) }
        guard let deviceID else { return }
        let ids = locallyBusyWorkers.sorted().map { FirestoreValue.integer(Int64($0)) }
        Task { [pairing] in
            // Best-effort: a failed publish costs a stale pill, and failing the run over it would
            // trade a cosmetic problem for a real one. ⚠ But SAID OUT LOUD — this was a bare `try?`
            // with no else, so a denied write left the web app showing an idle worker for a live run
            // with nothing anywhere to explain it.
            do {
                try await pairing.patchDocument(
                    path: "devices/\(deviceID)", set: ["busyWorkerIds": .array(ids)]
                )
                NSLog("[SR] workers: published busy=%@", String(describing: ids.count))
            } catch {
                NSLog("[SR] workers: busy publish FAILED (the web app will show a stale pill) — %@",
                      String(describing: error))
            }
        }
    }

    /// Is an abandoned-looking `start` still wanted? The research document is the authority.
    ///
    /// ⚠ **A read failure means KEEP.** Deleting queued work because a read blipped destroys the
    /// only claim ticket a parked run has. Never destroy work on a transient.
    private func runIsStillWanted(_ entry: QueueEntry) async -> Bool {
        let path = "users/\(entry.uid)/researches/\(entry.researchId)"
        do {
            guard let fields = try await pairing.readDocument(path: path) else { return false }
            if case .string(let status)? = fields["status"] { return status == "queued" }
            return false
        } catch {
            return true
        }
    }

    /// The conditional claim, ported from the desktop's `_try_claim_queue_doc`.
    ///
    /// Four steps and the order matters: early-out on a sibling's claim, route to a free worker,
    /// write the claim **with a precondition**, and treat a lost precondition as the expected
    /// race-loss — returning quietly, never retrying. Retrying a lost precondition reads the
    /// sibling's claim as the new base version and turns a clean loss into a stolen run.
    /// Claim one queue document and place its run. Returns the worker it was placed on, so the
    /// caller can keep the rest of this pass off it.
    ///
    /// ⚠ Returns the worker on the no-launcher path too. That branch leaves a CLAIMED document that
    /// will never run — bad enough on its own — and handing the next document the same worker on top
    /// of it turns one stuck run into two.
    @discardableResult
    private func claimAndRun(
        _ entry: QueueEntry, queuePath: String, state: (busy: Set<Int>, resting: Set<Int>),
        reserved: Set<Int> = []
    ) async -> Int? {
        // No base version, no claim. Claiming blind is worse than not claiming: two backends run
        // the same research and both write to the same documents.
        guard let updateTime = entry.updateTime else {
            NSLog("[SR] queue: %@ has no updateTime — cannot claim safely, skipping",
                  entry.id)
            return nil
        }
        // ⛔ **`state` is read ONCE per poll, so it cannot see a claim this same pass just made.**
        // With one worker and two queued documents that meant both were claimed onto worker 1 —
        // FIFO order was then irrelevant, because the queue had not actually been respected at all.
        // `locallyBusyWorkers` is updated synchronously by `markBusy` below, so unioning it here is
        // what makes the second iteration see the first one's claim.
        guard let worker = RunQueuePolicy.freeWorker(
            count: workers.count,
            busy: state.busy.union(locallyBusyWorkers).union(reserved),
            resting: state.resting
        ) else { return nil }   // every worker is busy or resting; the next beat retries

        do {
            try await pairing.patchDocument(
                path: "\(queuePath)/\(entry.id)",
                set: ["assignedWorker": .integer(Int64(worker)),
                      "claimedAt": .integer(Int64(Date().timeIntervalSince1970 * 1000))],
                ifUpdateTime: updateTime
            )
        } catch FirestoreRESTError.preconditionFailed {
            // The expected path when a Mac backend and this phone watch one account. Not an error.
            NSLog("[SR] queue: %@ was claimed by a sibling first — standing down", entry.id)
            return nil
        } catch {
            NSLog("[SR] queue: claim of %@ failed: %@", entry.id, String(describing: error))
            return nil
        }
        // ⛔ Resolved AFTER the claim rather than at startup, and reported when it is absent. A nil
        // launcher here means the entry has been claimed and will never run — the single worst state
        // this loop can leave behind, because the stamp tells every other backend to keep away.
        guard let deviceID, let launcher = launcher(for: deviceID) else {
            NSLog("[SR] queue: %@ was CLAIMED but no run launcher is attached — the run cannot "
                  + "start, and the claim stamp keeps other backends away from it", entry.id)
            return worker
        }

        // ⛔ **DETACHED, and this is not an optimisation — it is the difference between a run the
        // owner can watch and a device that appears to die.** `beat()` awaits this whole chain, so
        // awaiting a 30-to-90-minute run here means: no heartbeat (the web app shows the device
        // OFFLINE within the beat window), no device commands, and — worst — **no run-command
        // polling, so Stop and Pause from the web app reach nothing at all**. Everything the owner
        // does during the run silently fails, on a run that is in fact progressing normally.
        markBusy(worker, running: true)
        activeRuns[worker] = (uid: entry.uid, researchID: entry.researchId)
        runTasks[worker] = Task { [weak self] in
            await launcher.launch(entry, worker: worker)
            guard let self else { return }
            // ⭐ **Consumption is by DELETE.** The contract says so in as many words, and the device
            // has delete permission on its own queue. Without it our OWN 30-second zombie sweep is
            // what eventually removes the document — deciding that the claimer is dead when the
            // claimer is us — which is the right outcome reached by a reason that would mislead
            // anyone reading the log.
            try? await self.pairing.deleteDocument(path: "\(queuePath)/\(entry.id)")
            self.markBusy(worker, running: false)
            self.activeRuns[worker] = nil
            self.runTasks[worker] = nil
            NSLog("[SR] queue: %@ finished and its queue entry was consumed", entry.id)
        }
        return worker
    }

    private func handle(command: String, deviceID: String) async {
        switch command {
        case "hard_reset", "restart":
            NSLog("[SR] command %@ — bouncing the worker loop", command)
            bounceForReset()
        case "check-update":
            // Stamp `versionCheckedAt` so the web app's About row stops spinning. Allow-listed for
            // the synthetic device user, so this is a write the device may actually make.
            try? await pairing.patchDevice(
                deviceId: deviceID,
                set: ["versionCheckedAt": Int64(Date().timeIntervalSince1970 * 1000)],
                delete: []
            )
        case "clear_local_storage":
            _ = await resetState()
        default:
            // Marked processed by the caller regardless, so an action this device cannot perform is
            // skipped once rather than retried on every poll for the life of the pairing.
            NSLog("[SR] command %@ is not supported on an iOS backend — skipped", command)
        }
    }

    /// The iOS-honest hard reset.
    ///
    /// ⚠ The desktop's version ends in `os._exit`, and a supervisor respawns it. iOS has no
    /// supervisor: terminating the app stops the heartbeat and the device goes offline permanently
    /// rather than bouncing. So this does the part that is real — stop serving, drop the cached run
    /// state, come back — and deliberately keeps the process alive.
    ///
    /// ⚠⚠ **DETACHED, and that is load-bearing.** This is reached from `pollCommands()`, which runs
    /// inside `heartbeatTask`. `stopHeartbeat()` cancels that task — the very task this code is
    /// executing in — and `Task.sleep` in a cancelled task returns IMMEDIATELY rather than
    /// sleeping. Written inline, the pause below silently did not happen: the device stopped
    /// serving and resumed in the same tick. Running it detached is what makes the gap real.
    ///
    /// ⚠ What the pause is NOT. It is tempting to say it exists so the web app can see the device
    /// go down (`RESET_OFFLINE_DETECTION_MS`, 8s) and prove the reset worked — but the phone beats
    /// every 20s, so heartbeat age exceeds 8s for most of any ordinary interval and that detector
    /// trips whether or not a reset happened. **Do not judge an end-to-end reset by the pill going
    /// green.** The pause is here because the device genuinely is not serving during it; the web
    /// app's own signal is too weak to be evidence either way.
    private func bounceForReset() {
        stopHeartbeat()
        // ⛔ **"Kills any active run" is what the web app's own modal promises**, and until the stop
        // channel existed this could not keep it: the run is a DETACHED task, so stopping the
        // heartbeat and clearing the device document left it driving the platforms exactly as
        // before. The owner reset the backend and the run carried on — and worse, the reset cleared
        // `busyWorkerIds`, so the device would happily claim a second run onto the same worker.
        let running = Array(activeRuns.values)
        Task.detached { [weak self] in
            guard let self else { return }
            if !running.isEmpty {
                // ⛔ EVERY run, not the one that happened to be last. The modal promises to kill
                // active runs; leaving a sibling driving the platforms after a reset is the exact
                // shape of the bug that made this per-worker in the first place.
                for run in running { await self.stopActiveRun(researchID: run.researchID) }
                // Give the run a moment to notice at its next check, so the reset does not race
                // ahead and clear state the run is still writing.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            _ = await self.resetState()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            _ = await self.restartServing()
        }
    }

    // MARK: - Doctor, version, diagnostics, reset

    /// The app's own version, which IS the backend version on this device.
    /// Version AND update, in one operation.
    ///
    /// ⚠ These were two rows, and Update's report always began by restating Version's — so the
    /// owner tapped twice to learn one thing. Merged: this always answers "what am I running", and
    /// adds "and here is what is newer" when there is something newer. The ROW TITLE carries the
    /// same signal, so the list shows an update without anything being opened.
    private func versionAndUpdate() async -> OpResult {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var newer: String?
        if let deviceID {
            await restoreSessionIfNeeded()
            let fields = try? await pairing.readDocument(path: "devices/\(deviceID)")
            if case .string(let value)? = fields?["updateAvailable"], !value.isEmpty {
                newer = value
            }
        }

        // ⚠ An iOS app cannot replace its own binary — there is no `pipx install --force` here, and
        // a button that appeared to update would be exactly the failure this wave exists to remove.
        // So the report names the real route rather than implying one that does not exist.
        let closing = newer == nil
            ? "The server reports nothing newer."
            : "An iOS backend updates by installing a new build (bin/build_app.sh), not from inside "
              + "the app."
        return OpResult(
            ok: true,
            message: newer.map { "Update available: \($0) (running \(short))" }
                ?? "Up to date — Super Research \(short)",
            detail: """
                Backend version   \(short)
                Build             \(build)
                Update            \(newer.map { "\($0) available" } ?? "none — this is current")
                Runs on           this iPhone — the app is the backend

                \(closing)
                """
        )
    }

    /// Real checks, reported as findings rather than as a spinner that ends in "OK".
    ///
    /// Every line is something that has actually gone wrong at least once in this project: a pairing
    /// that never reached storage, a session that could not be re-armed after relaunch, a worker
    /// with an empty cookie jar, an API key nobody noticed had rotated.
    private func doctor() async -> OpResult {
        var findings: [String] = []
        var problems = 0

        if let deviceID {
            findings.append("✓ Paired — device \(deviceID.prefix(8))…")
        } else {
            findings.append("✗ Not paired")
            problems += 1
        }

        if store.deviceID != nil {
            findings.append("✓ Identity is on disk — it will survive a relaunch")
        } else if deviceID != nil {
            findings.append("✗ Identity is in memory only — this pairing will be LOST on relaunch")
            problems += 1
        }

        if store.refreshToken != nil {
            findings.append("✓ Session credential stored")
        } else if deviceID != nil {
            findings.append("✗ No stored session — the device cannot re-authenticate after a relaunch")
            problems += 1
        }

        if let deviceID {
            do {
                await restoreSessionIfNeeded()
                if try await pairing.readDocument(path: "devices/\(deviceID)") == nil {
                    findings.append("✗ The device document is gone from the server")
                    problems += 1
                } else {
                    findings.append("✓ Reached the server and read this device's record")
                }
            } catch {
                findings.append("✗ Could not reach the server: \(error)")
                problems += 1
            }
        }

        findings.append(heartbeatTask == nil ? "✗ Not serving — the heartbeat is stopped"
                                             : "✓ Serving — heartbeat is running")
        if heartbeatTask == nil, deviceID != nil { problems += 1 }

        // Per worker, because a device-level answer hides the worker that is actually signed out.
        for worker in workers.workers {
            let signedIn = worker.logins.filter { $0.value }.count
            let checked = worker.logins.count
            if checked == 0 {
                findings.append("• Worker \(worker.id): no platform checked yet")
            } else {
                let mark = signedIn == checked ? "✓" : "•"
                findings.append("\(mark) Worker \(worker.id): \(signedIn)/\(checked) platforms signed in")
            }
        }

        for kind in APIKeyStore.Kind.allCases {
            findings.append(APIKeyStore.has(kind)
                            ? "✓ \(kind.rawValue) present"
                            : "• \(kind.rawValue) not set")
        }

        return OpResult(
            ok: problems == 0,
            message: problems == 0 ? "Doctor: everything checks out"
                                   : "Doctor: \(problems) problem\(problems == 1 ? "" : "s") found",
            detail: findings.joined(separator: "\n")
        )
    }


    /// A shareable report of everything that matters, with nothing secret in it.
    private func collectDiagnostics() async -> OpResult {
        let doctorResult = await doctor()
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        // ⚠ No pair code, no poll secret, no refresh token, no API key value. A diagnostics bundle
        // is made to be sent to someone, so anything credential-shaped must never enter it — the
        // device id is truncated for the same reason.
        let report = """
            Super Research — device diagnostics
            Version      \(short)
            Device       \(deviceID.map { String($0.prefix(8)) + "…" } ?? "not paired")
            Workers      \(workers.count)
            Serving      \(heartbeatTask == nil ? "no" : "yes")

            \(doctorResult.detail ?? "")
            """
        return OpResult(ok: true, message: "Diagnostics ready to share", detail: report)
    }

    /// Drop cached run state. **Not** logins, not API keys, not the pairing.
    private func resetState() async -> OpResult {
        guard let deviceID else { return OpResult(ok: false, message: "Not paired") }
        await restoreSessionIfNeeded()
        do {
            // The device's own view of what it is running. Clearing these is what makes a wedged
            // worker claimable again; the frontend recomputes the queue from them.
            try await pairing.patchDevice(
                deviceId: deviceID,
                set: ["workers": [String: Any](), "busyWorkerIds": [Any](),
                      "queueOwners": [Any]()],
                delete: []
            )
            return OpResult(
                ok: true,
                message: "Cleared queued work and cached run state. Logins and pairing are untouched."
            )
        } catch {
            return OpResult(ok: false, message: "Clear state failed: \(error)")
        }
    }

    /// Stage 1, driven by the already-tested coordinator, with progress reported as it happens.
    ///
    /// Callbacks rather than a single return value because the *interesting* moments are in the middle:
    /// the code appears seconds before the claim, and the claim starts a five-minute clock the user
    /// cannot otherwise see.
    enum PairOutcome {
        case success
        case failure(String)
    }

    func startPairing(
        onCode: @escaping (String, String) -> Void,
        onClaimed: @escaping () -> Void
    ) async -> PairOutcome {
        let coordinator = PairingCoordinator(backend: pairing)
        do {
            let (secret, display, id) = try await coordinator.begin()
            deviceID = id
            inFlightSecret = secret.hexText
            pairCode = display
            onCode(display, id)

            // ⚠ 15 minutes, not the coordinator's 5-minute default. Parity with the backend, whose
            // `DEFAULT_POLL_TIMEOUT_SECONDS = 15 * 60` carries the comment "Matches FE
            // pendingCustomToken TTL". At 5 minutes the app would give up ten minutes before the
            // code actually expires, and the user would be told nobody claimed it while the web app
            // still showed it as claimable.
            try await coordinator.awaitClaim(
                secret: secret, deviceId: id, pollInterval: 2, timeout: 15 * 60
            )
            onClaimed()
            // Immediately, not on the next heartbeat tick: the confirm is what cancels the TTL.
            // ⚠ `workers.count`, not the literal `1` this used to send. The frontend sizes the whole
            // capacity UI off this number, so a device with three browser profiles that reported 1
            // would be handed one run at a time forever.
            try await coordinator.confirmPairing(deviceId: id, workerCount: workers.count)
            // ⚠ Persisted only NOW, after the confirm. An earlier version saved before the claim wait
            // so a killed app would not "orphan" the device — but that traded one problem for a worse
            // one: an app killed mid-flow kept an identity for a device that was never confirmed, and
            // on next launch it heartbeat a document that the TTL had already deleted. The device
            // showed "Not paired" while still beating.
            //
            // Losing the identity when the flow dies is the correct outcome: an unconfirmed device is
            // already dead (the confirm window is five minutes), and the server-side initiate-pair TTL
            // reaps the document on its own.
            // ⚠ The refresh token, not just the id. `signIn` runs exactly once — here — so this is
            // the only moment the long-lived credential exists to be captured. Without it the app
            // relaunches with an identity it cannot authenticate, which means it can neither
            // heartbeat nor unpair itself, and the pairing is effectively dead on the next launch.
            let refresh = await pairing.sessionRefreshToken()
            let saved = store.save(
                deviceID: id, pollSecret: secret.hexText, refreshToken: refresh
            )
            self.coordinator = coordinator
            // ⚠ Reported, not swallowed. A pair whose identity never reached the Keychain works
            // perfectly until the app is next launched and then presents as never having been
            // paired — with no error, at a moment far away from the cause. Saying so here is the
            // difference between a five-minute fix and re-pairing repeatedly without knowing why.
            guard saved, store.verifyRoundTrip(deviceID: id) else {
                return .failure(
                    "Paired, but this device's identity could not be saved to the Keychain — it "
                    + "would be lost on the next launch. The app is signed without "
                    + "keychain-access-groups; rebuild with bin/build_app.sh."
                )
            }
            inFlightSecret = nil
            DeviceIdentityStore.lastPairedDeviceID = id
            DeviceIdentityStore.clearLostPairingNote()
            return .success
        } catch PairingError.timedOut {
            return .failure("No one claimed the code in time. Tap Start to try again.")
        } catch PairingError.confirmDeadlineMissed(let elapsed) {
            // Named precisely: past the deadline the document is already gone, so the *next* error
            // would be a permissions failure pointing nowhere near the real cause.
            return .failure("Claimed, but the 5-minute confirm window closed after \(Int(elapsed))s. Pair again.")
        } catch {
            return .failure("Pairing failed: \(error)")
        }
    }

    /// Stage 2's intent, mirrored so the frontend's Account-page toggle reflects it live.
    ///
    /// Best-effort by design, matching the backend: a failure here must not fail a pair that is
    /// otherwise complete. `supervised` is in the rules' synth allow-list, so the device may write it.
    func setSupervised(_ enabled: Bool) async {
        // ⚠ Recorded LOCALLY first, and that is the half that was missing. The toggle used to write
        // `supervised` to the device document and stop — nothing consumed it, so "come online
        // automatically" did nothing at all. Launch has to know the intent before it can act on it,
        // and it cannot wait on a network read to decide whether to start serving.
        Self.storedSupervised = enabled
        keepAwake?(enabled)
        if enabled {
            startServingIfPaired()
        } else {
            // Turning it off stops serving now, rather than at the next launch. A toggle whose
            // effect is deferred to an event the owner cannot see reads as a toggle that did
            // nothing.
            stopHeartbeat()
        }
        guard let deviceID else { return }
        try? await pairing.patchDevice(
            deviceId: deviceID, set: ["supervised": enabled], delete: []
        )
    }

    /// The On Startup intent, persisted on this device.
    ///
    /// Local rather than read back from Firestore because it is consulted at launch, before there is
    /// a session — and because it decides whether to *create* the session at all.
    static var storedSupervised: Bool {
        get { UserDefaults.standard.bool(forKey: supervisedKey) }
        set { UserDefaults.standard.set(newValue, forKey: supervisedKey) }
    }
    private static let supervisedKey = "sr.supervised"

    private func startServingIfPaired() {
        guard deviceID != nil else { return }
        if coordinator == nil { coordinator = PairingCoordinator(backend: pairing) }
        // ⛔ The AUTO-START path, and the one that matters most for the stale-busy fix: a device
        // whose previous process was killed mid-run comes back through HERE, not through the
        // Settings button. Reconciling only in `startServing` would leave the exact case the
        // reconciliation exists for uncovered.
        startHeartbeat()
    }

    /// Stage 4's result: record what a login check saw **for one worker**, then publish the device's
    /// combined state.
    ///
    /// ⚠ Per worker, because a worker is a browser profile with its own cookie jar. What gets written
    /// to the device doc is `WorkerRegistry.deviceLogins()` — the intersection across every worker,
    /// not the raw observation. A device that reported ChatGPT signed in because *one* of its three
    /// profiles was would be handed runs that two of its workers cannot do.
    ///
    /// `logins` is a `map<string, bool>` in the 22-key device allow-list, so the wire shape is
    /// unchanged: per-worker detail stays on the device, where the app renders it.
    func reportLogins(_ state: [String: Bool], forWorker workerID: Int) async {
        for (platform, signedIn) in state {
            workers.setLogin(worker: workerID, platform: platform, signedIn: signedIn)
        }
        await publishLogins()
    }

    /// Park or wake one worker, by rewriting `restingWorkerIds`.
    ///
    /// ⚠ **Needs the rules change deployed.** `restingWorkerIds` was in the OWNER allow-list only,
    /// so this write 403s until `firestore.rules` is deployed with it added to the synthetic-device
    /// list. The error is surfaced rather than swallowed: a rest toggle that silently does nothing
    /// is worse than one that says why.
    ///
    /// A whole-array replace, matching the web app's own `toggleRest` — Firestore's `arrayUnion`
    /// would not let a stale out-of-range id be pruned, and the frontend prunes on every write for
    /// exactly that reason.
    func setWorkerResting(_ workerID: Int, resting: Bool, current: Set<Int>) async -> OpResult {
        guard let deviceID else { return OpResult(ok: false, message: "Not paired") }
        await restoreSessionIfNeeded()

        var next = current
        // Prune ids past the current capacity, as the frontend does: a worker parked and then
        // removed leaves an id with no pill, which nothing can ever un-park.
        next = next.filter { $0 >= 1 && $0 <= workers.count }
        if resting { next.insert(workerID) } else { next.remove(workerID) }

        do {
            // ⚠ INTEGERS. This wrote `.map(String.init)`, and the web app types the field
            // `number[]` and filters reads on `typeof n === "number"` — so a string entry was
            // invisible to it while the backend (which accepts digit-strings) honoured it. The
            // worker really stopped taking runs and the web app showed full capacity.
            try await pairing.patchDevice(
                deviceId: deviceID,
                set: ["restingWorkerIds": next.sorted()],
                delete: []
            )
            return OpResult(
                ok: true,
                message: resting ? "Worker \(workerID) is resting" : "Worker \(workerID) is awake"
            )
        } catch {
            // Name the STATUS. A 403 here means one specific thing — `restingWorkerIds` is still
            // owner-only in the DEPLOYED rules — and saying so turns an opaque failure into an
            // instruction. Anything else is a different problem and must not be mislabelled as it.
            if case FirestoreRESTError.http(let status, _) = error, status == 403 {
                return OpResult(
                    ok: false,
                    message: "Worker rest needs the updated Firestore rules deployed — the device "
                        + "is not allowed to write restingWorkerIds yet (403)."
                )
            }
            return OpResult(
                ok: false,
                message: "Could not change worker \(workerID): \(error)"
            )
        }
    }

    /// Push the combined per-worker login state to the device document.
    func publishLogins() async {
        guard let deviceID else { return }
        let combined = workers.deviceLogins()
        guard !combined.isEmpty else { return }
        try? await pairing.patchDevice(
            deviceId: deviceID, set: ["logins": combined], delete: []
        )
    }

    /// Stage 5: go online and STAY online.
    ///
    /// ⚠ Without this the app pairs and then goes silent. The frontend decides "online" from
    /// `lastHeartbeat`, so a device that beats once looks online for a moment and offline forever after
    /// — which presents as "pairing worked but the web app won't send me runs".
    ///
    /// The heartbeat *is* the confirm, on every tick, so it also keeps `pairConfirmedAt` true.
    func goOnline(supervised: Bool) async {
        await setSupervised(supervised)
        // ⚠ Started AFTER `setSupervised`, and unconditionally, on purpose. `setSupervised(false)`
        // stops the heartbeat — correct everywhere else, wrong here. On Startup governs whether the
        // device serves *automatically on a later launch*; it does not mean "having just finished
        // setting this device up, leave it offline". Stage 5's whole promise is that the device is
        // ready now.
        startServingIfPaired()
    }

    /// Forget this device's identity and stop reporting.
    ///
    /// Distinct from retire: retire tells the server, this only clears the local side. Needed because a
    /// flow interrupted mid-pair, or a device document deleted from the web app, leaves an identity
    /// here that can never work again — and without a way to clear it the app is permanently stuck
    /// heartbeating a document that does not exist.
    /// Abandon a pair that is part-way through, and leave nothing behind on the server.
    ///
    /// ⚠ `initiate-pair` creates THREE things and a Firestore TTL sweep can clean up only one of
    /// them: it deletes documents, and cannot reach Firebase Auth at all. The synthetic machine
    /// login and the `_internal/device_secrets` entry outlive any sweep — which is how eighteen
    /// orphaned logins accumulated between May and July, one per pair that was started and never
    /// claimed. So a cancel has to say so explicitly rather than relying on expiry.
    ///
    /// Two routes, because the device's credentials differ by stage:
    ///
    /// * **before the claim** there is no session at all, so `cancel-pair` proves ownership with the
    ///   poll secret;
    /// * **after the exchange** the device is a real authenticated principal, and `unpair-self` is
    ///   the route that accepts it. `cancel-pair` deliberately refuses a claimed device.
    ///
    /// Best-effort and non-blocking: a cancel that fails must still return the UI to a clean state,
    /// because the alternative is a flow the owner cannot leave. The backstop for a client that dies
    /// mid-pair is server-side and is not this method's job.
    func abandonPairing() async {
        guard let id = deviceID else { resetPairing(); return }
        let secret = inFlightSecret
        let hadSession = await pairing.hasSession()

        // ⚠ Local state is cleared FIRST, before the network call. Two reasons, both from the
        // server-side spec: the caller must not block dismissal on this (a cancel you cannot leave
        // is worse than a leaked document), and clearing up front makes a double-cancel naturally
        // idempotent instead of sending a second request.
        inFlightSecret = nil
        resetPairing()

        if hadSession {
            // Past the exchange this is a real authenticated principal, and `cancel-pair` refuses a
            // claimed device by design — so `unpair-self` is the route that accepts it.
            _ = try? await pairing.unpairSelf(deviceId: id)
            return
        }
        guard let secret else { return }
        do {
            _ = try await pairing.cancelPair(deviceId: id, pollSecret: secret)
        } catch FirestoreRESTError.http(status: 409, _) {
            // ⚠ 409 means the device WAS claimed — the pair actually succeeded while the owner was
            // reaching for Cancel. Not an error, and specifically not retryable: refusing a claimed
            // device is exactly what bounds an unauthenticated endpoint to devices nobody adopted.
            NSLog("[SR] cancel-pair: %@ had already been claimed (409) — it really did pair", id)
        } catch FirestoreRESTError.http(let status, _) where status >= 500 || status == 429 {
            // Distinguished because it means something different. The route deletes login, then
            // secret, then document, and returns 500 with everything else intact when the login
            // delete fails — so nothing was removed and a retry is safe. A 429 is the same shape:
            // the handler rate-limits before it touches anything. Safe to retry — but NOT here. A killed app never runs its own cleanup at all, so correctness belongs to the
            // server-side backstop, and an on-device retry queue would be a second, weaker copy of
            // it that only helps in the case that was already fine.
            NSLog("[SR] cancel-pair: server error %d for %@ — nothing was deleted, safe to retry; "
                  + "leaving it to the server-side sweep", Int32(status), id)
        } catch {
            // Logged, never swallowed. This leak is invisible from the device: the tile is hidden
            // until it is claimed, and the stranded artefact is a Firebase login nobody can see. A
            // silent failed cancel is precisely how the original orphans accumulated unnoticed.
            NSLog("[SR] cancel-pair FAILED for %@ (%@) — a half-made device may be left behind",
                  id, String(describing: error))
        }
    }

    func resetPairing(reason: String? = nil) {
        // ⚠ Leave a trace when this was NOT the owner's decision. Without it, a pairing that
        // evaporates is indistinguishable from one that never existed: the app shows "Get started",
        // the owner re-pairs, and a SECOND device document appears with no workers and no logins —
        // which is exactly the "it opened as a new backend" report.
        if let reason { DeviceIdentityStore.noteLostPairing(deviceID: deviceID, reason: reason) }
        stopHeartbeat()
        store.clear()
        deviceID = nil
        pairCode = ""
        coordinator = nil
    }

    /// Restart the heartbeat for an already-paired device — on launch, and on returning to foreground.
    ///
    /// ⚠ Verifies the device document still exists first. A stale identity — from a flow that died
    /// mid-pair, or a device removed from the web app — would otherwise beat forever against a
    /// document that is gone, and every beat 404s while the UI says "Not paired". Clearing it is what
    /// lets the user simply pair again.
    func resumeIfPaired() {
        guard deviceID != nil else { return }
        if coordinator == nil { coordinator = PairingCoordinator(backend: pairing) }
        Task { [weak self] in
            guard let self, let id = self.deviceID else { return }

            // ⚠ Re-arm the session FIRST. `signIn` only ever runs during pairing, so a relaunched
            // app has a device id and no credentials at all — every request below would throw
            // `notAuthenticated`, which the old code could not tell apart from a deleted document.
            if await !self.pairing.hasSession(), let token = self.store.refreshToken {
                await self.pairing.restoreSession(refreshToken: token)
            }

            // ⚠ NOT `try?`. `getDocument` returns nil for a 404 and THROWS for everything else, so
            // `try?` flattened "the device was deleted" and "we are offline / not signed in / the
            // token expired" into the same nil — and the branch below deletes the pairing. A dropped
            // Wi-Fi connection at launch was enough to unpair the device permanently, with the log
            // line confidently reporting the document was gone.
            do {
                if try await self.pairing.readDocument(path: "devices/\(id)") == nil {
                    self.resetPairing(
                        reason: "the device record was deleted on the server (a 404, not a "
                            + "connection problem)"
                    )
                    return
                }
            } catch {
                // Keep the identity. A device that cannot reach the server is offline, not unpaired.
                NSLog("[SR] could not verify pairing for %@ (%@) — keeping the identity and "
                      + "retrying on the next heartbeat", id, String(describing: error))
            }

            // ⚠ THIS is what On Startup means. It used to start the heartbeat unconditionally, so
            // the toggle was decorative: the device came online on every launch whether or not the
            // owner had asked it to. Now "off" means the device stays quiet until Start serving is
            // tapped — which is exactly why Start serving and Restart exist in the Runtime group.
            guard Self.storedSupervised else {
                NSLog("[SR] paired but On Startup is off — not serving until asked")
                return
            }
            self.keepAwake?(true)
            self.startHeartbeat()
        }
    }

    func startHeartbeat() {
        // ⚠ Ensure the coordinator exists FIRST. `beat()` guards on it and returns silently when it
        // is nil, so calling `startHeartbeat()` on its own used to spin a loop that ticked every 20
        // seconds and wrote nothing — a device that looked like it was serving and never reported
        // anything. Found by a test that called this directly, which is exactly what any future
        // caller would do.
        ensureCoordinator()
        // ⭐ **Both of these live HERE, at the one choke point every start path calls**, rather than
        // at each of the four (`startServing`, `restartServing`, `runDaemonLoop`,
        // `startServingIfPaired`). A join that has to be remembered at four call sites is a join
        // that will be missing from the fifth — which is precisely how `controller` came to be nil
        // in the first place, and how the owner's Stop reached nothing for so long.
        attachRunController()
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            // ⚠ Inside the heartbeat task and BEFORE the first beat, rather than in a `Task` of its
            // own. A stray task is unordered with respect to the beats and cancelled by nothing, so
            // a restart could race its own reconciliation — and no caller could await it, which is
            // also what made it untestable.
            await self?.reconcileBusyWorkers()
            while !Task.isCancelled {
                await self?.beat()
                // 20s: comfortably inside any staleness window the frontend applies, and cheap. The
                // desktop backend beats on a similar cadence.
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// The resting set as of the last beat, so a change can be named rather than merely happening.
    private var lastPublishedResting: Set<Int> = []

    /// The one-line state of the device, as the document just reported it.
    ///
    /// ⚠ Reports what the DOCUMENT said, not what the app believes, with the single exception of
    /// `workers=` — the registry is the only writer of the worker count, so the document's copy lags
    /// by a beat. Everything else is deliberately server truth: when the owner parks a worker from
    /// the web app and the phone does not move, the question being asked is "did the document
    /// change", and a line rendering the phone's own idea of the resting set would answer it with
    /// the phone's own idea and look like a confirmation.
    ///
    /// `doc=` distinguishes an unreadable tick from an empty one. `loadSnapshot` returns
    /// `online: false` and leaves the sets empty when the read throws, which is otherwise
    /// indistinguishable from a device the server says is quiet.
    static func beatSummary(snapshot: DeviceSnapshot, workerCount: Int) -> String {
        let doc = snapshot.online ? "ok" : "unreadable-or-offline"
        // ⭐ **`runMap` is a DIFFERENT field from `busy`, and the web app believes the map.** `busy`
        // is `busyWorkerIds`; the Shared-with popup builds its pills from the `workers` MAP, and a
        // worker listed there renders as a busy pill — which the web app makes UNCLICKABLE. A stale
        // entry left by a crashed run therefore disables the owner's rest toggle in the browser
        // while the phone, which reads the other field, shows the same worker idle and toggles
        // fine. That asymmetry is invisible unless both fields are on the same line.
        let runMap = snapshot.workers.filter(\.isBusy).map(\.id).sorted()
        // ⚠ Truncated: this is a real account identifier and the log is a file the owner shares.
        let owner = snapshot.ownerUID.isEmpty ? "none" : String(snapshot.ownerUID.prefix(8))
        // ⚠ WHICH document this is. A re-pair leaves the previous device's tile on the Account page
        // under the SAME name — `UIDevice.name` for both — so two tiles can be indistinguishable in
        // the browser while only one of them is the device that is running. A toggle on the dead
        // tile writes a document nothing reads, which looks exactly like a broken sync.
        let device = snapshot.deviceID.isEmpty ? "none" : String(snapshot.deviceID.prefix(8))
        return "beat: device=\(device) doc=\(doc) workers=\(workerCount)"
            + " busy=\(snapshot.busyWorkerIDs.sorted())"
            + " runMap=\(runMap)"
            + " resting=\(snapshot.restingWorkerIDs.sorted())"
            + " queued=\(snapshot.queue.count)"
            + " owner=\(owner)"
    }

    /// The coordinator every beat guards on. One definition, called by both start paths.
    private func ensureCoordinator() {
        if coordinator == nil, deviceID != nil {
            coordinator = PairingCoordinator(backend: pairing)
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Run exactly one beat, for tests.
    ///
    /// ⚠ Exists because `startHeartbeat()` spawns an unstructured 20-second loop that no test can
    /// await or bound — a test that started it would either race the first tick or wait 20 seconds
    /// for the second. The loop's body is the thing worth asserting on, so it is reachable directly.
    func beatOnceForTesting() async {
        // ⚠ Ensures the coordinator EXACTLY as `startHeartbeat()` does. Without it `beat()` returns
        // on its first guard and the helper silently exercises nothing — which is how the first
        // version of this passed while asserting on an empty array.
        ensureCoordinator()
        await beat()
    }

    private func beat() async {
        guard let deviceID, let coordinator else { return }
        // Failures are swallowed deliberately: a dropped beat is normal (a tunnel, a sleeping Mac), and
        // the next tick recovers. Tearing the loop down on one failure is how a device goes permanently
        // offline after a momentary blip.
        // Re-read every tick rather than captured once: Add worker must take effect on the next beat
        // instead of on the next relaunch.
        try? await coordinator.heartbeat(deviceId: deviceID, workerCount: workers.count)
        await publishWorkerRuns(deviceID: deviceID)
        // One timer, not two. The web app's reset budget is ~8-15s and the beat is 20s, so a
        // command can wait up to a beat — acceptable, and far better than the previous "never".
        await pollCommands()
        // ⚠ Run CONTROL before intake. A Stop for the run in flight must be honoured before this
        // device claims another one — reversed, an owner stopping a run watches the phone pick up
        // the next queued topic in the same tick, which reads as the Stop having done nothing.
        await pollRunCommands()
        // Then the research lifecycle. Device commands came first because a `restart` that arrived
        // alongside a queued run should bounce the loop before the run is claimed, not after —
        // claiming and then immediately bouncing leaves the claim stamped on a run nobody executes.
        await pollQueue()

        // ⭐ LAST, and after the polls on purpose: a claim made moments ago should be reflected in
        // the snapshot this tick publishes rather than in the next one.
        //
        // ⚠ Costs one extra document read per 20s. `beat()` reads `devices/{id}` ZERO times on an
        // idle tick today — `workerState` is the only reader and `pollQueue` returns before it
        // whenever the queue is empty — so this is a real addition rather than a free ride, and it
        // is the price of the web app's rest toggle reaching the phone at all.
        if let onSnapshot {
            let snapshot = await loadSnapshot()
            // ⭐ EVERY tick, unconditionally — see `beatLogger`. This is the one line that says the
            // beat ran, the document was readable, and what it said; without it "the web app's
            // toggle never arrived" cannot be told apart from "the beat stopped".
            beatLogger?(Self.beatSummary(snapshot: snapshot, workerCount: workers.count))
            // ⚠ Logged ON CHANGE, not every tick. A line every 20 seconds saying the same thing is
            // noise that hides the one tick where it differs — and the change is the whole event:
            // it is the web app's toggle arriving. Silence here would make the fix unverifiable
            // during an e2e, which is how it stayed broken this long.
            if snapshot.restingWorkerIDs != lastPublishedResting {
                NSLog("[SR] workers: resting set changed %@ -> %@ (from the device document)",
                      String(describing: lastPublishedResting.sorted()),
                      String(describing: snapshot.restingWorkerIDs.sorted()))
                lastPublishedResting = snapshot.restingWorkerIDs
            }
            onSnapshot(snapshot)
        }
    }

    /// Say WHOSE run each busy worker is running.
    ///
    /// ⛔ **`devices/{id}.workers` was read and cleared by this device and never written.** It is the
    /// map that carries `{uid, title, phase, totalPhases}` per worker, and it is what puts a busy
    /// pill on the right PERSON — in the phone's People popup and in the web app's "Shared with"
    /// popup alike. Without it every run showed only as an anonymous `busyWorkerIds` entry, so a
    /// run always looked like it belonged to nobody.
    ///
    /// ⚠ Published from the BEAT rather than at each phase change, and the whole map is rewritten
    /// each time. A per-phase patch would need dotted-path merges and a delete for the worker that
    /// just finished; rewriting the map makes "this worker is no longer running" the same operation
    /// as "this worker moved to phase 2", so a finished run cannot leave a pill behind.
    private func publishWorkerRuns(deviceID: String) async {
        let runs = LiveRunActivity.shared.runs
        var map: [String: FirestoreValue] = [:]
        for (worker, facts) in runs {
            map[String(worker)] = .map([
                "uid": .string(facts.uid),
                "title": .string(facts.title),
                "phase": .integer(Int64(facts.phase)),
                "totalPhases": .integer(Int64(facts.totalPhases)),
                // ⛔ Published so the ELAPSED TIMER has something to count from. Browser watch
                // built its per-worker snapshot with `elapsedSeconds: 0` because this map carried
                // no start time — so every live run showed 00:00, which reads as a frozen app.
                "startedAt": .integer(facts.startedAtMillis),
                // The PLATFORM's own phase, published beside the run-wide one rather than over it.
                "platformPhase": .integer(Int64(facts.platformPhase)),
            ])
        }
        // Best-effort, like every other beat write: a dropped publish costs one stale tick, and the
        // next beat corrects it. Failing the beat over it would take the device offline.
        try? await pairing.patchDocument(path: "devices/\(deviceID)", set: ["workers": .map(map)])
    }

    /// Unpair: what `superresearch --unpair` does, from the phone.
    ///
    /// ⚠ This used to write `status: "retired"` and nothing else. **No frontend code reads that
    /// field** — the web app derives online/offline from `lastHeartbeat` — so the device document,
    /// its `ownerUid`, its `pairConfirmedAt`, the synthetic Auth user and the stored device secret
    /// all survived. The tile stayed on the Account page forever while the app cheerfully reported
    /// "Unpaired". The terminal does the one thing that actually works: `POST
    /// /api/devices/unpair-self` authenticated as the synthetic device user, which is the only route
    /// that can delete the document (`allow create, delete: if false` for every client).
    private func release(_ op: Operation) async -> OpResult {
        guard let deviceID else { return OpResult(ok: false, message: "Not paired") }
        // Stopped FIRST. A beat racing the release would rewrite `lastHeartbeat` after it and leave
        // a released device looking online — a device you cannot get rid of.
        stopHeartbeat()
        do {
            // Re-arm the session if this is a relaunched app that has never signed in this process.
            // Unpair is exactly the operation most likely to be the first thing done after a launch.
            if await !pairing.hasSession(), let token = store.refreshToken {
                await pairing.restoreSession(refreshToken: token)
            }
            let action = try await pairing.unpairSelf(deviceId: deviceID)
            clearLocalIdentity()
            return OpResult(
                ok: true,
                message: action == "already-gone"
                    ? "Already unpaired — the device was no longer on the server"
                    : "Unpaired"
            )
        } catch {
            // ⚠ The local identity is KEPT on failure, deliberately. Clearing it here would leave a
            // device that still exists server-side, still holds the owner's slot, and can never be
            // reached again to remove it — because the credential that authorises the removal is the
            // thing we just deleted. A failed unpair must stay retry-able.
            startHeartbeat()
            return OpResult(
                ok: false,
                message: "Unpair failed, so this device is still paired: \(error)"
            )
        }
    }

    private func clearLocalIdentity() {
        // Deliberate. No breadcrumb — the owner asked for this and does not need telling.
        DeviceIdentityStore.clearLostPairingNote()
        store.clear()
        deviceID = nil
        pairCode = ""
        coordinator = nil
    }
}

// MARK: - Identity persistence

/// Where the device's identity lives between launches.
///
/// The poll secret is a 256-bit credential that authorises collecting this device's custom token, so
/// it belongs in the Keychain — a plist in the app container is readable by anything that can read
/// the container and is included in unencrypted backups.
///
/// ⚠ **But the Keychain is not always available, and pretending otherwise lost a real pairing.** An
/// unprovisioned Simulator build is signed ad-hoc, so it carries no `application-identifier` and has
/// no keychain access group: every write fails with `errSecMissingEntitlement` (-34018). The app
/// still worked for the whole session, because the id and secret were also in memory — the loss only
/// appeared on the next launch, as a device that had apparently never been paired. Signing with the
/// entitlements is not a way out: they embed fine, and then SpringBoard refuses to launch the app at
/// all (see the comment in `bin/build_app.sh`).
///
/// So this store *prefers* the Keychain and *falls back* to a protected file in the app container,
/// loudly. The fallback is a deliberate, logged security downgrade for a build that has no better
/// option — not a default. A provisioned device build never reaches it.
struct DeviceIdentityStore {
    var deviceID: String? { load(key: Self.deviceKey) ?? fileValue(Self.deviceKey) }
    var pollSecret: String? { load(key: Self.secretKey) ?? fileValue(Self.secretKey) }
    /// The Firebase refresh token for the synthetic device user.
    ///
    /// ⚠ Persisted because `signIn(customToken:)` runs exactly once, during pairing. Everything the
    /// device does afterwards — heartbeat, queue poll, event writes, and unpairing itself — needs an
    /// authenticated session, and without this the app relaunches holding an identity it cannot
    /// prove. It is a bearer credential, so it lives beside the poll secret rather than anywhere
    /// more convenient.
    var refreshToken: String? { load(key: Self.refreshKey) ?? fileValue(Self.refreshKey) }

    static let keychain = DeviceIdentityStore()

    private static let service = "com.distributedglobal.superresearch.device"
    private static let deviceKey = "deviceId"
    private static let secretKey = "pollSecret"
    private static let refreshKey = "refreshToken"

    // MARK: - The breadcrumb

    /// The last device this app was paired to, and why that ended — kept **across** a lost pairing.
    ///
    /// ⚠ This exists because losing a pairing is currently indistinguishable from never having had
    /// one: the app just shows "Get started" again, and the owner re-pairs, producing a *second*
    /// device document with no workers and no logins. That has now happened twice, from two
    /// unrelated causes, and both times the only symptom was a screen that looked normal.
    ///
    /// Deliberately **not** in the Keychain: this is a diagnostic breadcrumb, not a credential, and
    /// it has to survive precisely the conditions in which the Keychain turned out to be unusable.
    static var lastPairedDeviceID: String? {
        get { UserDefaults.standard.string(forKey: "sr.lastPairedDeviceId") }
        set { UserDefaults.standard.set(newValue, forKey: "sr.lastPairedDeviceId") }
    }

    /// Nil when the device is paired, or was unpaired deliberately. Set only when a pairing was lost
    /// without the owner asking for it.
    static var lostPairingReason: String? {
        get { UserDefaults.standard.string(forKey: "sr.lostPairingReason") }
        set { UserDefaults.standard.set(newValue, forKey: "sr.lostPairingReason") }
    }

    /// Record that a pairing ended on its own.
    static func noteLostPairing(deviceID: String?, reason: String) {
        if let deviceID { lastPairedDeviceID = deviceID }
        lostPairingReason = reason
        NSLog("[SR] PAIRING LOST for %@: %@", deviceID ?? "?", reason)
    }

    /// Clear the breadcrumb. Called on a deliberate unpair and on a successful re-pair — the two
    /// cases where the owner knows what happened and does not need telling.
    static func clearLostPairingNote() {
        lostPairingReason = nil
    }

    /// Whether launch should skip the marketing splash and open on the not-paired notice.
    ///
    /// ⚠ **The breadcrumb was written but never read by anyone who needed it.** `noteLostPairing`
    /// records why a pairing ended on its own, and only `NotPairedView` renders it — but the app
    /// opens on `.landing`, so the explanation sat one tap behind a "Get started" button. The owner
    /// taps Get started, pairs again, and produces a SECOND empty device document without ever
    /// seeing that the first one was lost. That is the exact silence the breadcrumb exists to break,
    /// and it has now happened twice.
    ///
    /// Lives here rather than in `AppModel.init` because `ios/App` is not a package target — see
    /// `AppLayerBoundaryTests`. A launch-routing rule inside a view initialiser is a rule no test
    /// can reach.
    static func shouldOpenOnLostPairingNotice(reason: String?, isRealBackend: Bool) -> Bool {
        // An empty string is what a cleared-but-not-nilled breadcrumb looks like; it explains
        // nothing, so routing to a page whose whole purpose is the explanation would be worse than
        // the splash. And the preview backend has no pairing to have lost.
        guard let reason, !reason.isEmpty, isRealBackend else { return false }
        return true
    }

    /// Overridable so the tests can exercise the fallback without touching a real container.
    var fallbackDirectory: URL? = DeviceIdentityStore.defaultFallbackDirectory

    static var defaultFallbackDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }

    private var fallbackURL: URL? {
        fallbackDirectory?.appendingPathComponent("device-identity.json")
    }

    private func fileValue(_ key: String) -> String? {
        guard let fallbackURL, let data = try? Data(contentsOf: fallbackURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return map[key]
    }

    /// Write the identity to the container, with the strongest protection that still lets a headless
    /// backend resume after a reboot without anyone unlocking the phone.
    @discardableResult
    private func writeFallback(_ values: [String: String]) -> Bool {
        guard let fallbackURL, let data = try? JSONEncoder().encode(values) else { return false }
        do {
            try data.write(to: fallbackURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            NSLog("[SR] identity fallback write FAILED: %@", String(describing: error))
            return false
        }
    }

    private func clearFallback() {
        guard let fallbackURL else { return }
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    /// Returns `false` when the identity did **not** reach the Keychain.
    ///
    /// ⚠ This used to return nothing and discard `SecItemAdd`'s `OSStatus`, and that silence cost a
    /// pairing. A Simulator build signed ad-hoc with no entitlements has no keychain access group,
    /// so every write failed with `errSecMissingEntitlement` — while the app kept working perfectly,
    /// because the device id and secret were also held in memory. The loss only appeared on the next
    /// launch, as a device that had apparently never been paired at all. Nothing in any log said so.
    ///
    /// A store that cannot report a failed write is indistinguishable from one that works.
    @discardableResult
    func save(deviceID: String, pollSecret: String, refreshToken: String? = nil) -> Bool {
        var values = [Self.deviceKey: deviceID, Self.secretKey: pollSecret]
        if let refreshToken { values[Self.refreshKey] = refreshToken }

        let allStored = values.allSatisfy { store(key: $0.key, value: $0.value) }
        if allStored && load(key: Self.deviceKey) == deviceID {
            // The Keychain took it AND gives it back. Nothing else needed, and no plaintext copy is
            // left lying in the container.
            clearFallback()
            return true
        }
        NSLog("[SR] Keychain unusable for the pairing identity — falling back to a "
              + "protected file in the app container. Expected on an unprovisioned Simulator build; "
              + "on a real device this means the provisioning profile is missing.")
        return writeFallback(values)
    }

    /// Prove a written identity can be read back, rather than trusting the write's own status.
    ///
    /// The status says the item was accepted; this says it is retrievable by the query the app will
    /// actually use on the next launch — which is the property that matters and the one that broke.
    func verifyRoundTrip(deviceID: String) -> Bool {
        self.deviceID == deviceID
    }

    func clear() {
        for key in [Self.deviceKey, Self.secretKey, Self.refreshKey] {
            SecItemDelete(query(key: key) as CFDictionary)
        }
        // Both homes, always. Clearing only the Keychain would leave the fallback file behind, and
        // the next launch would resurrect an identity the user just unpaired.
        clearFallback()
    }

    private func query(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
    }

    @discardableResult
    private func store(key: String, value: String) -> Bool {
        var attributes = query(key: key)
        SecItemDelete(attributes as CFDictionary)   // upsert; add alone fails with errSecDuplicateItem
        attributes[kSecValueData as String] = Data(value.utf8)
        // Survives a reboot without the device being unlocked first, which a headless backend needs:
        // the pipeline may resume before anyone has touched the phone.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            // Named, not swallowed. -34018 is errSecMissingEntitlement and means the build was signed
            // without keychain-access-groups — see the entitlements block in bin/build_app.sh.
            NSLog("[SR] KEYCHAIN WRITE FAILED for %@: OSStatus %d%@", key, Int32(status),
                  status == -34018 ? " (errSecMissingEntitlement — app signed without "
                                   + "keychain-access-groups; the pairing will not survive relaunch)"
                                   : "")
        }
        return status == errSecSuccess
    }

    private func load(key: String) -> String? {
        var attributes = query(key: key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - API keys

/// Stage 3's storage. Keychain, never `UserDefaults`.
///
/// An API key is a bearer credential: `UserDefaults` is a plist in the app container, readable by
/// anything that can read the container and included in unencrypted backups. The Keychain entry uses
/// `kSecAttrAccessibleAfterFirstUnlock` so a backend that resumes after a reboot can still reach it
/// without someone unlocking the phone first.
enum APIKeyStore {
    enum Kind: String, CaseIterable {
        case anthropic = "anthropicApiKey"
        case gemini = "geminiApiKey"
    }

    private static let service = "com.distributedglobal.superresearch.keys"

    /// Save a key, and say whether it actually persisted.
    ///
    /// ⚠ **This discarded `SecItemAdd`'s `OSStatus` and it cost the owner both API keys.** Entered
    /// during pairing, accepted by the UI, and then absent from Settings on the next look — because
    /// an ad-hoc-signed Simulator build has no keychain access group, so every write fails with
    /// `errSecMissingEntitlement` while the caller sees nothing. `DeviceIdentityStore` was given a
    /// read-back check and a container fallback for exactly this failure after it cost a pairing;
    /// this store was left as it was, so the same bug was still here waiting.
    ///
    /// The fallback file holds real credentials, unlike the identity store's ids and booleans, so it
    /// takes the strongest protection class that still lets a headless backend resume after reboot
    /// without someone unlocking the phone — and it is written **only** when the Keychain has
    /// demonstrably refused. On a properly provisioned device the Keychain works and no plaintext
    /// copy is ever created.
    /// The Keychain, behind a seam.
    ///
    /// ⚠ **Not indirection for its own sake — without it the fallback path is untestable and the
    /// fix was unproven.** `swift test` runs on a macOS host whose Keychain WORKS, so every test
    /// took the happy path and five separate mutations of this store — including restoring the
    /// original discard-the-status bug — all passed. The failure being fixed only happens where the
    /// Keychain refuses, so a test must be able to make it refuse.
    static var keychainWrite: (Kind, String) -> OSStatus = { kind, value in
        var attributes = liveQuery(kind)
        SecItemDelete(attributes as CFDictionary)   // upsert; add alone fails errSecDuplicateItem
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static var keychainRead: (Kind) -> String? = { kind in
        var attributes = liveQuery(kind)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var keychainDelete: (Kind) -> Void = { kind in
        SecItemDelete(liveQuery(kind) as CFDictionary)
    }

    /// Restore the real Keychain. Tests that install a stub must call this in tearDown, or every
    /// later test in the process inherits the stub.
    static func useRealKeychain() {
        keychainWrite = { kind, value in
            var attributes = liveQuery(kind)
            SecItemDelete(attributes as CFDictionary)
            attributes[kSecValueData as String] = Data(value.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(attributes as CFDictionary, nil)
        }
        keychainRead = { kind in
            var attributes = liveQuery(kind)
            attributes[kSecReturnData as String] = true
            attributes[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        keychainDelete = { kind in SecItemDelete(liveQuery(kind) as CFDictionary) }
    }

    @discardableResult
    static func save(_ kind: Kind, _ value: String) -> Bool {
        let status = keychainWrite(kind, value)

        // Not the status alone — whether the query the app will really use can find it again.
        if status == errSecSuccess, keychainHas(kind) {
            removeFallback(kind)
            return true
        }
        NSLog("[SR] Keychain unusable for %@ (OSStatus %d) — falling back to a protected file. "
              + "Expected on an unprovisioned Simulator build.", kind.rawValue, Int(status))
        return writeFallback(kind, value)
    }

    /// Presence only. The value is never returned to the UI — nothing in the app needs to display it,
    /// and a key on screen is a key in a screenshot.
    static func has(_ kind: Kind) -> Bool {
        keychainHas(kind) || fallbackValue(kind) != nil
    }

    /// The key itself, for the code that must actually send it somewhere.
    static func value(_ kind: Kind) -> String? {
        keychainRead(kind) ?? fallbackValue(kind)
    }

    private static func keychainHas(_ kind: Kind) -> Bool { keychainRead(kind) != nil }

    static func clear() {
        for kind in Kind.allCases { remove(kind) }
    }

    /// Remove one key. Needed because Settings can now replace or drop a single credential without
    /// the only route being Clear state, which also destroys the pairing and every platform login.
    ///
    /// ⚠ Clears BOTH stores. Removing only the Keychain copy would leave the fallback behind, and
    /// `has()` would keep reporting a key the owner believes they deleted.
    static func remove(_ kind: Kind) {
        keychainDelete(kind)
        removeFallback(kind)
    }

    // MARK: - The container fallback

    /// Overridable so tests exercise the fallback without touching a real container or the Keychain.
    static var fallbackDirectory: URL? = DeviceIdentityStore.defaultFallbackDirectory

    private static func fallbackURL(_ kind: Kind) -> URL? {
        fallbackDirectory?.appendingPathComponent("apikey-\(kind.rawValue).bin")
    }

    private static func writeFallback(_ kind: Kind, _ value: String) -> Bool {
        guard let url = fallbackURL(kind) else { return false }
        do {
            try Data(value.utf8).write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            NSLog("[SR] API key fallback write FAILED: %@", String(describing: error))
            return false
        }
    }

    private static func fallbackValue(_ kind: Kind) -> String? {
        guard let url = fallbackURL(kind), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func removeFallback(_ kind: Kind) {
        guard let url = fallbackURL(kind) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func liveQuery(_ kind: Kind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
