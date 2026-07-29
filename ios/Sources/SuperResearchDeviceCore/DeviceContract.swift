import Foundation

/// The exact shapes the Firestore rules will accept from a paired device.
///
/// Every field list here is transcribed from `dg-research/firestore.rules`, and the reason they are
/// *lists* rather than just structs is the rule mechanism itself:
///
/// ⚠ **`hasOnly()` is all-or-nothing, and the device document carries THREE separate `allow update`
/// statements which Firestore ORs — each with its own list.** A write is permitted only if it
/// satisfies at least one rule *entirely*. So a patch that mixes a synth-list field with an
/// owner-list field satisfies **neither** and is rejected wholesale. Including one extra key,
/// however innocuous, fails the whole write.
public enum DeviceContract {

    /// The keys the synthetic-device principal may write to `devices/{deviceId}`.
    ///
    /// Transcribed from the synth branch of `firestore.rules`. A field not in this set turns an
    /// otherwise-valid heartbeat into a permission denial.
    public static let synthWritableKeys: Set<String> = [
        "lastHeartbeat", "status", "logins", "authMode",
        "pairConfirmedAt", "expireAt", "supervised",
        "currentRunId", "currentRunOwnerUid", "currentRunTitle", "currentRunStartedAt",
        "currentRunPhase", "currentRunPhaseStartedAt",
        "workerCount", "busyWorkerIds",
        // 2026-05-28 / 2026-07-05 additions to the rules' synth allow-list. Absent here, a local
        // pre-check would refuse writes the rules actually permit — a self-inflicted 403.
        "workers", "queueOwners", "version", "updateAvailable",
    ]

    /// Keys only the **owner** may write. Present so a device-side patch can be checked against
    /// them and refused locally rather than producing an opaque 403.
    public static let ownerOnlyKeys: Set<String> = [
        "name", "priority", "supervised", "restingWorkerIds", "feFifoCurrent",
    ]

    /// The deadline the claim route sets via `expireAt: now + 5 minutes`, under a Firestore TTL.
    public static let pairConfirmDeadline: TimeInterval = 5 * 60

    /// A heartbeat write, which is also the pair-confirm.
    ///
    /// ⚠ **The pair-confirm is not a separate one-off write — it is part of EVERY heartbeat tick.**
    /// The claim route stamps `expireAt: now + 5min`; each heartbeat sets `pairConfirmedAt: true`
    /// and *deletes* `expireAt`. Miss that window and the TTL removes `devices/{deviceId}`
    /// outright, and recovery is **impossible**: `allow create: if false`, and the synth update rule
    /// reads a `syntheticDeviceUid` that no longer exists. The only way back is a fresh
    /// `initiate-pair` — new deviceId, new synth uid, orphaned Auth user, dead pollSecret path.
    ///
    /// Which means the heartbeat loop *is* the confirm mechanism, and a device that starts
    /// heartbeating promptly can never miss the deadline. Getting this wrong looks like a device
    /// that pairs successfully and then vanishes from the web app minutes later.
    public struct Heartbeat: Equatable, Sendable {
        /// Milliseconds since epoch. ⚠ An **integer**, not a Timestamp — the frontend computes
        /// `Date.now() - lastHeartbeat` directly, so a Timestamp breaks the offline calculation.
        public let lastHeartbeatMillis: Int64
        public let status: String
        /// A **boolean `true`**, not a timestamp, despite the field's name.
        public let pairConfirmedAt: Bool
        public let workerCount: Int?

        public init(
            lastHeartbeatMillis: Int64,
            status: String = "active",
            pairConfirmedAt: Bool = true,
            workerCount: Int? = nil
        ) {
            self.lastHeartbeatMillis = lastHeartbeatMillis
            self.status = status
            self.pairConfirmedAt = pairConfirmedAt
            self.workerCount = workerCount
        }

        /// Fields to set. `expireAt` is deliberately absent — see ``fieldsToDelete``.
        public var fieldsToSet: [String: Any] {
            var out: [String: Any] = [
                "lastHeartbeat": lastHeartbeatMillis,
                "status": status,
                "pairConfirmedAt": pairConfirmedAt,
            ]
            if let workerCount { out["workerCount"] = workerCount }
            return out
        }

        /// Fields to remove.
        ///
        /// ⚠ Deleting `expireAt` is what cancels the TTL. It must be an actual **field delete**
        /// (`FieldValue.delete()`), never `null`: the frontend distinguishes absent from
        /// present-but-null, and a null write reports success while leaving the TTL armed. The
        /// document then disappears on schedule and the pairing appears to have worked right up
        /// until it didn't.
        public var fieldsToDelete: [String] { ["expireAt"] }

        /// Every key this write touches — what `hasOnly()` is evaluated against.
        public var touchedKeys: Set<String> {
            Set(fieldsToSet.keys).union(fieldsToDelete)
        }

        /// Whether the rules will accept this write, checked locally.
        ///
        /// Worth doing device-side because the alternative is a 403 whose message names neither the
        /// offending field nor the rule it failed — so the cost of a mistake is a debugging session
        /// rather than an assertion.
        public var satisfiesSynthRule: Bool {
            touchedKeys.isSubset(of: DeviceContract.synthWritableKeys)
        }
    }

    /// A `pipeline_events` document, in the shape the rules and the frontend both require.
    ///
    /// Absence is meaningful in three different ways in this one collection, so the omissions below
    /// are contract rather than tidiness.
    public struct PipelineEvent: Equatable, Sendable {
        public let type: String
        /// ⚠ Integer milliseconds. A Timestamp fails the rule's `is number` check.
        public let timestampMillis: Int64
        /// ⚠ Integer milliseconds, forced monotonic — **not** a per-run counter. A 0-based counter
        /// restarts each run below the frontend's stored cursor (`where seq > lastSeq`), so every
        /// event of that run is filtered out and the run appears to produce nothing.
        public let seq: Int64
        /// ⚠ **Top level**, a sibling of `type` — not nested inside `data`. The device branch of the
        /// rule reads the top-level field.
        public let deviceId: String
        public let expireAt: Date
        /// Written whenever non-nil, so **phase 0 IS written**. P0 is a real phase, and a
        /// truthiness check would silently drop it.
        public let phase: Int?
        /// Omitted when empty; not lowercased.
        public let agent: String?
        /// Omitted **entirely** when empty. The frontend's own emitter always writes `{}`, so a
        /// consumer sees both shapes from the one collection.
        public let data: [String: Any]?

        public init(
            type: String,
            timestampMillis: Int64,
            seq: Int64,
            deviceId: String,
            expireAt: Date,
            phase: Int? = nil,
            agent: String? = nil,
            data: [String: Any]? = nil
        ) {
            self.type = type
            self.timestampMillis = timestampMillis
            self.seq = seq
            self.deviceId = deviceId
            self.expireAt = expireAt
            self.phase = phase
            self.agent = agent
            self.data = data
        }

        public static func == (lhs: PipelineEvent, rhs: PipelineEvent) -> Bool {
            lhs.type == rhs.type && lhs.seq == rhs.seq && lhs.deviceId == rhs.deviceId
        }

        /// The document body, with the omission rules applied.
        public var document: [String: Any] {
            var out: [String: Any] = [
                "type": type,
                "timestamp": timestampMillis,
                "seq": seq,
                "deviceId": deviceId,
                "expireAt": expireAt,
            ]
            if let phase { out["phase"] = phase }                       // 0 included
            if let agent, !agent.isEmpty { out["agent"] = agent }       // "" omitted
            if let data, !data.isEmpty { out["data"] = data }           // {} omitted
            return out
        }
    }

    /// Monotonic `seq` generator: epoch millis that never repeats or moves backwards.
    ///
    /// Mirrors the backend exactly: `new = now_ms; if new <= last { new = last + 1 }`. The guard
    /// covers two real cases — two events inside one millisecond, and a clock stepping backwards
    /// (NTP correction, sleep/wake, both routine on a device running a long pipeline). Either would
    /// produce a value the frontend's strictly-greater-than cursor discards.
    public final class SeqGenerator: @unchecked Sendable {
        private var last: Int64
        private let lock = NSLock()

        public init(start: Int64 = 0) { self.last = start }

        public func next(nowMillis: Int64) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            var candidate = nowMillis
            if candidate <= last { candidate = last + 1 }
            last = candidate
            return candidate
        }

        /// Raise the floor after reading a resumed run's last event, so the next emit lands above
        /// the frontend's stored cursor rather than being filtered out.
        public func observe(_ seq: Int64) {
            lock.lock()
            defer { lock.unlock() }
            last = max(last, seq)
        }

        public var lastIssued: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return last
        }
    }
}
