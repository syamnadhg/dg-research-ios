import Foundation

// The in-app half of P2's extraction. The JavaScript is the SAME script the Python half runs
// (`emubackend/report_extract.py`) — gate zero resolved the report's location as a same-origin
// fetch, which is one of the few things that behaves identically in Simulator Safari and in the
// app's `WKWebView`.
//
// ⚠ **The script is generated from the Python module, not retyped here.** Two hand-maintained
// copies of a 40-line parser that walks an undocumented shape (`metadata.chatgpt_sdk.widget_state`,
// JSON-encoded as a *string*, `report_message.content.parts`) is a divergence waiting to happen,
// and the divergence would present as "extraction works on one surface and returns nothing on the
// other" — which is exactly the failure this repo has already paid for once with selectors.
// `bin/gen_report_js.py` regenerates it; `ReportExtractParityTests` fails if they drift.

public enum ReportExtract {

    /// Where the page stashes the result. Must match the Python half.
    public static let stash = "__srReport"

    /// The BE's tier floor. A "report" shorter than this is not a report.
    public static let floorChars = 2000

    public struct Progress: Equatable, Sendable {
        public let state: String
        public let chars: Int
        public let status: String?
        public let error: String?
        public let reason: String?

        public init(state: String, chars: Int = 0, status: String? = nil,
                    error: String? = nil, reason: String? = nil) {
            self.state = state
            self.chars = chars
            self.status = status
            self.error = error
            self.reason = reason
        }

        /// Decode one poll. Anything unreadable is `missing`, never "done" — a poller that reads an
        /// unparseable answer as completion stops waiting for a run that is still going.
        public static func decode(_ any: Any?) -> Progress {
            guard let dict = any as? [String: Any],
                  let state = dict["state"] as? String else {
                return Progress(state: "missing")
            }
            return Progress(
                state: state,
                chars: (dict["chars"] as? Int) ?? Int((dict["chars"] as? Double) ?? 0),
                status: dict["status"] as? String,
                error: dict["error"] as? String,
                reason: dict["reason"] as? String
            )
        }

        public var isTerminal: Bool { state != "pending" && state != "missing" }
    }

    public enum ExtractError: Error, Equatable {
        case pageReportedError(String)
        case noReport(String)
        case timedOut(lastState: String)
        case shortRead(expected: Int, got: Int)
    }

    /// Start the extraction, poll until it settles, then pull the report across in chunks.
    ///
    /// - Parameter sleep: injected so the tests do not spend real seconds. The **cadence matters**
    ///   for a different reason than usual here: this polls the page's own global, not the
    ///   platform, so it is not bot-flag-adjacent — but the fetch it kicks off talks to ChatGPT
    ///   exactly once, and a caller that restarted it per poll would turn one request into dozens.
    public static func extract(
        from page: any WebPage,
        pollInterval: Duration = .seconds(1),
        timeout: Duration = .seconds(45),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> String {
        _ = try await page.evaluateJSON(startJS)

        var elapsed = Duration.zero
        var last = Progress(state: "pending")
        while elapsed < timeout {
            try await sleep(pollInterval)
            elapsed += pollInterval
            last = Progress.decode(try await page.evaluateJSON(pollJS))
            if last.isTerminal { break }
        }

        switch last.state {
        case "ok":
            break
        case "error":
            throw ExtractError.pageReportedError(last.error ?? "unspecified")
        case "absent":
            throw ExtractError.noReport(last.reason ?? "no report in this conversation")
        default:
            throw ExtractError.timedOut(lastState: last.state)
        }

        // Chunked: a report is tens of thousands of characters and the conversation it came from is
        // half a megabyte. One evaluate carrying all of it is the kind of thing that works on a
        // short report and fails on the one that matters.
        var text = ""
        var offset = 0
        while offset < last.chars {
            let chunk = try await page.evaluateJSON(sliceJS(offset: offset, length: chunkChars))
            guard let piece = chunk as? String, !piece.isEmpty else { break }
            text += piece
            offset += piece.count
        }
        // ⚠ Assert the whole thing arrived. A truncated report is the worst possible outcome: it is
        // still markdown, still passes a floor check, and ships as research with its conclusions
        // missing.
        guard text.count == last.chars else {
            throw ExtractError.shortRead(expected: last.chars, got: text.count)
        }
        return text
    }

    static let chunkChars = 40_000

    public static func sliceJS(offset: Int, length: Int) -> String {
        "(window.\(stash).text || '').slice(\(offset), \(offset + length))"
    }
}
