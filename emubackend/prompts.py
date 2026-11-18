"""What the pipeline actually says to each platform, and how long it waits.

⚠ **Ported verbatim from the backend, which is the reference implementation.** These strings are
not stylistic: P1's is a *wrapper* that asks for a research brief, and sending the bare topic — which
is what this repo did — gets a chat answer instead of a brief, so P2 is then fed a conversation.
"""
from __future__ import annotations

#: P1's wrapper. Verbatim from `BE research.py:36045-36050`.
#:
#: ⚠ The instruction to omit preamble is load-bearing: P1's output is pasted straight into three
#: deep-research agents, so "Sure! Here's a brief:" becomes the first line of every P2 prompt.
P1_BRIEF_PROMPT = (
    "Please create a detailed research report brief for a deep research LLM agent "
    "that covers this topic: {topic}. Be as thorough as you can. Simply output the "
    "research brief, no preamble or post-amble. I just need something I can copy and "
    "paste into a research agent LLM."
)

#: Appended when the owner supplied feedback. Verbatim from `BE research.py:36052`.
P1_FEEDBACK_SUFFIX = "\n\nUSER FEEDBACK (incorporate this): {feedback}"


def brief_prompt(topic: str, feedback: str | None = None) -> str:
    """The P1 prompt for *topic*.

    ⚠ Raises on an empty topic rather than sending the bare wrapper. "Please create a research
    brief that covers this topic: ." is a request a platform will cheerfully answer, and the run
    would proceed to spend three deep-research units on the answer.
    """
    if not topic or not topic.strip():
        raise ValueError("P1 needs a topic; sending the wrapper alone yields a plausible answer "
                         "to nothing and the run would spend three DR units on it")
    prompt = P1_BRIEF_PROMPT.format(topic=topic.strip())
    if feedback and feedback.strip():
        prompt += P1_FEEDBACK_SUFFIX.format(feedback=feedback.strip())
    return prompt


#: How long to wait for a response, **keyed on the phase and not on the platform**.
#:
#: ⛔ ChatGPT is used TWICE, in two different modes, and one timeout for "chatgpt" is wrong for one
#: of them whichever value is picked: P1 runs with Deep Research OFF and answers in seconds to a
#: couple of minutes; P2 runs with it ON and takes 10–30 minutes. The 240-second default that
#: produced gate zero's bad read is generous for P1 and absurd for P2 — it expired mid-research and
#: the harvest read `Pro thinking`, 27 characters, as the report.
#:
#: The measured run behind gate zero took **8 minutes 57 seconds**; the ceiling is set well above
#: that because a longer topic legitimately takes longer, and the cost of waiting too long is a slow
#: run while the cost of waiting too little is a wrong one.
RESPONSE_TIMEOUT_SECONDS = {
    0: 60.0,      # P0 is a readiness probe, not a generation
    1: 300.0,     # the brief, Deep Research OFF
    2: 2_400.0,   # a deep-research report, 40 minutes
    3: 900.0,     # NotebookLM upload + notebook operations
}


#: Which platforms offer a DEEP RESEARCH mode on this surface.
#:
#: ⚠ **RETRACTED, 2026-08-08.** An earlier version had `claude: False`, on the strength of driving
#: its composer opener and reading a menu with no Research item. **That negative was wrong, and the
#: way it was wrong is the lesson:** Claude has a **Chat / Cowork** mode switch, and the mode was
#: never checked before the menu was read. A menu enumerated in the wrong mode says nothing about
#: the other mode — §14's *"a script-driven negative is not a negative"* applies with full force,
#: and driving the tap for real was not enough to make it one.
#:
#: The owner, who uses the product daily: *"In claude we select Opus highest so far (rn at 5). And
#: also there is chat and cowork mode please use chat. Also in '+' use 'Research'."*
DEEP_RESEARCH_AVAILABLE = {
    "chatgpt": True,
    "gemini": True,
    "claude": True,
}

#: Claude has a mode switch, and P2 needs the CHAT one.
#:
#: ⛔ Not cosmetic: Cowork is the agentic mode, whose composer menu offers files, projects, skills,
#: connectors and plugins — and no Research. A P2 that lands in Cowork cannot find the control it
#: needs, and the failure reads as a missing selector rather than as the wrong mode. That is exactly
#: the misdiagnosis recorded above.
REQUIRED_MODE = {"claude": "Chat"}


def required_mode(platform: str) -> str | None:
    """Which mode this platform must be in before P2 touches its composer, if any."""
    return REQUIRED_MODE.get(platform)


def deep_research_available(platform: str) -> bool:
    """⚠ Unknown platforms default to **False**.

    The safe direction: a platform nobody has measured is one whose research mode nobody has seen,
    and claiming a deep-research report that is actually a chat answer is the failure this exists to
    prevent.
    """
    return DEEP_RESEARCH_AVAILABLE.get(platform, False)


#: Appended to a document produced WITHOUT deep research, so the artefact carries its own provenance.
#:
#: ⚠ On the document itself rather than only in a log: the file is uploaded to NotebookLM, merged
#: into the consolidated report, and read by a human later. A caveat that lives only in a log is a
#: caveat nobody downstream ever sees.
NO_DEEP_RESEARCH_NOTE = (
    "\n\n---\n\n*Note: this section was produced in standard mode. Deep research is not "
    "available for this platform on the device that ran it, so this is a direct answer to the "
    "research brief rather than a multi-source deep-research report.*"
)


def annotate_report(platform: str, text: str) -> str:
    """Label a report that was not produced by deep research."""
    body = (text or "").rstrip()
    if not body or deep_research_available(platform):
        return body
    return body + NO_DEEP_RESEARCH_NOTE


#: P2's platforms, in the order the backend runs them and the order the consolidated report uses.
#:
#: ⚠ **Sequentially, one at a time** (decision B1) — not because it is simpler but because
#: MobileSafari has ONE foreground tab and HID taps reach only it. Wall-clock is therefore the SUM
#: of three deep-research runs, not the slowest of three. That is a documented deviation from the
#: backend, which drives all three concurrently across tabs.
P2_PLATFORMS = ("chatgpt", "gemini", "claude")

#: How the consolidated report names each agent. Ported from `BE research.py:50581`.
CONSOLIDATED_TITLES = {"chatgpt": "ChatGPT", "gemini": "Gemini", "claude": "Claude"}


def consolidated_report(topic: str, reports: dict[str, str]) -> str:
    """The fifth document: the three P2 reports merged, and what P3 actually uploads.

    ⚠ **Ordered by `P2_PLATFORMS`, never by whatever order the reports arrived in.** A dict's
    insertion order is a record of which platform happened to finish first, and a run that
    reproduces its inputs should reproduce its output.

    ⚠ **Missing platforms are skipped, not written as empty sections.** A heading with nothing under
    it reads, to anyone opening the document, as a platform that found nothing — rather than one
    that failed and was already reported as failed.
    """
    parts = [f"# Consolidated Research Report: {topic}\n"]
    for platform in P2_PLATFORMS:
        text = (reports.get(platform) or "").strip()
        if text:
            heading = CONSOLIDATED_TITLES[platform]
            if not deep_research_available(platform):
                # ⚠ In the HEADING, not a footnote: a reader scanning the contents must see
                # that one of the three sections is a different kind of thing.
                heading += " (standard mode)"
            parts.append(f"\n## {heading} Research\n\n{text}")
    return "\n".join(parts) if len(parts) > 1 else ""


def response_timeout(phase: int) -> float:
    """The wait for *phase*. Unknown phases get P1's, never P2's — erring toward a fast failure on
    a phase nobody has characterised rather than a 40-minute hang."""
    return RESPONSE_TIMEOUT_SECONDS.get(phase, RESPONSE_TIMEOUT_SECONDS[1])
