import Foundation

/// Turns a claimed queue entry into a running `RunExecutor` — the join that did not exist.
///
/// ⛔ **`DeviceBackend.launcher` was never set by anything.** The intake, the claim, the pipeline,
/// the emitter, the handoff and P3 were all built and tested, and the one line that hands a claimed
/// run to them was missing — so the device claimed a run, stamped the queue document so no sibling
/// would take it, and then did nothing at all. The run sat "ongoing" for ever and the owner's next
/// run queued behind it.
///
/// ⚠ **A factory, not a single executor.** `ContractEmitter` is bound to ONE research — its paths,
/// its `seq` guard and its write log all are — so a long-lived executor would write every run's
/// events into the first run's document. One executor per entry is the only shape that is correct.
public final class InAppRunLauncher: RunLauncher, @unchecked Sendable {

    /// Hands back the web view for a platform on a given worker.
    ///
    /// ⚠ A closure rather than a stored table: the app keeps one long-lived view per (worker,
    /// platform) and recreating one mid-run would destroy the session the run is driving.
    public typealias PageProvider = @Sendable (_ platform: String, _ worker: Int) -> any WebPage

    private let client: FirestoreREST
    private let deviceID: String
    private let apiBaseURL: URL
    private let storageBucket: String
    private let pages: PageProvider
    /// Hand the host back its web views when a run ends.
    private let releasePages: @Sendable () -> Void
    private let manifest: [String: [String: [String]]]
    private let texts: [String: [String: String]]
    private let openers: [String: [String: String]]
    private let responseTimeout: TimeInterval
    private let extractionTimeout: Duration
    private let audioTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    /// Where run traces are kept.
    ///
    /// ⚠ Application Support rather than Caches: the system may evict a Caches directory whenever
    /// it likes, and the one thing a post-mortem trace must do is still be there afterwards.
    public static var logDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SuperResearch/runs", isDirectory: true)
    }()

    public init(
        client: FirestoreREST,
        deviceID: String,
        apiBaseURL: URL,
        storageBucket: String,
        pages: @escaping PageProvider,
        releasePages: @escaping @Sendable () -> Void = {},
        manifest: [String: [String: [String]]],
        texts: [String: [String: String]] = [:],
        openers: [String: [String: String]] = [:],
        responseTimeout: TimeInterval = 2_400,
        extractionTimeout: Duration = .seconds(120),
        audioTimeout: TimeInterval = 90 * 60,
        clock: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { NSLog("[SR] %@", $0) }
    ) {
        self.client = client
        self.deviceID = deviceID
        self.apiBaseURL = apiBaseURL
        self.storageBucket = storageBucket
        self.pages = pages
        self.releasePages = releasePages
        self.manifest = manifest
        self.texts = texts
        self.openers = openers
        self.responseTimeout = responseTimeout
        self.extractionTimeout = extractionTimeout
        self.audioTimeout = audioTimeout
        self.clock = clock
        self.log = log
    }

    /// The run id this device reports as `backendRunId`.
    ///
    /// ⚠ The entry's own id is REUSED when it has one, so a resumed run keeps the id the frontend
    /// has already displayed and correlated its events against. A fresh id on resume looks like a
    /// second run of the same research.
    static func runID(for entry: QueueEntry, deviceID: String, now: Date) -> String {
        if let existing = entry.backendRunId, !existing.isEmpty { return existing }
        return "ios-\(deviceID.prefix(8))-\(Int64(now.timeIntervalSince1970 * 1000))"
    }

    public func launch(_ entry: QueueEntry, worker: Int) async {
        // ⭐ One file per RUN, named after the research, so a trace can be read long after the
        // process that wrote it is gone — and so two runs cannot interleave into one unreadable
        // file. The console echo stays for anyone watching live.
        let trace = RunLog(
            directory: Self.logDirectory,
            name: "run-\(entry.researchId).log",
            clock: clock
        )
        trace.write("run.start", "research=\(entry.researchId) worker=\(worker) topic=\(entry.topic)")
        trace.write("run.input", "briefSupplied=\(!entry.briefText.isEmpty) "
            + "podcastLength=\(entry.podcastLength ?? "unset")")
        // ⭐ The RESOLVED settings, written before anything acts on them. The run that died on
        // 2026-08-14 was verifying logins because the device ignored a setting that was switched
        // off, and the trace could not say so — it recorded what the run DID and never what it had
        // been told. One line here turns "why did it do that" into a fact rather than a bisect.
        let config = entry.config
        trace.write("run.config", "skipInitVerify=\(config.skipInitVerify) "
            + "agents=\(config.enabledPlatforms.joined(separator: "+")) "
            + "skipPhases=\(config.skipPhases.sorted()) "
            + "video=\(config.videoEnabled) email=\(config.emailEnabled)")
        let emitter = ContractEmitter(
            client: client,
            uid: entry.uid,
            researchId: entry.researchId,
            deviceId: deviceID,
            runId: Self.runID(for: entry, deviceID: deviceID, now: clock()),
            clock: clock
        )
        let configReader = FirestoreConfigReader(client: client)
        let executor = RunExecutor(
            pipeline: InAppRunPipeline(
                pages: pages, worker: worker, manifest: manifest, texts: texts, openers: openers,
                responseTimeout: responseTimeout, extractionTimeout: extractionTimeout,
                trace: trace,
                // ⭐ The owner's Stop, finally connected to the thing it is meant to stop. Read by
                // the phase loop AND inside `awaitResponse`, which is the wait long enough — up to
                // 40 minutes — for a stop to be pressed during it.
                shouldStop: { [researchId = entry.researchId] in
                    RunStopSignal.shared.isStopped(researchId)
                },
                releasePages: releasePages,
                // ⭐ **The narration channel, connected.** `agent_progress` fills the raw-activity
                // panel's source list and step rows; `agent_narration` appends one line to the
                // strikethrough strip. The frontend has rendered both since long before this device
                // existed and this device emitted neither, so every run it served looked silent
                // beside the same run on the desktop — most visibly with Pro, where the answer
                // itself is a placeholder for minutes and the panel is the only thing moving.
                publishActivity: { [emitter] platform, phase, delta, totalSources in
                    Task {
                        var data: [String: FirestoreValue] = [
                            "status": .string("researching"),
                            "sources": .integer(Int64(totalSources)),
                        ]
                        if !delta.sources.isEmpty {
                            data["sourceUrls"] = .array(delta.sources.map { .string($0.url) })
                            data["sourceItems"] = .array(delta.sources.map {
                                .map(["url": .string($0.url), "title": .string($0.title)])
                            })
                        }
                        if !delta.steps.isEmpty {
                            data["steps"] = .array(delta.steps.map { .string($0) })
                        }
                        try? await emitter.emit(
                            type: "agent_progress", phase: phase, agent: platform, data: data
                        )
                        // ⚠ ONE narration line per tick, the newest. The frontend APPENDS these and
                        // caps the visible history at six, so emitting the whole delta would push
                        // the four lines before it off the strip in the same instant they arrived.
                        if let newest = delta.steps.last {
                            try? await emitter.emit(
                                type: "agent_narration", phase: phase, agent: platform,
                                data: ["text": .string(newest)]
                            )
                        }
                    }
                }
            ),
            emitter: emitter,
            handoff: RESTHandoffTransport(
                client: client, deviceID: deviceID, apiBaseURL: apiBaseURL, log: log
            ),
            notebook: InAppNotebookStage(
                // ⚠ Bound to notebooklm HERE rather than inside the stage: the stage owns the ORDER
                // of P3 and has no business knowing which platform key its pages come from.
                pages: { [pages] worker in pages("notebooklm", worker) },
                worker: worker,
                manifest: manifest["notebooklm"] ?? [:],
                texts: texts["notebooklm"] ?? [:],
                openers: openers["notebooklm"] ?? [:],
                configReader: configReader,
                audioTimeout: audioTimeout,
                log: { message in trace.write("p3", message) }
            ),
            audioSink: StorageAudioSink(
                storage: FirebaseStorage(bucket: storageBucket) { [client] in
                    try await client.freshIDToken()
                },
                log: { message in trace.write("audio", message) }
            ),
            configReader: configReader,
            now: { [clock] in Int64(clock().timeIntervalSince1970 * 1000) }
        )
        log("run \(entry.researchId) claimed on worker \(worker) — starting")
        // ⛔ Cleared on EVERY exit, including a throw. A research that was stopped once and is then
        // retried would otherwise be born stopped and end instantly — with no explanation, looking
        // exactly like intake never claiming it.
        defer { RunStopSignal.shared.clear(researchID: entry.researchId) }
        await executor.launch(entry, worker: worker)
        let steps = await executor.steps
        for step in steps { trace.write("run.step", step) }
        trace.write("run.end", "steps=\(steps.count)")
        // ⚠ Logged as ONE line at the end rather than streamed: this is the only place the whole
        // shape of a run is visible, and a run that produced no reports is only recognisable from
        // the sequence.
        log("run \(entry.researchId) finished: \(steps.joined(separator: " -> "))")
    }
}

/// The handoff, over REST.
public struct RESTHandoffTransport: HandoffTransport {
    private let client: FirestoreREST
    private let deviceID: String
    private let apiBaseURL: URL
    private let log: @Sendable (String) -> Void

    public init(
        client: FirestoreREST, deviceID: String, apiBaseURL: URL,
        log: @escaping @Sendable (String) -> Void = { NSLog("[SR] %@", $0) }
    ) {
        self.client = client
        self.deviceID = deviceID
        self.apiBaseURL = apiBaseURL
        self.log = log
    }

    public func patchResearch(
        uid: String, researchId: String, set: [String: FirestoreValue]
    ) async throws {
        var fields = set
        // ⛔ Same rule as every other research write, and the same 403 if it is missing:
        // `request.resource.data.deviceId == request.auth.token.deviceId`, judged on the resource
        // being WRITTEN rather than on the document that already exists.
        fields["deviceId"] = .string(deviceID)
        try await client.patchDocument(path: "users/\(uid)/researches/\(researchId)", set: fields)
    }

    /// ⚠ **Field names verified against the backend's own caller** (`_post_fe_p4p5_trigger`):
    /// `{"research_id": …, "ownerUid": …}` — snake in one and camel in the other, which is exactly
    /// the kind of thing a plausible guess gets wrong in a way that returns 400 and names nothing.
    ///
    /// ⚠ **Detached and long-lived.** The route encodes and uploads INLINE, for up to an hour, and a
    /// client disconnect can abort it mid-encode. So this must neither block the run loop nor be
    /// cancelled by it — and it must never throw, because the `needsFeTrigger` marker written just
    /// before it is the backstop that makes a failed POST survivable.
    public func postUploadYouTube(researchId: String, ownerUid: String) async {
        let url = apiBaseURL.appendingPathComponent("api/uploadYouTube")
        Task.detached { [client, log] in
            do {
                let (status, _) = try await client.authorizedPOST(
                    url: url, body: ["research_id": researchId, "ownerUid": ownerUid]
                )
                if status == 200 || status == 202 {
                    log("handoff: P4/P5 dispatched (HTTP \(status))")
                } else {
                    log("handoff: uploadYouTube returned \(status) — the needsFeTrigger marker is "
                        + "now the only route, and the web app will pick it up on next open")
                }
            } catch {
                log("handoff: uploadYouTube POST failed (\(error)) — falling back to the "
                    + "needsFeTrigger marker")
            }
        }
    }
}
