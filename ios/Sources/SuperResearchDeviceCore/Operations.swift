import Foundation

/// The device's operation catalogue.
///
/// ⚠ **This used to be a remote control for a Mac.** Nearly every entry was `scope: .daemon`,
/// meaning "relay to a Mac-side bridge which invokes the real CLI" — and that bridge was never
/// built. The executor existed, the transport did not. So Runtime and Maintenance rendered a
/// fifteen-item list in which almost nothing did anything, the footer read *bridge offline*, and
/// tapping an action reported it "queued" for a channel that could not deliver it.
///
/// The phone **is** the backend now. Every operation below acts on this device, `OpScope` is gone
/// along with the bridge, and an entry that cannot be performed here is not listed. Three
/// consequences worth stating, because each removed something the UI used to show:
///
/// * **No Pairing group.** By the time Settings is reachable the device is paired, so "Pair this
///   device" was dead copy. `unpair` moved to Maintenance, where the rest of the device-lifecycle
///   actions already were.
/// * **No `retire`, `resurrect` or `resume`.** Retire/resurrect are the On Startup toggle — the
///   terminal's `--retire` means *disable autostart*, not *unpair*, and the old entry's summary
///   ("Unpair and mark the device retired") was the inverted-retire bug written into the copy. A
///   resumable run belongs on the main screen, not behind an operation row.
/// * **No `uninstall`, no `upgrade`.** iOS uninstalls apps itself, and `upgrade` was a straight
///   duplicate of `update`.
enum OpRisk: String, Codable {
    case safe
    /// Interrupts work in progress but nothing is lost permanently.
    case disruptive
    /// Irreversible, or loses credentials/state. Always confirmed, never one-tap.
    case destructive
}

struct Operation: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let risk: OpRisk
    let group: String
    /// When set, the operation is only usable while the On Startup toggle matches this value.
    ///
    /// Encodes the owner's rule — Start serving and Restart exist for a device that is NOT
    /// supervised, and Daemon loop only means anything for one that is — in the catalogue rather
    /// than in whichever view happens to render it. A rule living in a view is a rule the next view
    /// forgets.
    var requiresSupervised: Bool? = nil

    var requiresConfirmation: Bool { risk != .safe }

    /// Nil when available. Otherwise the reason it is not, phrased for the person reading it.
    func unavailableReason(supervised: Bool) -> String? {
        guard let requiresSupervised, requiresSupervised != supervised else { return nil }
        return requiresSupervised
            ? "Turn On Startup on to use this."
            : "On Startup is on, so this device already serves automatically."
    }
}

enum Operations {

    /// Everything the device can actually do, grouped as the owner thinks about it.
    static let all: [Operation] = [

        // ── Runtime — this device's own serving loop ─────────────────────────────
        Operation(
            id: "serve", title: "Start serving",
            summary: "Come online now and start accepting runs.",
            risk: .safe, group: "Runtime",
            // Pointless while supervised: the app already comes online by itself on open.
            requiresSupervised: false),
        Operation(
            id: "restart", title: "Restart",
            summary: "Stop the worker loop and bring it back up. In-flight work is interrupted.",
            // ⚠ NOT gated, unlike Start serving — owner correction 2026-08-07. A wedged worker loop
            // is exactly as likely on a device that starts automatically as on one that does not,
            // and on the supervised device it is *more* likely to be the only way out, because
            // nothing else there is manual.
            risk: .disruptive, group: "Runtime"),
        Operation(
            id: "daemon-loop", title: "Daemon loop",
            summary: "Keep this device awake and serving for as long as the app is open.",
            risk: .safe, group: "Runtime",
            // The supervisor IS the On Startup intent. Offering it while autostart is off would be
            // offering to supervise a device that has not agreed to be supervised.
            requiresSupervised: true),

        // ── Maintenance ──────────────────────────────────────────────────────────
        Operation(
            id: "doctor", title: "Doctor",
            summary: "Check this device and report what is wrong.",
            risk: .safe, group: "Maintenance"),
        Operation(
            id: "version", title: "Version",
            summary: "Show the backend version running on this device.",
            risk: .safe, group: "Maintenance"),
        Operation(
            id: "update", title: "Update",
            summary: "Check whether a newer backend is available.",
            risk: .safe, group: "Maintenance"),
        Operation(
            id: "collect", title: "Collect diagnostics",
            summary: "Bundle this device's state into a report you can share.",
            risk: .safe, group: "Maintenance"),
        Operation(
            id: "clear", title: "Clear state",
            summary: "Drop queued work and cached run state. Logins and pairing are kept.",
            risk: .destructive, group: "Maintenance"),
        Operation(
            id: "unpair", title: "Unpair",
            summary: "Release this device from the account. It disappears from the web app.",
            risk: .destructive, group: "Maintenance"),
    ]

    static let groups = ["Runtime", "Maintenance"]

    static func inGroup(_ group: String) -> [Operation] {
        all.filter { $0.group == group }
    }

    static func byID(_ id: String) -> Operation? {
        all.first { $0.id == id }
    }
}
