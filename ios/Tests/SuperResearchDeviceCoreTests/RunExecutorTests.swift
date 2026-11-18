import XCTest

@testable import SuperResearchDeviceCore

private struct StubPipeline: RunExecutor.Pipeline {
    var briefText = String(repeating: "A research brief. ", count: 30)
    var reports: [String: String]
    var failing: Set<String> = []

    func runPhases(
        entry: QueueEntry, platform: String, brief: String,
        onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> (brief: String, report: String?) {
        if failing.contains(platform) {
            throw InAppPhaseError.notLoggedIn(platform: platform, reason: "test double")
        }
        return (brief: brief.isEmpty ? briefText : brief, report: reports[platform])
    }
}

private final class SpyHandoffTransport: HandoffTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var patches: [[String: FirestoreValue]] = []
    private(set) var posts = 0
    func patchResearch(uid: String, researchId: String, set: [String: FirestoreValue]) async throws {
        lock.lock(); patches.append(set); lock.unlock()
    }
    func postUploadYouTube(researchId: String, ownerUid: String) async {
        lock.lock(); posts += 1; lock.unlock()
    }
}

/// The piece that joins intake, the pipeline, the documents and the handoff.
final class RunExecutorTests: XCTestCase {

    private let config = FirebaseProjectConfig(
        projectID: "p", apiKey: "k", apiBaseURL: URL(string: "https://x.test")!, emulatorHost: nil
    )

    private func emitter(_ transport: StubTransport) async throws -> ContractEmitter {
        transport.prepend(.ok("{\"idToken\":\"i\",\"refreshToken\":\"r\",\"expiresIn\":\"3600\"}"))
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        return ContractEmitter(client: client, uid: "owner-1", researchId: "res-1",
                               deviceId: "dev-9", runId: "run-1")
    }

    private func entry(agents: [String: Bool]? = nil) -> QueueEntry {
        QueueEntry(id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
                   submittedBy: "owner-1", topic: "solid-state batteries",
                   config: agents.map { RunConfig(agents: $0) } ?? .default)
    }

    private let body = String(repeating: "Report prose. ", count: 200)

    func testAClaimedRunProducesDocumentsAndTHENHandsOff() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 12))
        let spy = SpyHandoffTransport()
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: try await emitter(transport), handoff: spy, now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let steps = await executor.steps
        // The ORDER is what this owns: documents, then handoff. Reversed, the cloud would fetch
        // documents that do not exist yet.
        let docsAt = try XCTUnwrap(steps.firstIndex { $0.hasPrefix("documents:") })
        let handoffAt = try XCTUnwrap(steps.firstIndex(of: "handoff"))
        XCTAssertLessThan(docsAt, handoffAt)
        XCTAssertEqual(spy.posts, 1)
    }

    func testALLFIVEDocumentTypesAreWritten() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 12))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let written = await contract.written.map(\.path)
        for docType in ["brief", "chatgpt", "gemini", "claude", "consolidated"] {
            XCTAssertTrue(written.contains { $0.hasSuffix("/documents/\(docType)") }, docType)
        }
    }

    func testONEPlatformFailingStillFinishesTheRun() async throws {
        // Their research units are already spent — two reports plus a stated gap is a degraded run
        // worth finishing, not one to throw away.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 12))
        let spy = SpyHandoffTransport()
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "claude": body],
                                   failing: ["gemini"]),
            emitter: try await emitter(transport), handoff: spy, now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let steps = await executor.steps
        XCTAssertTrue(steps.contains("failed:gemini"))
        XCTAssertTrue(steps.contains("handoff"))
        XCTAssertEqual(spy.posts, 1)
    }

    func testNOReportsAtAllABANDONSTheRunWithoutHandingOff() async throws {
        // ⛔ Handing off with nothing sets beDone, unstalls the queue, fires the cloud trigger, and
        // produces a video of an empty document — a run that reports success and delivers nothing.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 6))
        let spy = SpyHandoffTransport()
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: [:]), emitter: try await emitter(transport),
            handoff: spy, now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let steps = await executor.steps
        XCTAssertTrue(steps.contains("abandoned:no-reports"))
        XCTAssertFalse(steps.contains("handoff"))
        XCTAssertEqual(spy.posts, 0, "the cloud was triggered for a run with no documents")
        XCTAssertTrue(spy.patches.isEmpty, "beDone was written for a run that produced nothing")
    }

    func testTheBRIEFIsProducedONCEAndReusedByEveryPlatform() async throws {
        // P1 runs once; P2 feeds the same brief to all three. Re-deriving it per platform would
        // spend three P1s and could give three different briefs.
        final class Counting: RunExecutor.Pipeline, @unchecked Sendable {
            private(set) var briefsIssued = 0
            let body: String
            init(body: String) { self.body = body }
            func runPhases(
                entry: QueueEntry, platform: String, brief: String,
                onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
            ) async throws -> (brief: String, report: String?) {
                // ⚠ Returns a DIFFERENT brief every call. Echoing the one it was given makes a
                // reassignment invisible — a mutation proved it: dropping the "only if empty"
                // guard changed nothing, because the value it reassigned was identical.
                briefsIssued += 1
                if brief.isEmpty { return (brief: "BRIEF-1", report: body) }
                XCTAssertEqual(brief, "BRIEF-1", "every platform must get P1's ONE brief")
                return (brief: "BRIEF-\(briefsIssued)", report: body)
            }
        }
        let counting = Counting(body: body)
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 12))
        let executor = RunExecutor(
            pipeline: counting, emitter: try await emitter(transport),
            handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        // Called once per platform, but P1's brief is derived ONCE and reused: re-deriving would
        // spend three P1s and could feed three agents three different briefs.
        XCTAssertEqual(counting.briefsIssued, 3)
    }

    func testTheConsolidatedDocumentKeepsTheContractsOrder() {
        let out = RunExecutor.consolidate(
            topic: "t", reports: ["claude": "C", "chatgpt": "A", "gemini": "B"]
        )
        XCTAssertLessThan(try! XCTUnwrap(out.range(of: "Chatgpt")).lowerBound,
                          try! XCTUnwrap(out.range(of: "Gemini")).lowerBound)
        XCTAssertLessThan(try! XCTUnwrap(out.range(of: "Gemini")).lowerBound,
                          try! XCTUnwrap(out.range(of: "Claude")).lowerBound)
    }

    func testNoReportsMeansNoConsolidatedDocumentRatherThanABareTitle() {
        XCTAssertEqual(RunExecutor.consolidate(topic: "t", reports: [:]), "")
        XCTAssertEqual(RunExecutor.consolidate(topic: "t", reports: ["chatgpt": "  "]), "")
    }
}


// MARK: - P3, and the fact that it must never take the run with it

/// Records what it was asked and answers with whatever the test wants.
private actor SpyNotebookStage: RunExecutor.NotebookStage {
    private let products: RunExecutor.Products?
    private let error: Error?
    private(set) var calls: [(consolidated: String, lengthAtClaim: String?)] = []

    init(products: RunExecutor.Products? = nil, error: Error? = nil) {
        self.products = products
        self.error = error
    }

    func run(
        entry: QueueEntry, consolidated: String, lengthAtClaim: String?
    ) async throws -> RunExecutor.Products {
        calls.append((consolidated, lengthAtClaim))
        if let error { throw error }
        return products!
    }
}

private actor SpyAudioSink: RunExecutor.AudioSink {
    private(set) var uploads = 0
    func deliver(audio: Data, entry: QueueEntry) async throws -> AudioDelivery.Delivered {
        uploads += 1
        return AudioDelivery.Delivered(
            url: "https://storage.test/podcast.mp3", format: "mp3", degraded: false, reason: ""
        )
    }
}

/// Counts its reads so "when was the length read" is checkable, which is the whole point of there
/// being two reads.
private actor SpyConfigReader: InAppNotebookStage.ConfigReader {
    private let value: String?
    private(set) var reads = 0
    init(_ value: String?) { self.value = value }
    func podcastLength(uid: String, researchId: String) async -> String? {
        reads += 1
        return value
    }
}

private enum StageFailure: Error { case theShareDialogMoved }

final class RunExecutorNotebookPhaseTests: XCTestCase {

    private let config = FirebaseProjectConfig(
        projectID: "p", apiKey: "k", apiBaseURL: URL(string: "https://x.test")!, emulatorHost: nil
    )
    private let body = String(repeating: "Report prose. ", count: 200)

    private func emitter(_ transport: StubTransport) async throws -> ContractEmitter {
        transport.prepend(.ok("{\"idToken\":\"i\",\"refreshToken\":\"r\",\"expiresIn\":\"3600\"}"))
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        return ContractEmitter(client: client, uid: "owner-1", researchId: "res-1",
                               deviceId: "dev-9", runId: "run-1")
    }

    private func entry(agents: [String: Bool]? = nil) -> QueueEntry {
        QueueEntry(id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
                   submittedBy: "owner-1", topic: "solid-state batteries",
                   config: agents.map { RunConfig(agents: $0) } ?? .default)
    }

    private func executor(
        notebook: (any RunExecutor.NotebookStage)?, sink: (any RunExecutor.AudioSink)? = nil,
        reader: (any InAppNotebookStage.ConfigReader)? = nil, handoff: SpyHandoffTransport,
        transport: StubTransport
    ) async throws -> RunExecutor {
        RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: try await emitter(transport), handoff: handoff,
            notebook: notebook, audioSink: sink, configReader: reader, now: { 1_000 }
        )
    }

    func testP3RunsAFTERTheDocumentsAndBEFORETheHandoff() async throws {
        // The cloud fetches the documents; the notebook is built FROM them. Either boundary crossed
        // gives a run that reports success with a podcast about nothing.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let spy = SpyHandoffTransport()
        let stage = SpyNotebookStage(
            products: .init(notebookURL: "https://notebook.google.com/notebook/n1",
                            publicVerified: true, audio: Data([0x49, 0x44, 0x33]))
        )
        let executor = try await executor(
            notebook: stage, sink: SpyAudioSink(), handoff: spy, transport: transport
        )

        await executor.launch(entry(), worker: 1)

        let steps = await executor.steps
        let docs = try XCTUnwrap(steps.firstIndex { $0.hasPrefix("documents:") })
        let notebook = try XCTUnwrap(steps.firstIndex { $0.hasPrefix("notebook:") })
        let handoff = try XCTUnwrap(steps.firstIndex(of: "handoff"))
        XCTAssertLessThan(docs, notebook)
        XCTAssertLessThan(notebook, handoff)
    }

    func testTheCONSOLIDATEDReportIsWhatP3IsGiven() async throws {
        // ⛔ Not the topic, and not one platform's report: the podcast is made from the merged
        // document, and handing P3 anything else produces a plausible podcast about a fraction of
        // the research.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let stage = SpyNotebookStage(
            products: .init(notebookURL: "u", publicVerified: false, audio: nil)
        )
        let executor = try await executor(
            notebook: stage, handoff: SpyHandoffTransport(), transport: transport
        )

        await executor.launch(entry(), worker: 1)

        let calls = await stage.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].consolidated.contains("Chatgpt Research"))
        XCTAssertTrue(calls[0].consolidated.contains("Claude Research"))
    }

    func testAP3ThatTHROWSStillHandsTheRunOff() async throws {
        // ⛔ Three deep-research units and five documents are already paid for. The desktop backend
        // runs its handoff tail for the audio-skipped branch too, and the frontend's own P3 gate
        // accepts `beDone` alone precisely so an audio-less run advances to P5.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let spy = SpyHandoffTransport()
        let executor = try await executor(
            notebook: SpyNotebookStage(error: StageFailure.theShareDialogMoved),
            handoff: spy, transport: transport
        )

        await executor.launch(entry(), worker: 1)

        XCTAssertEqual(spy.posts, 1, "a failed P3 stranded the run at NotebookLM")
        let steps = await executor.steps
        XCTAssertTrue(steps.contains { $0.hasPrefix("p3-failed:") })
        XCTAssertTrue(steps.contains("handoff"))
    }

    func testPHASECOMPLETE3IsEmittedEvenWhenThereIsNoPodcast() async throws {
        // The frontend's catch-up drives P4 off this event. Withholding it on a degraded P3 strands
        // the run at NotebookLM for ever, with no error anywhere.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(),
            notebook: SpyNotebookStage(error: StageFailure.theShareDialogMoved), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        // ⚠ Matched on the TYPE **and the phase**. Asserting the bare type was satisfied by phase
        // 1's and phase 2's own completions the moment those started being emitted — the guard kept
        // passing while the thing it names stopped happening. Caught by mutation.
        let completions = await events(contract)
        XCTAssertTrue(
            completions.contains { $0 == ("phase_complete", Int64(3)) },
            "P3 never announced its completion: \(completions)"
        )
    }

    func testNoNotebookStageMeansNoPHASEEVENTSAtAll() async throws {
        // ⛔ Advertising a phase that did not run is worse than silence: the tile lights up at
        // NotebookLM and stays there.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let steps = await executor.steps
        XCTAssertTrue(steps.contains("p3-skipped:no-notebook-stage"))
        let phase3 = await contract.written.contains { entry in
            entry.fields["phase"] == .integer(3)
        }
        XCTAssertFalse(phase3)
    }

    func testTheAudioSinkIsNOTCalledWhenP3ProducedNoAudio() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let sink = SpyAudioSink()
        let executor = try await executor(
            notebook: SpyNotebookStage(
                products: .init(notebookURL: "u", publicVerified: false, audio: nil,
                                note: "still generating")
            ),
            sink: sink, handoff: SpyHandoffTransport(), transport: transport
        )

        await executor.launch(entry(), worker: 1)

        let uploads = await sink.uploads
        XCTAssertEqual(uploads, 0)
        let steps = await executor.steps
        XCTAssertTrue(steps.contains { $0.hasPrefix("no-audio:") && $0.contains("generating") },
                      "the REASON was dropped: \(steps)")
    }

    func testTheNotebookLinkIsWrittenEvenWhenTheAudioNeverArrives() async throws {
        // A notebook that exists is worth linking: it is the only way the owner can open the thing
        // the run built, and its absence reads as "P3 never ran".
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(),
            notebook: SpyNotebookStage(
                products: .init(notebookURL: "https://notebook.google.com/notebook/n1",
                                publicVerified: false, audio: nil)
            ),
            now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let wroteLink = await contract.written.contains { $0.fields["links.notebooklm"] != nil }
        XCTAssertTrue(wroteLink)
    }

    func testEveryResearchPatchCarriesTheDEVICEID() async throws {
        // ⛔ The rule is `request.resource.data.deviceId == request.auth.token.deviceId` and it is
        // judged on the resource being WRITTEN — so a patch that omits the field 403s even though
        // the document already carries the right value from `startRun`. Both halves of this
        // codebase learned that the same way, from a denial that names neither.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 4))
        let contract = try await emitter(transport)

        try await contract.patchResearch(["links.audio_file": .map(["url": .string("u")])])

        let written = await contract.written
        let patch = try XCTUnwrap(written.last)
        XCTAssertEqual(patch.fields["deviceId"], .string("dev-9"))
    }

    func testAnEmptyPatchWritesNOTHINGRatherThanABareDeviceId() async throws {
        // Otherwise every no-op call bumps the document and the frontend re-renders a run that did
        // not change.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 4))
        let contract = try await emitter(transport)
        let before = await contract.written.count

        try await contract.patchResearch([:])

        let after = await contract.written.count
        XCTAssertEqual(before, after)
    }

    // MARK: - A run the owner can actually SEE

    private func events(_ contract: ContractEmitter) async -> [(String, Int64?)] {
        await contract.written
            .filter { $0.path.hasSuffix("pipeline_events") }
            .compactMap { entry in
                guard case .string(let type)? = entry.fields["type"] else { return nil }
                if case .integer(let phase)? = entry.fields["phase"] { return (type, phase) }
                return (type, nil)
            }
    }

    func testEVERYPhaseIsAnnouncedAndNotJustP3() async throws {
        // ⛔ The run was INVISIBLE. The executor emitted nothing for phases 1 and 2, so the web app
        // showed a research that sat still through three deep-research runs and then jumped
        // straight to NotebookLM — indistinguishable from a device that claimed the run and died.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(),
            notebook: SpyNotebookStage(
                products: .init(notebookURL: "u", publicVerified: false, audio: nil)
            ),
            now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let seen = await events(contract)
        for phase in Int64(1)...3 {
            XCTAssertTrue(seen.contains { $0 == ("phase_start", phase) }, "no phase_start:\(phase)")
            XCTAssertTrue(
                seen.contains { $0 == ("phase_complete", phase) }, "no phase_complete:\(phase)"
            )
        }
    }

    func testPHASE1EndsWhenTheBRIEFArrivesAndNotWhenTheLoopDoes() async throws {
        // ⭐ P1's product exists the moment the FIRST platform hands one back. Ending phase 1 at the
        // end of the loop leaves the tile on "brief" through three deep-research runs — 90 minutes
        // of a run reporting the wrong stage.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let seen = await events(contract)
        let p1Done = try XCTUnwrap(seen.firstIndex { $0 == ("phase_complete", Int64(1)) })
        let p2Start = try XCTUnwrap(seen.firstIndex { $0 == ("phase_start", Int64(2)) })
        XCTAssertLessThan(p1Done, p2Start)
        // ...and phase 2 opens BEFORE the loop has finished all three platforms.
        let writes = await contract.written.filter { $0.path.hasSuffix("documents/consolidated") }
        XCTAssertFalse(writes.isEmpty, "the run did not get as far as consolidating")
    }

    func testCURRENTPHASEIsWrittenAlongsidePHASE() async throws {
        // ⛔ The contract is explicit: omit `currentPhase` and the homepage tile glows the stale
        // node for ever. The events drive a tab that is already open; these fields are what a tab
        // opened later reads.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let written = await contract.written
        // ⚠ Scoped to patches of the RESEARCH DOCUMENT. Every `pipeline_event` also carries a
        // `phase` field, and an unscoped filter would demand `currentPhase` on documents that must
        // not have it — a test failing on the correct behaviour.
        let paired = written.filter {
            $0.op == "patch" && !$0.path.contains("/pipeline_events")
                && ($0.fields["currentPhase"] != nil || $0.fields["phase"] != nil)
        }
        XCTAssertFalse(paired.isEmpty, "no phase field was ever written to the research document")
        for patch in paired {
            XCTAssertEqual(
                patch.fields["currentPhase"], patch.fields["phase"],
                "phase was written without currentPhase — the tile will glow the stale node"
            )
        }
    }

    func testEachAGENTIsMarkedRunningAndThenSettled() async throws {
        // Without this the three agent rows sit at whatever they were before, so a run in flight
        // looks exactly like one that never started.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let written = await contract.written
        for platform in ["chatgpt", "gemini", "claude"] {
            let states: [String] = written.compactMap { patch in
                guard case .map(let record)? = patch.fields["agents.\(platform)"],
                      case .string(let status)? = record["status"] else { return nil }
                return status
            }
            // ⛔ **The desktop's vocabulary, measured from its own writer:** `running` /
            // `complete` / `errored` / `skipped`. This wrote `completed` and `failed` — plausible
            // English, and words the frontend's tile logic does not recognise, so a finished agent
            // rendered as neither done nor failed.
            XCTAssertEqual(states.first, "running", platform)
            XCTAssertEqual(states.last, "complete", platform)
            XCTAssertFalse(states.contains("completed"), "`completed` is not a status the FE reads")
        }
    }

    func testAFAILEDPlatformIsMarkedFAILEDRatherThanLeftRunning() async throws {
        // An agent stuck on "running" for ever is how a degraded run reads as a hung one.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "claude": body], failing: ["gemini"]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let written = await contract.written
        let gemini: [String] = written.compactMap { patch in
            guard case .map(let record)? = patch.fields["agents.gemini"],
                  case .string(let status)? = record["status"] else { return nil }
            return status
        }
        XCTAssertEqual(gemini.last, "errored")
        XCTAssertFalse(gemini.contains("failed"), "`failed` is not a status the FE reads")
    }

    // MARK: - Two reads of the length, at two different times

    func testTheLengthIsReadAtCLAIMTimeAndCarriedIntoP3() async throws {
        // ⛔ The mechanism: the read must happen BEFORE the platforms run, not at P3. Two reads
        // taken at the same moment are one read, and the value the run STARTED with is lost — which
        // matters because the P3 re-read is denied for this device's identity, and the fallback
        // then has nothing to fall back to.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let reader = SpyConfigReader("short")
        let stage = SpyNotebookStage(
            products: .init(notebookURL: "u", publicVerified: false, audio: nil)
        )
        let executor = try await executor(
            notebook: stage, reader: reader, handoff: SpyHandoffTransport(), transport: transport
        )

        await executor.launch(entry(), worker: 1)

        let calls = await stage.calls
        XCTAssertEqual(calls.first?.lengthAtClaim, "short")
        let reads = await reader.reads
        XCTAssertEqual(reads, 1, "the executor's read is the CLAIM-time one, exactly once")
    }

    func testTheQUEUESOwnLengthIsPreferredToAReadThatMayBeRefused() async throws {
        // ⭐ The queue document is this device's OWN subcollection and is always readable, while the
        // research document's `pipelineConfig` sits behind a membership check. Preferring the read
        // that may be refused loses the owner's choice on every run where it is.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let reader = SpyConfigReader("long")
        let stage = SpyNotebookStage(
            products: .init(notebookURL: "u", publicVerified: false, audio: nil)
        )
        let queued = QueueEntry(
            id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
            submittedBy: "owner-1", topic: "t", podcastLength: "short"
        )
        let executor = try await executor(
            notebook: stage, reader: reader, handoff: SpyHandoffTransport(), transport: transport
        )

        await executor.launch(queued, worker: 1)

        let calls = await stage.calls
        XCTAssertEqual(calls.first?.lengthAtClaim, "short")
        let reads = await reader.reads
        XCTAssertEqual(reads, 0, "it read the research document when the queue already said")
    }

    func testADENIEDConfigReadIsNormalAndNotAFailure() async throws {
        // The synthetic device identity is denied on the owner's user-tree research document, and
        // the desktop backend tolerates exactly that. A run must not die over it.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 30))
        let spy = SpyHandoffTransport()
        let executor = try await executor(
            notebook: SpyNotebookStage(
                products: .init(notebookURL: "u", publicVerified: false, audio: nil)
            ),
            reader: SpyConfigReader(nil), handoff: spy, transport: transport
        )

        await executor.launch(entry(), worker: 1)

        XCTAssertEqual(spy.posts, 1)
    }

    // MARK: - The brief belongs to ChatGPT

    /// ⛔ Measured live 2026-08-14: ChatGPT was blocked by a modal, Gemini's send went unconfirmed,
    /// and CLAUDE became the brief writer — because the executor took the brief from whichever
    /// platform finished first. The desktop hardcodes P1 to chatgpt.com (`run_phase1`).
    func testTheBRIEFComesFromChatGPTAndNotWhoeverFinishesFirst() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        // ChatGPT is OFF; the other two succeed and would happily hand back a brief.
        //
        // ⚠ It used to FAIL ChatGPT instead, and that stopped reaching this rule the moment a
        // failed brief platform began ending the run — the assignment line was never evaluated, so
        // deleting `platform == briefPlatform` changed nothing and the mutation survived. Switched
        // OFF is the case where the loop genuinely continues without a brief writer.
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(agents: ["chatgpt": false]), worker: 1)

        let written = await contract.written
        let briefSaved = written.contains { $0.path.hasSuffix("/documents/brief") }
        XCTAssertFalse(
            briefSaved,
            "with ChatGPT down there is no brief — another platform's answer must not silently "
                + "become one"
        )
    }

    /// ⛔⛔ **Measured live 2026-08-17.** ChatGPT's composer took no caret, P1 produced nothing —
    /// and the loop carried straight on, so Gemini and Claude each ran their OWN phase 1 against the
    /// raw topic. The owner watched three platforms light up one after another in Browser watch,
    /// the frontend showed everything failing, and two deep-research units went on answering a
    /// question nobody asked. Phase 1 is ChatGPT's alone; without its brief there is nothing for the
    /// others to research, and the run must stop rather than improvise.
    func testWithNoBRIEFFromChatGPTTheOTHERAgentsAreNeverDriven() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        // Records WHICH platforms the executor actually drove — the thing the owner sees light up.
        final class Recording: RunExecutor.Pipeline, @unchecked Sendable {
            let lock = NSLock()
            var driven: [String] = []
            func runPhases(
                entry: QueueEntry, platform: String, brief: String,
                onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
            ) async throws -> (brief: String, report: String?) {
                lock.lock(); driven.append(platform); lock.unlock()
                if platform == "chatgpt" { throw InAppPhaseError.outcomeUnconfirmed(intent: "x") }
                return (brief: "a brief this platform invented", report: "a report")
            }
        }
        let pipeline = Recording()
        let executor = RunExecutor(
            pipeline: pipeline, emitter: contract,
            handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        XCTAssertEqual(
            pipeline.driven, ["chatgpt"],
            "the other agents were driven with no brief — each one re-asking the raw topic and "
                + "spending a deep-research unit on it"
        )
    }

    /// ...and the run SAYS why it stopped, rather than sitting `ongoing` for ever.
    func testARunWithNoBriefIsFAILEDWithTheReasonRatherThanLeftOngoing() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: [:], failing: ["chatgpt", "gemini", "claude"]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let written = await contract.written
        let statuses: [String] = written.compactMap {
            if case .string(let status)? = $0.fields["status"] { return status }
            return nil
        }
        XCTAssertEqual(statuses.last, "stopped",
                       "the run was left ongoing: \(written.map(\.path))")
        // ⚠ And the REASON names the brief, so the owner is not left guessing which of three
        // agents went wrong when the answer is that phase 1 never produced anything to research.
        let errors: [String] = written.compactMap {
            if case .string(let text)? = $0.fields["lastError"] { return text }
            return nil
        }
        XCTAssertTrue(errors.last?.contains("no brief") == true, "\(errors)")
    }

    /// ⛔ **The owner's own brief must survive P1.**
    ///
    /// A supported flow: the owner pastes a brief and P1 is skipped. ChatGPT still runs P2 and its
    /// pipeline echoes the brief it was given, so without the `brief.isEmpty` guard the echo
    /// overwrites the original — the run then answers a subtly different question from the one that
    /// was asked, and nothing reports a fault.
    ///
    /// ⚠ Asserted as a PRODUCT property, not as a guard's behaviour. Pinning P1 to ChatGPT retired
    /// what `brief.isEmpty` used to do (stop platforms two and three re-assigning), and because the
    /// pipeline echoes a supplied brief, removing that condition today changes nothing observable —
    /// mutation proved it. So the line is kept for a future un-pinning while this test pins the
    /// thing that actually matters: whatever the mechanism, the owner's words reach the document.
    func testAnOWNERSuppliedBriefIsNotOverwrittenByChatGPT() async throws {
        let ownerBrief = "OWNER BRIEF: compare the three model families on security posture."
        final class Echoing: RunExecutor.Pipeline, @unchecked Sendable {
            let body: String
            init(body: String) { self.body = body }
            func runPhases(
                entry: QueueEntry, platform: String, brief: String,
                onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
            ) async throws -> (brief: String, report: String?) {
                // What the real pipeline returns when P1 is skipped: the brief it was handed.
                (brief: brief, report: body)
            }
        }
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: Echoing(body: body), emitter: contract,
            handoff: SpyHandoffTransport(), now: { 1_000 }
        )
        let supplied = QueueEntry(
            id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
            submittedBy: "owner-1", topic: "t", briefText: ownerBrief
        )

        await executor.launch(supplied, worker: 1)

        let written = await contract.written
        let savedBrief = written.first { $0.path.hasSuffix("/documents/brief") }
        guard case .string(let content)? = savedBrief?.fields["content"] else {
            return XCTFail("the owner's brief was never saved")
        }
        XCTAssertEqual(content, ownerBrief, "ChatGPT's echo overwrote the brief the owner wrote")
    }

    /// ⛔ The run that shipped: brief 11,969 chars, "report" 11,970 — the same text.
    func testAReportThatIsJustTheBriefIsRefused() async throws {
        // Asserted on the comparison the pipeline uses, because the pipeline seam here is a stub
        // that cannot reproduce a live page's stale turn.
        let brief = String(repeating: "Deep Research Brief. ", count: 600)
        XCTAssertTrue(InAppPipeline.isSameText(brief + ".", as: brief))
    }

    // MARK: - The owner's Settings

    /// An entry carrying a pipeline config, as the queue document would.
    private func entry(_ config: RunConfig) -> QueueEntry {
        QueueEntry(id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
                   submittedBy: "owner-1", topic: "solid-state batteries", config: config)
    }

    /// Records which platforms were actually driven.
    private final class RecordingPipeline: RunExecutor.Pipeline, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var driven: [String] = []
        let report: String
        init(report: String) { self.report = report }

        func runPhases(
            entry: QueueEntry, platform: String, brief: String,
            onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
        ) async throws -> (brief: String, report: String?) {
            lock.lock(); driven.append(platform); lock.unlock()
            return (brief: String(repeating: "A research brief. ", count: 30), report: report)
        }
    }

    private func agentStatuses(
        _ written: [(op: String, path: String, fields: [String: FirestoreValue],
                     deletePaths: [String])],
        _ platform: String
    ) -> [String] {
        written.compactMap { patch in
            guard case .map(let record)? = patch.fields["agents.\(platform)"],
                  case .string(let status)? = record["status"] else { return nil }
            return status
        }
    }

    func testAnAgentSwitchedOffInSettingsIsNeverDriven() async throws {
        // It costs a deep-research unit out of a hard monthly cap and answers a question the owner
        // explicitly said they did not want answered.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let pipeline = RecordingPipeline(report: body)
        let executor = RunExecutor(
            pipeline: pipeline, emitter: try await emitter(transport),
            handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(
            entry(RunConfig(agents: ["chatgpt": true, "gemini": false, "claude": true])), worker: 1
        )

        XCTAssertEqual(pipeline.driven, ["chatgpt", "claude"])
    }

    func testASwitchedOffAgentIsReportedAsSkippedRatherThanLeftSilent() async throws {
        // ⚠ An untouched agent row is indistinguishable from one still thinking. `skipped` is a
        // word the frontend's tile logic knows; leaving the row alone is not a smaller statement,
        // it is no statement.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: RecordingPipeline(report: body), emitter: contract,
            handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(
            entry(RunConfig(agents: ["chatgpt": true, "gemini": false, "claude": true])), worker: 1
        )

        let written = await contract.written
        XCTAssertEqual(agentStatuses(written, "gemini"), ["skipped"])
        XCTAssertFalse(
            agentStatuses(written, "gemini").contains("running"),
            "an agent that never ran must not be announced as running"
        )
        XCTAssertEqual(agentStatuses(written, "chatgpt").first, "running")
    }

    func testThePodcastIsNotBuiltWhenTheOwnerTurnedItOff() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let stage = SpyNotebookStage(
            products: .init(notebookURL: "u", publicVerified: true, audio: nil)
        )
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: try await emitter(transport), handoff: SpyHandoffTransport(),
            notebook: stage, now: { 1_000 }
        )

        await executor.launch(entry(RunConfig(skipPhases: [3])), worker: 1)

        let calls = await stage.calls
        XCTAssertTrue(calls.isEmpty, "phase 3 was switched off in Settings")
        let steps = await executor.steps
        XCTAssertTrue(steps.contains("p3-skipped:disabled-in-settings"))
        // ⛔ And the run STILL hands off. A configured no-podcast run is a complete run.
        XCTAssertTrue(steps.contains("handoff"))
    }

    func testASwitchedOffPodcastEmitsNoPhaseThreeEvents() async throws {
        // ⚠ The frontend drives P4 off `phase_complete:3`. Bracketing a phase that was configured
        // never to run announces a podcast step that is not happening.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(),
            notebook: SpyNotebookStage(products: .init(notebookURL: "u", publicVerified: true, audio: nil)),
            now: { 1_000 }
        )

        await executor.launch(entry(RunConfig(skipPhases: [3])), worker: 1)

        let written = await contract.written
        let phaseThree = written.filter { patch in
            if case .integer(3)? = patch.fields["currentPhase"] { return true }
            return false
        }
        XCTAssertTrue(phaseThree.isEmpty, "no phase-3 announcement for a phase that never ran")
    }

    // MARK: - Phases are announced only if they happened

    /// ⛔ **Reported live 2026-08-14: "phase two is finished, which is weird because we didn't even
    /// start phase one".** Phase 2 begins only when a brief exists, but its COMPLETION was emitted
    /// unconditionally at the end of the platform loop — so a run where every platform failed sent
    /// `phase_start:1` and then `phase_complete:2`, and the web app reported phase two done on a
    /// run that never reached phase one.
    func testAFAILEDRunDoesNotAnnounceAPhaseItNeverSTARTED() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: [:], failing: ["chatgpt", "gemini", "claude"]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        // ⚠ ChatGPT OFF, so the loop runs to its end. With it enabled the run now stops at the
        // no-brief guard and never reaches the post-loop announce this test is about — the fixture
        // would still pass while covering nothing, which is what mutation caught.
        await executor.launch(entry(agents: ["chatgpt": false]), worker: 1)

        let events = await contract.written.compactMap { patch -> String? in
            guard case .string(let type)? = patch.fields["type"] else { return nil }
            guard case .integer(let phase)? = patch.fields["phase"] else { return type }
            return "\(type):\(phase)"
        }
        XCTAssertFalse(
            events.contains("phase_complete:2"),
            "phase 2 never started — announcing it complete tells the web app work happened that "
                + "did not. Events: \(events)"
        )
    }

    func testASUCCESSFULRunStillAnnouncesPhase2Complete() async throws {
        // The other half. A guard that suppressed the completion unconditionally would be just as
        // wrong, and the frontend drives its next step off this event.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: ["chatgpt": body, "gemini": body, "claude": body]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let events = await contract.written.compactMap { patch -> String? in
            guard case .string(let type)? = patch.fields["type"],
                  case .integer(let phase)? = patch.fields["phase"] else { return nil }
            return "\(type):\(phase)"
        }
        XCTAssertTrue(events.contains("phase_start:2"), "\(events)")
        XCTAssertTrue(events.contains("phase_complete:2"), "\(events)")
    }

    // MARK: - A run that produces nothing must SAY so

    func testARunWhereEveryAgentFailsIsMarkedStoppedRatherThanLeftOngoing() async throws {
        // ⛔ **The exact production symptom, 2026-08-14.** `startRun` wrote `ongoing`; every agent
        // then failed; the executor returned in silence. The research sat at phase 1 in the web app
        // for the rest of the day, looking live, having died in four seconds.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: [:], failing: ["chatgpt", "gemini", "claude"]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        // ⚠ ChatGPT switched OFF in Settings, and that is now load-bearing. With it enabled the run
        // stops one step earlier at a MORE specific cause — "ChatGPT produced no brief" — so this
        // fixture is what keeps the generic reason reachable at all. Leaving it as it was made this
        // test assert the other guard's message and stop covering its own.
        await executor.launch(entry(agents: ["chatgpt": false]), worker: 1)

        let written = await contract.written
        let statuses: [String] = written.compactMap { patch in
            guard case .string(let status)? = patch.fields["status"] else { return nil }
            return status
        }
        XCTAssertEqual(statuses.first, "ongoing", "the run still starts by claiming itself")
        XCTAssertEqual(
            statuses.last, "stopped",
            "a run that produced nothing must reach a TERMINAL status, or the web app shows it live for ever"
        )
        // The reason, in the field the contract reserves for it.
        let errors: [String] = written.compactMap { patch in
            guard case .string(let text)? = patch.fields["lastError"] else { return nil }
            return text
        }
        XCTAssertTrue(errors.last?.contains("every enabled agent failed") == true, "\(errors)")
    }

    func testTheTerminalWriteDoesNotClaimAHumanStoppedTheRun() async throws {
        // ⛔ `stoppedBy` has a CLOSED vocabulary and every value in it names a person —
        // `owner_stop`, `owner_cancel`, `hard_reset_*`. Writing a device failure there would tell
        // the owner they stopped a run they never touched.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: [:], failing: ["chatgpt", "gemini", "claude"]),
            emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        let written = await contract.written
        XCTAssertTrue(
            written.allSatisfy { $0.fields["stoppedBy"] == nil },
            "a device failure is not a human pressing Stop"
        )
    }

    func testARunWithNoAgentsEnabledSaysThatRatherThanBlamingTheAgents() async throws {
        // Configuration doing what it was told is not a fault, and reporting it as one sends the
        // owner looking for a failure that never happened.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        let executor = RunExecutor(
            pipeline: RecordingPipeline(report: body), emitter: contract,
            handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(
            entry(RunConfig(agents: ["chatgpt": false, "gemini": false, "claude": false])),
            worker: 1
        )

        let written = await contract.written
        let errors: [String] = written.compactMap { patch in
            guard case .string(let text)? = patch.fields["lastError"] else { return nil }
            return text
        }
        XCTAssertTrue(errors.last?.contains("no agents are enabled") == true, "\(errors)")
    }

    func testARunThatProducedNothingDoesNotHandOff() async throws {
        // Handing off would set beDone, unstall the queue, fire the cloud trigger and produce a
        // video of an empty document — a run that reports success and delivers nothing.
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let spy = SpyHandoffTransport()
        let executor = RunExecutor(
            pipeline: StubPipeline(reports: [:], failing: ["chatgpt", "gemini", "claude"]),
            emitter: try await emitter(transport), handoff: spy, now: { 1_000 }
        )

        await executor.launch(entry(), worker: 1)

        XCTAssertEqual(spy.posts, 0)
    }
}


/// Phase 1's product must survive phase 2's failure.
final class BriefSurvivalTests: XCTestCase {

    /// ⛔⛔ **Measured live 2026-08-17, and the fault was mine.** P1 spent FIFTEEN MINUTES producing
    /// a brief on Pro; ChatGPT's P2 then threw `noReport` — and the throw discarded the whole
    /// outcome tuple, brief included. The executor saw an empty brief, concluded phase 1 had
    /// produced nothing, and abandoned the run 1.5 seconds later. Gemini and Claude were never
    /// driven, which the owner reported as "stuck at phase two"; it was not stuck, it was over.
    ///
    /// ⚠ Asserts on the BOX, which is the mechanism: the brief has to be captured when it is
    /// produced, because by the time anything is returned it may not exist any more.
    func testABriefProducedInPhase1SurvivesAFailureInPhase2() {
        let box = BriefBox()
        box.set("a real brief, fifteen minutes in the making")

        // What the run pipeline does in its catch: a platform that failed AFTER producing the brief
        // is a degraded platform, not a dead run.
        XCTAssertEqual(box.value, "a real brief, fifteen minutes in the making")
    }

    /// ...and an empty report is never mistaken for a brief.
    func testAnEmptyBriefIsNeverStoredSoAFailedP1StillReadsAsFailed() {
        let box = BriefBox()
        box.set("")

        XCTAssertNil(box.value, "an empty string was kept, which would make a failed P1 look fine")
    }

    /// The last non-empty wins: a retry that produces a longer brief replaces the first.
    func testTheLatestNonEmptyBriefIsTheOneKept() {
        let box = BriefBox()
        box.set("first")
        box.set("second")
        box.set("")

        XCTAssertEqual(box.value, "second")
    }
}

/// Phase 1 ends when the brief exists — not when the platform does.
final class BriefStreamingTests: XCTestCase {

    private let config = FirebaseProjectConfig(
        projectID: "p", apiKey: "k", apiBaseURL: URL(string: "https://x.test")!, emulatorHost: nil
    )

    private func emitter(_ transport: StubTransport) async throws -> ContractEmitter {
        transport.prepend(.ok("{\"idToken\":\"i\",\"refreshToken\":\"r\",\"expiresIn\":\"3600\"}"))
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        return ContractEmitter(client: client, uid: "owner-1", researchId: "res-1",
                               deviceId: "dev-9", runId: "run-1")
    }

    /// ⛔⛔ **The frontend sat "stuck in phase one" for a whole run and then errored.** Documents were
    /// written only after the entire platform loop, and phase 1 was announced complete at the same
    /// point — but P1 and P2 both happen inside ONE call per platform, so for the forty minutes of
    /// deep research the web app had an open phase-1 tile and no brief to show in it.
    ///
    /// ⚠ Asserts the ORDER, from inside the call: what the double sees written by the time its own
    /// `onBriefProduced` returns. Checking after `launch()` finished would pass against the old
    /// behaviour, which wrote everything eventually.
    func testTheBriefDocumentIsWrittenBEFOREDeepResearchBegins() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        final class Reporting: RunExecutor.Pipeline, @unchecked Sendable {
            let contract: ContractEmitter
            var pathsAtBriefTime: [String] = []
            init(contract: ContractEmitter) { self.contract = contract }
            func runPhases(
                entry: QueueEntry, platform: String, brief: String,
                onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
            ) async throws -> (brief: String, report: String?) {
                guard platform == "chatgpt" else { return (brief: brief, report: "report") }
                await onBriefProduced(String(repeating: "A brief. ", count: 60))
                // Everything the run had written by the moment phase 1 handed over.
                pathsAtBriefTime = await contract.written.map(\.path)
                return (brief: String(repeating: "A brief. ", count: 60), report: "report")
            }
        }
        let pipeline = Reporting(contract: contract)
        let executor = RunExecutor(
            pipeline: pipeline, emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(
            QueueEntry(id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
                       submittedBy: "owner-1", topic: "t"),
            worker: 1
        )

        XCTAssertTrue(
            pipeline.pathsAtBriefTime.contains { $0.hasSuffix("/documents/brief") },
            "deep research began with no brief document written — the web app's phase-1 tile has "
                + "nothing to show and stays open: \(pipeline.pathsAtBriefTime)"
        )
    }

    /// ...and the phase transition is announced at the same moment, so the tile can actually close.
    func testPhaseOneIsAnnouncedCOMPLETEAsSoonAsTheBriefExists() async throws {
        let transport = StubTransport(responses: Array(repeating: .ok("{}"), count: 40))
        let contract = try await emitter(transport)
        final class Reporting: RunExecutor.Pipeline, @unchecked Sendable {
            let contract: ContractEmitter
            var eventsAtBriefTime: [String] = []
            init(contract: ContractEmitter) { self.contract = contract }
            func runPhases(
                entry: QueueEntry, platform: String, brief: String,
                onBriefProduced: @escaping @Sendable (String) async -> Void = { _ in }
            ) async throws -> (brief: String, report: String?) {
                guard platform == "chatgpt" else { return (brief: brief, report: "report") }
                await onBriefProduced(String(repeating: "A brief. ", count: 60))
                eventsAtBriefTime = await contract.written.compactMap { write in
                    guard case .string(let type)? = write.fields["type"] else { return nil }
                    guard case .integer(let phase)? = write.fields["phase"] else { return type }
                    return "\(type):\(phase)"
                }
                return (brief: String(repeating: "A brief. ", count: 60), report: "report")
            }
        }
        let pipeline = Reporting(contract: contract)
        let executor = RunExecutor(
            pipeline: pipeline, emitter: contract, handoff: SpyHandoffTransport(), now: { 1_000 }
        )

        await executor.launch(
            QueueEntry(id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
                       submittedBy: "owner-1", topic: "t"),
            worker: 1
        )

        XCTAssertTrue(pipeline.eventsAtBriefTime.contains("phase_complete:1"),
                      "\(pipeline.eventsAtBriefTime)")
        XCTAssertTrue(pipeline.eventsAtBriefTime.contains("phase_start:2"),
                      "phase 2 never opened, so the web app shows neither phase running")
    }
}
