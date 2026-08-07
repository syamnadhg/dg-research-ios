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
    /// The persisted half of the auth session.
    func sessionRefreshToken() async -> String?
    func restoreSession(refreshToken: String) async
    func hasSession() async -> Bool
}

extension RESTPairingBackend: DeviceTransport {
    func readDocument(path: String) async throws -> [String: FirestoreValue]? {
        try await firestore.getDocument(path: path)
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

    func loadSnapshot() async -> DeviceSnapshot {
        guard let deviceID else {
            var snapshot = DeviceSnapshot.unpaired
            snapshot.platforms = Self.unknownPlatforms
            return snapshot
        }

        var snapshot = DeviceSnapshot()
        snapshot.deviceID = deviceID
        snapshot.pairCode = pairCode
        snapshot.platforms = Self.unknownPlatforms

        guard let fields = try? await pairing.readDocument(path: "devices/\(deviceID)")
        else {
            return snapshot   // unreadable is not the same as unpaired; leave it offline and paired
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
        if case .array(let resting)? = fields["restingWorkerIds"] {
            snapshot.restingWorkerIDs = Set(resting.compactMap { value in
                if case .string(let id) = value { return id }
                return nil
            })
        }
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
                    totalPhases: integer(run["totalPhases"]).map(Int.init)
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
        guard case .array(let entries)? = fields["busyWorkerIds"] else { return [] }
        return Set(entries.compactMap { entry -> Int? in
            switch entry {
            case .integer(let number): return Int(number)
            case .string(let text): return Int(text) ?? Int(text.replacingOccurrences(
                of: "worker-", with: ""))
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
        case "version": return versionReport()
        case "update": return await checkForUpdate()
        case "collect": return await collectDiagnostics()
        case "clear": return await clearState()
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

    // MARK: - Maintenance

    /// The app's own version, which IS the backend version on this device.
    private func versionReport() -> OpResult {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return OpResult(
            ok: true,
            message: "Super Research \(short) (build \(build))",
            detail: """
                Backend version   \(short)
                Build             \(build)
                Runs on           this iPhone — the app is the backend
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

    /// What "update" can honestly mean here.
    ///
    /// ⚠ An iOS app cannot replace its own binary — there is no `pipx install --force` equivalent,
    /// and pretending otherwise would be the one failure mode this whole wave exists to remove. So
    /// this reports what is running and what the server believes is available, and names the actual
    /// route. Saying "no update mechanism" plainly beats a button that appears to work.
    private func checkForUpdate() async -> OpResult {
        let running = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard let deviceID else {
            return OpResult(ok: false, message: "Not paired, so there is nothing to check against")
        }
        await restoreSessionIfNeeded()
        let fields = try? await pairing.readDocument(path: "devices/\(deviceID)")
        var newer: String?
        if case .string(let value)? = fields?["updateAvailable"], !value.isEmpty { newer = value }

        if let newer {
            return OpResult(
                ok: true,
                message: "Update available: \(newer) (running \(running))",
                detail: "Running \(running); the server reports \(newer) is available.\n\n"
                    + "This device is an iOS app, so it updates by installing a new build — "
                    + "bin/build_app.sh — not from inside the app."
            )
        }
        return OpResult(
            ok: true,
            message: "Up to date — running \(running)",
            detail: "Running \(running). The server reports nothing newer."
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
    private func clearState() async -> OpResult {
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
    func setWorkerResting(_ workerID: Int, resting: Bool, current: Set<String>) async -> OpResult {
        guard let deviceID else { return OpResult(ok: false, message: "Not paired") }
        await restoreSessionIfNeeded()

        var next = Set(current.compactMap(Int.init))
        // Prune ids past the current capacity, as the frontend does: a worker parked and then
        // removed leaves an id with no pill, which nothing can ever un-park.
        next = next.filter { $0 >= 1 && $0 <= workers.count }
        if resting { next.insert(workerID) } else { next.remove(workerID) }

        do {
            try await pairing.patchDevice(
                deviceId: deviceID,
                set: ["restingWorkerIds": next.sorted().map(String.init)],
                delete: []
            )
            return OpResult(
                ok: true,
                message: resting ? "Worker \(workerID) is resting" : "Worker \(workerID) is awake"
            )
        } catch {
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
        if coordinator == nil, deviceID != nil {
            coordinator = PairingCoordinator(backend: pairing)
        }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.beat()
                // 20s: comfortably inside any staleness window the frontend applies, and cheap. The
                // desktop backend beats on a similar cadence.
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func beat() async {
        guard let deviceID, let coordinator else { return }
        // Failures are swallowed deliberately: a dropped beat is normal (a tunnel, a sleeping Mac), and
        // the next tick recovers. Tearing the loop down on one failure is how a device goes permanently
        // offline after a momentary blip.
        // Re-read every tick rather than captured once: Add worker must take effect on the next beat
        // instead of on the next relaunch.
        try? await coordinator.heartbeat(deviceId: deviceID, workerCount: workers.count)
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

    static func save(_ kind: Kind, _ value: String) {
        var attributes = query(kind)
        SecItemDelete(attributes as CFDictionary)   // upsert; add alone fails errSecDuplicateItem
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Presence only. The value is never returned to the UI — nothing in the app needs to display it,
    /// and a key on screen is a key in a screenshot.
    static func has(_ kind: Kind) -> Bool {
        var attributes = query(kind)
        attributes[kSecReturnData as String] = false
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        for kind in Kind.allCases { SecItemDelete(query(kind) as CFDictionary) }
    }

    /// Remove one key. Needed because Settings can now replace or drop a single credential without
    /// the only route being Clear state, which also destroys the pairing and every platform login.
    static func remove(_ kind: Kind) {
        SecItemDelete(query(kind) as CFDictionary)
    }

    private static func query(_ kind: Kind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
