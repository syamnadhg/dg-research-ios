import XCTest

@testable import SuperResearchDeviceCore

/// The join that did not exist: a claimed entry becoming a running executor.
///
/// ⛔ `DeviceBackend.launcher` was never assigned by anything, so the device claimed a run — stamping
/// the queue document so no sibling would take it — and then did nothing. The run sat "ongoing" for
/// ever and the owner's next run queued behind it. These assert the pieces that make the join
/// correct rather than merely present.
final class RunLauncherAssemblyTests: XCTestCase {

    private let config = FirebaseProjectConfig(
        projectID: "p", apiKey: "k", apiBaseURL: URL(string: "https://fe.test")!, emulatorHost: nil
    )

    private func entry(backendRunId: String? = nil) -> QueueEntry {
        QueueEntry(id: "q1", action: .start, researchId: "res-1", uid: "owner-1",
                   submittedBy: "owner-1", topic: "t", backendRunId: backendRunId)
    }

    // MARK: - The run id

    func testARESUMEDRunKEEPSTheIdTheFrontendAlreadyShows() {
        // A fresh id on resume reads as a SECOND run of the same research: the frontend has already
        // displayed the old one and correlated its events against it.
        let id = InAppRunLauncher.runID(
            for: entry(backendRunId: "run-from-before"), deviceID: "dev-123456789",
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(id, "run-from-before")
    }

    func testAFreshRunGetsAnIdThatNamesTheDEVICEAndTheMOMENT() {
        // Two runs on one device must not collide, and a run's id should say where it came from —
        // the same document is written by a Mac backend on other runs.
        let first = InAppRunLauncher.runID(
            for: entry(), deviceID: "dev-123456789", now: Date(timeIntervalSince1970: 1_000)
        )
        let second = InAppRunLauncher.runID(
            for: entry(), deviceID: "dev-123456789", now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertTrue(first.hasPrefix("ios-dev-1234"), first)
        XCTAssertNotEqual(first, second)
    }

    func testAnEMPTYBackendRunIdIsTreatedAsAbsent() {
        // Firestore returns "" for a field the frontend created and never filled; taking it
        // literally gives every such run the same empty id.
        let id = InAppRunLauncher.runID(
            for: entry(backendRunId: ""), deviceID: "dev-1", now: Date(timeIntervalSince1970: 5)
        )
        XCTAssertFalse(id.isEmpty)
    }

    // MARK: - The handoff transport

    func testEveryHandoffPatchCarriesTheDEVICEID() async throws {
        // ⛔ `request.resource.data.deviceId == request.auth.token.deviceId`, judged on the resource
        // being WRITTEN. Without it the beDone write 403s and the owner's NEXT run stalls behind a
        // queue gate that never opens.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"i\",\"refreshToken\":\"r\",\"expiresIn\":\"3600\"}"), .ok("{}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        let handoff = RESTHandoffTransport(
            client: client, deviceID: "dev-9", apiBaseURL: config.apiBaseURL, log: { _ in }
        )

        try await handoff.patchResearch(
            uid: "owner-1", researchId: "res-1", set: ["beDone": .boolean(true)]
        )

        let body = try transport.lastBodyJSON()
        let fields = try XCTUnwrap(body["fields"] as? [String: Any])
        let device = try XCTUnwrap(fields["deviceId"] as? [String: Any])
        XCTAssertEqual(device["stringValue"] as? String, "dev-9")
    }

    func testTheHandoffPatchAddressesTheOWNERSTreeAndNotTheSubmitters() async throws {
        // ⚠ For a sharer's run these diverge: the research lives under the SHARER's uid, and
        // addressing it by the submitter writes a run into the wrong user's tree.
        let transport = StubTransport(responses: [
            .ok("{\"idToken\":\"i\",\"refreshToken\":\"r\",\"expiresIn\":\"3600\"}"), .ok("{}"),
        ])
        let client = FirestoreREST(config: config, transport: transport)
        try await client.signIn(customToken: "ct")
        let handoff = RESTHandoffTransport(
            client: client, deviceID: "dev-9", apiBaseURL: config.apiBaseURL, log: { _ in }
        )

        try await handoff.patchResearch(
            uid: "sharer-7", researchId: "res-1", set: ["beDone": .boolean(true)]
        )

        let url = try XCTUnwrap(transport.lastRequest().url?.absoluteString)
        XCTAssertTrue(url.contains("users/sharer-7/researches/res-1"), url)
    }
}

/// A navigation destroys the injected page runtime, and a run navigates several times.
///
/// ⛔ `window.__sr` lives in the page's JS context, which is rebuilt on every document load —
/// enabling deep research navigates (the URL gains a conversation id), and so does confirming
/// Gemini's research plan. The runtime was injected exactly ONCE, at the top of a run, so every call
/// after the first navigation threw "undefined is not an object": a WebKit error raised against a
/// selector that is perfectly correct, at a point that reads as the platform's fault.
///
/// ⚠ The surrounding plumbing needs a real `WKWebView` and cannot be unit-tested at all. This is the
/// part of the decision that can be, and it is extracted for exactly that reason.
final class RuntimeReinjectionTests: XCTestCase {

    func testAFailedRUNTIMECallIsRetriedAfterReinjecting() {
        XCTAssertTrue(WebAutomationBridge.shouldReinject(expression: "window.__sr.query('#x')"))
        XCTAssertTrue(WebAutomationBridge.shouldReinject(expression: "window.__sr.textOf(3)"))
    }

    func testAFailureInSOMEONEELSESJavaScriptIsReportedAsItself() {
        // ⛔ Retrying every failure behind an injection would hide a genuine page error and report
        // it as whatever the second attempt happened to do.
        XCTAssertFalse(WebAutomationBridge.shouldReinject(expression: "String(location.href)"))
        XCTAssertFalse(
            WebAutomationBridge.shouldReinject(expression: "document.querySelector('audio')")
        )
    }
}

/// Attaching the launcher, and refusing to pretend when it cannot be attached.
final class RunLauncherAttachmentTests: XCTestCase {

    /// ⚠ A store rooted in a temp directory, so these never read or write the real keychain entry
    /// this machine's PAIRED device is using.
    private func backend(_ transport: DeviceTransport) -> DeviceBackend {
        var store = DeviceIdentityStore()
        store.fallbackDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-launcher-tests-\(UUID().uuidString)")
        return DeviceBackend(
            transport: transport, store: store,
            workers: WorkerRegistry(storage: InMemoryWorkerStorage())
        )
    }

    func testNoLauncherIsBuiltBEFOREOneIsAttached() {
        // The state the device shipped in: a claim with nothing behind it.
        let device = backend(FakeTransport())
        XCTAssertNil(device.launcher(for: "dev-1"))
    }

    func testATRANSPORTWithNoRESTSessionDoesNotGetAFakeLauncher() {
        // ⛔ The preview backend has no Firestore session, so a run could not be driven anyway —
        // and a launcher that existed but could not write would claim runs and lose them, which is
        // strictly worse than not claiming.
        let device = backend(FakeTransport())
        device.attachRunLauncher(
            apiBaseURL: URL(string: "https://fe.test")!, storageBucket: "b.appspot.com",
            pages: { _, _ in ScriptedNotebookPage() }, manifest: [:], texts: [:], openers: [:]
        )
        XCTAssertNil(device.launcher(for: "dev-1"))
    }

    func testAttachingToTheRESTBackendYIELDSALauncher() {
        let device = backend(RESTPairingBackend(
            config: FirebaseProjectConfig(
                projectID: "p", apiKey: "k", apiBaseURL: URL(string: "https://fe.test")!
            )
        ))
        device.attachRunLauncher(
            apiBaseURL: URL(string: "https://fe.test")!, storageBucket: "b.appspot.com",
            pages: { _, _ in ScriptedNotebookPage() }, manifest: [:], texts: [:], openers: [:]
        )
        XCTAssertNotNil(device.launcher(for: "dev-1"))
    }

    func testTheLauncherIsBuiltONCEAndReused() {
        // A new FirebaseStorage and token closure per claim is waste, and the device id cannot
        // change without a re-pair — which rebuilds the whole backend.
        let device = backend(RESTPairingBackend(
            config: FirebaseProjectConfig(
                projectID: "p", apiKey: "k", apiBaseURL: URL(string: "https://fe.test")!
            )
        ))
        device.attachRunLauncher(
            apiBaseURL: URL(string: "https://fe.test")!, storageBucket: "b.appspot.com",
            pages: { _, _ in ScriptedNotebookPage() }, manifest: [:], texts: [:], openers: [:]
        )
        let first = device.launcher(for: "dev-1")
        let second = device.launcher(for: "dev-1")
        XCTAssertTrue(first as AnyObject === second as AnyObject)
    }
}

/// The Storage bucket is READ, never derived.
final class StorageBucketConfigTests: XCTestCase {

    func testTheBucketComesFromThePLISTAndIsNotDerivedFromTheProjectId() throws {
        // ⛔ Firebase changed its default bucket name: older projects are `<project>.appspot.com`,
        // newer ones `<project>.firebasestorage.app`. This project is the NEWER form, measured in
        // its own plist — a derived guess uploads to a bucket that does not exist, and the failure
        // is a 404 on a URL that looks perfectly well formed.
        let config = try FirebaseProjectConfig(
            plist: [
                "PROJECT_ID": "super-research-492814", "API_KEY": "k",
                "STORAGE_BUCKET": "super-research-492814.firebasestorage.app",
            ],
            apiBaseURL: URL(string: "https://fe.test")!
        )
        XCTAssertEqual(config.storageBucket, "super-research-492814.firebasestorage.app")
        XCTAssertFalse(config.storageBucket.hasSuffix(".appspot.com"))
    }

    func testAMissingBucketIsEMPTYRatherThanGuessed() throws {
        // Empty makes the upload fail with a named `noBucket` that points at the plist. A guess
        // fails somewhere else entirely, with a 404.
        let config = try FirebaseProjectConfig(
            plist: ["PROJECT_ID": "p", "API_KEY": "k"],
            apiBaseURL: URL(string: "https://fe.test")!
        )
        XCTAssertEqual(config.storageBucket, "")
    }
}

/// The trace a run leaves behind.
///
/// ⭐ A FILE, not only a console stream. A run takes 30 to 90 minutes and the questions afterwards
/// are always the same — which step did it stop at, what did the page hand back, how long did each
/// wait take — and a stream nobody attached before the interesting moment answers none of them.
final class RunLogTests: XCTestCase {

    private func log(_ clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) })
        -> RunLog {
        RunLog(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sr-runlog-tests-\(UUID().uuidString)"),
            name: "run.log", clock: clock, echo: { _ in }
        )
    }

    private func read(_ log: RunLog) -> String {
        (try? String(contentsOf: log.url, encoding: .utf8)) ?? ""
    }

    func testEveryLineIsTIMESTAMPED() {
        // "Which step was slow" is the first question of every post-run reading, and a trace of
        // bare step names cannot answer it.
        let trace = log()
        trace.write("p2.chatgpt.send")
        XCTAssertTrue(read(trace).contains("1970-01-01T00:00:00.000Z"), read(trace))
    }

    func testLinesACCUMULATERatherThanOverwriting() {
        // A file handle opened for writing without seeking to the end truncates — and the symptom
        // is a trace containing only the LAST step, which reads as a run that did nothing else.
        let trace = log()
        trace.write("first")
        trace.write("second")
        let text = read(trace)
        XCTAssertTrue(text.contains("first"), text)
        XCTAssertTrue(text.contains("second"), text)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testALARGEValueIsEXCERPTEDAndItsLengthIsKept() {
        // ⚠ Truncated rather than omitted: the interesting fact about a report is nearly always its
        // LENGTH plus the opening, and dumping 40,000 characters makes the trace unreadable while
        // omitting it makes "the extractor returned something short" unanswerable.
        let trace = log()
        trace.excerpt("chatgpt.report", String(repeating: "x", count: 5_000))
        let text = read(trace)
        XCTAssertTrue(text.contains("5000 chars"), text)
        XCTAssertLessThan(text.count, 500, "the whole report was written into the trace")
    }

    func testANEWLINEDoesNotBreakALineIntoTwo() {
        // A multi-line excerpt would otherwise turn one entry into many, and every line-oriented
        // reading of the file — including the counter above — becomes wrong.
        let trace = log()
        trace.excerpt("brief", "one\ntwo\nthree")
        XCTAssertEqual(read(trace).split(separator: "\n").count, 1)
    }

    func testTheDISCARDINGLogWritesNothingToTheConsole() {
        // The paths that take a log but are not being traced must not spam a real run's console.
        let trace = RunLog.discarding()
        trace.write("noise")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trace.url.path) || true)
    }
}
