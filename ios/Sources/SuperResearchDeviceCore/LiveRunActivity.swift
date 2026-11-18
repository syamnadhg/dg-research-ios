import Foundation

/// Which platform each worker is driving, **right now**.
///
/// ⭐ **Reported by the run itself rather than read back from Firestore, and that is the point.** The
/// run is executing inside this process, so the app already knows which web view it is typing into;
/// asking a server to tell it back would be a round trip, a write the rules must allow, and a lag —
/// and it would still be wrong between phases. The one question Browser watch exists to answer —
/// *which tab do I open to see this happening* — is answered locally and instantly.
///
/// ⚠ `RunState.agents` cannot answer it on this device: the per-worker map the snapshot builds
/// carries `agents: [:]`, and the document's own `currentRun*` fields describe worker 1 only. A
/// glow driven off that would be blank on every worker but the first, and stale on that one.
public final class LiveRunActivity: @unchecked Sendable {

    public static let shared = LiveRunActivity()

    /// What a worker is running, as the device document describes it.
    ///
    /// ⭐ These are the four fields `devices/{id}.workers.{n}` carries, and they are what puts a
    /// busy pill on the RIGHT PERSON in both the phone's People popup and the web app's
    /// "Shared with" popup. The device read that map and cleared it and **never wrote it**, so no
    /// run has ever been attributed to the person who fired it.
    public struct RunFacts: Sendable, Equatable {
        public var uid: String
        public var title: String
        public var phase: Int
        public var totalPhases: Int
        /// ⚠ NOT published to the device document — it is not one of the four fields `workers`
        /// carries. It is here because Stop is keyed by research id, and the only thing the UI
        /// holds is a worker ordinal: without this the popup can see a run it cannot name, and so
        /// cannot stop it.
        public var researchID: String

        /// The phase the PLATFORM is executing (0 login, 1 brief, 2 report, 3 sources) — distinct
        /// from `phase`, which is the run-wide product phase the web app gates on.
        public var platformPhase: Int = 0

        /// When this run was claimed, in epoch millis.
        ///
        /// ⛔ **The elapsed timer in Browser watch was stuck at 00:00 for every live run**, because
        /// the per-worker snapshot was built with `elapsedSeconds: 0` — the map carried no start
        /// time, so the one number the screen has to derive was hard-coded to nothing. A timer that
        /// never moves reads as a frozen app, which is the opposite of what it is there to say.
        public var startedAtMillis: Int64

        public init(
            uid: String, title: String, phase: Int, totalPhases: Int = 6, researchID: String = "",
            startedAtMillis: Int64 = 0
        ) {
            self.startedAtMillis = startedAtMillis
            self.uid = uid
            self.title = title
            self.phase = phase
            self.totalPhases = totalPhases
            self.researchID = researchID
        }
    }

    private let lock = NSLock()
    /// Every platform each worker is driving, and the one in front.
    ///
    /// ⛔ **A SET, and it was a single string.** The old shape could hold one platform per worker and
    /// `clear` removed the whole key — so the moment P2 runs three agents at once, the first one to
    /// finish darkens the two still working, and the owner is looking at an idle-looking tile for a
    /// platform that is mid-deep-research. Sequential execution is the only reason a single string
    /// survived this long, and that is a property of today's executor rather than of the model.
    /// ⚠ ORDERED, not a Set, and the order is what makes the handover answerable. With a Set the
    /// rule could only be "alphabetically first", which is arbitrary — and worse, untestable: a Set
    /// has no defined iteration order, so a test could not tell a deliberate ordering from a lucky
    /// hash seed. Insertion order means the front goes to the platform that has been running
    /// LONGEST, which is a reason rather than a tiebreak.
    private var byWorker: [Int: [String]] = [:]
    /// The platform whose web view is actually in front, per worker.
    ///
    /// ⚠ Separate from the set on purpose. Exactly one tile may carry the strong "this is what you
    /// will see if you tap" treatment, and exactly one page may take owner input — while several
    /// platforms can legitimately be running. Collapsing the two makes one of them wrong.
    private var foreground: [Int: String] = [:]
    private var facts: [Int: RunFacts] = [:]
    /// Called on every change so a UI layer can republish it. Set by the app; nil in tests.
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    /// The platform whose page is in FRONT for *worker*, or nil when it is between platforms.
    public func platform(forWorker worker: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return foreground[worker]
    }

    /// Every platform *worker* is driving right now — one today, three when P2 goes concurrent.
    public func platforms(forWorker worker: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return byWorker[worker] ?? []
    }

    /// Every worker currently driving something.
    public var busyWorkers: Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return Set(byWorker.keys)
    }

    /// Record that *worker* has started on *platform*, or finished when nil.
    ///
    /// ⚠ Setting a platform REPLACES the previous one for that worker rather than adding to it: a
    /// run drives the three platforms in sequence, so two glowing at once would mean the previous
    /// one was never cleared — and a stale glow points the owner at a tab where nothing is
    /// happening, which is worse than no glow at all.
    public func set(worker: Int, platform: String?) {
        lock.lock()
        if let platform, !platform.isEmpty {
            if byWorker[worker, default: []].contains(platform) == false {
                byWorker[worker, default: []].append(platform)
            }
            foreground[worker] = platform
        } else {
            byWorker.removeValue(forKey: worker)
            foreground.removeValue(forKey: worker)
        }
        lock.unlock()
        onChange?()
    }

    /// One platform has finished on this worker; anything else it is driving keeps its glow.
    ///
    /// ⛔ **The distinction `clear(worker:)` could not make.** That removes the worker outright,
    /// which is right when the RUN ends and wrong when one of three agents finishes — and with the
    /// old single-string model there was no third option to reach for.
    public func finished(worker: Int, platform: String) {
        lock.lock()
        byWorker[worker]?.removeAll { $0 == platform }
        if byWorker[worker]?.isEmpty == true { byWorker.removeValue(forKey: worker) }
        if foreground[worker] == platform {
            // Hand the front to whatever has been running LONGEST — deterministic, and a reason
            // rather than a tiebreak. An arbitrary pick would make Browser watch open a different
            // tab on every redraw, which reads as the app choosing at random.
            foreground[worker] = byWorker[worker]?.first
        }
        lock.unlock()
        onChange?()
    }

    /// Forget everything — for a run that ended, however it ended.
    ///
    /// ⛔ Called from the run's exit path whatever happened, including a throw. A crash-out that
    /// left the glow on would leave Browser watch permanently pointing at a platform nothing is
    /// using, and the owner's only clue that it is stale would be that nothing ever changes.
    public func clear(worker: Int) {
        set(worker: worker, platform: nil)
    }

    // MARK: - Who this worker is running for

    /// Record the run a worker has taken on.
    public func startRun(
        worker: Int, uid: String, title: String, totalPhases: Int = 6, researchID: String = "",
        // ⚠ Injectable so a test can assert the elapsed arithmetic against a fixed clock rather
        // than against "roughly now", which is how a timer test ends up asserting nothing.
        now: @Sendable () -> Date = { Date() }
    ) {
        lock.lock()
        facts[worker] = RunFacts(
            uid: uid, title: title, phase: 0, totalPhases: totalPhases, researchID: researchID,
            startedAtMillis: Int64(now().timeIntervalSince1970 * 1000)
        )
        lock.unlock()
        onChange?()
    }

    /// The phase the PLATFORM is in, which is not the phase the executor is in.
    ///
    /// ⛔⛔ **This is why Browser watch said "Research brief" for the whole of deep research.** P1
    /// and P2 both happen inside ONE `runPhases` call per platform, while the executor's counter
    /// only advances BETWEEN calls — so for the forty minutes ChatGPT spends on its report the
    /// document still says phase 1. The two numberings are genuinely different facts and must not
    /// share a field: the web app gates its own phase transitions on the executor's.
    public func setPlatformPhase(worker: Int, phase: Int) {
        lock.lock()
        if facts[worker] != nil { facts[worker]?.platformPhase = phase }
        lock.unlock()
        onChange?()
    }

    /// Move a running worker to a new phase.
    ///
    /// ⚠ Does NOT create an entry. A phase update for a worker with no run would publish a busy
    /// pill for a run that is not happening, and the popup has no way to tell the difference.
    public func setPhase(worker: Int, phase: Int) {
        lock.lock()
        if facts[worker] != nil { facts[worker]?.phase = phase }
        lock.unlock()
        onChange?()
    }

    /// The run has ended, however it ended.
    public func endRun(worker: Int) {
        lock.lock()
        facts.removeValue(forKey: worker)
        lock.unlock()
        onChange?()
    }

    public func run(forWorker worker: Int) -> RunFacts? {
        lock.lock(); defer { lock.unlock() }
        return facts[worker]
    }

    /// Every worker currently running something, for publication to the device document.
    /// This worker's run as the SCREEN needs it, straight from the process that is driving it.
    ///
    /// ⛔ **The card asked Firestore for a fact this process owns.** `DeviceSnapshot.run(forWorker:)`
    /// is fed only by the device document's `workers` map, which is written once per 20-second beat
    /// — so the strip lags a run by up to a beat at the start, and reads "No runs live" for the
    /// whole window between a run ending and the next publish. Measured live 2026-08-17: the card
    /// flipped to "No runs live" the instant the run was abandoned, while ChatGPT's tab carried on
    /// visibly researching.
    public func runState(forWorker worker: Int, now: Date = Date()) -> (
        title: String, phase: Int, elapsedSeconds: Int, startedAtMillis: Int64
    )? {
        lock.lock(); defer { lock.unlock() }
        guard let f = facts[worker] else { return nil }
        let elapsed = f.startedAtMillis > 0
            ? max(0, Int(now.timeIntervalSince1970) - Int(f.startedAtMillis / 1000))
            : 0
        return (title: f.title, phase: f.platformPhase, elapsedSeconds: elapsed,
                startedAtMillis: f.startedAtMillis)
    }

    public var runs: [Int: RunFacts] {
        lock.lock(); defer { lock.unlock() }
        return facts
    }
}
