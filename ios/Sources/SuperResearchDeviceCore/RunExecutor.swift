import Foundation

/// Turns a **claimed** queue entry into a finished run: P0–P3 here, P4/P5 in the cloud.
///
/// ⭐ **The piece that connects the others.** Intake claims a run, the pipeline drives the
/// platforms, the emitter writes the documents, and the handoff hands the cloud its half — each of
/// those existed and nothing joined them, so a claimed run went nowhere.
///
/// ⚠ Deliberately thin. Every decision it needs already lives somewhere with tests of its own; this
/// owns only the ORDER, which is the thing that cannot be tested inside any of them.
public actor RunExecutor: RunLauncher {

    /// What a run needs from the outside world, so the order can be tested without a device.
    public protocol Pipeline: Sendable {
        /// Run P0–P3 for one platform and return its report, or nil if it produced none.
        ///
        /// ⛔ `onBriefProduced` is AWAITED the instant phase 1 has a brief, and that ordering is the
        /// point. P1 and P2 both happen inside this one call, so a run that only reports its brief
        /// on RETURN leaves the web app's phase-1 tile open — with no brief document to show — for
        /// the entire forty minutes of deep research that follow. Measured: the owner's frontend sat
        /// "stuck in phase one" for a whole run and then errored.
        func runPhases(
            entry: QueueEntry, platform: String, brief: String,
            onBriefProduced: @escaping @Sendable (String) async -> Void
        ) async throws -> (brief: String, report: String?)
        /// The run is over — put any host resources back to rest.
        ///
        /// ⚠ Defaulted to a no-op so every existing test double still conforms. Only the real
        /// pipeline has web views to release.
        func release()
    }

    /// P3: the notebook, its public link, and the podcast.
    ///
    /// ⚠ A separate seam from `Pipeline` because it is a different shape of work — one platform, no
    /// brief, no report — and because the ORDER around it is what this file owns: P3 runs after the
    /// documents exist and before the handoff, and its failure must not take the run with it.
    /// - Parameter lengthAtClaim: the podcast length as it read when the run was CLAIMED.
    ///
    ///   ⛔ Read at claim time and carried through, NOT read at P3. The whole reason the backend has
    ///   two reads is that the owner can change the setting mid-run and the later value must win —
    ///   two reads taken at the same moment are one read with extra steps, and the setting the run
    ///   started with is silently lost.
    public protocol NotebookStage: Sendable {
        func run(
            entry: QueueEntry, consolidated: String, lengthAtClaim: String?
        ) async throws -> Products
    }

    /// What P3 produced. Every field is optional-in-effect, because each of the three steps degrades
    /// independently: a notebook with no public link is still worth linking, and a run with no
    /// podcast still has five documents and must still hand off.
    public struct Products: Sendable, Equatable {
        public let notebookURL: String
        public let publicVerified: Bool
        public let audio: Data?
        /// Why the audio is missing, or how the link degraded. Empty on a clean run.
        public let note: String

        public init(notebookURL: String, publicVerified: Bool, audio: Data?, note: String = "") {
            self.notebookURL = notebookURL
            self.publicVerified = publicVerified
            self.audio = audio
            self.note = note
        }
    }

    /// Where the podcast goes once P3 has it.
    ///
    /// ⚠ A seam rather than a direct `FirebaseStorage`: the upload is the one step that needs a real
    /// bucket and a real token, and without this the ordering around it could only be tested by
    /// uploading.
    public protocol AudioSink: Sendable {
        func deliver(audio: Data, entry: QueueEntry) async throws -> AudioDelivery.Delivered
    }

    private let pipeline: any Pipeline
    private let notebook: (any NotebookStage)?
    private let audioSink: (any AudioSink)?
    private let configReader: (any InAppNotebookStage.ConfigReader)?
    /// Who this worker is running for, so the device document can say so.
    ///
    /// ⭐ Written HERE because this is the only place that knows the entry AND the phase. The
    /// device published `busyWorkerIds` (which worker is busy) but never `workers` (whose run it
    /// is), so a busy pill could never appear on the person who fired it.
    private let activity: LiveRunActivity
    private let emitter: ContractEmitter
    private let handoff: HandoffTransport
    private let now: @Sendable () -> Int64

    public init(
        pipeline: any Pipeline, emitter: ContractEmitter, handoff: HandoffTransport,
        notebook: (any NotebookStage)? = nil, audioSink: (any AudioSink)? = nil,
        configReader: (any InAppNotebookStage.ConfigReader)? = nil,
        activity: LiveRunActivity = .shared,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.activity = activity
        self.pipeline = pipeline
        self.notebook = notebook
        self.audioSink = audioSink
        self.configReader = configReader
        self.emitter = emitter
        self.handoff = handoff
        self.now = now
    }

    /// Who writes the brief. ChatGPT, as the desktop hardcodes it.
    ///
    /// ⚠ A named constant rather than `platforms.first`, so the rule survives a reordering of
    /// `Prompts.p2Platforms` and so a reader can find it.
    static let briefPlatform = "chatgpt"

    public private(set) var steps: [String] = []
    /// P1's product, once it exists. See `briefArrived`.
    private var brief = ""
    /// Whether `phase_start:2` has been announced, so the completion is not emitted for a phase
    /// that never began.
    private var phase2Started = false

    /// The worker this run is on, so `announce` can move the right pill without threading the
    /// ordinal through every call. Set once, at launch.
    private var activeWorker = 1

    public func launch(_ entry: QueueEntry, worker: Int) async {
        steps.append("start:\(entry.researchId):w\(worker)")
        activeWorker = worker
        // ⛔ On EVERY exit, including the abandon and stop paths. A run that ends leaving four
        // full-screen WebContent processes attached to the window is what the crash report's
        // 452MB of IOSurface was — and they can never suspend while attached.
        defer { pipeline.release() }
        activity.startRun(
            worker: worker, uid: entry.uid, title: entry.topic, researchID: entry.researchId
        )
        // ⛔ Cleared on EVERY exit, including a throw or an early return. A `workers` entry that
        // outlives its run leaves a busy pill on someone's tile for ever — and, worse, the entry is
        // what the web app counts as capacity.
        defer { activity.endRun(worker: worker) }
        do {
            try await emitter.startRun()
        } catch {
            // ⚠ Not fatal on its own. The run can still produce documents and hand off; refusing to
            // start because one patch failed would waste research units that are about to be spent
            // anyway. It IS recorded, because a run whose start never landed will look odd later.
            steps.append("startRun-failed")
        }

        // ⭐ Read HERE, at the top of the run, and carried to P3 untouched. This is the "disk" half
        // of the backend's two-source length resolution — the value as it stood when the run was
        // claimed. Reading it at P3 instead would make both reads the same read, and an owner who
        // changed the setting mid-run would get their new value either way, which sounds fine until
        // the P3 re-read is DENIED (the normal case for this device's identity) and the fallback
        // then has nothing to fall back to.
        // ⭐ The QUEUE document first, because it is the one this device can always read: the
        // research document's `pipelineConfig` sits behind a membership check, while the queue is
        // this device's own subcollection. A length the owner chose must not be lost to a read that
        // may be refused — every podcast would silently be the fallback length.
        var lengthAtClaim = entry.podcastLength
        if lengthAtClaim == nil {
            lengthAtClaim = await configReader?.podcastLength(
                uid: entry.uid, researchId: entry.researchId
            )
        }

        // P1 once, then P2 per platform — sequentially, because the device has one foreground view
        // per worker (decision B1).
        // ⭐ The owner's OWN brief, when they pasted one. A supported flow — and dropping it makes
        // the device spend a P1 re-deriving a brief that already exists, then answer a subtly
        // different question from the one that was asked.
        // ⚠ Actor state rather than locals, because `briefArrived` is now called from INSIDE
        // `runPhases` — mid-call — and a local could not be reached from there. Reset here so an
        // executor that serves a second run does not inherit the first one's brief.
        brief = entry.briefText.trimmingCharacters(in: .whitespacesAndNewlines)
        phase2Started = false
        if !brief.isEmpty { steps.append("brief:supplied:\(brief.count)") }
        var reports: [String: String] = [:]

        // ⭐ **The agents the OWNER left switched on.** A platform toggled off in Settings must not
        // be driven — it costs a deep-research unit from a hard monthly cap and answers a question
        // nobody asked.
        //
        // ⚠ Reported as `skipped` rather than left alone, and that is the difference between a row
        // the web app can explain and a row that sits silent: `skipped` is a word the frontend's
        // tile logic knows, while an untouched agent is indistinguishable from one that is still
        // thinking. Written BEFORE the loop so the rows settle immediately rather than after three
        // deep-research runs.
        let platforms = entry.config.enabledPlatforms
        for platform in Prompts.p2Platforms where !entry.config.runsAgent(platform) {
            steps.append("agent-off:\(platform)")
            try? await emitter.patchResearch(
                ["agents.\(platform)": .map(["status": .string("skipped")])]
            )
        }

        await announce(phase: 1, starting: true)
        // ⛔ **A phase that never STARTED must never be announced as COMPLETE.** Phase 2 begins only
        // when a brief exists; the completion below used to fire unconditionally at the end of the
        // loop, so a run where every platform failed emitted `phase_start:1` and then
        // `phase_complete:2` — and the web app duly reported phase two finished on a run that never
        // reached phase one. Reported live 2026-08-14.
        for platform in platforms {
            // ⚠ The agent map is what the web app's per-agent rows read. Without it three agents sit
            // at whatever they were before, and a run in flight is indistinguishable from one that
            // never started — which is the same class of invisibility the phase events fix.
            //
            // ⛔ **The VOCABULARY is the desktop's, measured from its own writer:** `running`,
            // `complete`, `errored`, `skipped`. This wrote `completed` and `failed` — plausible
            // English, and words the frontend's tile logic does not recognise, so a finished agent
            // would have rendered as neither done nor failed.
            try? await emitter.patchResearch(["agents.\(platform)": .map(["status": .string("running")])])
            do {
                let out = try await pipeline.runPhases(
                    entry: entry, platform: platform, brief: brief,
                    // ⭐ **Phase 1 ends HERE — when the brief exists, not when the platform does.**
                    // The document is written and the phase announced before deep research starts,
                    // which is what lets the web app close its phase-1 tile and show the brief. It
                    // used to happen after the whole platform finished, so a run spent its entire
                    // forty minutes reporting "phase 1, in progress, no document".
                    onBriefProduced: { [weak self] produced in
                        await self?.briefArrived(produced, from: platform)
                    }
                )
                // ⛔ **P1 belongs to ChatGPT, and only to ChatGPT.** The desktop hardcodes it —
                // `research.py`'s `run_phase1` navigates to chatgpt.com and every event it emits
                // says `agent="chatgpt"`; there is no P1 platform setting anywhere in the product.
                //
                // Here it was whichever platform happened to finish first, which is invisible
                // until ChatGPT fails. Measured live 2026-08-14: ChatGPT was blocked by a modal,
                // Gemini's send went unconfirmed, and CLAUDE silently became the brief writer —
                // a different model, a different prompt contract, and nothing said so.
                // ⚠ A BACKSTOP now, not the main path: `briefArrived` already ran, mid-call, the
                // moment phase 1 produced the brief. This still matters for a pipeline that returns
                // a brief without reporting one — the owner-supplied-brief echo, and every test
                // double that implements the protocol without the callback.
                if brief.isEmpty, !out.brief.isEmpty, platform == Self.briefPlatform {
                    await briefArrived(out.brief, from: platform)
                }
                if let report = out.report, !report.isEmpty {
                    reports[platform] = report
                    steps.append("report:\(platform):\(report.count)")
                    try? await emitter.patchResearch(
                        ["agents.\(platform)": .map(["status": .string("complete")])]
                    )
                } else {
                    steps.append("no-report:\(platform)")
                    try? await emitter.patchResearch(
                        ["agents.\(platform)": .map(["status": .string("errored")])]
                    )
                }
            } catch InAppPhaseError.stoppedByOwner {
                // ⛔ **A stop ends the RUN, not just this platform.** Carrying on to the next agent
                // would spend a deep-research unit on a run the owner has already cancelled — and
                // would do it twice more. Marked `skipped` rather than `errored`, because nothing
                // failed here.
                steps.append("stopped:\(platform)")
                try? await emitter.patchResearch(
                    ["agents.\(platform)": .map(["status": .string("skipped")])]
                )
                if phase2Started { await announce(phase: 2, starting: false) }
                await stopped()
                return
            } catch {
                // ⚠ One platform failing must not discard the others — their research units are
                // already spent, and two reports plus a stated gap is a degraded run worth
                // finishing.
                steps.append("failed:\(platform)")
                try? await emitter.patchResearch(
                    ["agents.\(platform)": .map(["status": .string("errored")])]
                )
            }

            // ⛔⛔ **THE BRIEF IS THE RUN. Without one there is nothing for the others to research.**
            // Measured live 2026-08-17: ChatGPT's composer took no caret, P1 produced nothing — and
            // the loop carried straight on, so Gemini and Claude each ran their OWN phase 1 against
            // the raw topic. Three platforms lit up in Browser watch one after another, the frontend
            // showed everything failing, and two deep-research units were spent answering a question
            // nobody asked: P1's contract is a researched brief, not a chat reply to a topic.
            //
            // ⚠ The guard is on the PRODUCT, not on the exception: ChatGPT can also return a brief
            // too short to use, which throws nowhere and leaves `brief` empty just the same.
            if platform == Self.briefPlatform, brief.isEmpty {
                steps.append("abandoned:no-brief")
                for other in platforms where other != platform {
                    try? await emitter.patchResearch(
                        ["agents.\(other)": .map(["status": .string("skipped")])]
                    )
                }
                await fail(
                    reason: "ChatGPT produced no brief, so there was nothing for the other agents "
                        + "to research — phase 1 is ChatGPT's alone and the run stops here rather "
                        + "than spending deep-research units on the raw topic"
                )
                return
            }
        }
        if phase2Started { await announce(phase: 2, starting: false) }

        guard !reports.isEmpty else {
            // ⛔ NO handoff. Handing off with nothing would set beDone, unstall the queue, fire the
            // cloud trigger, and produce a video of an empty document — a run that reports success
            // and delivers nothing.
            steps.append("abandoned:no-reports")
            // ⛔ **And it must SAY SO.** `startRun` wrote `ongoing`; the success path deliberately
            // leaves it there because the cloud finishes the run and flips it. This path has no
            // cloud half — so returning silently leaves the research `ongoing` for ever, and the
            // owner watches a run that died in four seconds sit at phase 1 all day. Measured
            // exactly that way on 2026-08-14.
            //
            // ⚠ The two reasons are distinguished because only one of them is a fault: every agent
            // failing is a broken run, while every agent being switched OFF is the configuration
            // doing what it was told.
            await fail(
                reason: platforms.isEmpty
                    ? "no agents are enabled in Settings, so there was nothing to run"
                    : "every enabled agent failed to produce a report"
            )
            return
        }

        if !brief.isEmpty {
            try? await emitter.saveDocument(.brief, content: brief)
        }
        for platform in Prompts.p2Platforms {
            guard let report = reports[platform],
                  let docType = ContractEmitter.DocType(rawValue: platform) else { continue }
            try? await emitter.saveDocument(docType, content: report)
        }
        let consolidated = Self.consolidate(topic: entry.topic, reports: reports)
        if !consolidated.isEmpty {
            try? await emitter.saveDocument(.consolidated, content: consolidated)
        }
        steps.append("documents:\(reports.count + (brief.isEmpty ? 0 : 1) + 1)")

        await runNotebookPhase(
            entry: entry, consolidated: consolidated, lengthAtClaim: lengthAtClaim
        )

        // ⚠ The handoff is LAST and is not conditional on the document writes succeeding: `beDone`
        // is what unstalls the owner's NEXT run, so withholding it because a document write failed
        // punishes a second run for the first one's trouble.
        await RunHandoff.handOff(
            uid: entry.uid, researchId: entry.researchId, now: now(), transport: handoff
        )
        steps.append("handoff")
    }

    /// End a run that produced nothing, in a way the web app can render.
    ///
    /// ⭐ **`stopped` and `lastError`, both from the contract's own vocabulary.** `status` is a
    /// closed enum and it contains no `failed` or `error` — the terminal word for a run that ended
    /// without finishing is `stopped`, and the human-readable half goes in `lastError`, which the
    /// contract lists as a device-written string for exactly this.
    ///
    /// ⚠ **`stoppedBy` is deliberately NOT written.** Its vocabulary is closed too — `owner_stop`,
    /// `owner_cancel`, `hard_reset_*` — and every value in it names a HUMAN. Putting a device
    /// failure there would tell the owner they stopped a run they never touched.
    /// End a run the OWNER cancelled.
    ///
    /// ⚠ `stopped` with no `lastError`, and the difference from `fail` is the point: `lastError`
    /// makes the web app show a problem, and a run the owner deliberately stopped is not one. The
    /// same status word, reached for a different reason, told honestly.
    ///
    /// ⛔ And NO handoff. Handing off would set `beDone`, fire the cloud trigger, and produce a
    /// video and an email for a research the owner just cancelled.
    private func stopped() async {
        steps.append("stopped-by-owner")
        try? await emitter.patchResearch([
            "status": .string("stopped"),
            "updatedAt": .integer(now()),
        ])
    }

    /// Phase 1 has a brief: write it, stream it, and move the run on.
    ///
    /// ⚠ Idempotent, because it is now reachable twice — once from the pipeline mid-call and once
    /// from the backstop after it returns. Announcing the same transition twice would emit a second
    /// `phase_complete:1` the web app has already acted on.
    private func briefArrived(_ produced: String, from platform: String) async {
        guard brief.isEmpty, !produced.isEmpty, platform == Self.briefPlatform else { return }
        brief = produced
        // ⛔ The DOCUMENT first, then the phase. The frontend closes its phase-1 tile on
        // `phase_complete:1` and immediately looks for `documents/brief`; announcing first would
        // hand it a completed phase with nothing to show, which is the race the owner sees as an
        // empty tile.
        try? await emitter.saveDocument(.brief, content: produced)
        steps.append("brief:\(produced.count)")
        await announce(phase: 1, starting: false)
        await announce(phase: 2, starting: true)
        phase2Started = true
    }

    private func fail(reason: String) async {
        steps.append("failed:\(reason)")
        try? await emitter.patchResearch([
            "status": .string("stopped"),
            "lastError": .string(reason),
            "updatedAt": .integer(now()),
        ])
    }

    /// Say that a phase began or ended — in the event stream AND on the document.
    ///
    /// ⛔ **Both, and `currentPhase` is not optional.** The contract is explicit that `phase` must be
    /// written alongside `currentPhase`, and that omitting `currentPhase` leaves the homepage tile
    /// glowing the stale node for ever. The events alone drive the live view for a tab that is open;
    /// the fields are what a tab opened later reads.
    ///
    /// ⚠ Neither write may abort the run. A research that produced three reports and could not
    /// announce them is still a research worth finishing — reporting is not the product.
    private func announce(phase: Int, starting: Bool) async {
        try? await emitter.emit(type: starting ? "phase_start" : "phase_complete", phase: phase)
        if starting {
            // The same phase the research document gets, so the worker pill on the person's tile
            // and the run card cannot disagree about how far along the run is.
            activity.setPhase(worker: activeWorker, phase: phase)
            try? await emitter.patchResearch([
                "currentPhase": .integer(Int64(phase)), "phase": .integer(Int64(phase)),
            ])
        }
    }

    /// P3: notebook → public link → podcast → Storage → links.
    ///
    /// ⛔ **Nothing in here may abort the run.** By this point the run has spent three deep-research
    /// units and written five documents; losing all of that because a share dialog moved, or because
    /// no MP3 encoder is linked, is a worse outcome than a research with no podcast. The desktop
    /// backend takes the same position — it runs its handoff tail for the audio-captured AND the
    /// audio-skipped branches alike — and the frontend's own P3 gate accepts `beDone` on its own,
    /// precisely so an audio-less run still advances to P5.
    ///
    /// ⚠ The phase events bracket it because the frontend drives P4 off `phase_complete:3`. Emitting
    /// them around a phase that did not run would be worse than silence, so they are emitted only
    /// when a notebook stage is actually configured.
    private func runNotebookPhase(
        entry: QueueEntry, consolidated: String, lengthAtClaim: String?
    ) async {
        guard let notebook else {
            steps.append("p3-skipped:no-notebook-stage")
            return
        }
        // ⭐ The owner's "Generate podcast" toggle, which resolves to skipping phase 3.
        //
        // ⚠ Checked BEFORE the phase events, not inside the stage. The frontend drives P4 off
        // `phase_complete:3`, so bracketing a phase that was configured never to run would announce
        // a podcast step that is not happening — the comment right above this method already says
        // emitting them around a phase that did not run is worse than silence.
        guard !entry.config.skipPhases.contains(3) else {
            steps.append("p3-skipped:disabled-in-settings")
            return
        }
        await announce(phase: 3, starting: true)

        var products: Products?
        do {
            products = try await notebook.run(
                entry: entry, consolidated: consolidated, lengthAtClaim: lengthAtClaim
            )
        } catch {
            steps.append("p3-failed:\(error)")
        }

        if let products {
            // The notebook links first, and independently of the audio: a notebook that exists is
            // worth linking even when the podcast never materialises, and it is the only way the
            // owner can open the thing the run built.
            if !products.notebookURL.isEmpty {
                try? await emitter.patchResearch(
                    AudioDelivery.notebookLinkPatch(
                        url: products.notebookURL, publicVerified: products.publicVerified
                    )
                )
                steps.append(
                    "notebook:\(products.publicVerified ? "public" : "unverified")"
                )
            }
            if let audio = products.audio, let audioSink {
                do {
                    let delivered = try await audioSink.deliver(audio: audio, entry: entry)
                    try? await emitter.patchResearch(AudioDelivery.linkPatch(url: delivered.url))
                    steps.append(
                        "audio:\(delivered.format):\(delivered.degraded ? "degraded" : "ok")"
                    )
                } catch {
                    steps.append("audio-upload-failed:\(error)")
                }
            } else {
                steps.append("no-audio:\(products.note)")
            }
        }

        // ⛔ Emitted whether or not P3 produced anything. The frontend's catch-up waits for this
        // event to drive P4; withholding it on a degraded P3 strands the run at NotebookLM for ever
        // with no error anywhere.
        await announce(phase: 3, starting: false)
    }

    /// The five-document set's fifth member, ordered by the contract rather than by arrival.
    static func consolidate(topic: String, reports: [String: String]) -> String {
        var parts = ["# Consolidated Research Report: \(topic)\n"]
        for platform in Prompts.p2Platforms {
            let text = (reports[platform] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            parts.append("\n## \(platform.capitalized) Research\n\n\(text)")
        }
        return parts.count > 1 ? parts.joined(separator: "\n") : ""
    }
}


public extension RunExecutor.Pipeline {
    /// Most pipelines hold nothing that needs releasing.
    func release() {}
}
