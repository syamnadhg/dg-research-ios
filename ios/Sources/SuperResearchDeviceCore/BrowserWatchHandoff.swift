import Foundation

/// How a web view moves between the offscreen window slot and the Browser-watch container.
///
/// ⛔⛔ **This exists because getting it wrong crashed the app two minutes into a live run.**
/// 2026-08-14: the owner opened Browser watch on the platform P1 was driving. The container's update
/// removed every subview and added the live one in a single runloop turn, so three WebContent
/// processes flipped background→foreground inside ONE millisecond while
/// `WebPage::runJavaScriptInFrameInScriptWorld` was in flight. `ProcessThrottlerActivity::invalidate`
/// hit its `RELEASE_ASSERT` inside `sendPrepareToSuspendIPC` and the process died, taking the run
/// with it. Same trap, same address, third occurrence.
///
/// The rules are in the core rather than in the view because a `UIViewRepresentable` cannot be unit
/// tested — and "we changed the view and hoped" is what the previous two occurrences were.
public enum BrowserWatchHandoff {

    /// What to do with one view during a hand-off.
    public enum Move: Equatable, Sendable {
        /// The page the watch is about to show. Goes into the container.
        case present(platform: String)
        /// A page that was on screen and no longer is.
        ///
        /// ⛔ **Back to the offscreen WINDOW slot, never merely removed.** WebKit does not read a
        /// bare `removeFromSuperview()` as "moved" — with no window, the view is invisible, and it
        /// begins suspending its WebContent process. That suspension is half of the crash; the other
        /// half is a later attach undoing it in the same breath.
        case returnToWindow(platform: String)
    }

    /// A move, and which runloop turn it belongs to.
    public struct Step: Equatable, Sendable {
        public let move: Move
        /// 0 is this turn, 1 the next, and so on. ⚠ **Never two moves in one turn.** The assert
        /// fires on a suspension entered reentrantly, so asking for several transitions at once is
        /// precisely the shape to avoid.
        public let turn: Int
    }

    /// Plan the hand-off.
    ///
    /// - Parameters:
    ///   - showing: platforms currently parented in the watch container.
    ///   - target: the platform the watch is switching to.
    /// How visible a page is while PARKED in the window, waiting to be watched.
    ///
    /// ⚠ Not zero and not hidden: a view with `alpha == 0`, `isHidden`, or a zero frame is treated
    /// by WebKit as invisible, and an invisible page's WebContent process is suspended — which is
    /// both a stalled run and the state whose transitions trip `ProcessThrottler`. Barely visible
    /// keeps the process in the foreground regime while showing the owner nothing.
    public static let parkedAlpha: CGFloat = 0.01

    /// ⭐ **And what it must be restored to when Browser watch shows it.** These are a PAIR, in one
    /// place, because they were not: parking set `0.01` in one file and the screen that presents the
    /// same view set nothing in another — so tapping a platform rendered the live page at one
    /// percent opacity. The owner reported it three times as "it's all dark, nothing loaded", and
    /// the log agreed with them and with the code: `page=live url=https://chatgpt.com/c/… loading=no`.
    public static let presentedAlpha: CGFloat = 1.0

    /// What parking a page should do, given where that page currently sits.
    public enum Parking: Equatable {
        /// It is already in the window — leave it alone; re-adding is a needless transition.
        case alreadyParked
        /// It is somewhere else (a Browser-watch container) or nowhere: move it, in ONE step.
        case reparent
        /// There is no window to park it in, which is not this function's problem to solve.
        case noWindow
    }

    /// ⛔ **The rule the crash came from, extracted so it can be exercised.** The real code guarded
    /// on `superview == nil` and therefore refused every caller that had something to rescue the
    /// page FROM — the container it was being removed from. The page was left orphaned, WebKit
    /// suspended its process mid-JavaScript, and `ProcessThrottler` asserted. Three crashes.
    ///
    /// ⚠ `hasSuperview` is deliberately NOT a reason to refuse. The only reason to do nothing is
    /// that the page is already parked where it belongs.
    public static func parking(hasWindow: Bool, superviewIsWindow: Bool) -> Parking {
        guard hasWindow else { return .noWindow }
        return superviewIsWindow ? .alreadyParked : .reparent
    }

    public static func plan(showing: [String], target: String) -> [Step] {
        // Already there: no transition at all. The cheapest hand-off is the one that does not
        // happen, and re-presenting a page the run is driving is a visibility flip for nothing.
        if showing == [target] { return [] }
        var steps = [Step(move: .present(platform: target), turn: 0)]
        for (index, platform) in showing.filter({ $0 != target }).enumerated() {
            steps.append(Step(move: .returnToWindow(platform: platform), turn: index + 1))
        }
        return steps
    }

    /// Delay for a step, in milliseconds — one spacing rule, used by every caller.
    public static func delayMillis(turn: Int, spacing: Int = 250) -> Int { turn * spacing }
}
