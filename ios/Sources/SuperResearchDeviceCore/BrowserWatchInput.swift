import Foundation

/// Who may send input to a watched platform page — the owner, the run, or nobody.
///
/// ⛔ **The problem this solves was invisible and cost a debugging session.** Browser watch applied
/// `.allowsHitTesting(false)` unless the owner tapped "Take over", which is right for a *human*: a
/// stray tap arriving mid-automation competes with the run for the same composer. But **HID taps
/// are indistinguishable from a human's**, so the same modifier also blocked the automation. The
/// symptom is not a refusal — it is calibration failing with *"fewer than two probe taps produced a
/// trusted event"*, which reads as a broken input channel and is in fact a SwiftUI modifier two
/// files away. It is not broken; it is switched off.
///
/// ⚠ **And it is not optional to fix.** ChatGPT's composer plus-menu does not open for a scripted
/// click — measured — so any in-app phase that must open a menu needs a real tap, which is exactly
/// what watching suppressed. The run and the watcher could not both have the page.
///
/// **The decision, stated rather than buried:** hit-testing is binary, so it cannot admit AXe while
/// refusing a finger. Input is therefore enabled whenever **the run is driving this very platform**,
/// and the bar underneath says so. The protection the overlay used to give becomes a warning
/// instead of a hard block — which is the honest trade, because the alternative is an automation
/// that cannot act at all.
public enum BrowserWatchInput {

    /// - Parameters:
    ///   - ownerTookOver: the owner pressed "Take over" — an explicit, reversible decision.
    ///   - runIsDriving: the pipeline is acting on THIS platform right now.
    public static func hitTestingEnabled(ownerTookOver: Bool, runIsDriving: Bool) -> Bool {
        ownerTookOver || runIsDriving
    }

    /// What the bar says, so the state is never ambiguous to the person looking at it.
    public static func caption(
        ownerTookOver: Bool, runIsDriving: Bool, runExists: Bool
    ) -> String {
        if ownerTookOver && runExists { return "You are driving. The run is paused on this platform." }
        if ownerTookOver { return "Yours to drive. Nothing is running on this worker." }
        // ⚠ Says "avoid tapping" rather than "read-only", because it is no longer read-only — input
        // is live so the automation can act. Telling the owner it is locked when it is not is worse
        // than telling them nothing.
        if runIsDriving { return "The run is driving this page. Avoid tapping while it works." }
        if runExists { return "Read-only while the run works on another platform." }
        return "Nothing is running here. Take over to sign in or check a session."
    }
}
