import XCTest
@testable import SuperResearchDeviceCore

/// The hand-off that crashed the app mid-run.
///
/// ⛔⛔ 2026-08-14: the owner opened Browser watch on the platform P1 was driving. Three WebContent
/// processes flipped background→foreground inside ONE millisecond while a JS evaluation was in
/// flight, and WebKit's `ProcessThrottler` hit its `RELEASE_ASSERT`. The app died two minutes into
/// the run. Same trap, same address, third occurrence — and the first two were "fixed" by changing
/// the view and hoping, which is why the rules now live somewhere a test can reach them.
final class BrowserWatchHandoffTests: XCTestCase {

    /// ⛔ **Never orphaned.** WebKit does not read a bare removal as "moved" — with no window the
    /// view is invisible, and it starts suspending its WebContent process. That suspension is half
    /// the crash; a later attach undoing it in the same breath is the other half.
    func testTheOUTGOINGPageIsReturnedToTheWindowNotOrphaned() {
        let steps = BrowserWatchHandoff.plan(showing: ["chatgpt"], target: "gemini")
        XCTAssertTrue(
            steps.contains(Step(.returnToWindow(platform: "chatgpt"), turn: 1)),
            "the outgoing page was not returned to the window: \(steps)"
        )
        // And it must be a RETURN, never a bare drop — asserted as the case, not as a count.
        for step in steps {
            if case .present = step.move { continue }
            guard case .returnToWindow = step.move else {
                return XCTFail("a page left the container without going back to the window")
            }
        }
    }

    /// ⛔ **One transition per turn.** The assert fires on a suspension entered reentrantly, so
    /// asking for several visibility changes at once is precisely the shape to avoid.
    func testHandoffsAreSPACEDOneTransitionPerTurn() {
        let steps = BrowserWatchHandoff.plan(showing: ["chatgpt", "claude"], target: "gemini")
        let turns = steps.map(\.turn)
        XCTAssertEqual(turns, Array(0..<steps.count), "two moves landed in the same turn: \(steps)")
        XCTAssertEqual(Set(turns).count, steps.count, "turns must be distinct")
        // And the delay grows with the turn — a schedule that returns 0 for everything is the same
        // defect wearing a spacing function's name.
        XCTAssertEqual(BrowserWatchHandoff.delayMillis(turn: 0), 0)
        XCTAssertGreaterThan(
            BrowserWatchHandoff.delayMillis(turn: 1), BrowserWatchHandoff.delayMillis(turn: 0)
        )
        XCTAssertGreaterThan(
            BrowserWatchHandoff.delayMillis(turn: 2), BrowserWatchHandoff.delayMillis(turn: 1)
        )
    }

    /// The page being shown goes in FIRST, so the watch is never blank while the outgoing one
    /// unwinds — and, more importantly, so the run's own page is never the thing left waiting.
    func testTheINCOMINGPageIsPresentedOnTheFirstTurn() {
        let steps = BrowserWatchHandoff.plan(showing: ["chatgpt"], target: "gemini")
        XCTAssertEqual(steps.first, Step(.present(platform: "gemini"), turn: 0))
    }

    /// ⚠ **The cheapest hand-off is the one that does not happen.** Re-presenting the page already
    /// on screen would be a visibility flip for nothing — and SwiftUI calls `updateUIView` for
    /// reasons that have nothing to do with the platform changing.
    func testSwitchingToThePageAlreadyShownMovesNOTHING() {
        XCTAssertEqual(BrowserWatchHandoff.plan(showing: ["gemini"], target: "gemini"), [])
    }

    func testOpeningTheWatchOnAFreshContainerOnlyPresents() {
        XCTAssertEqual(
            BrowserWatchHandoff.plan(showing: [], target: "chatgpt"),
            [Step(.present(platform: "chatgpt"), turn: 0)]
        )
    }

    private typealias Step = BrowserWatchHandoff.Step
}

private extension BrowserWatchHandoff.Step {
    init(_ move: BrowserWatchHandoff.Move, turn: Int) { self.init(move: move, turn: turn) }
}

/// Parking a page, and the guard that made three crashes possible.
final class BrowserWatchParkingTests: XCTestCase {

    /// ⛔⛔ **THE CRASH, as a rule.** The shipped guard was `superview == nil`, so every caller that
    /// had a page to rescue — Browser watch handing a tab over, and Browser watch being torn down —
    /// was refused, because such a page always HAS a superview: the container it is leaving. The
    /// page was then orphaned by the container's own removal, WebKit read a windowless view as
    /// invisible, started suspending its WebContent process while the run's JavaScript was in
    /// flight, and `ProcessThrottlerActivity::invalidate` hit its RELEASE_ASSERT.
    func testAPageInsideTheWATCHCONTAINERIsReparentedRatherThanRefused() {
        XCTAssertEqual(
            BrowserWatchHandoff.parking(hasWindow: true, superviewIsWindow: false), .reparent,
            "the page was refused rescue because it had somewhere to be rescued FROM"
        )
    }

    /// ...and a page already parked is left alone: re-adding it is a needless visibility
    /// transition, which is the very thing the assert fires on.
    func testAPageALREADYInTheWindowIsLeftAlone() {
        XCTAssertEqual(
            BrowserWatchHandoff.parking(hasWindow: true, superviewIsWindow: true), .alreadyParked
        )
    }

    func testWithNoWindowThereIsNowhereToPark() {
        XCTAssertEqual(
            BrowserWatchHandoff.parking(hasWindow: false, superviewIsWindow: false), .noWindow
        )
    }

    /// ⭐ **THE BLACK SCREEN, as a pair.** Parked pages are near-invisible on purpose; the screen
    /// that presents the same view has to put the alpha back. They were a literal in one file and
    /// nothing in the other, so watching a live page showed one percent of it — reported three
    /// times as "all dark", while the log correctly insisted the page was live and loaded.
    func testThePARKEDAndPRESENTEDAlphasAreNotTheSameValue() {
        XCTAssertLessThan(BrowserWatchHandoff.parkedAlpha, 0.05,
                          "a parked page visible to the owner is a page they can tap by accident")
        XCTAssertEqual(BrowserWatchHandoff.presentedAlpha, 1.0,
                       "the page being watched is rendered at less than full opacity")
        XCTAssertNotEqual(BrowserWatchHandoff.parkedAlpha, BrowserWatchHandoff.presentedAlpha)
    }

    /// ⚠ And NOT zero. A view at `alpha == 0` is invisible to WebKit too, so its WebContent process
    /// suspends — a stalled run, and the suspension transitions are what the assert fires on.
    func testAParkedPageIsNEARLYInvisibleRatherThanFullyInvisible() {
        XCTAssertGreaterThan(BrowserWatchHandoff.parkedAlpha, 0,
                             "alpha 0 suspends the page's process — the run stops with no error")
    }
}
