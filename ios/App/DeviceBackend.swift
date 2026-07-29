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
final class DeviceBackend: AppBackend {
    private let config: FirebaseProjectConfig
    private let pairing: RESTPairingBackend
    private let store: DeviceIdentityStore

    private var deviceID: String?
    private var pairCode: String = ""
    /// Retained so the heartbeat keeps using the same claim clock the confirm used.
    private var coordinator: PairingCoordinator?
    private var heartbeatTask: Task<Void, Never>?

    init(config: FirebaseProjectConfig, store: DeviceIdentityStore = .keychain) {
        self.config = config
        self.pairing = RESTPairingBackend(config: config)
        self.store = store
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
        // The bridge's transport does not exist yet, so this is false by construction rather than by
        // measurement. Stated here so the UI's "bridge unreachable" notice is honest instead of a
        // placeholder that might later be mistaken for a probe result.
        snapshot.bridgeReachable = false

        guard let fields = try? await pairing.firestore.getDocument(path: "devices/\(deviceID)")
        else {
            return snapshot   // unreadable is not the same as unpaired; leave it offline and paired
        }

        snapshot.paired = fields["pairConfirmedAt"] != nil
        if case .string(let status)? = fields["status"] {
            snapshot.online = status == "active" || status == "online"
        }
        if case .integer(let millis)? = fields["lastHeartbeat"] {
            let seconds = Int(Date().timeIntervalSince1970) - Int(millis / 1000)
            snapshot.lastHeartbeatAgo = max(0, seconds)
        }
        if case .integer(let count)? = fields["workerCount"] { snapshot.workerCount = Int(count) }
        if case .array(let busy)? = fields["busyWorkerIds"] { snapshot.busyWorkers = busy.count }

        snapshot.users = Self.users(from: fields)
        if let logins = Self.platforms(from: fields) { snapshot.platforms = logins }
        return snapshot
    }

    /// Owner plus anyone the device is shared with.
    ///
    /// ⚠ These are **uids, not email addresses** — the device tree stores uids and the frontend is what
    /// resolves them to people. Truncated for display rather than padded out into something that looks
    /// like an email, because a plausible-looking wrong identity is worse than an obviously partial one.
    private static func users(from fields: [String: FirestoreValue]) -> [ConnectedUser] {
        var users: [ConnectedUser] = []
        if case .string(let owner)? = fields["ownerUid"] {
            users.append(ConnectedUser(id: owner, label: short(owner), isOwner: true))
        }
        if case .array(let shared)? = fields["sharedWith"] {
            for entry in shared {
                if case .string(let uid) = entry {
                    users.append(ConnectedUser(id: uid, label: short(uid), isOwner: false))
                }
            }
        }
        return users
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

    func perform(_ op: Operation) async -> OpResult {
        switch op.id {
        case "pair":
            // Owned by PairingFlowView now, because pairing is five stages rather than one call. A
            // one-shot here would pair the device and skip On Startup, keys and logins entirely.
            return OpResult(ok: false, message: "Use Set up this device — pairing is a guided flow")
        case "unpair", "retire": return await release(op)
        default:
            guard op.scope == .daemon else {
                return OpResult(ok: false, message: "\(op.title) is not implemented on the device yet")
            }
            // Not "queued". The command channel does not exist, so nothing was sent and nothing will
            // run; claiming otherwise would leave the owner waiting for an effect that cannot arrive.
            return OpResult(
                ok: false,
                message: "not sent — the Mac control bridge has no transport yet",
                relayed: true
            )
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
            try await coordinator.confirmPairing(deviceId: id, workerCount: 1)
            // ⚠ Persisted only NOW, after the confirm. An earlier version saved before the claim wait
            // so a killed app would not "orphan" the device — but that traded one problem for a worse
            // one: an app killed mid-flow kept an identity for a device that was never confirmed, and
            // on next launch it heartbeat a document that the TTL had already deleted. The device
            // showed "Not paired" while still beating.
            //
            // Losing the identity when the flow dies is the correct outcome: an unconfirmed device is
            // already dead (the confirm window is five minutes), and the server-side initiate-pair TTL
            // reaps the document on its own.
            store.save(deviceID: id, pollSecret: secret.hexText)
            self.coordinator = coordinator
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
        guard let deviceID else { return }
        try? await pairing.patchDevice(
            deviceId: deviceID, set: ["supervised": enabled], delete: []
        )
    }

    /// Stage 4's result, mirrored to the device doc's `logins` map.
    ///
    /// So the frontend shows the same per-platform state the app does, rather than the two disagreeing
    /// about which platforms are usable.
    func reportLogins(_ state: [String: Bool]) async {
        guard let deviceID, !state.isEmpty else { return }
        try? await pairing.patchDevice(
            deviceId: deviceID, set: ["logins": state], delete: []
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
        startHeartbeat()
    }

    /// Forget this device's identity and stop reporting.
    ///
    /// Distinct from retire: retire tells the server, this only clears the local side. Needed because a
    /// flow interrupted mid-pair, or a device document deleted from the web app, leaves an identity
    /// here that can never work again — and without a way to clear it the app is permanently stuck
    /// heartbeating a document that does not exist.
    func resetPairing() {
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
            // A read, not a write: if the document is gone the identity is worthless.
            if (try? await self.pairing.firestore.getDocument(path: "devices/\(id)")) == nil {
                NSLog("[SR] stale pairing for \(id) — the device document is gone; clearing it")
                self.resetPairing()
                return
            }
            self.startHeartbeat()
        }
    }

    func startHeartbeat() {
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
        try? await coordinator.heartbeat(deviceId: deviceID, workerCount: 1)
    }

    private func release(_ op: Operation) async -> OpResult {
        guard let deviceID else { return OpResult(ok: false, message: "Not paired") }
        do {
            // Stopped FIRST. A heartbeat racing the retire would rewrite lastHeartbeat after it and
            // leave a retired device looking online — visible on the frontend as a device you cannot
            // get rid of.
            stopHeartbeat()
            try await pairing.patchDevice(
                deviceId: deviceID, set: ["status": "retired"], delete: []
            )
            store.clear()
            self.deviceID = nil
            pairCode = ""
            coordinator = nil
            return OpResult(ok: true, message: op.id == "retire" ? "Device retired" : "Unpaired")
        } catch {
            return OpResult(ok: false, message: "\(op.title) failed: \(error)")
        }
    }
}

// MARK: - Identity persistence

/// Where the device's identity lives between launches.
///
/// The poll secret is a 256-bit credential that authorises collecting this device's custom token, so it
/// belongs in the Keychain rather than `UserDefaults` — the latter is a plist in the app container,
/// readable by anything that can read the container and included in unencrypted backups.
struct DeviceIdentityStore {
    var deviceID: String? { load(key: Self.deviceKey) }
    var pollSecret: String? { load(key: Self.secretKey) }

    static let keychain = DeviceIdentityStore()

    private static let service = "com.distributedglobal.superresearch.device"
    private static let deviceKey = "deviceId"
    private static let secretKey = "pollSecret"

    func save(deviceID: String, pollSecret: String) {
        store(key: Self.deviceKey, value: deviceID)
        store(key: Self.secretKey, value: pollSecret)
    }

    func clear() {
        for key in [Self.deviceKey, Self.secretKey] {
            SecItemDelete(query(key: key) as CFDictionary)
        }
    }

    private func query(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
    }

    private func store(key: String, value: String) {
        var attributes = query(key: key)
        SecItemDelete(attributes as CFDictionary)   // upsert; add alone fails with errSecDuplicateItem
        attributes[kSecValueData as String] = Data(value.utf8)
        // Survives a reboot without the device being unlocked first, which a headless backend needs:
        // the pipeline may resume before anyone has touched the phone.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
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

    private static func query(_ kind: Kind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
