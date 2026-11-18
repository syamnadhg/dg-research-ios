import Foundation

// Controlling a run that is already going — Stop, Pause, Resume.
//
// ⛔ **A THIRD channel, and the recipe got this wrong.** §8b.1 listed `stop` as a fourth action on
// `devices/{id}/queue`. It is not one: the queue's vocabulary is `start`, `cancel` and `resume`, and
// the web app's Stop button writes to **`users/{uid}/researches/{rid}/commands`** instead
// (`FE firestore.ts:2135`, `writeCommand`). So a device that implements only the queue can start a
// run and cancel it *while it is still queued*, and can do nothing at all once it is running.
//
// The owner's words were *"a run I can't stop isn't parity"*. This is that.
//
// The frontend stamps the parent research's `deviceId` onto every command document precisely so the
// synthetic device user is allowed to read it, so the identity this app already holds is the right
// one — no new auth.

/// What the web app is asking of a run in flight.
public enum RunCommand: Equatable, Sendable {
    case stop
    case pause
    case resume
    /// Recognised but not implemented here — config changes and added context belong to the
    /// pipeline, not to run control. Named rather than lumped into `unsupported` so the log says
    /// which, and so adding them later is a change in one place.
    case notImplemented(String)
    case unsupported(String)

    public init(raw: String) {
        switch raw {
        case "stop": self = .stop
        case "pause": self = .pause
        case "resume": self = .resume
        case "config", "add_context": self = .notImplemented(raw)
        default: self = .unsupported(raw)
        }
    }
}

public struct RunCommandEntry: Equatable, Sendable {
    public let id: String
    public let command: RunCommand
    public let commandID: String?
    public let decisionID: String?
    public let timestampMillis: Int64
    public let processed: Bool

    public init(id: String, command: RunCommand, commandID: String? = nil,
                decisionID: String? = nil, timestampMillis: Int64 = 0, processed: Bool = false) {
        self.id = id
        self.command = command
        self.commandID = commandID
        self.decisionID = decisionID
        self.timestampMillis = timestampMillis
        self.processed = processed
    }

    public static func decode(_ doc: FirestoreREST.ListedDocument) -> RunCommandEntry? {
        func string(_ key: String) -> String? {
            if case .string(let value)? = doc.fields[key] { return value }
            return nil
        }
        guard let action = string("action") else { return nil }
        var millis: Int64 = 0
        switch doc.fields["timestamp"] {
        case .integer(let value)?: millis = value
        case .double(let value)?: millis = Int64(value)
        default: break
        }
        var processed = false
        if case .boolean(true)? = doc.fields["processed"] { processed = true }
        return RunCommandEntry(
            id: doc.id, command: RunCommand(raw: action),
            commandID: string("command_id"), decisionID: string("decisionId"),
            timestampMillis: millis, processed: processed
        )
    }

    /// The identity a repeat is judged by.
    ///
    /// The decision id when the web app supplies one — a decision is answered **once**, however many
    /// times the document is delivered — and the client nonce otherwise. Falling back to the
    /// document id last, so a command with neither is still de-duplicated against redelivery.
    public var dedupeKey: String {
        if let decisionID, !decisionID.isEmpty { return "decision:\(decisionID)" }
        if let commandID, !commandID.isEmpty { return "nonce:\(commandID)" }
        return "doc:\(id)"
    }
}

public enum RunCommandDecision: Equatable, Sendable {
    case execute
    /// A previous session's command, replayed on first read. Ack it, do not run it.
    case skipStale
    /// Already handled, or already seen this session.
    case ignore
    case unsupported(String)
}

public enum RunControlPolicy {
    /// How old a command from a *previous* session may be before it is acked rather than run.
    ///
    /// 30 seconds, matching the desktop. Well past a normal round trip.
    public static let staleMillis: Int64 = 30_000

    /// Decide what to do with one command document.
    ///
    /// - Parameter isFirstPoll: whether this is the first read after (re)attaching.
    ///
    /// ⚠⚠ **The staleness gate applies to the FIRST poll ONLY, and this is the whole subtlety.**
    /// On first read every pre-existing document arrives at once, including a previous session's
    /// unprocessed `stop` — which would otherwise execute the instant this device comes back and
    /// kill a run seconds after it started. That is why the gate exists.
    ///
    /// But applying it to **live** commands is worse in the opposite direction, and the desktop
    /// records exactly that regression: the `timestamp` is written by the *browser's* clock, so any
    /// skew against this device's clock silently discards the owner's clicks — leaving a run stuck
    /// on pause after they had already pressed Resume, with nothing anywhere saying why. **A live
    /// command always executes, however old its timestamp claims to be.**
    /// - Parameter key: the identity this command is remembered under. Defaults to the entry's own
    ///   `dedupeKey`, which is unique only WITHIN one research's command subcollection — a caller
    ///   watching more than one run at a time must scope it, or one run's handled command silences a
    ///   different run's.
    public static func decide(
        _ entry: RunCommandEntry, now nowMillis: Int64, isFirstPoll: Bool,
        alreadySeen: Set<String>, key: String? = nil
    ) -> RunCommandDecision {
        if entry.processed { return .ignore }
        if alreadySeen.contains(key ?? entry.dedupeKey) { return .ignore }
        if case .unsupported(let raw) = entry.command { return .unsupported(raw) }
        if case .notImplemented(let raw) = entry.command { return .unsupported(raw) }
        if isFirstPoll, entry.timestampMillis > 0,
           nowMillis - entry.timestampMillis > staleMillis {
            return .skipStale
        }
        return .execute
    }

    /// Bound on the remembered-commands set.
    ///
    /// This poller lives for the whole run and an unbounded set grows with every click of a long
    /// session. Oldest out first.
    public static func remember(
        _ key: String, in seen: inout [String], limit: Int = 200
    ) {
        seen.append(key)
        if seen.count > limit { seen.removeFirst(seen.count - limit) }
    }
}

/// What a run being controlled can be asked to do. The pipeline implements this; run control only
/// decides *when* to call it.
public protocol RunController: AnyObject, Sendable {
    func stopRun(researchID: String) async
    func pauseRun(researchID: String) async
    func resumeRun(researchID: String) async
}
