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
/// * **No Pairing group, and no Maintenance group either.** By the time Settings is reachable the
///   device is paired, so "Pair this device" was dead copy. And splitting Runtime from Maintenance
///   put Restart and Reset in different collapsed sections despite being the same kind of act on
///   the same loop, so there is now ONE group.
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

    /// The row's title, which for `version` carries the update state.
    ///
    /// ⚠ Version and Update used to be two rows, and Update's report always started by restating
    /// Version's. One row, and the TITLE is the signal — an owner scanning the list sees "Update
    /// available" without opening anything, which is the only moment the distinction matters.
    func title(updateAvailable: String?) -> String {
        guard id == "version", let updateAvailable, !updateAvailable.isEmpty else { return title }
        return "Update available — \(updateAvailable)"
    }

    /// Nil when available. Otherwise the reason it is not, phrased for the person reading it.
    func unavailableReason(supervised: Bool) -> String? {
        guard let requiresSupervised, requiresSupervised != supervised else { return nil }
        return requiresSupervised
            ? "Turn On Startup on to use this."
            : "On Startup is on, so this device already serves automatically."
    }
}

enum Operations {

    /// Everything the device can actually do, in ONE group, in the order the owner asked for.
    ///
    /// ⚠ Maintenance was folded into Runtime — owner decision 2026-08-07. Splitting them put
    /// Restart and Reset in different sections despite being the same kind of act on the same
    /// loop, and made the owner open two collapsed groups to find two adjacent controls.
    ///
    /// Order is deliberate and runs from routine to irreversible: the things you do to get the
    /// device working, then the things you do to find out why it is not, then the one that ends
    /// the relationship. `unpair` is last for the same reason it is `.destructive`.
    static let all: [Operation] = [
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
            // ⚠ Renamed from "Clear state". It IS the web app's Reset — the same act reached by
            // tapping a device's online indicator — and calling one of them something else made
            // them look like two different operations with two different outcomes.
            id: "reset", title: "Reset",
            summary: "Drop queued work and cached run state. Logins and pairing are kept.",
            risk: .destructive, group: "Runtime"),
        Operation(
            // ⚠ Version and Update merged. They were two rows answering one question — "what am I
            // running, and is that current?" — and Update's answer always began by restating
            // Version's. The TITLE carries the state: it reads "Update available" when there is
            // one. See `title(updateAvailable:)`.
            id: "version", title: "Version",
            summary: "Show the backend version running on this device, and check for a newer one.",
            risk: .safe, group: "Runtime"),
        Operation(
            id: "doctor", title: "Doctor",
            summary: "Check this device and report what is wrong.",
            risk: .safe, group: "Runtime"),
        Operation(
            id: "daemon-loop", title: "Daemon loop",
            summary: "Watch the supervisor and workers live while the app stays awake.",
            risk: .safe, group: "Runtime",
            // The supervisor IS the On Startup intent. Offering it while autostart is off would be
            // offering to supervise a device that has not agreed to be supervised.
            requiresSupervised: true),
        Operation(
            id: "collect", title: "Diagnostics",
            summary: "Bundle this device's state into a report you can share.",
            risk: .safe, group: "Runtime"),
        Operation(
            id: "unpair", title: "Unpair",
            summary: "Release this device from the account. It disappears from the web app.",
            risk: .destructive, group: "Runtime"),
    ]

    static let groups = ["Runtime"]

    static func inGroup(_ group: String) -> [Operation] {
        all.filter { $0.group == group }
    }

    static func byID(_ id: String) -> Operation? {
        all.first { $0.id == id }
    }
}
