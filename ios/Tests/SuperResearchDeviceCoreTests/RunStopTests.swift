import XCTest
@testable import SuperResearchDeviceCore

/// The owner's Stop, and the run it is supposed to stop.
///
/// ⛔ **Stop reached nothing at all until 2026-08-14.** `pollRunCommands` read the command,
/// classified it correctly and acked it — then called `controller?.stopRun(…)` on a **nil**,
/// because `RunController`'s only conformer in the whole repository was a test spy. Separately,
/// `InAppPipeline.run` had taken a `shouldStop` since it was written and nothing had ever passed
/// one, so it defaulted to `{ false }` for every real run. Two independent breaks, both invisible:
/// the button acknowledged the press and the run carried on.
final class RunStopTests: XCTestCase {

    private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    private func driver(_ page: FakePage) -> InAppPhaseDriver {
        InAppPhaseDriver(
            platform: "chatgpt",
            manifest: [
                "logged_in_marker": ["#signed-in-marker"],
                "composer": ["#composer"],
                "send": ["#send-button"],
                "response_container": ["#response-container"],
            ],
            page: page
        )
    }

    // MARK: - The signal

    func testAStopIsRememberedForTheResearchItNames() {
        let signal = RunStopSignal()
        signal.request(researchID: "res-1")
        XCTAssertTrue(signal.isStopped("res-1"))
        // ⚠ And ONLY the one it names. A stop that stopped everything would cancel a sibling
        // worker's unrelated run, which the owner never asked for and would never connect to the
        // button they pressed.
        XCTAssertFalse(signal.isStopped("res-2"))
    }

    func testAStoppedResearchCanBeRunAgain() {
        // ⛔ Without the clear, a stopped research is stopped for ever: the retry ends instantly,
        // with no explanation, looking exactly like intake never claiming it.
        let signal = RunStopSignal()
        signal.request(researchID: "res-1")
        signal.clear(researchID: "res-1")
        XCTAssertFalse(signal.isStopped("res-1"))
    }

    func testAnEmptyResearchIDIsNotStoppable() {
        // A blank id would otherwise match every run whose id failed to decode.
        let signal = RunStopSignal()
        signal.request(researchID: "")
        XCTAssertTrue(signal.all.isEmpty)
    }

    func testTheControllerIsAREALConformerAndNotASpy() async {
        // ⛔ The whole defect in one assertion: there WAS a `RunController` protocol, run control
        // called it correctly, and the only type conforming to it lived in a test file.
        let controller = InAppRunController()
        RunStopSignal.shared.clear(researchID: "res-real")
        await controller.stopRun(researchID: "res-real")
        XCTAssertTrue(RunStopSignal.shared.isStopped("res-real"))
        RunStopSignal.shared.clear(researchID: "res-real")
    }

    // MARK: - The pipeline honours it

    func testAStopDuringTheLongResponseWaitEndsIt() async throws {
        // ⭐ THE case that made Stop look broken. A deep-research reply is allowed 40 minutes; a
        // stop honoured only between phases would sit inside this wait for the rest of them.
        let page = FakePage()
        page.generating = true          // never finishes on its own
        page.responseText = ""
        let subject = driver(page)

        do {
            _ = try await subject.awaitResponse(
                timeout: 600, shouldStop: { true }, sleep: { _ in }
            )
            XCTFail("a stop must end the response wait")
        } catch let InAppPhaseError.stoppedByOwner(platform) {
            XCTAssertEqual(platform, "chatgpt")
        }
    }

    func testAWaitThatIsNotStoppedStillWaits() async throws {
        // The other half: a `shouldStop` that always answered true would end every run instantly,
        // and this test is what tells the two apart.
        let page = FakePage()
        let ok = try await driver(page).awaitResponse(
            timeout: 2, shouldStop: { false }, sleep: { _ in }
        )
        XCTAssertTrue(ok, "a settled response must still be accepted when nothing stopped it")
    }

    func testAStopBetweenPhasesEndsTheRunAsStoppedRatherThanFailed() async throws {
        let page = FakePage()
        var pipeline = InAppPipeline(driver: driver(page), topic: "t")

        let outcome = try await pipeline.run(
            shouldStop: { true }, pageReadyTimeout: 1, sleep: noSleep
        )

        XCTAssertEqual(outcome.status, "stopped")
        // ⚠ Nothing was typed. A stop that still drove the page would spend the research unit it
        // was pressed to save.
        XCTAssertTrue(page.inserted.isEmpty)
    }
}
