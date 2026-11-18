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
            // ⛔ **Without this every research patch 403s** — and it did, on both halves.
            //
            // The rule is `request.resource.data.deviceId == request.auth.token.deviceId` on the
            // research document itself, so the field must be in the WRITE, not merely present on
            // the doc from an earlier one. The `deviceId` this repo already carries on every
            // `pipeline_event` is a different field on a different document, which is exactly why
            // this looked covered: grep finds it, the events write fine, and the patch is denied.
            // A 403 that names nothing, on the write that starts the run.
            "deviceId": .string(deviceId),
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
            // ⛔ A real TIMESTAMP, not a string. Firestore's TTL only collects
            // `timestampValue`; as a string this field looks right in the console, passes
            // any rule that checks it exists, and never expires — so a `pipeline_events`
            // subcollection meant to age out in 30 days grows forever, silently.
            "expireAt": .timestamp(Self.iso8601(clock().addingTimeInterval(30 * 24 * 3600))),
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

    /// The five document types a finished run produces.
    ///
    /// ⚠ **Five, not three.** The three platform reports are the obvious ones; the `brief` is P1's
    /// product and P2's input, and `consolidated` is the three reports concatenated, which is what
    /// P3 actually uploads. A run that writes only the three reports looks complete on the
    /// Documents page and has nothing for the podcast to be made from.
    public enum DocType: String, CaseIterable, Sendable {
        case brief, chatgpt, claude, gemini, consolidated
    }

    /// Write one research document — the thing a run exists to produce.
    ///
    /// ⚠ **An upsert keyed by the docType**, which is deliberate: a re-extraction or a second run
    /// against the same research overwrites in place. Auto-ids here would leave the Documents page
    /// showing two copies of the same report with no way to tell which is current.
    ///
    /// ⚠ **Blank content is refused rather than written.** The frontend gates its "Read report"
    /// button on the document existing, so an empty write earns a button that opens an empty modal
    /// — a run that looks finished and delivers nothing. The backend learned this and gates its own
    /// `link_extracted` emit on the write having committed.
    @discardableResult
    public func saveDocument(
        _ docType: DocType, content: String, name: String? = nil
    ) async throws -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSLog("[SR] refusing to write an EMPTY %@ document", docType.rawValue)
            return false
        }
        let millis = Int64(clock().timeIntervalSince1970 * 1000)
        let fields: [String: FirestoreValue] = [
            "id": .string(docType.rawValue),
            "name": .string(name ?? "\(docType.rawValue).md"),
            "type": .string(docType.rawValue),
            "content": .string(content),
            // The frontend renders this string as-is; computing it here keeps the two halves
            // agreeing on the rounding rather than each inventing one.
            "size": .string("\(Int((Double(content.utf8.count) / 1024.0).rounded())) KB"),
            "createdAt": .integer(millis),
            "deviceId": .string(deviceId),
        ]
        let path = "\(researchPath)/documents/\(docType.rawValue)"
        written.append((op: "patch", path: path, fields: fields, deletePaths: []))
        try await client.patchDocument(path: path, set: fields)
        return true
    }

    /// Patch the research document with arbitrary fields — P3's links, and nothing else so far.
    ///
    /// ⛔ **`deviceId` is added here rather than left to the caller**, and it is not a convenience.
    /// The rule is `request.resource.data.deviceId == request.auth.token.deviceId` and it is judged
    /// on the resource being WRITTEN, so a patch that omits it 403s even though the document already
    /// carries the right value from `startRun`. Every research patch in this file learned that the
    /// same way; a public method that lets a caller forget is a 403 waiting to be re-diagnosed.
    ///
    /// ⚠ Dotted keys are field PATHS — `links.audio_file` addresses a member of the `links` map, not
    /// a field with a dot in its name. The REST client nests them for the body; see its own note for
    /// what happens when it does not.
    public func patchResearch(_ set: [String: FirestoreValue]) async throws {
        guard !set.isEmpty else { return }
        var fields = set
        fields["deviceId"] = .string(deviceId)
        written.append((op: "patch", path: researchPath, fields: fields, deletePaths: []))
        try await client.patchDocument(path: researchPath, set: fields)
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
        // Same rule, same reason as `startRun`. Omitting it here is the subtler half: the run works
        // right up to the moment it tries to finish, and then cannot say that it did.
        let fields: [String: FirestoreValue] = [
            "status": .string(status), "deviceId": .string(deviceId),
        ]
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
        // ⚠ Masked to the SAME placeholder a string ISO date produced, so the golden fixture — which
        // records `<iso8601>` — keeps matching across the string-to-timestamp fix. The fixture is
        // about shape and ordering; changing a field's wire TYPE must not read as a shape change.
        case .timestamp:
            return "<iso8601>"
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
