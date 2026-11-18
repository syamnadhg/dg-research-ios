import Foundation

/// Runs the owner has asked to stop.
///
/// ⛔ **The channel that was missing.** `pollRunCommands` already reads the web app's Stop, decides
/// correctly, and calls `controller?.stopRun(researchID:)` — but `RunController`'s only conformer in
/// the whole repository was a **test spy**, so `controller` was never set and every Stop was decoded,
/// acked, and dropped. Measured 2026-08-14: the owner pressed Stop, the run carried on into a
/// 40-minute `awaitResponse`, and the worker pill kept pulsing because it was honestly still busy.
///
/// ⚠ A lock-guarded box rather than actor state, for the same reason `LiveRunActivity` is one: the
/// pipeline asks this question SYNCHRONOUSLY from inside a poll loop. An `async` read would need
/// every polling site to become a suspension point, and a suspension point inside the loop that is
/// meant to notice a stop is how a stop gets noticed late.
public final class RunStopSignal: @unchecked Sendable {

    public static let shared = RunStopSignal()

    private let lock = NSLock()
    private var stopped: Set<String> = []

    public init() {}

    /// The owner pressed Stop on this research.
    public func request(researchID: String) {
        guard !researchID.isEmpty else { return }
        lock.lock(); stopped.insert(researchID); lock.unlock()
    }

    public func isStopped(_ researchID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped.contains(researchID)
    }

    /// Forget a research, so a later run of the same id is not born stopped.
    ///
    /// ⛔ Called on the run's exit path whatever happened. Without it a stopped-then-retried research
    /// would stop instantly and for ever, and the only symptom would be a run that ends immediately
    /// with no explanation — indistinguishable from the intake never claiming it.
    public func clear(researchID: String) {
        lock.lock(); stopped.remove(researchID); lock.unlock()
    }

    /// Every research currently marked stopped. For tests and diagnostics.
    public var all: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

/// The real `RunController` — the conformer that was missing.
///
/// ⚠ Deliberately tiny and stateless. Run control's job is to decide *when*; the pipeline reads the
/// signal and decides *how*. Putting the flag in a shared, lock-guarded box rather than in the
/// backend is what lets the pipeline — which runs on a detached task, off the backend's isolation —
/// read it without an await inside its poll loop.
public final class InAppRunController: RunController {

    public init() {}

    public func stopRun(researchID: String) async {
        RunStopSignal.shared.request(researchID: researchID)
        NSLog("[SR] stop requested for %@ — the run will end at its next check", researchID)
    }

    /// ⚠ Pause and resume are NOT implemented, and they say so rather than pretending.
    ///
    /// A no-op that returns silently is indistinguishable from a pause that worked, and the owner
    /// would find out only by watching a "paused" run keep going. Stop is the control that exists;
    /// these are honestly absent until the pipeline grows a resume point that can survive one.
    public func pauseRun(researchID: String) async {
        NSLog("[SR] pause is not implemented on this device — the run for %@ CONTINUES", researchID)
    }

    public func resumeRun(researchID: String) async {
        NSLog("[SR] resume is not implemented on this device (nothing here pauses) — %@", researchID)
    }
}
