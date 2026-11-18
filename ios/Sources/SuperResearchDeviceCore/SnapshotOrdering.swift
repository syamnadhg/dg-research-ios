import Foundation

/// Which device snapshot may replace the one already on screen.
///
/// ⛔ **Completion order is not issue order, and until the beat started pushing, nothing depended on
/// the difference.** Snapshots now arrive from two places: the owner's own actions (`refresh()`
/// after a toggle, an operation, the end of pairing) and the 20-second beat. A beat load issued a
/// second *before* the owner parks a worker can finish a second *after* that toggle's refresh — and
/// a bare `snapshot = await load()` would then put the stale value back on screen. The pill flips,
/// flips back, and stays wrong until the next beat.
///
/// ⚠ Its own type rather than three lines inlined in the view model, because the view model is
/// `@MainActor` UI code that no test can construct — and an ordering rule that cannot be exercised
/// is an ordering rule that will be quietly deleted by the next person who finds it puzzling.
public enum SnapshotOrdering {

    /// - Parameters:
    ///   - incoming: the arriving snapshot's issue stamp.
    ///   - applied: the stamp of the snapshot currently on screen.
    public static func shouldApply(incoming: UInt64, applied: UInt64) -> Bool {
        // ⚠ **0 always applies, and that is deliberate rather than an oversight.** Zero means
        // "unsequenced": `DeviceSnapshot.unpaired` and every test fixture carry it. Treating those
        // as stale would make an unpaired snapshot — the one that must always be honoured, because
        // it is how the UI learns the device was reset — the single snapshot that never lands.
        if incoming == 0 { return true }
        // ⛔ Strictly greater, never `>=`. Equal stamps mean the SAME read, so re-applying costs a
        // needless SwiftUI invalidation; more importantly, allowing equality would let a duplicate
        // delivery of an old snapshot win a race it had already lost.
        return incoming > applied
    }
}
