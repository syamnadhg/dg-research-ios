import XCTest

@testable import SuperResearchDeviceCore

/// Who may send input to a watched page — and why the automation must be one of them.
final class BrowserWatchInputTests: XCTestCase {

    func testTheRUNCanDriveThePageWithoutTheOwnerTakingOver() {
        // ⛔ The bug: hit-testing was off unless the owner tapped Take over, and HID taps are
        // indistinguishable from a finger — so the automation was blocked too. It presented as
        // calibration failing with "fewer than two probe taps produced a trusted event", which
        // reads as a broken input channel rather than a SwiftUI modifier two files away.
        XCTAssertTrue(
            BrowserWatchInput.hitTestingEnabled(ownerTookOver: false, runIsDriving: true)
        )
    }

    func testTheOwnerCanStillDriveWhenNothingIsRunning() {
        XCTAssertTrue(
            BrowserWatchInput.hitTestingEnabled(ownerTookOver: true, runIsDriving: false)
        )
    }

    func testAnIdleWatchedPageStaysNONINTERACTIVE() {
        // The original protection is kept where it costs nothing: with no run driving and no
        // takeover, a stray tap should not reach a page the owner is only looking at.
        XCTAssertFalse(
            BrowserWatchInput.hitTestingEnabled(ownerTookOver: false, runIsDriving: false)
        )
    }

    func testTheCaptionSaysINPUTISLIVEWhenTheRunIsDriving() {
        // ⚠ Not "read-only" — it is no longer read-only. Telling the owner it is locked when it is
        // not is worse than telling them nothing.
        let caption = BrowserWatchInput.caption(
            ownerTookOver: false, runIsDriving: true, runExists: true
        )
        XCTAssertFalse(caption.lowercased().contains("read-only"))
        XCTAssertTrue(caption.lowercased().contains("avoid tapping"))
    }

    func testACaptionForARunWorkingElsewhereStillSaysReadOnly() {
        let caption = BrowserWatchInput.caption(
            ownerTookOver: false, runIsDriving: false, runExists: true
        )
        XCTAssertTrue(caption.lowercased().contains("read-only"))
    }

    // MARK: - Which platform the run is on

    private func run(agents: [String: String]) -> RunState {
        RunState(researchTitle: "t", phase: 2, phaseName: "Research",
                 elapsedSeconds: 0, agents: agents)
    }

    func testTheActivePlatformIsTheOneMarkedActive() {
        XCTAssertEqual(
            run(agents: ["chatgpt": "done", "gemini": "active", "claude": "pending"])
                .activePlatform,
            "gemini"
        )
    }

    func testTWOActivePlatformsIsAMBIGUOUSAndYieldsNONE() {
        // ⚠ This decides whether INPUT is handed to the automation. Two "active" entries means the
        // device state is mid-update or wrong, and guessing between them would enable taps on a
        // page the run is not driving.
        XCTAssertNil(
            run(agents: ["chatgpt": "active", "gemini": "active"]).activePlatform
        )
    }

    func testNoActivePlatformYieldsNone() {
        XCTAssertNil(run(agents: ["chatgpt": "done", "gemini": "pending"]).activePlatform)
        XCTAssertNil(run(agents: [:]).activePlatform)
    }

    func testAPlatformThatIsDONEDoesNotCountAsActive() {
        XCTAssertNil(run(agents: ["chatgpt": "done"]).activePlatform)
    }
}
