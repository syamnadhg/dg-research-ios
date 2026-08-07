import Foundation

/// The backend's terminal surface, as a fixed catalogue.
///
/// The owner's ask was full parity with what they manage via the BE terminal, so this enumerates it
/// from the real CLI (37 flags in `research.py`). Two properties make that safe to expose over a
/// network channel, and both are structural rather than advisory:
///
/// 1. **A closed enum mapped to literal argv.** No string is ever interpolated into a command line.
///    A remote channel that executed arbitrary text would be remote code execution on the owner's
///    Mac dressed up as a feature — so the wire format carries an *operation id*, and the argv it
///    maps to is a compile-time constant.
/// 2. **`scope` is explicit.** An iOS app can genuinely do the `.device` operations itself. The
///    `.daemon` ones act on the Mac's process and filesystem and are impossible from the phone
///    alone — they are relayed to a bridge that runs on the Mac and invokes the CLI. Marking that
///    in the type means the UI can never present a daemon action as if the phone were doing it.
enum OpScope: String, Codable {
    /// The phone can perform this against Firestore on its own.
    case device
    /// Must be relayed to the Mac-side bridge, which invokes the real CLI.
    case daemon
}

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
    let scope: OpScope
    let risk: OpRisk
    /// The literal argv the bridge runs. **Never** built from user input.
    let argv: [String]
    let group: String

    var requiresConfirmation: Bool { risk != .safe }
}

enum Operations {

    /// Everything the terminal exposes, grouped as the owner thinks about it rather than as the
    /// flags happen to be ordered.
    static let all: [Operation] = [

        // ── Pairing — the phone owns these outright ──────────────────────────────
        Operation(
            id: "pair", title: "Pair this device",
            summary: "Get a pair code and claim it from the web app.",
            scope: .device, risk: .safe, argv: ["--pair"], group: "Pairing"),
        Operation(
            id: "unpair", title: "Unpair",
            summary: "Drop this device's credentials. It disappears from the web app.",
            scope: .device, risk: .destructive, argv: ["--unpair"], group: "Pairing"),
        Operation(
            id: "retire", title: "Retire",
            summary: "Unpair and mark the device retired so it is not offered again.",
            scope: .device, risk: .destructive, argv: ["--retire"], group: "Pairing"),

        // ── Runtime — the Mac's own process ──────────────────────────────────────
        Operation(
            id: "serve", title: "Start serving",
            summary: "Run the backend worker loop.",
            scope: .daemon, risk: .safe, argv: ["--serve"], group: "Runtime"),
        Operation(
            id: "restart", title: "Restart",
            summary: "Stop and re-launch the backend. In-flight work is interrupted.",
            scope: .daemon, risk: .disruptive, argv: ["--restart"], group: "Runtime"),
        Operation(
            id: "resurrect", title: "Resurrect",
            summary: "Re-register autostart and bring the supervisor back up.",
            scope: .daemon, risk: .disruptive, argv: ["--resurrect"], group: "Runtime"),
        Operation(
            id: "resume", title: "Resume run",
            summary: "Pick up an interrupted run where it stopped.",
            scope: .daemon, risk: .safe, argv: ["--resume"], group: "Runtime"),
        Operation(
            id: "daemon-loop", title: "Daemon loop",
            summary: "Run the supervisor loop in the foreground.",
            scope: .daemon, risk: .safe, argv: ["--daemon-loop"], group: "Runtime"),

        // ── Maintenance ──────────────────────────────────────────────────────────
        Operation(
            id: "doctor", title: "Doctor",
            summary: "Run diagnostics and report what is wrong.",
            scope: .daemon, risk: .safe, argv: ["--doctor"], group: "Maintenance"),
        Operation(
            id: "version", title: "Version",
            summary: "Report the installed backend version.",
            scope: .daemon, risk: .safe, argv: ["--version"], group: "Maintenance"),
        Operation(
            id: "update", title: "Update",
            summary: "Fetch and install a newer backend.",
            scope: .daemon, risk: .disruptive, argv: ["--update"], group: "Maintenance"),
        Operation(
            id: "upgrade", title: "Upgrade",
            summary: "Upgrade the backend in place.",
            scope: .daemon, risk: .disruptive, argv: ["--upgrade"], group: "Maintenance"),
        Operation(
            id: "collect", title: "Collect diagnostics",
            summary: "Bundle logs and state for support.",
            scope: .daemon, risk: .safe, argv: ["--collect"], group: "Maintenance"),
        Operation(
            id: "clear", title: "Clear state",
            summary: "Wipe queued work and cached state.",
            scope: .daemon, risk: .destructive, argv: ["--clear"], group: "Maintenance"),
        Operation(
            id: "uninstall", title: "Uninstall",
            summary: "Remove the backend and its autostart entry from this machine.",
            scope: .daemon, risk: .destructive, argv: ["--uninstall"], group: "Maintenance"),

        // ── Platform logins — the emulator setup the owner wants to drive ────────
        Operation(
            id: "login", title: "Seed platform logins",
            summary: "Open each platform so you can sign in once. Sessions persist afterwards.",
            scope: .daemon, risk: .safe, argv: ["--login"], group: "Platforms"),
    ]

    static let groups = ["Pairing", "Runtime", "Maintenance", "Platforms"]

    static func inGroup(_ group: String) -> [Operation] {
        all.filter { $0.group == group }
    }

    static func byID(_ id: String) -> Operation? {
        all.first { $0.id == id }
    }

    /// Resolve a wire-format operation id to its argv.
    ///
    /// The bridge calls **only** this. An unknown id yields `nil` rather than anything executable,
    /// which is what keeps a malformed or hostile command document inert instead of dangerous.
    static func argv(forID id: String) -> [String]? {
        byID(id)?.argv
    }
}
