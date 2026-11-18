import Foundation

// Run intake — how a research run reaches this device.
//
// The owner submits a topic in the web app with this device paired and **selected**, and the web app
// writes into `devices/{deviceId}/queue/{docId}`. Nothing on the phone has ever read that.
//
// ⛔ **`queue` is not `commands`.** The app already polls `devices/{id}/commands` — restart, update,
// check-update, clear_local_storage — and a reviewer skimming for "does it poll the device?" finds
// that and concludes intake is done. `commands` is device operations; `queue` is the research
// lifecycle. They are different collections with different rules, different payloads and different
// consumers, and only one of them starts a run.
//
// ⚠ **There is a THIRD channel, and it is the one the Stop button uses.** `users/{uid}/researches/
// {rid}/commands` carries `stop` / `pause` / `resume` / `config` for a run already in flight. The
// recipe's §8b.1 lists `stop` as a fourth queue action; it is not one — the queue's vocabulary is
// `start`, `cancel` and `resume` only, and the web app's Stop writes to the per-research collection
// instead. Implementing the queue alone leaves the owner's Stop button dead, which is why
// `RunControl.swift` exists beside this file.

/// What a queue document asks this device to do.
public enum QueueAction: Equatable, Sendable {
    case start
    case cancel
    case resume
    /// Anything else. Kept rather than dropped so an unknown action is skipped **once, loudly**,
    /// instead of being re-evaluated on every poll for the life of the pairing.
    case unsupported(String)

    public init(raw: String) {
        switch raw {
        case "start": self = .start
        case "cancel": self = .cancel
        case "resume": self = .resume
        default: self = .unsupported(raw)
        }
    }
}

/// One `devices/{id}/queue/{docId}` document, decoded.
public struct QueueEntry: Equatable, Sendable {
    public let id: String
    public let action: QueueAction
    public let researchId: String

    /// ⚠ **`uid` and `submittedBy` are NOT interchangeable, and conflating them writes a run into
    /// the wrong user's tree.** For the ordinary case they are equal. For an owner stopping a
    /// *sharer's* run they diverge deliberately: `uid` is the sharer's — whose `users/{uid}/
    /// researches/{rid}` the run actually lives under — while `submittedBy` is the owner's, because
    /// that is the only one the create rule constrains. Always address the research document by
    /// `uid`; use `submittedBy` only for attribution and rule reasoning.
    public let uid: String
    public let submittedBy: String

    public let topic: String
    public let email: String

    /// The **client-ms** clock, and deliberately not `submittedAt`.
    ///
    /// The web app writes both, on purpose: `submittedAt` is a `serverTimestamp()` that lands a few
    /// milliseconds later, and the desktop backend's stale-queue defense reads this one. Reading the
    /// server field instead would make this device's staleness arithmetic disagree with the
    /// product's on every single document.
    public let timestampMillis: Int64

    /// The Firestore **server** timestamp, in epoch ms — the FIFO ordering key.
    ///
    /// ⭐ **Ordering and staleness are different questions and they read different clocks.**
    /// `timestampMillis` above is the client's `Date.now()` and is right for "how old is this
    /// document" — the desktop's stale-queue defence uses it, and disagreeing with the product about
    /// staleness would sweep documents it keeps. But ordering by a CLIENT clock is wrong the moment
    /// two people share a device: the backend's own note records the repro — a sharer's browser was
    /// a few seconds behind the owner's, so their later submission carried the earlier stamp and
    /// sorted ahead of a run that had genuinely reached Firestore first.
    ///
    /// Nil when the field is absent (a legacy document, or one written before the server stamp
    /// landed), in which case the ordering falls back to the client clock and finally to last place.
    public let submittedAtMillis: Int64?

    public let assignedWorker: Int?
    public let claimedAtMillis: Int64?
    public let processed: Bool

    /// `"stop"` or `"cancel"` when an owner is controlling a sharer's run. For `stop` it means
    /// **preserve** the running run rather than purge it — the opposite of a plain cancel.
    public let ownerControl: String?

    /// Re-stamped whenever a document is deferred because the worker is resting. A parked run is
    /// *expected* to sit unclaimed past the abandonment horizon — that is the feature's headline use
    /// — so the sweep measures from here when it is present.
    public let restDeferredAtMillis: Int64?

    public let backendRunId: String?

    /// The server version this entry was read at — the base version a claim is asserted against.
    public let updateTime: String?

    /// A brief the OWNER supplied instead of having P1 produce one.
    ///
    /// ⭐ Real product behaviour, not a test affordance: the web app's start payload carries
    /// `briefText` for the flow where the owner pastes their own brief and P1 is skipped. Dropping
    /// it — which this decoder did — makes the device re-derive a brief the owner had already
    /// written, spending a P1 and answering a different question from the one they asked.
    public let briefText: String

    /// The account's pipeline Settings for this run, from the queue document's `config` map.
    ///
    /// ⭐ The natural claim-time source, and it is readable where the alternative may not be: the
    /// device can always read its own queue, while the research document's `pipelineConfig` sits
    /// behind a membership check. Reading it here means the settings the owner chose travel with
    /// the run instead of every run silently using the device's own defaults.
    public let config: RunConfig

    /// `config.podcastLength` — kept as a name because P3 asks for it by this one.
    ///
    /// ⚠ COMPUTED rather than stored. It was a second copy of a value that also lives in `config`,
    /// and two copies of a setting is how a run obeys the owner in one phase and ignores them in
    /// the next.
    public var podcastLength: String? { config.podcastLength }

    public init(
        id: String, action: QueueAction, researchId: String, uid: String, submittedBy: String,
        topic: String = "", email: String = "", timestampMillis: Int64 = 0,
        submittedAtMillis: Int64? = nil,
        assignedWorker: Int? = nil, claimedAtMillis: Int64? = nil, processed: Bool = false,
        ownerControl: String? = nil, restDeferredAtMillis: Int64? = nil,
        backendRunId: String? = nil, updateTime: String? = nil,
        briefText: String = "", podcastLength: String? = nil,
        config: RunConfig = .default
    ) {
        self.id = id
        self.action = action
        self.researchId = researchId
        self.uid = uid
        self.submittedBy = submittedBy
        self.topic = topic
        self.email = email
        self.timestampMillis = timestampMillis
        self.submittedAtMillis = submittedAtMillis
        self.assignedWorker = assignedWorker
        self.claimedAtMillis = claimedAtMillis
        self.processed = processed
        self.ownerControl = ownerControl
        self.restDeferredAtMillis = restDeferredAtMillis
        self.backendRunId = backendRunId
        self.updateTime = updateTime
        self.briefText = briefText
        // ⚠ The explicit `podcastLength:` wins when given, so every existing caller that passes
        // only a length still means what it said. Passing both is not ambiguous for the same
        // reason: the more specific argument is the one the caller went out of their way to write.
        var resolved = config
        if let podcastLength { resolved.podcastLength = podcastLength }
        self.config = resolved
    }

    /// Decode from a listing. Returns nil only when the document cannot describe any action at all.
    /// Parse a Firestore RFC-3339 timestamp to epoch ms.
    ///
    /// ⚠ Two formatters, tried in order. Firestore emits fractional seconds (`...T10:00:00.123Z`)
    /// but omits them when they are zero, and `ISO8601DateFormatter` matches only the shape it was
    /// configured for — one formatter silently returns nil for half the documents in a queue, which
    /// would order them by a coin flip.
    static func epochMillis(fromRFC3339 raw: String) -> Int64? {
        for options in [
            [ISO8601DateFormatter.Options.withInternetDateTime, .withFractionalSeconds],
            [ISO8601DateFormatter.Options.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = ISO8601DateFormatter.Options(options)
            if let date = formatter.date(from: raw) {
                return Int64((date.timeIntervalSince1970 * 1000).rounded())
            }
        }
        return nil
    }

    public static func decode(_ doc: FirestoreREST.ListedDocument) -> QueueEntry? {
        func string(_ key: String) -> String? {
            if case .string(let value)? = doc.fields[key] { return value }
            return nil
        }
        func millis(_ key: String) -> Int64? {
            switch doc.fields[key] {
            case .integer(let value)?: return value
            // The web app writes `Date.now()`, which arrives as an integer; a double is accepted
            // because Firestore returns a `doubleValue` for anything that went through a JS number
            // path that lost its integrality. Refusing it would silently un-age the document — and
            // an entry with no readable age never trips either sweep.
            case .double(let value)?: return Int64(value)
            default: return nil
            }
        }
        /// A real Firestore timestamp, as epoch ms.
        ///
        /// ⚠ Accepts the integer shapes too. `serverTimestamp()` lands as a `timestampValue`, but a
        /// document written by a test double or an older client can carry a number under the same
        /// key — and reading only the RFC-3339 form would silently return nil there, demoting a
        /// perfectly ordered document to last place with nothing in the log to say why.
        func serverMillis(_ key: String) -> Int64? {
            switch doc.fields[key] {
            case .timestamp(let value)?:
                return QueueEntry.epochMillis(fromRFC3339: value)
            case .integer(let value)?: return value
            case .double(let value)?: return Int64(value)
            default: return nil
            }
        }
        func int(_ key: String) -> Int? {
            switch doc.fields[key] {
            case .integer(let value)?: return Int(value)
            case .double(let value)?: return Int(value)
            // The device doc's sibling field carries both shapes in the wild, so accept a numeric
            // string here too rather than reading a claimed document as unclaimed.
            case .string(let value)?: return Int(value)
            default: return nil
            }
        }
        guard let action = string("action") else { return nil }
        var processed = false
        if case .boolean(true)? = doc.fields["processed"] { processed = true }
        return QueueEntry(
            id: doc.id,
            action: QueueAction(raw: action),
            researchId: string("researchId") ?? "",
            uid: string("uid") ?? "",
            submittedBy: string("submittedBy") ?? "",
            topic: string("topic") ?? "",
            email: string("email") ?? "",
            timestampMillis: millis("timestamp") ?? 0,
            submittedAtMillis: serverMillis("submittedAt"),
            assignedWorker: int("assignedWorker"),
            claimedAtMillis: millis("claimedAt"),
            processed: processed,
            ownerControl: string("ownerControl"),
            restDeferredAtMillis: millis("restDeferredAt"),
            backendRunId: string("backendRunId"),
            updateTime: doc.updateTime,
            briefText: string("briefText") ?? "",
            // ⚠ Nested inside `config`, not top level. Reading it from the top would find nothing
            // and fall back silently — which is the same outcome as not reading it at all, and
            // indistinguishable from an owner who never chose any of it.
            config: RunConfig.decode(doc.fields["config"])
        )
    }
}

/// What to do with one queue entry, before any network call is made.
public enum QueueDecision: Equatable, Sendable {
    /// Try to claim it for this worker. The claim itself may still lose.
    case claim
    /// A sibling claimed it and then died. Delete it.
    case sweepZombie
    /// A sibling claimed it recently and may well still be alive. Leave it alone this tick.
    case waitOutGrace
    /// Old enough that the owner has moved on. Delete it — but for a `start` doc, only after
    /// reading the research document, because a healthy `queued` run is still wanted.
    case sweepAbandoned(needsHealthCheck: Bool)
    /// Already claimed, already processed, or otherwise not ours to act on.
    case ignore
    /// An action this backend does not implement.
    case unsupported(String)
}

/// Who actually runs a claimed research.
///
/// A seam, and deliberately so: intake is finished and testable **now**, while the pipeline that
/// consumes a claimed run is items 2 through 17. Without the seam, item 20 could not be shown to
/// work until the last of those landed, and "the owner presses go and this device claims it" is a
/// separable, verifiable thing.
///
/// ⚠ `launch` must not block the poll. It owns a run measured in tens of minutes; the caller is a
/// heartbeat tick.
public protocol RunLauncher: AnyObject, Sendable {
    func launch(_ entry: QueueEntry, worker: Int) async
}

/// The intake rules, ported from the desktop backend's queue loop.
///
/// Pure, and separated from the polling so the protocol can be tested without a Firestore. The
/// interesting cases here are all ones that only appear on a device that was *offline for a while*,
/// which is exactly the case a phone hits and a desktop rarely does.
/// One run waiting behind a busy or parked worker — the shape both apps already render.
///
/// Mirrors the desktop's `queueOwners` entry (`uid` / `runId` / `title` / `position`) plus the
/// per-run breakdown it writes onto the research document, so a queued run reads the same whichever
/// backend is serving the device.
public struct DeferredRun: Equatable {
    public let uid: String
    public let researchID: String
    public let title: String
    /// The queue document this run is waiting in, so the rest keep-alive can re-stamp it.
    public let queueDocID: String
    /// Its current rest-defer stamp, so an already-fresh one costs no write.
    public let restDeferredAtMillis: Int64?
    /// 1-based, over the waiting runs only. A run in flight is not "position 0" — it has left.
    public let position: Int
    public let aheadFromSelf: Int
    public let aheadFromOthers: Int
    /// The run immediately ahead, so the banner can name what this one is waiting on. Empty at the
    /// head of the queue, where the thing ahead is the run actually executing.
    public let behindRunID: String
    public let behindTitle: String

    public init(
        uid: String, researchID: String, title: String, position: Int,
        aheadFromSelf: Int, aheadFromOthers: Int,
        behindRunID: String = "", behindTitle: String = "",
        queueDocID: String = "", restDeferredAtMillis: Int64? = nil
    ) {
        self.uid = uid
        self.researchID = researchID
        self.title = title
        self.queueDocID = queueDocID
        self.restDeferredAtMillis = restDeferredAtMillis
        self.position = position
        self.aheadFromSelf = aheadFromSelf
        self.aheadFromOthers = aheadFromOthers
        self.behindRunID = behindRunID
        self.behindTitle = behindTitle
    }
}

public enum RunQueuePolicy {
    /// How long after a claim a claiming backend is presumed dead.
    public static let zombieGraceMillis: Int64 = 30_000
    /// How long an unclaimed document may sit before the owner is presumed to have moved on.
    ///
    /// 12 hours, matching the desktop. Without this a phone that was off overnight wakes up and
    /// starts a stack of runs the owner abandoned yesterday — each one burning Deep Research quota
    /// on three platforms for a question nobody is waiting for.
    public static let abandonedMaxMillis: Int64 = 12 * 60 * 60 * 1000

    public static func decide(
        _ entry: QueueEntry, now nowMillis: Int64, workerIsResting: Bool
    ) -> QueueDecision {
        if entry.processed { return .ignore }
        if case .unsupported(let raw) = entry.action { return .unsupported(raw) }

        // A claimed document. Whether the claimer is alive is the only question.
        if let claimedAt = entry.claimedAtMillis, entry.assignedWorker != nil, claimedAt > 0 {
            return nowMillis - claimedAt > zombieGraceMillis ? .sweepZombie : .waitOutGrace
        }
        // Claimed but with no usable claim stamp: someone else owns it and we cannot age it.
        if entry.assignedWorker != nil { return .ignore }

        // Unclaimed. Old enough to sweep?
        //
        // ⚠ A document with no readable timestamp has age 0 and is therefore never swept. That is
        // the desktop's behaviour and it is deliberately bug-compatible: sweeping a document whose
        // age is unknown deletes work on a guess.
        let age = entry.timestampMillis > 0 ? nowMillis - entry.timestampMillis : 0
        guard age > abandonedMaxMillis else { return .claim }

        // ⚠ Never sweep a cancel. A cancel is a terminal SIGNAL, not queued work: deleting one
        // before it is handled drops the owner's Stop with no feedback anywhere. Processing a stale
        // cancel is a cheap idempotent no-op, so it is let through.
        if entry.action == .cancel { return .claim }
        // ⚠ Never sweep while resting. A rest-deferred document is EXPECTED to sit unclaimed past
        // the horizon — parking a run over a weekend is the feature, not a fault.
        if workerIsResting { return .claim }
        if let deferred = entry.restDeferredAtMillis, deferred > 0,
           nowMillis - deferred <= abandonedMaxMillis {
            return .claim
        }
        // A `start` document may still be wanted: the research doc is the authority. This is the
        // wake-before-boot hole — park Friday, wake the workers from the phone on Sunday, boot on
        // Monday and the naive sweep deletes the run the owner is waiting on.
        let needsCheck = entry.action == .start && !entry.researchId.isEmpty && !entry.uid.isEmpty
        return .sweepAbandoned(needsHealthCheck: needsCheck)
    }

    /// Queue documents in the order they were submitted — the order they must be claimed in.
    ///
    /// ⛔ **A listing is not a queue.** Firestore's `listDocuments` returns documents ordered by
    /// document NAME, and a queue document's name is an id that has nothing to do with when it was
    /// submitted. So a device with one free worker and two waiting runs claimed whichever id sorted
    /// first — which is a coin flip, and looks from the outside like the queue being ignored. This
    /// is the same ordering the desktop backend applies before it claims, ported key for key so the
    /// two cannot disagree about who is next while sharing one account.
    ///
    /// The key, in precedence order:
    ///   1. `submittedAt`, the Firestore **server** timestamp — immune to clock skew between an
    ///      owner's browser and a sharer's, which is the failure that made this a server field.
    ///   2. `timestamp`, the client clock, for a document written before the server stamp existed.
    ///   3. Last place, for a document carrying neither. ⚠ Demoted rather than dropped: an
    ///      unorderable document is still work somebody asked for.
    ///
    /// The document id breaks ties, so two submissions in the same millisecond still have ONE
    /// answer — a comparator that leaves them equal makes the order depend on the sort's stability
    /// and on the listing it happened to be handed.
    public static func fifoOrdered(_ entries: [QueueEntry]) -> [QueueEntry] {
        entries.sorted { lhs, rhs in
            let a = fifoKey(lhs)
            let b = fifoKey(rhs)
            if a.rank != b.rank { return a.rank < b.rank }
            if a.millis != b.millis { return a.millis < b.millis }
            return lhs.id < rhs.id
        }
    }

    /// How much of a topic travels into a queue badge. The desktop's own truncation, matched so the
    /// same run does not read differently depending on which backend published it.
    public static let queueTitleMaxChars = 60

    /// How stale a rest-defer stamp may get before it is refreshed. The desktop's 30 minutes.
    public static let restStampRefreshMillis: Int64 = 30 * 60 * 1000

    /// Whether a parked run's abandonment clock needs re-stamping on this pass.
    ///
    /// ⛔ **The stamp is what makes "park it over the weekend" safe, and this backend READ the field
    /// without ever writing it.** The sweep measures a rest-deferred document's age from
    /// `restDeferredAt` once the workers are awake again — so with nothing stamping it, a run parked
    /// on Friday is aged from its submission and the Monday sweep deletes the work the owner came
    /// back for. Half a mechanism reads exactly like a whole one until the day it matters.
    ///
    /// ⚠ Only while a worker is actually resting. Stamping a run that is merely waiting behind a
    /// BUSY worker would extend the abandonment horizon indefinitely for every queue, which is the
    /// hole the horizon exists to bound.
    public static func needsRestStamp(
        _ run: DeferredRun, workersResting: Bool, now: Int64
    ) -> Bool {
        guard workersResting else { return false }
        guard let stamp = run.restDeferredAtMillis, stamp > 0 else { return true }
        return now - stamp > restStampRefreshMillis
    }

    /// The runs waiting behind a busy or parked worker, in the order they will be taken.
    ///
    /// ⛔ **Nothing on this device published this, and both UIs already render it.** The web app's
    /// Shared-with popup draws an amber `#N` badge per waiting run from the device document's
    /// `queueOwners`, the phone's own People popup parses the same field, and the desktop backend
    /// rewrites it on every queue recompute. The iOS backend only ever READ it — so a run deferred
    /// because the owner parked a worker sat in the queue correctly and appeared, on every screen,
    /// as though nothing had been submitted at all. The whole point of parking a worker is that the
    /// work waits *visibly*.
    ///
    /// ⚠ Sorted here rather than trusting the caller. The positions ARE the ordering claim, and a
    /// function that renumbers whatever order it is handed would publish a queue that disagrees
    /// with the one `fifoOrdered` claims from — same list, two different answers about who is next.
    ///
    /// - Parameter entries: queue documents that are still waiting. The caller removes anything it
    ///   claimed or swept in this pass, because an entry claimed a moment ago still carries no
    ///   `assignedWorker` in the copy this process is holding.
    public static func deferredRuns(_ entries: [QueueEntry]) -> [DeferredRun] {
        // The desktop's scan filter, field for field: unclaimed `start` work that names both a
        // research and a submitter. A `cancel` is a signal rather than queued work, and an entry
        // missing either id cannot be joined to anything the apps could render.
        let waiting = fifoOrdered(entries).filter {
            $0.action == .start && !$0.processed && $0.assignedWorker == nil
                && !$0.researchId.isEmpty && !submitter($0).isEmpty
        }
        return waiting.enumerated().map { index, entry in
            let uid = submitter(entry)
            let ahead = waiting.prefix(index)
            // ⚠ Split by ACCOUNT, because the two counts say different things to the person
            // reading them: "you have two runs ahead of this" is your own doing, "someone else
            // has two ahead of you" is the shared device being shared. The web app's banner
            // words them differently for exactly that reason.
            let fromSelf = ahead.filter { submitter($0) == uid }.count
            let previous = index > 0 ? waiting[index - 1] : nil
            return DeferredRun(
                uid: uid,
                researchID: entry.researchId,
                title: title(entry.topic),
                position: index + 1,
                aheadFromSelf: fromSelf,
                aheadFromOthers: index - fromSelf,
                behindRunID: previous?.researchId ?? "",
                behindTitle: previous.map { title($0.topic) } ?? "",
                queueDocID: entry.id,
                restDeferredAtMillis: entry.restDeferredAtMillis
            )
        }
    }

    /// `submittedBy` first, `uid` second — the desktop's own precedence. They differ on a run a
    /// SHARER submitted to someone else's device, and picking the wrong one puts the badge on the
    /// wrong person in the owner's popup.
    static func submitter(_ entry: QueueEntry) -> String {
        entry.submittedBy.isEmpty ? entry.uid : entry.submittedBy
    }

    static func title(_ topic: String) -> String {
        String(topic.prefix(queueTitleMaxChars))
    }

    static func fifoKey(_ entry: QueueEntry) -> (rank: Int, millis: Int64) {
        if let server = entry.submittedAtMillis, server > 0 { return (0, server) }
        if entry.timestampMillis > 0 { return (0, entry.timestampMillis) }
        return (1, 0)
    }

    /// The lowest-numbered worker that is neither busy nor resting, or nil if there is none.
    ///
    /// Lowest-first rather than any-free so run placement is deterministic and reproducible from a
    /// log. ⚠ Resting workers are excluded as well as busy ones: resting is the owner's explicit
    /// "not now", and handing a resting worker a run silently overrides it.
    public static func freeWorker(
        count: Int, busy: Set<Int>, resting: Set<Int>
    ) -> Int? {
        guard count > 0 else { return nil }
        return (1...count).first { !busy.contains($0) && !resting.contains($0) }
    }
}
