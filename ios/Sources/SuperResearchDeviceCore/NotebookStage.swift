import Foundation

/// Joins the NotebookLM driver to the run executor: the ORDER of P3, in one place.
///
/// ⚠ Thin on purpose, like the executor it plugs into. Every decision it makes is already tested
/// somewhere else — the length resolution, the share degrade, the readiness predicate — and what
/// lives here is only the sequence, which is the thing none of those can test from the inside.
public struct InAppNotebookStage: RunExecutor.NotebookStage {

    /// Reads a run's configured podcast length back off the research document.
    ///
    /// ⚠ **Returning nil is the EXPECTED case on this device**, not an error path. The re-read is
    /// against the owner's user-tree research document and the synthetic device identity is denied
    /// there — the desktop backend tolerates exactly that. A reader that threw, or that reported the
    /// denial as a failure, would make the normal path look broken.
    public protocol ConfigReader: Sendable {
        func podcastLength(uid: String, researchId: String) async -> String?
    }

    public typealias PageProvider = @Sendable (_ worker: Int) -> any WebPage

    private let pages: PageProvider
    private let worker: Int
    private let manifest: [String: [String]]
    private let texts: [String: String]
    private let openers: [String: String]
    private let configReader: (any ConfigReader)?
    /// Which platform this worker is driving, so Browser watch can glow NotebookLM during P3.
    private let activity: LiveRunActivity
    private let audioTimeout: TimeInterval
    private let log: @Sendable (String) -> Void

    /// ⚠ Ninety minutes, and it is the backend's own number (`PHASE_3_AUDIO_MAX_MIN=90`) rather than
    /// a guess. Audio generation genuinely takes that long on a large notebook, and a shorter
    /// deadline abandons a podcast that was about to arrive — after the expensive part is paid for.
    public init(
        pages: @escaping PageProvider,
        worker: Int,
        manifest: [String: [String]],
        texts: [String: String] = [:],
        openers: [String: String] = [:],
        configReader: (any ConfigReader)? = nil,
        audioTimeout: TimeInterval = 90 * 60,
        activity: LiveRunActivity = .shared,
        log: @escaping @Sendable (String) -> Void = { NSLog("[SR] %@", $0) }
    ) {
        self.activity = activity
        self.pages = pages
        self.worker = worker
        self.manifest = manifest
        self.texts = texts
        self.openers = openers
        self.configReader = configReader
        self.audioTimeout = audioTimeout
        self.log = log
    }

    public func run(
        entry: QueueEntry, consolidated: String, lengthAtClaim: String?
    ) async throws -> RunExecutor.Products {
        let driver = NotebookPhaseDriver(
            manifest: manifest, texts: texts, openers: openers, page: pages(worker)
        )

        // ⭐ **NotebookLM glows for P3**, the same way each platform glows for its own phase.
        // This stage never touched `LiveRunActivity`, so Browser watch went dark for the whole of
        // phase 3 — the longest single stretch of a run, and the one the owner most wants to watch
        // (the notebook being built, the audio being generated).
        //
        // ⛔ Cleared on EVERY exit, including a throw, for the same reason the platform phases are:
        // a glow left on points the owner at a tab where nothing is happening.
        activity.set(worker: worker, platform: "notebooklm")
        defer { activity.clear(worker: worker) }

        // 1. The notebook. This one IS allowed to end P3 — with no notebook there is nothing to
        // share, generate from, or download, and every later step would fail for a reason pointing
        // somewhere else.
        let notebookURL = try await driver.createNotebook()
        log("p3: notebook \(NotebookPhaseDriver.notebookID(notebookURL))")

        // 2. The source. Also fatal to P3: an empty notebook generates a podcast about nothing.
        try await driver.addSource(consolidated, notebookURL: notebookURL)
        log("p3: source added (\(consolidated.count) chars)")

        // 3. The public link — degrades, never throws.
        let share = try await driver.share(notebookURL: notebookURL)
        log("p3: share — \(share.reason)")

        // 4. The audio, at the owner's length.
        //
        // ⭐ The phase-time re-read is the OVERLAY and it wins when it carries a valid value, so a
        // setting changed after the run was queued is honoured. Its denial is normal; the claim-time
        // value then stands.
        let overlay = await configReader?.podcastLength(uid: entry.uid, researchId: entry.researchId)
        let length = AudioLengthResolver.resolve(disk: lengthAtClaim, overlay: overlay)
        log("p3: audio length \(length.rawValue) (claim=\(lengthAtClaim ?? "-"), overlay=\(overlay ?? "denied"))")

        do {
            _ = try await driver.generateAudio(length: length)
            guard try await driver.awaitAudio(timeout: audioTimeout) else {
                return RunExecutor.Products(
                    notebookURL: share.url, publicVerified: share.publicVerified, audio: nil,
                    note: "the Audio Overview was still generating after "
                        + "\(Int(audioTimeout / 60)) minutes"
                )
            }
            let audio = try await driver.downloadAudio(notebookURL: notebookURL)
            log("p3: audio downloaded (\(audio.count) bytes)")
            return RunExecutor.Products(
                notebookURL: share.url, publicVerified: share.publicVerified, audio: audio
            )
        } catch {
            // ⛔ Swallowed HERE rather than by the executor, so the reason survives. The executor
            // knows only "no audio"; this knows whether the panel moved, the wait ran out, or the
            // download produced nothing — and those need three different responses.
            return RunExecutor.Products(
                notebookURL: share.url, publicVerified: share.publicVerified, audio: nil,
                note: "\(error)"
            )
        }
    }
}

/// The podcast's route to Storage, with the MP3 preference and its degrade.
public struct StorageAudioSink: RunExecutor.AudioSink {
    private let storage: FirebaseStorage
    private let transcoder: any AudioTranscoder
    private let log: @Sendable (String) -> Void

    public init(
        storage: FirebaseStorage, transcoder: any AudioTranscoder = UnavailableTranscoder(),
        log: @escaping @Sendable (String) -> Void = { NSLog("[SR] %@", $0) }
    ) {
        self.storage = storage
        self.transcoder = transcoder
        self.log = log
    }

    public func deliver(audio: Data, entry: QueueEntry) async throws -> AudioDelivery.Delivered {
        let delivered = try await AudioDelivery.deliver(
            audio: audio, ownerUID: entry.uid, researchID: entry.researchId,
            storage: storage, transcoder: transcoder
        )
        // ⚠ Logged on BOTH paths. A degrade that is only logged when it happens to be noticed is a
        // degrade that gets rediscovered from first principles every few months.
        log("p3: audio delivered as \(delivered.format) — \(delivered.reason)")
        return delivered
    }
}

/// `ConfigReader` over the REST client.
public struct FirestoreConfigReader: InAppNotebookStage.ConfigReader {
    private let client: FirestoreREST

    public init(client: FirestoreREST) { self.client = client }

    public func podcastLength(uid: String, researchId: String) async -> String? {
        // ⚠ Every failure collapses to nil, deliberately. A permission denial here is the NORMAL
        // outcome for this device's identity, and distinguishing it from a network blip would only
        // let a caller act on the difference — and there is no different action to take.
        guard let fields = try? await client.getDocument(
            path: "users/\(uid)/researches/\(researchId)"
        ) else { return nil }
        guard case .map(let config)? = fields["pipelineConfig"],
              case .string(let value)? = config["podcastLength"], !value.isEmpty
        else { return nil }
        return value
    }
}
