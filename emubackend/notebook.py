"""P3 — NotebookLM: a notebook holding the research, then an Audio Overview.

⭐ **The document picker never enters this design, and that is a measured result, not a shortcut.**
Item 16's blocking question was how three `.md` files could reach the iOS document picker at all.
Measured on the real signed-in page: **"Copied text" is a first-class source type**, and the page
carries **zero** `input[type=file]` elements on mobile — so the file route is not merely harder
here, it is closed, while the paste route is a supported first-class one. The backend uploads files
because Playwright can set a file input's files; nothing on this surface can.

⚠ **Two names in this product are wrong everywhere else in this repo**, both measured at the same
time: the page lives on **`notebook.google.com`** (not `notebooklm.google.com`), and it renders as
**"Gemini Notebook"** (not "NotebookLM"). A selector or host lookup keyed on the old names finds
nothing at all, which presents as "the platform is signed out".
"""
from __future__ import annotations

#: Where the notebook UI actually lives.
#:
#: ⚠ `notebooklm.google.com` redirects here, but a *page lookup* — which matches on the host of an
#: already-open page — never sees the pre-redirect host. `bin/drive_selectors.py` and
#: `bin/capture_selectors.py` still carry the old one.
HOST = "notebook.google.com"

#: The source type P3 uses. Matched by TEXT rather than by a selector because the sheet's controls
#: carry icon-font ligatures in their text (`content_paste\nCopied text`) and no stable test id.
SOURCE_TYPE_TEXT = "Copied text"

#: A notebook needs a source before an Audio Overview can be generated from it.
MIN_SOURCE_CHARS = 200


class NotebookError(RuntimeError):
    """P3 could not do something it must do. Raised rather than returned: a run that reaches P3 has
    already spent three deep-research units, and silently producing no podcast would report success
    on a run with nothing to deliver."""


def notebook_title(topic: str, *, limit: int = 100) -> str:
    """The notebook's name.

    ⚠ Named after the topic rather than left as "Untitled note". Every P3 run creates a **permanent**
    notebook in the owner's real Google account and there is no cleanup step anywhere in the backend
    or in this plan, so an account accumulating a hundred notebooks called "Untitled note" is a real
    cost of getting this wrong.
    """
    cleaned = " ".join((topic or "").split())
    if not cleaned:
        raise NotebookError("a notebook needs a title; an untitled one is unfindable later")
    return cleaned[:limit]


def source_text(topic: str, consolidated: str) -> str:
    """What gets pasted as the notebook's single source.

    The consolidated report — the three P2 reports already merged under named headings — rather than
    three separate sources. One paste is one interaction; three are three chances for a sheet to
    close early, and the audio overview is generated from the notebook as a whole either way.
    """
    body = (consolidated or "").strip()
    if len(body) < MIN_SOURCE_CHARS:
        raise NotebookError(
            f"the consolidated report is {len(body)} chars, under the {MIN_SOURCE_CHARS}-char "
            f"minimum for a source. Generating an Audio Overview from it would produce a podcast "
            f"about nothing."
        )
    return body


#: The Audio Overview variant table, in NotebookLM's own words.
#:
#: ⭐ Measured from the production backend's `_variant_label`, which drives its log copy, its
#: narration and its agent prompt from one place. Kept here as well as in `AudioLength.swift`
#: because a device that picks `Deep Dive` where the desktop picks `Brief` produces a podcast of the
#: wrong shape while every step reports success — and `test_notebook.py` asserts the two agree.
#:
#: ⛔ `short` is a DIFFERENT FORMAT TILE, not a shorter Deep Dive, and it has **no separate length
#: step**. A flow that always sets format-then-length hunts for a control that is not on screen.
AUDIO_VARIANTS = {
    "short": ("Brief", None),
    "default": ("Deep Dive", "Default"),
    "long": ("Deep Dive", "Long"),
}

#: Is the Audio Overview ready? — the MEASURED, markup-specific predicate.
#:
#: ⭐ Pinned from the desktop's own DOM dump, and the pinning is the point: the selectors this
#: replaced gated on an ``<audio>`` element and a progressbar inside an article card, **none of
#: which exist** in the live Studio panel, so that check *"could NEVER fire"* and completion
#: detection rested entirely on a vision agent. The live panel renders a "Generating Audio
#: Overview…" placeholder while in flight, then an ``artifact-library-item`` bearing the
#: ``audio_magic_eraser`` icon ligature.
#:
#: ⚠ This is the primary; :data:`AUDIO_READY_JS` below is the generic player-based fallback, and it
#: is explicitly NOT sufficient on its own for the reason above.
AUDIO_COMPLETE_JS = """
(() => {
  const cont = document.querySelector('artifact-library, .artifact-library-container')
    || document.body;
  const contText = cont.innerText || cont.textContent || '';
  if (/generating audio overview/i.test(contText)) return false;
  for (const el of document.querySelectorAll('artifact-library-item')) {
    if (el.offsetParent === null) continue;
    if ((el.innerText || el.textContent || '').includes('audio_magic_eraser')) return true;
  }
  return false;
})()
"""

#: Is the Audio Overview ready? — the generic fallback.
#:
#: ⚠ **Asks for a positive signal, and treats an unreadable page as NOT ready.** The generation takes
#: up to ninety minutes (`PHASE_3_AUDIO_MAX_MIN=90`), so the cost of a false "ready" is a run that
#: reports a podcast it does not have, while the cost of a false "not ready" is more waiting. Those
#: are not symmetrical.
AUDIO_READY_JS = """
(() => {
  const norm = s => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
  const body = norm(document.body && document.body.innerText);
  // The player's own controls are the positive signal — text like "Audio Overview" is present from
  // the moment the card is created, long before anything can be played.
  const player = document.querySelector('audio, [role="slider"][aria-label*="progress" i]');
  const playing = [...document.querySelectorAll('button,[role=button]')].some(b => {
    const label = norm(b.getAttribute('aria-label') || b.innerText);
    return label === 'play' || label.startsWith('play ');
  });
  const generating = /generating|loading|creating|preparing/.test(body);
  return { ready: (!!player || playing) && !generating,
           hasPlayer: !!player, hasPlay: playing, generating };
})()
"""


def audio_is_ready(state: dict | None) -> bool:
    """Judge the readiness probe. Anything unreadable is NOT ready."""
    if not isinstance(state, dict):
        return False
    return bool(state.get("ready"))
