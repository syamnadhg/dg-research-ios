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
        case "pair": return await pair()
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

    /// The full pairing sequence, deadline included, driven by the already-tested coordinator.
    private func pair() async -> OpResult {
        let coordinator = PairingCoordinator(backend: pairing)
        do {
            let (secret, display, id) = try await coordinator.begin()
            deviceID = id
            pairCode = display
            // Persisted *before* the wait: if the app is killed while the human is claiming the code,
            // the identity must survive or the device is orphaned — a document nobody can reach and
            // that the TTL will silently delete.
            store.save(deviceID: id, pollSecret: secret.hexText)

            try await coordinator.awaitClaim(secret: secret, deviceId: id)
            // Immediately, not on the next heartbeat tick: the confirm is what cancels the TTL, and
            // the five-minute clock started when the *server* wrote the claim.
            try await coordinator.confirmPairing(deviceId: id, workerCount: 1)
            return OpResult(ok: true, message: "Paired — the web app should show this device online")
        } catch PairingError.timedOut {
            return OpResult(ok: false, message: "No one claimed the code in time. Try again.")
        } catch PairingError.confirmDeadlineMissed(let elapsed) {
            // Named precisely because past the deadline the document is already gone, so the *next*
            // error would be a permissions failure that points nowhere near the real cause.
            return OpResult(
                ok: false,
                message: "Claimed, but the confirm window closed after \(Int(elapsed))s. Pair again."
            )
        } catch {
            return OpResult(ok: false, message: "Pairing failed: \(error)")
        }
    }

    private func release(_ op: Operation) async -> OpResult {
        guard let deviceID else { return OpResult(ok: false, message: "Not paired") }
        do {
            try await pairing.patchDevice(
                deviceId: deviceID, set: ["status": "retired"], delete: []
            )
            store.clear()
            self.deviceID = nil
            pairCode = ""
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
