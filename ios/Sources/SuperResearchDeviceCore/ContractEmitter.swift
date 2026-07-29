import Foundation

/// Writes the run's Firestore documents from inside the app.
///
/// Without this the app can *run* a pipeline but cannot *report* one — the frontend would show a device
/// that pairs, goes online, and then never says anything. It is the half of "registers as a normal
/// device" that pairing alone does not cover.
///
/// The shapes are not invented here. They mirror `emubackend/contract/events.py`, which mirrors the
/// production backend, and `bin/c1_contract_gate.sh` diffs what this actually writes against
/// `fixtures/golden/p0_p3_happy_path.jsonl` — captured from real backend runs. That diff is the point:
/// with no e2e in existence, a golden-fixture comparison is the only mechanical proof that a second
/// implementation of this contract is faithful rather than plausible.
public actor ContractEmitter {

    /// Monotonic `seq`: epoch millis that never repeat and never go backwards.
    ///
    /// ⚠ Both halves matter, and both are silent when wrong. The consumer's cursor is strictly
    /// `seq > lastSeq`, so a **duplicate** (two events inside the same millisecond, which is routine)
    /// drops one event, and a **regression** (an NTP correction or a sleep/wake during a 90-minute
    /// pipeline) drops everything until the clock catches up. Neither produces an error anywhere.
    public struct SeqGuard {
        private var last: Int64 = 0

        public init(start: Int64 = 0) { self.last = start }

        public mutating func next(now: Int64) -> Int64 {
            var candidate = now
            if candidate <= last { candidate = last + 1 }
            last = candidate
            return candidate
        }
    }

    private let client: FirestoreREST
    private let uid: String
    private let researchId: String
    private let deviceId: String
    private let runId: String
    private var seq: SeqGuard
    private let clock: @Sendable () -> Date

    /// Every write attempted, in order — so a gate can compare the sequence, not just the endpoint.
    public private(set) var written: [(op: String, path: String, fields: [String: FirestoreValue],
                                      deletePaths: [String])] = []

    public init(
        client: FirestoreREST,
        uid: String,
        researchId: String,
        deviceId: String,
        runId: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.uid = uid
        self.researchId = researchId
        self.deviceId = deviceId
        self.runId = runId
        self.seq = SeqGuard()
        self.clock = clock
    }

    private var researchPath: String { "users/\(uid)/researches/\(researchId)" }

    /// The run's opening write: claim it, and clear any pending decision.
    ///
    /// ⚠ `pendingDecision` is **deleted**, not set to null. A null leaves the field present, and the
    /// frontend distinguishes absent from present-but-null — so a stale decision from a previous run
    /// would be re-applied to this one.
    public func startRun() async throws {
        let fields: [String: FirestoreValue] = [
            "status": .string("ongoing"),
            "backendRunId": .string(runId),
        ]
        written.append((op: "patch", path: researchPath, fields: fields,
                        deletePaths: ["pendingDecision"]))
        try await client.patchDocument(
            path: researchPath, set: fields, delete: ["pendingDecision"]
        )
    }

    /// Append one pipeline event.
    ///
    /// The omission rules are exact and each one has a reason:
    ///
    /// * `phase` is written whenever it is **non-nil**, so `phase: 0` IS written — a truthiness guard
    ///   would drop it, and P0 is a real phase.
    /// * `agent` is written only when **non-empty**, so `agent: ""` is omitted.
    /// * `data` is omitted **entirely** when empty, rather than written as `{}`.
    /// * `deviceId` is **top level**, a sibling of `type` — nested inside `data` it fails the device
    ///   branch of the rule, which reads the top-level field, and the 403 names neither.
    public func emit(
        type: String, phase: Int?, agent: String? = nil, data: [String: FirestoreValue] = [:]
    ) async throws {
        let millis = Int64(clock().timeIntervalSince1970 * 1000)
        var fields: [String: FirestoreValue] = [
            "type": .string(type),
            "deviceId": .string(deviceId),
            "seq": .integer(seq.next(now: millis)),
            "timestamp": .integer(millis),
            "expireAt": .string(Self.iso8601(clock().addingTimeInterval(30 * 24 * 3600))),
        ]
        if let phase { fields["phase"] = .integer(Int64(phase)) }
        if let agent, !agent.isEmpty { fields["agent"] = .string(agent) }
        if !data.isEmpty { fields["data"] = .map(data) }

        let path = "\(researchPath)/pipeline_events"
        written.append((op: "create", path: path, fields: fields, deletePaths: []))
        // A create, not a patch: events are append-only, and a document id chosen by the client would
        // make two workers racing on the same millisecond overwrite each other.
        try await client.createDocument(path: path, fields: fields)
    }

    /// The run's closing writes: the terminal event, then the status patch.
    ///
    /// ⚠ **`pipeline_complete` carries no phase**, and emitting it is not optional — the golden fixture
    /// has it as the ninth event and my first version omitted it entirely. Without it the frontend sees
    /// phase 3 complete and then a bare status change, with nothing marking the run as finished.
    /// Caught only by the fixture diff; every write was individually valid and the rules accepted all
    /// of them.
    ///
    /// It also happens to be the one event that exercises the nil-`phase` omission path, so a
    /// truthiness guard that dropped `phase: 0` and a guard that wrongly *wrote* `phase` here are both
    /// visible in the same comparison.
    ///
    /// Both writes live here rather than in the caller so their order cannot be got wrong: the event
    /// precedes the patch, because a consumer that sees `status: complete` first has no reason to look
    /// for another event.
    public func finishRun(status: String) async throws {
        try await emit(type: "pipeline_complete", phase: nil)
        let fields: [String: FirestoreValue] = ["status": .string(status)]
        written.append((op: "patch", path: researchPath, fields: fields, deletePaths: []))
        try await client.patchDocument(path: researchPath, set: fields)
    }

    /// A JSON summary of the write sequence, for the golden-fixture diff.
    public func writeLog() -> [[String: Any]] {
        written.map { entry in
            [
                "op": entry.op,
                "path": entry.path,
                "fields": entry.fields.reduce(into: [String: Any]()) { result, pair in
                    result[pair.key] = Self.describe(pair.key, pair.value)
                },
                "delete_paths": entry.deletePaths,
            ]
        }
    }

    /// Normalise a value the way the golden fixture does, so volatile values do not defeat the diff.
    ///
    /// `seq` and `timestamp` are wall-clock and an id is per-run, so a literal comparison would fail on
    /// every run for reasons that say nothing. The fixture records their *types* — `<int>`, `<iso8601>`
    /// — and this produces the same placeholders, which keeps the diff about shape and ordering.
    private static func describe(_ key: String, _ value: FirestoreValue) -> Any {
        switch value {
        case .integer(let number):
            // Only the volatile ones are masked. `phase` is a real, comparable value — masking it too
            // would make the diff blind to a phase written under the wrong number, or to phase 0
            // being dropped, which is precisely what the fixture exists to catch.
            return ["seq", "timestamp"].contains(key) ? "<int>" : Int(number)
        case .string(let text):
            return text.count == 20 && text.hasSuffix("Z") ? "<iso8601>" : text
        case .boolean(let flag): return flag
        case .map: return "<map>"
        case .array: return "<array>"
        case .double: return "<double>"
        case .null: return NSNull()
        }
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
