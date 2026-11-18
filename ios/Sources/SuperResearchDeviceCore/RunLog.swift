import Foundation

/// A durable, readable trace of what a run actually did.
///
/// ⭐ **Written to a FILE, not only to `NSLog`.** The device log is a stream: it has to be attached
/// before the interesting moment, it is interleaved with every other subsystem on the simulator, and
/// it is gone once the process ends. A run takes 30 to 90 minutes and the questions afterwards are
/// always the same — *which step did it stop at, what did the page look like, how long did each wait
/// take* — and none of them can be answered by a stream nobody was watching.
///
/// ⚠ **Both, deliberately.** `NSLog` keeps a live console useful while the run is watched; the file
/// is what survives to be read afterwards. Dropping either loses one of the two ways this gets used.
public final class RunLog: @unchecked Sendable {

    /// Where the file lives, so a caller can pull it off the device.
    public let url: URL
    private let queue = DispatchQueue(label: "sr.runlog")
    private let clock: @Sendable () -> Date
    private let echo: @Sendable (String) -> Void

    /// The characters of a value that get written before it is elided.
    ///
    /// ⚠ Truncated rather than omitted. A brief and a report are thousands of characters and the
    /// interesting fact about them is nearly always the LENGTH and the first line — dumping them
    /// whole makes the trace unreadable, and omitting them makes "the extractor returned something
    /// short" unanswerable.
    public static let excerptChars = 160

    public init(
        directory: URL,
        name: String,
        clock: @escaping @Sendable () -> Date = { Date() },
        echo: @escaping @Sendable (String) -> Void = { NSLog("[SR] %@", $0) }
    ) {
        self.url = directory.appendingPathComponent(name)
        self.clock = clock
        self.echo = echo
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// One line: an ISO-8601 stamp, a step name, and its detail.
    ///
    /// ⚠ The TIMESTAMP is the point of the format. "Which step was slow" is the first question of
    /// every post-run reading, and a trace of bare step names cannot answer it.
    public func write(_ step: String, _ detail: String = "") {
        append(detail.isEmpty
            ? "\(Self.stamp(clock())) \(step)"
            : "\(Self.stamp(clock())) \(step) — \(detail)")
    }

    /// A value whose SIZE matters as much as its content.
    public func excerpt(_ step: String, _ text: String) {
        let flat = text
            .replacingOccurrences(of: "\n", with: "⏎")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = flat.count <= Self.excerptChars
            ? flat : String(flat.prefix(Self.excerptChars)) + "…"
        append("\(Self.stamp(clock())) \(step) — \(text.count) chars: \(head)")
    }

    private func append(_ line: String) {
        echo(line)
        queue.sync {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A no-op sink, for the paths that take a log but are not being traced.
    public static func discarding() -> RunLog {
        RunLog(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sr-discarded-logs"),
            name: "discard.log", echo: { _ in }
        )
    }
}
