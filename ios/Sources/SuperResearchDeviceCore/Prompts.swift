import Foundation

/// What the pipeline says to a platform, and the floors it judges the answers by.
///
/// ⚠ **Ported verbatim from the backend rather than paraphrased.** P1's is a *wrapper* that asks for
/// a research brief; sending the bare topic — which both halves of this repo used to do — gets a chat
/// answer, and P2 is then fed a conversation instead of a brief.
public enum Prompts {

    /// Verbatim from the backend's Phase-1 prompt.
    ///
    /// The instruction to omit preamble is load-bearing: P1's output is pasted straight into three
    /// deep-research agents, so "Sure! Here's a brief:" would become the first line of every P2
    /// prompt.
    public static func briefPrompt(topic: String, feedback: String = "") -> String {
        let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = "Please create a detailed research report brief for a deep research LLM agent "
            + "that covers this topic: \(cleaned). Be as thorough as you can. Simply output the "
            + "research brief, no preamble or post-amble. I just need something I can copy and "
            + "paste into a research agent LLM."
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            prompt += "\n\nUSER FEEDBACK (incorporate this): \(note)"
        }
        return prompt
    }

    /// A brief shorter than this is not a brief.
    ///
    /// Guards the shape measured on the live page: a 15-character assistant turn reading
    /// `"ChatGPT said:"`, which is what an unfinished response looks like and which would otherwise
    /// be sent to three deep-research agents.
    public static let briefFloorChars = 400

    /// The backend's own tier floor. A "report" shorter than this is not a report.
    public static let reportFloorChars = 2000

    /// P2's platforms, in the order the backend runs them and the consolidated report uses.
    ///
    /// ⚠ Run **sequentially**: wall-clock is the SUM of three deep-research runs rather than the
    /// slowest of three. A documented deviation from the backend, which drives them concurrently.
    public static let p2Platforms = ["chatgpt", "gemini", "claude"]
}
