"""Extract a Deep Research **report** — the product of P2 — from ChatGPT.

⭐ **Gate zero resolved this as H7** (recipe §3.0), and the answer is much cheaper than the DOM
route everything upstream assumed. Measured on a completed in-app run:

* the main document holds **499 characters** — chrome plus the user's own prompt;
* `[data-turn=assistant]` is the literal string ``"ChatGPT said:"``;
* the report renders inside a **cross-origin** sandbox frame whose targets accept no `Runtime`;
* but `GET /api/auth/session` → `accessToken`, then `GET /backend-api/conversation/{id}` with a
  bearer header, returns the whole conversation — and the report is sitting in it **already in
  markdown**, 65,690 characters of it.

So there is no HTML to convert, no frame to traverse and no download to intercept. The extraction is
a same-origin `fetch`, which behaves identically in Simulator Safari and in the app's web view.

⚠ **Two things this must not become.** It must not cache the access token across runs — it is a
session credential and the page's own client re-reads it. And it must not poll either endpoint: one
request per extraction, matching what the page itself does, because §0.1's bot-flag hazard applies
to anything that talks to the platform.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

#: The BE's own tier floor (`research.py:30095`). A "report" shorter than this is not a report.
REPORT_FLOOR_CHARS = 2000

#: Where the extraction result is stashed in the page.
#:
#: A global plus a poll, rather than an awaited promise, because the two halves reach the page
#: through different bridges and only this shape works on both: the inspector's `Runtime.evaluate`
#: returns an empty object for a resolved promise unless `awaitPromise` is threaded through every
#: layer, and WKWebView's `evaluateJavaScript` has its own async rules. A global is boring and
#: identical on both.
STASH = "__srReport"

#: The pure half — given a decoded conversation, pick the report.
#:
#: Kept as its own source string so it can be executed **directly** by the tests under node against
#: the real captured conversation. A guard tested only through a mock of the thing it parses is a
#: guard tested against my assumptions about the shape, and the shape here is not one anybody would
#: have guessed: the report is not in `content.parts` where every other message keeps its text, but
#: in `metadata.chatgpt_sdk.widget_state`, JSON-encoded **as a string**, under `report_message`.
PICK_REPORT_JS = """
function srPickReport(conv) {
  var mapping = (conv && conv.mapping) || {};
  var best = null;
  for (var key in mapping) {
    if (!Object.prototype.hasOwnProperty.call(mapping, key)) continue;
    var msg = mapping[key] && mapping[key].message;
    var sdk = msg && msg.metadata && msg.metadata.chatgpt_sdk;
    var raw = sdk && sdk.widget_state;
    if (!raw) continue;
    var ws;
    try { ws = (typeof raw === 'string') ? JSON.parse(raw) : raw; } catch (e) { continue; }
    var rm = ws && ws.report_message;
    var parts = (rm && rm.content && rm.content.parts) || [];
    var text = '';
    for (var i = 0; i < parts.length; i++) {
      if (typeof parts[i] === 'string') text += (text ? '\\n\\n' : '') + parts[i];
    }
    if (!text) continue;
    var cand = {
      state: 'ok', text: text, chars: text.length,
      status: ws.status || null,
      startedAt: ws.research_started_at || null,
      stoppedAt: ws.research_stopped_at || null,
      title: (ws.plan && ws.plan.title) || null
    };
    // Longest wins. A conversation can carry several widgets — a superseded plan revision, or a
    // second research turn — and "the last one I happened to iterate over" is not a choice.
    if (!best || cand.chars > best.chars) best = cand;
  }
  return best || { state: 'absent',
                   reason: 'no widget_state carrying a report_message with text' };
}
"""

#: Kick off the extraction. Returns immediately; poll `POLL_JS`.
#:
#: ⚠ **One expression, with the helper nested INSIDE it — not a declaration followed by a call.**
#: The inspector bridge evaluates as `JSON.stringify((function(){ return (EXPR); })())`, so a
#: top-level `function srPickReport(…) {…}` followed by `(function(){…})()` parses as a function
#: *expression* **invoked with the IIFE as its argument**: the extraction never runs and the bridge
#: returns the function object. Measured against the live page, which is the only place it shows up
#: — under node, where the tests define the helper themselves, both shapes work identically.
START_JS = """
(function () {
  %(pick)s
  window.%(stash)s = { state: 'pending' };
  (async function () {
    try {
      var s = await fetch('/api/auth/session', { credentials: 'include' });
      if (!s.ok) throw new Error('session HTTP ' + s.status);
      var tok = (await s.json()).accessToken;
      // ⚠ Cookies alone are NOT enough: measured, the conversation endpoint answers 404 with
      // "Log in to view this conversation." A missing token must fail loudly here rather than
      // produce that 404 and be read as "the conversation is gone".
      if (!tok) throw new Error('session carried no accessToken');
      var cid = location.pathname.split('/').pop();
      if (!cid) throw new Error('no conversation id in ' + location.pathname);
      var r = await fetch('/backend-api/conversation/' + cid,
        { credentials: 'include', headers: { Authorization: 'Bearer ' + tok } });
      if (!r.ok) throw new Error('conversation HTTP ' + r.status);
      window.%(stash)s = srPickReport(await r.json());
    } catch (e) {
      window.%(stash)s = { state: 'error', error: String(e) };
    }
  })();
  return 'started';
})()
""" % {"stash": STASH, "pick": PICK_REPORT_JS.strip()}

#: Read the state without dragging the whole report across the bridge on every poll.
POLL_JS = """
(function () {
  var r = window.%(stash)s;
  if (!r) return { state: 'missing' };
  return { state: r.state, error: r.error || null, chars: r.chars || 0,
           status: r.status || null, stoppedAt: r.stoppedAt || null,
           title: r.title || null, reason: r.reason || null };
})()
""" % {"stash": STASH}


def slice_js(offset: int, length: int) -> str:
    """Read the report in chunks. 65k in one evaluate is fine; 500k is not, and the same code path
    carries both depending on how long a report is."""
    return f"(window.{STASH}.text || '').slice({offset}, {offset + length})"


# --- the guards, ported from the backend -------------------------------------------------------

_CHECKBOX_RE = re.compile(r"^\s*[-*]?\s*\[[ xX]\]", re.MULTILINE)
_READING_SOURCE_RE = re.compile(r"^\s*Reading source \d+", re.MULTILINE)
_HEADING_RE = re.compile(r"^#{1,6}\s+\S", re.MULTILINE)
_URL_LINE_RE = re.compile(r"^\s*(?:\d+[.)]\s*)?(?:https?://|www\.)\S+\s*$", re.MULTILINE)
_CHAT_CHROME_RE = re.compile(
    r"^\s*(?:you|chatgpt|gemini|claude|notebooklm|gpt)\s+(?:said|responded)\b", re.IGNORECASE
)
_NAV_MARKERS_RE = re.compile(
    r"\b(new\s+chat|recents?|projects|search|topic\s+generator|starred|chats?\b)\b",
    re.IGNORECASE,
)


def is_sources_not_document(text: str) -> bool:
    """Is this the SOURCES checklist rather than the report? Ported from `BE research.py:24241`.

    ⚠ **Errs toward letting documents through**, exactly as the backend's does. A wrongly rejected
    report costs a retry of a *correct* extraction — and on a Deep Research run a retry costs a unit
    of a hard monthly cap. A wrongly accepted checklist costs a run that reports success with a
    plausible body, which is worse; hence the guard, but the asymmetry sets the thresholds.
    """
    if not text or len(text) < 200:
        return False

    # CHAT-TRANSCRIPT: a recorded conversation is not a report, however much prose it has.
    #
    # ⚠ This sits ABOVE the strong-document override deliberately, and the backend's comment says
    # why: a "Deep Research" tile whose body is "You said: … / Claude responded: …" has prose AND
    # headings, so the override below would wave it straight through. It is the one shape that
    # looks more like a report the longer it gets.
    chat_chrome = sum(
        1 for line in text.splitlines() if _CHAT_CHROME_RE.match(line)
    )
    if chat_chrome >= 2:
        return True

    headings = len(_HEADING_RE.findall(text))
    paragraphs = [ln for ln in text.split("\n") if len(ln.strip()) > 100]

    # STRONG-DOC override: long prose with structure is always a document.
    #
    # ⚠ **Currently redundant, and kept anyway — say so rather than pretend.** Every rejection below
    # requires `headings < 2`, and this requires `headings >= 2`, so no input can reach a negative
    # that this override would have to rescue. A mutation harness cannot kill it, which is exactly
    # the signal worth writing down: it is documentation of intent and a guard against a future
    # loosening of the thresholds below, not a live branch. The backend carries the same redundancy.
    if len(text) >= 4000 and headings >= 2 and any(len(p) >= 200 for p in paragraphs):
        return False
    if headings >= 3 and len(paragraphs) >= 5:
        return False

    lines = max(len(text.split("\n")), 1)
    checkboxes = len(_CHECKBOX_RE.findall(text))
    reading = len(_READING_SOURCE_RE.findall(text))
    if (checkboxes >= 4 or reading >= 4) and headings < 2 and len(text) < 5000 \
            and (checkboxes + reading) / lines > 0.15:
        return True

    url_lines = len(_URL_LINE_RE.findall(text))
    if url_lines >= 8 and headings < 2 and 800 <= len(text) <= 3000:
        return True
    return False


def looks_like_nav_sidebar(text: str) -> bool:
    """Is this navigation chrome? Ported from `BE research.py:24207`.

    All three conditions must hold — three distinct nav words near the top, almost no prose, and
    short overall — because any one of them alone matches real reports. A report about chat
    products says "new chat" in its first 500 characters.
    """
    if not text:
        return False
    hits = {m.group(0).lower() for m in _NAV_MARKERS_RE.finditer(text[:500])}
    if len(hits) < 3:
        return False
    if sum(1 for ln in text.split("\n") if len(ln.strip()) > 100) >= 3:
        return False
    return len(text) < 8000


@dataclass(frozen=True)
class ReportVerdict:
    ok: bool
    reason: str
    chars: int = 0


def judge_report(text: str, *, status: str | None = None) -> ReportVerdict:
    """Accept or reject an extracted report, against the pre-declared observable.

    ⚠ The status check is **not** "status says completed, therefore accept". A completed run whose
    text trips a wrong-document guard is still wrong. Both must hold.
    """
    if not text:
        return ReportVerdict(False, "no text was extracted")
    if status is not None and status != "completed":
        return ReportVerdict(False, f"the research is not finished (status={status!r})",
                             len(text))
    if len(text) < REPORT_FLOOR_CHARS:
        return ReportVerdict(False,
                             f"{len(text)} chars is under the {REPORT_FLOOR_CHARS}-char tier floor",
                             len(text))
    if is_sources_not_document(text):
        return ReportVerdict(False, "this is the sources checklist, not the document", len(text))
    if looks_like_nav_sidebar(text):
        return ReportVerdict(False, "this is navigation chrome, not the document", len(text))
    return ReportVerdict(True, "report accepted", len(text))
