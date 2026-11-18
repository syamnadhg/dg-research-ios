import Foundation

// The end of a run: P3 finishes here, P4 and P5 finish in the cloud.
//
// ⭐ **This is the part that makes the phone consistent with every other backend**, and it was
// absent from this repo entirely — `beDone`, `needsFeTrigger` and `uploadYouTube` appeared only in
// `docs/FIRESTORE_CONTRACT.md`, never in code. Without it a finished run is invisible to the
// product AND the owner's *next* run stalls, because the queue gate waits on `beDone`.
//
// The desktop backend does exactly three things after P3, and the order is not cosmetic.

/// What the handoff needs from the outside world. A protocol so the ordering — which is the whole
/// of this file's correctness — is testable without a network or a Firestore.
public protocol HandoffTransport: Sendable {
    /// Patch the research document. `uid` names whose tree it lives in, which for a sharer's run is
    /// not the submitting user.
    func patchResearch(
        uid: String, researchId: String, set: [String: FirestoreValue]
    ) async throws
    /// Fire the cloud trigger. **Must not block** and **must not throw** — see `handOff`.
    func postUploadYouTube(researchId: String, ownerUid: String) async
}

public struct HandoffOutcome: Equatable, Sendable {
    public let beDoneWritten: Bool
    public let markerWritten: Bool
    public let triggerFired: Bool
}

public enum RunHandoff {

    /// Hand a finished run to the cloud.
    ///
    /// Three steps, in this order, and each ordering choice is load-bearing:
    ///
    /// 1. **`beDone` / `beDoneAt`.** The queue gate waits on this, so a missing `beDone` stalls the
    ///    owner's *next* run, not just this one. Written first because it is the cheapest write and
    ///    the one whose absence damages a run other than this one.
    /// 2. **`needsFeTrigger` / `needsFeTriggerAt`** — the frontend catch-up backstop, written
    ///    **synchronously and before** the POST. ⚠ Reversing 2 and 3 means a failed POST leaves no
    ///    backstop at all and the run dies silently with the audio already paid for. With the
    ///    marker down first, the chain still completes from the web app on next open even if the
    ///    POST fails entirely.
    /// 3. **The POST to `/api/uploadYouTube`**, authenticated as this device. Only `uploadYouTube`
    ///    is hit — it owns the P5 chain, and calling P5 as well would double it. The frontend's
    ///    `casRouteP4` dedups this against its own catch-up, so both triggers coexist.
    ///
    /// ⛔ **`status` is never written here.** It stays `ongoing` through `beDone`; the cloud P5
    /// chain flips it to `completed`. A phone that wrote `completed` itself would report a run
    /// finished that has no video and no email.
    ///
    /// ⚠ Step 1 failing does **not** abort steps 2 and 3. They are three independent recoveries of
    /// a run, not a transaction — dropping the marker and the trigger because a stall-prevention
    /// write failed would turn one degraded run into a dead one.
    @discardableResult
    public static func handOff(
        uid: String, researchId: String, now: Int64, transport: HandoffTransport
    ) async -> HandoffOutcome {
        var beDone = false
        var marker = false

        do {
            try await transport.patchResearch(
                uid: uid, researchId: researchId,
                set: ["beDone": .boolean(true), "beDoneAt": .integer(now)]
            )
            beDone = true
        } catch {
            NSLog("[SR] handoff: beDone write failed — the NEXT run's queue gate will stall: %@",
                  String(describing: error))
        }

        do {
            try await transport.patchResearch(
                uid: uid, researchId: researchId,
                set: ["needsFeTrigger": .boolean(true), "needsFeTriggerAt": .integer(now)]
            )
            marker = true
        } catch {
            NSLog("[SR] handoff: needsFeTrigger marker failed — the POST is now the ONLY route: %@",
                  String(describing: error))
        }

        // Detached and long-lived: the route encodes and uploads inline, up to an hour, and a
        // client disconnect can abort it mid-encode. It must neither block the run loop nor be
        // cancelled by it.
        await transport.postUploadYouTube(researchId: researchId, ownerUid: uid)
        return HandoffOutcome(beDoneWritten: beDone, markerWritten: marker, triggerFired: true)
    }
}
