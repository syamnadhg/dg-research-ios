import XCTest
@testable import SuperResearchDeviceCore

/// The account's Settings, as this device reads them.
///
/// ⭐ Every case here is a setting the owner can press in the web app and that the device used to
/// ignore. The one that cost a live run is `verifyLogins`: it was off, the device verified anyway,
/// and three platforms were declared signed out four seconds into the run.
final class RunConfigTests: XCTestCase {

    private func map(_ fields: [String: FirestoreValue]) -> FirestoreValue { .map(fields) }

    // MARK: - Verification is opt-IN

    func testAnAccountWithNoSettingsSkipsTheLoginWalk() {
        // ⛔ The DEFAULT is the whole point, not an edge case. The backend's own default is
        // `skipInitVerify=True` because a proactive verify navigation is the strongest bot-score
        // signal there is — so "verify to be safe" is the unsafe choice, and it is also the one a
        // naive reimplementation picks.
        XCTAssertTrue(RunConfig.decode(nil).skipInitVerify)
        XCTAssertTrue(RunConfig.decode(map([:])).skipInitVerify)
        XCTAssertTrue(RunConfig.default.skips(phase: 0))
    }

    func testVerifyLoginsOnIsWhatTurnsTheLoginWalkBackOn() {
        let config = RunConfig.decode(map(["verifyLogins": .boolean(true)]))
        XCTAssertFalse(config.skipInitVerify)
        XCTAssertFalse(config.skips(phase: 0))
    }

    func testVerifyLoginsOffLeavesTheWalkSkipped() {
        // The exact configuration the owner was running on 2026-08-14.
        XCTAssertTrue(RunConfig.decode(map(["verifyLogins": .boolean(false)])).skipInitVerify)
    }

    func testTheBackendSpellingIsReadWithoutBeingInverted() {
        // ⚠ `skipInitVerify` and `verifyLogins` are OPPOSITES. Reading one as the other flips every
        // account's setting, and the symptom — verification running when it was switched off — is
        // exactly the bug the rename was introduced to end.
        XCTAssertFalse(RunConfig.decode(map(["skipInitVerify": .boolean(false)])).skipInitVerify)
        XCTAssertTrue(RunConfig.decode(map(["skipInitVerify": .boolean(true)])).skipInitVerify)
    }

    func testTheBackendSpellingWinsWhenBothArePresent() {
        // Both present and DISAGREEING: `skipInitVerify:false` (verify) vs `verifyLogins:false`
        // (do not verify). The resolved backend field is the one a backend obeys.
        let config = RunConfig.decode(map([
            "skipInitVerify": .boolean(false), "verifyLogins": .boolean(false),
        ]))
        XCTAssertFalse(config.skipInitVerify, "the resolved BE field must win over the raw toggle")
    }

    // MARK: - Agents

    func testAnAgentSwitchedOffIsNotDriven() {
        let config = RunConfig.decode(map([
            "agents": .map(["chatgpt": .boolean(true), "gemini": .boolean(false),
                            "claude": .boolean(true)]),
        ]))
        XCTAssertEqual(config.enabledPlatforms, ["chatgpt", "claude"])
        XCTAssertFalse(config.runsAgent("gemini"))
    }

    func testAnAbsentAgentRunsRatherThanSilentlyDisappearing() {
        // ⛔ **Constructed directly, NOT through `decode`, and that distinction is the whole test.**
        // `decode` starts from the default — which already names all three agents — so a key is
        // never actually missing by the time `runsAgent` is asked. The first version of this test
        // went through `decode`, and it passed just as happily with the fallback inverted to
        // `?? false`: a guard that could not run, asserted by a test that could not fail. Caught by
        // mutation, which is the only thing that would have caught it.
        let partial = RunConfig(agents: ["gemini": false])
        XCTAssertTrue(partial.runsAgent("chatgpt"), "an agent nobody mentioned is ON")
        XCTAssertTrue(partial.runsAgent("claude"))
        XCTAssertFalse(partial.runsAgent("gemini"))
        XCTAssertEqual(partial.enabledPlatforms, ["chatgpt", "claude"])
    }

    func testDecodeSeedsEveryAgentSoAPartialSettingsMapIsStillComplete() {
        // The other half of the pair: a settings map naming ONE agent must not switch the other two
        // off. This is what the previous test was written to check and could not.
        let config = RunConfig.decode(map(["agents": .map(["gemini": .boolean(false)])]))
        XCTAssertEqual(config.agents.count, 3)
        XCTAssertEqual(config.enabledPlatforms, ["chatgpt", "claude"])
    }

    func testEveryAgentOffAlsoSkipsTheResearchPhase() {
        let config = RunConfig.decode(map([
            "agents": .map(["chatgpt": .boolean(false), "gemini": .boolean(false),
                            "claude": .boolean(false)]),
        ]))
        XCTAssertTrue(config.enabledPlatforms.isEmpty)
        XCTAssertTrue(config.skipPhases.contains(2), "no agents means there is no research phase")
    }

    // MARK: - Skipped phases

    func testTheFrontendsSpellingOfSkippedPhasesIsRead() {
        // ⛔ **The two halves of the product disagree on this key.** The web app writes
        // `skippedPhases`; the backend writes `skipPhases`. Reading only one silently runs a phase
        // the owner switched off, and `research.py`'s own overlay accepts either for this reason.
        let config = RunConfig.decode(map(["skippedPhases": .array([.integer(1)])]))
        XCTAssertTrue(config.skips(phase: 1))
    }

    func testTheBackendsSpellingOfSkipPhasesIsRead() {
        XCTAssertTrue(RunConfig.decode(map(["skipPhases": .array([.integer(1)])])).skips(phase: 1))
    }

    func testPhasesArriveAsWireStringsAndAreStillRead() {
        // Firestore carries integers as strings on the wire. A decoder that only matched `.integer`
        // would drop every phase it was handed and report a config with nothing skipped.
        XCTAssertTrue(RunConfig.decode(map(["skippedPhases": .array([.string("1")])])).skips(phase: 1))
    }

    func testSkippingThePodcastAlsoSkipsTheVideo() {
        // P4 films the podcast. A run configured to make no podcast and then asked for a video
        // would hand the cloud an empty document to film — `research.py`: `if 3 in sp: sp.add(4)`.
        let config = RunConfig.decode(map(["skippedPhases": .array([.integer(3)])]))
        XCTAssertTrue(config.skipPhases.contains(4))
    }

    func testTurningTheVideoOffSkipsPhaseFourWithoutTouchingThePodcast() {
        let config = RunConfig.decode(map(["videoEnabled": .boolean(false)]))
        XCTAssertTrue(config.skipPhases.contains(4))
        XCTAssertFalse(config.skipPhases.contains(3), "no video is not the same as no podcast")
    }

    // MARK: - Podcast length

    func testAnUnknownPodcastLengthIsRefusedRatherThanPassedOn() {
        // The length picker has three rows. An unrecognised value reaching P3 would be looked up
        // and not found, at the end of a run rather than at the start of one.
        XCTAssertNil(RunConfig.decode(map(["podcastLength": .string("epic")])).podcastLength)
        XCTAssertEqual(RunConfig.decode(map(["podcastLength": .string("short")])).podcastLength, "short")
    }

    // MARK: - The queue document

    func testTheQueueDocumentsConfigBecomesTheRunsConfig() throws {
        let doc = FirestoreREST.ListedDocument(
            id: "q1",
            fields: [
                "action": .string("start"),
                "researchId": .string("r1"),
                "uid": .string("u1"),
                "config": .map([
                    "verifyLogins": .boolean(false),
                    "podcastLength": .string("short"),
                    "agents": .map(["gemini": .boolean(false)]),
                ]),
            ],
            updateTime: nil
        )
        let entry = try XCTUnwrap(QueueEntry.decode(doc))
        XCTAssertTrue(entry.config.skipInitVerify)
        XCTAssertEqual(entry.config.enabledPlatforms, ["chatgpt", "claude"])
        // The length still reads through its old name, because P3 asks for it by that name.
        XCTAssertEqual(entry.podcastLength, "short")
    }

    func testAQueueDocumentWithNoConfigStillSkipsVerification() {
        let doc = FirestoreREST.ListedDocument(
            id: "q1",
            fields: ["action": .string("start"), "researchId": .string("r1"), "uid": .string("u1")],
            updateTime: nil
        )
        let entry = try? XCTUnwrap(QueueEntry.decode(doc))
        XCTAssertEqual(entry?.config.skipInitVerify, true)
    }
}
