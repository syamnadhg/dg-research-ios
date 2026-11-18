"""Data-driven P0–P3 phase bodies.

The structural point of this module, and the reason it can exist before anyone has logged into a
platform: **a phase body describes a sequence, the manifest describes what the steps are on
mobile.** "Tap the composer, type the brief, tap send, wait for a response, harvest the sources" is
knowable now. *Which element is the composer on mobile Safari* is not — that needs real logged-in
DOM. So the browser layer is not one indivisible ~24k-line block gated on a login; it is code that
can be written and tested now plus data that arrives later.

Two disciplines are structural here rather than optional:

* **Every mutating step goes through :func:`emubackend.intents.guarded_intent`** with an
  ``outcome_predicate`` — that is phase A1 under A8, where wrapping is a design property rather
  than a retrofit.
* **Every extraction is judged by a harvest-shaped predicate**, not by "did we get something".
  Read drift is the dominant failure class, and the P1 incident is the proof: every click landed and
  extraction returned zero for an entire run, which a non-empty check passes happily.

An unresolved selector raises. It does **not** skip the step. A silent skip reports success on a
page nothing touched, which is the failure mode this whole layer is built to make impossible.
"""

from __future__ import annotations

import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import Any

from emubackend import harvest, intents, prompts, report_extract
from emubackend.selectors import ManifestError, SelectorEntry, SelectorManifest

#: A brief shorter than this is not a brief.
#:
#: Well under P2's 2000-char report floor, because a brief legitimately is much shorter than a
#: report — but not zero, and not a refusal. The number this guards against is the one measured on
#: the live page: a 15-character assistant turn reading ``"ChatGPT said:"``, which is what an
#: unfinished response looks like and which would otherwise be sent to three deep-research agents.
_BRIEF_FLOOR_CHARS = 400

#: The sentinel meaning "no explicit override — use the phase's own timeout".
#:
#: The historical default, kept as the sentinel value so every existing caller that does not pass
#: one now gets the PHASE-appropriate wait instead of 240 seconds for everything — which is the
#: number that expired mid-deep-research and produced gate zero's bad read.
_DEFAULT_RESPONSE_TIMEOUT = 240.0

#: Reads the deep-research toggle's real state. Ported from the backend's ``_GEMINI_DR_STATE_JS`` and
#: ``_cgpt_state_js`` rather than reinvented, because both carry fixes for failures already observed on
#: real platforms — see :meth:`PlatformDriver._toggle_state` for what they were.
#:
#: Takes the control's accessible name because it differs per platform: "research" on Claude, "deep
#: research" on ChatGPT and Gemini. Getting that wrong is not a near miss — searching Claude for "deep
#: research" finds nothing at all.
_TOGGLE_STATE_JS = """((name) => {
    const norm = s => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
    const target = norm(name);

    // The composer, lowest-on-screen first. Anchored deliberately: reading any old placeholder picks
    // up a stale modal's, and the backend records that exact misread.
    let ce = document.querySelector('rich-textarea div[contenteditable="true"]')
          || document.querySelector('#prompt-textarea')
          || document.querySelector('[data-testid="chat-input"]')
          || null;
    if (!ce) {
        const cands = [...document.querySelectorAll(
            'div[contenteditable="true"][data-placeholder], textarea[placeholder],'
            + ' div[contenteditable="true"][aria-label]')].filter(e => e.offsetParent);
        if (cands.length) {
            cands.sort((a, b) => b.getBoundingClientRect().top - a.getBoundingClientRect().top);
            ce = cands[0];
        }
    }
    let placeholder = '';
    if (ce) {
        placeholder = norm(ce.getAttribute('data-placeholder')
            || ce.getAttribute('placeholder') || ce.getAttribute('aria-label'));
    }
    const placeholderResearch = placeholder.includes('research')
        || placeholder.includes('what do you want to');
    // The platform asserting ordinary chat mode. `chat with` is here because ChatGPT's real composer
    // placeholder is "Chat with ChatGPT" — measured while driving its toggle, where the guessed
    // "ask chatgpt" matched nothing and ChatGPT could therefore never report confirmed_off. That is the
    // safe direction (escalation stays refused) but it also blocks legitimate recovery forever, so a
    // guard that can never say "off" is only half a guard.
    const placeholderChat = placeholder.includes('ask gemini') || placeholder.includes('ask chatgpt')
        || placeholder.includes('chat with') || placeholder.includes('write a message')
        || placeholder.includes('write your prompt')
        || placeholder.includes('message ');

    // Scoped to the form: an unscoped text search matches tooltips and help copy, which the backend
    // notes false-positived this check once already.
    const scope = (ce && ce.closest('form')) || document.querySelector('form') || document.body;
    // A pill is an INDICATOR, so it must not be the control itself.
    //
    // Without this the toggle becomes its own on-signal whenever it is visible and labelled with the
    // feature's name — and then `enable_deep_research` reports "already enabled", never taps, and the
    // run proceeds with deep research off. Measured on the mock platform, whose toggle sits in the form
    // carrying `aria-pressed`: the predicate returned True while aria-pressed went false -> false. The
    // P1 shape exactly, produced by the very check meant to prevent it.
    //
    // The distinction that separates them is state, not tag: a control carries `aria-pressed` /
    // `aria-checked` / `aria-selected`, an indicator carries none. Verified against real ChatGPT both
    // ways — its menu item has `aria-checked` (excluded, correctly, it is the control) while its active
    // composer pill has no state attribute at all (kept).
    let pill = null;
    for (const p of scope.querySelectorAll('button, [role="button"], span, div')) {
        if (!p.offsetParent) continue;
        if (p.hasAttribute('aria-pressed') || p.hasAttribute('aria-checked')
            || p.hasAttribute('aria-selected')) continue;
        if (norm(p.textContent) === target) { pill = p; break; }
    }
    let pressed = false, pillCls = '';
    if (pill) {
        pillCls = (pill.className || '').toString().toLowerCase();
        pressed = pill.getAttribute('aria-pressed') === 'true'
            || pill.getAttribute('aria-selected') === 'true'
            || pill.getAttribute('aria-checked') === 'true'
            || pill.getAttribute('data-active') === 'true'
            || pillCls.includes('--selected') || pillCls.includes('selected')
            || pillCls.includes('active') || pillCls.includes('--filled');
    }
    return { pillVisible: !!pill, pressed, placeholderResearch, placeholderChat,
             placeholder: placeholder.slice(0, 60), pillCls: pillCls.slice(0, 100) };
})(%s)"""

__all__ = [
    "PhaseDeps",
    "PlatformDriver",
    "build_phase_bodies",
    "classify_response",
    "resolve",
]

#: Is the popup this opener controls currently open?
#:
#: Asked of the OPENER rather than of the thing inside the popup, because the thing inside can outlive
#: the popup: activating ChatGPT's "Deep research" menu item leaves a "Deep research" pill in the
#: composer, so a text-matched target stays findable and a target-based check can never see the menu
#: close. Measured attributes on chatgpt.com's ``composer-plus-btn``: ``aria-expanded`` false/true,
#: ``data-state`` closed/open, and ``aria-controls`` naming the popup element.
#:
#: The ordering is deliberate: a NEGATIVE state attribute is decisive and checked first, because the
#: generic fallback ("is any popup container on screen") is the weakest signal and would otherwise
#: report a *different* component's open dialog as this opener's menu.
_POPUP_STATE_JS = """((openerCss) => {
    const op = document.querySelector(openerCss);
    if (!op) return {open: false, why: 'the opener itself is gone'};
    const expanded = op.getAttribute('aria-expanded');
    const state = op.getAttribute('data-state');
    if (expanded === 'false' || state === 'closed') {
        return {open: false, why: expanded === 'false' ? 'aria-expanded=false' : 'data-state=closed'};
    }
    if (expanded === 'true' || state === 'open') {
        return {open: true, why: expanded === 'true' ? 'aria-expanded=true' : 'data-state=open'};
    }
    // No state of its own. Prefer the element it explicitly names over guessing.
    const id = op.getAttribute('aria-controls');
    const popup = id ? document.getElementById(id) : null;
    if (popup) return {open: !!popup.offsetParent, why: 'aria-controls target visibility'};
    const containers = [...document.querySelectorAll('[role=menu],[role=listbox],[role=dialog]')]
        .filter(m => !!m.offsetParent);
    return {open: containers.length > 0, why: containers.length + ' visible popup container(s)'};
})(%s)"""


#: Is the platform still working on the answer?
#:
#: Ported from the backend's ``is_agent_generating`` rather than invented, selector sets included. It is
#: the POSITIVE in-flight signal, and it is what distinguishes "the text stopped changing because the
#: answer is finished" from "the text stopped changing because the placeholder has not changed yet".
#:
#: ⚠ Measured on live ChatGPT with deep research on: the assistant turn read ``Pro thinking`` — 27
#: characters — and held that for well over six seconds while ``Stop answering`` was on screen. Content
#: stability accepted it as complete, the harvest found nothing, and the run reported read drift about
#: selectors that were correct. Stability is a necessary condition for completion, never a sufficient
#: one; only the platform can say it has stopped.
#:
#: ⚠ Gemini's entry is broader on purpose, carrying the backend's own caveat (#897b): its collapsed
#: composer often shows NO stop button mid-run, so a stop-button-only check reads a live deep-research
#: run as finished.
_GENERATING_SELECTORS = {
    "chatgpt": (
        'button[data-testid="stop-button"], button[aria-label*="Stop"], [data-testid*="loading"]'
    ),
    "gemini": (
        'button[aria-label*="Stop"], [role="button"][aria-label*="stop" i], '
        '[jsname] [role="progressbar"], [data-is-streaming="true"], '
        ".loading-indicator, .streaming"
    ),
    "claude": 'button[aria-label*="Stop"], [data-testid*="stop"]',
    "notebooklm": 'button[aria-label*="Stop"], [role="progressbar"]',
}
_GENERATING_FALLBACK = 'button[aria-label*="Stop"]'


class PlatformStateError(RuntimeError):
    """The PAGE is in a failed state — distinct from our selectors being wrong.

    Kept separate from ``ManifestError`` because the two demand opposite responses. A manifest error means
    the selector rotted and the agent should try to repair it. This means the selector is fine and the
    platform failed, so repairing anything would be chasing a healthy target — the recipe's "escalate onto
    a healthy page" failure, arrived at by mis-attributing the fault.
    """


#: Platform-side error banners, verbatim from what the platform rendered.
#:
#: Fragments rather than whole strings, and matched case-insensitively, because the surrounding copy
#: changes far more readily than the phrase does. Each entry is something OBSERVED, not imagined — the
#: imagined list (human-verification prompts, quota modals, mid-wait logout) contained none of these, and
#: the first real deep-research attempt hit two of them.
PLATFORM_ERROR_FRAGMENTS = (
    "error loading app",
    "failed to fetch template",
    "something went wrong",
    "an error occurred",
    "please try again",
    "network error",
    "you've reached your limit",
    "usage limit",
    "rate limit",
    "verify you are human",
)

#: The label a platform offers alongside its own error, so a report can say recovery was available.
RECOVERY_LABELS = ("retry", "try again", "regenerate", "reload")

#: A turn holding nothing but the platform's own speaker prefix is EMPTY, not content.
#:
#: Measured: six minutes of `'ChatGPT said: '` and nothing else. Stripped before the emptiness test,
#: because a naive `len(text) > 0` reads that as an answer — which is the whole trap.
#: The backend's literal modal sweep, ported verbatim (`BE research.py:33598-33599`).
#:
#: ⭐ **Deliberately small.** The backend has NO cookie-banner, consent, onboarding, "Not now" or
#: "Try Pro" dismissal either — it explicitly tells its vision agent that a cookie banner is *not* a
#: login wall. So the missing general dismisser is a far smaller gap than a repo-wide grep for
#: `modal|dialog|overlay|consent` suggests, and building a general one would be inventing behaviour
#: the reference implementation deliberately does not have.
SWEEP_LABELS = ("okay", "got it", "dismiss")

#: ...plus the one attribute selector the backend sweeps alongside those labels.
SWEEP_CSS = '[aria-label="Close"]'

#: The gates that actually matter, because they BLOCK a phase rather than merely cover it.
#:
#: ⚠ These are not modals to be swept away — they are controls the run must PRESS to proceed, and
#: pressing the wrong one skips the research instead of starting it. Gemini shows "Start research"
#: after accepting a deep-research prompt and does nothing until it is pressed; Claude offers "Skip"
#: on its own setup step. Sweeping them with the generic dismisser would be the worst outcome: the
#: phase reports success and no research ever starts.
PLATFORM_GATES = {
    "gemini": "Start research",
    "claude": "Skip",
}


def sweep_targets(labels: list[str], platform: str) -> list[str]:
    """Which visible control labels the sweep should press, in order.

    ⚠ **A platform GATE is never swept.** It is returned as a gate for the caller to press
    deliberately, not lumped in with dismissals — see `PLATFORM_GATES`.

    ⚠ **The gate exclusion below is currently REDUNDANT, and is kept anyway — say so rather than
    pretend it is live.** No gate label appears in `SWEEP_LABELS` today, so nothing can reach it and
    no mutation of it can be caught. It is a second lock on the door because the first one is easy
    to open by accident: "Skip" looks exactly like a dismissal, and adding it to the sweep list is a
    plausible future edit that would make a phase report success while no research ever started.
    The invariant that keeps this honest — no gate may appear in the sweep list — IS tested.
    """
    gate = PLATFORM_GATES.get(platform, "").lower()
    out = []
    for label in labels:
        low = " ".join((label or "").split()).lower()
        if not low or low == gate:
            continue
        if low in SWEEP_LABELS:
            out.append(label)
    return out


def gate_for(platform: str, labels: list[str]) -> str | None:
    """The blocking control this platform is showing, if it is on screen."""
    gate = PLATFORM_GATES.get(platform)
    if not gate:
        return None
    for label in labels:
        if " ".join((label or "").split()).lower() == gate.lower():
            return label
    return None


SPEAKER_PREFIXES = ("chatgpt said:", "claude said:", "gemini said:", "you said:")

#: Deep research often replies with a CLARIFYING QUESTION before starting, and today that answer
#: passes every check: it is content, it is stable, and generation has stopped. The harvest then
#: finds no report and the run reports a SELECTOR problem — when the platform simply asked something
#: and is waiting.
#:
#: ⚠ Matched near the END of the text, not anywhere in it. A finished report legitimately contains
#: question marks and the phrase "before I begin" inside its own prose; a clarifying question is
#: the LAST thing on screen. Matching anywhere would classify a real report as a question and
#: discard it — the expensive direction, since the report cost a deep-research unit.
CLARIFYING_MARKERS = (
    "before i start",
    "before i begin",
    "could you clarify",
    "can you clarify",
    "a few questions",
    "some questions",
    "to make sure i",
    "which of these",
    "would you like me to",
    "should i focus",
    "let me know",
)

#: How much of the tail is examined for those markers.
CLARIFYING_TAIL_CHARS = 400

#: A clarifying question is SHORT. A 60,000-character report ending with "let me know if you'd like
#: more detail" is a report, and treating it as a question throws away the run's product.
CLARIFYING_MAX_CHARS = 2500




def classify_response(text: str) -> dict:
    """Sort a response container's text into ``content`` / ``empty`` / ``error``.

    Split out as a free function so it is testable without a page, a Simulator or a platform — the
    classification is the interesting part and it should not need any of those to be pinned.

    Error is checked FIRST. An error banner is non-empty text, so an emptiness-first order would classify
    ``Error loading app`` as content and hand it to the harvester as research.
    """
    raw = " ".join((text or "").split())
    low = raw.lower()
    for fragment in PLATFORM_ERROR_FRAGMENTS:
        if fragment in low:
            offered = [label for label in RECOVERY_LABELS if label in low]
            return {
                "state": "error",
                "matched": fragment,
                "recovery_offered": offered,
                "text": raw[:200],
            }
    stripped = low
    for prefix in SPEAKER_PREFIXES:
        if stripped.startswith(prefix):
            stripped = stripped[len(prefix):].strip()
    if not stripped:
        return {"state": "empty", "text": raw[:200]}

    # ⭐ The FOURTH state. Checked before `content` because a clarifying question IS content by every
    # structural measure — that is precisely why it slipped through and got reported as read drift.
    if len(stripped) <= CLARIFYING_MAX_CHARS:
        tail = stripped[-CLARIFYING_TAIL_CHARS:]
        for marker in CLARIFYING_MARKERS:
            if marker in tail:
                return {
                    "state": "question",
                    "matched": marker,
                    "chars": len(stripped),
                    "text": raw[:200],
                }
    return {"state": "content", "chars": len(stripped), "text": raw[:200]}


async def resolve(page: Any, entry: SelectorEntry) -> Any | None:
    """Find the element an entry describes, trying its CSS chain then its text.

    The chain exists because platforms A/B-test their DOM, so a single selector is a single point of
    failure on a surface we do not control. Order is significant: the first match wins, so a
    manifest should list its most specific selector first.
    """
    for css in entry.css:
        found = await page.query_selector(css)
        if found is not None:
            return found
    if entry.text_contains:
        # Text is the fallback for structure that moves but labels that do not. Deliberately
        # last — matching on copy is fragile in the opposite direction (an i18n change breaks it).
        #
        # ⚠ Menu roles are in this list for a measured reason. ChatGPT's deep-research control is a
        # `[role=menuitem]` inside the composer's plus menu, carrying no testid and no id — text is the
        # ONLY handle it has. With the old `button, a, [role=button]` list it could never be found, so
        # the one platform whose control had just been located would still have reported "no selector".
        #
        # ⛔ `menuitemcheckbox` is here because Claude's Research control IS one — measured in-app
        # 2026-08-08, `role=menuitemcheckbox aria-checked=false`, with a generated `id` that must
        # never be used as a handle. Omitting the role made the entry unresolvable no matter how
        # correct the manifest was, and the failure presents as "this platform has no Research
        # mode" — which is exactly the wrong conclusion this project already drew once.
        candidates = await page.query_selector_all(
            "button, a, [role=button], [role=menuitem], [role=menuitemradio], "
            "[role=menuitemcheckbox], [role=option]"
        )
        for handle in candidates:
            try:
                text = await handle.inner_text()
            except Exception:
                continue
            if entry.text_contains.lower() in (text or "").lower():
                return handle
    return None


@dataclass
class PhaseDeps:
    """What a phase body needs, injected so bodies are testable without a Simulator."""

    manifest: SelectorManifest
    registry: intents.IntentRegistry
    history: harvest.HarvestHistory
    #: platform key -> a PageShim-shaped object.
    pages: dict[str, Any] = field(default_factory=dict)
    topic: str = ""
    #: Optional owner feedback, appended to P1's wrapper prompt.
    feedback: str = ""
    #: ⭐ P1's product and P2's input. Empty until P1 has captured it — and P2 refuses to run
    #: without it rather than falling back to the topic, because that fallback is invisible: three
    #: deep-research units get spent and the run reports success on the wrong prompt.
    brief: str = ""
    #: platform -> its P2 markdown report. Populated one platform at a time as P2 completes each.
    reports: dict[str, str] = field(default_factory=dict)
    #: The three reports merged — the fifth document, and the one P3 uploads.
    consolidated: str = ""
    #: Recorded per platform so a caller can see what actually happened rather than inferring it.
    log: list[str] = field(default_factory=list)


class PlatformDriver:
    """The mutating steps for one platform, each already wrapped.

    Registers its intents on construction so an intent's predicate exists before anything can run
    it — an intent registered lazily at first use would have no bake history and could never
    accumulate one honestly.
    """

    def __init__(self, platform: str, deps: PhaseDeps):
        self.platform = platform
        self.deps = deps
        self.page = deps.pages.get(platform)
        self._register()

    # -- predicates --------------------------------------------------------------

    async def _present(self, key: str) -> bool:
        entry = self.deps.manifest.entry(self.platform, key)
        if not entry.resolvable or self.page is None:
            return False
        return await resolve(self.page, entry) is not None

    async def logged_in(self) -> bool:
        """The per-platform logged-in marker.

        ⚠ Deliberately a manifest entry rather than a hardcoded check: the recipe warns that the
        desktop sidebar markers *collapse on mobile*, so reusing them would report a logged-out
        page as logged in.
        """
        return await self._present("logged_in_marker")

    async def composer_focused(self) -> bool:
        if self.page is None:
            return False
        active = await self.page.evaluate("document.activeElement && document.activeElement.tagName")
        return bool(active)

    async def response_present(self) -> bool:
        """The send's outcome predicate: was the send ACCEPTED — not, did the response finish.

        ⚠ **This distinction was found by running against a real Simulator, and the fake-substrate
        tests could not have found it, because the fake had no latency.** A response arrives
        hundreds of milliseconds to minutes after the tap. A predicate that asserts *completion*
        therefore cannot be true at the moment it is evaluated, so it reports a **false failure on
        every single run** — and with acting enabled it would escalate an agent onto a perfectly
        healthy page every time, which is the precise failure mode the recipe calls worse than the
        crash it replaces.

        So ``response_container`` must match the container in **any** state (running, streaming,
        complete). Waiting for completion is a separate, explicit wait — not this predicate's job.
        """
        return await self._present("response_container")

    async def response_health(self) -> dict:
        """Classify what is actually IN the response container: content, empty, or a platform error.

        The first two entries in the agent's real failure catalogue, both measured on live ChatGPT and
        neither on the imagined list of human-verification prompts, quota modals and mid-wait logouts:

        * **the feature's own sub-app failed to load** — the assistant turn read
          ``Error loading app  Failed to fetch template  Retry``. Not a network error and not an
          automation error: the platform offered its own recovery control.
        * **a retry that succeeds as a click and produces nothing** — clicking that ``Retry`` cleared the
          error and left the turn *empty for six minutes*.

        Both defeat presence-based judgement, and that is the point. ``response_present`` is deliberately
        true for a container in *any* state, because asserting completion at send time reports a false
        failure on every run. The cost of that correctness is that presence alone cannot tell a streaming
        answer from an error banner from six minutes of nothing — so the run needs a second, separate
        question, asked later. This is it.

        Returns a classification rather than a bool because the three outcomes need different handling: a
        run continues on ``content``, waits on ``empty``, and must **stop rather than harvest** on
        ``error``. Harvesting an error banner as research is the failure this exists to prevent — and it
        is worse than crashing, because the output looks like an answer.
        """
        if self.page is None:
            return {"state": "absent", "reason": "no page"}
        entry = self.deps.manifest.entry(self.platform, "response_container")
        if not entry.resolvable:
            return {"state": "absent", "reason": "response_container not captured"}
        handle = await resolve(self.page, entry)
        if handle is None:
            return {"state": "absent", "reason": "container did not resolve"}
        text = (await handle.inner_text()) or ""
        return classify_response(text)

    # -- intents -----------------------------------------------------------------

    def _register(self) -> None:
        keys = self.deps.manifest.platforms.get(self.platform, {})

        def add(name: str, predicate, *, confirmed_off=None, reversible=False) -> None:
            intent_id = f"{self.platform}.{name}"
            try:
                self.deps.registry.get(intent_id)
            except KeyError:
                self.deps.registry.register(
                    intents.Intent(
                        id=intent_id,
                        platform=self.platform,
                        description=f"{name} on {self.platform}",
                        outcome_predicate=predicate,
                        confirmed_off=confirmed_off,
                        reversible=reversible,
                    )
                )

        add("focus_composer", self.composer_focused)
        add("send", self.response_present)
        for toggle in ("deep_research_toggle", "research_toggle"):
            if toggle in keys:
                # A toggle is the one genuinely reversible+verifiable shape, so it is the only kind
                # eligible to ever escalate live — and it needs a POSITIVE off-signal, because a
                # false-negative predicate driving a toggle would switch a live control OFF.
                add(
                    toggle,
                    self._toggle_on_predicate(toggle),
                    confirmed_off=self._toggle_off_predicate(toggle),
                    reversible=True,
                )

    async def _toggle_state(self, key: str) -> dict:
        """Read the deep-research toggle's REAL state — placeholder, pill, and pressed-ish markers.

        Ported from the backend's own predicates, which are richer than the ARIA attributes this used
        to read and richer for a reason it paid for. From
        ``dg-research-backend/research.py::_GEMINI_DR_STATE_JS``, verbatim:

            the DR pill's class (mat-tonal-button…) carries NO reliable pressed marker, so a
            pressed-class-only check false-negatived an ACTIVE pill last E2E and the CUA fallback then
            toggled the working DR OFF

        That is precisely what this method used to do. ``aria-pressed`` is absent on all three
        platforms' research controls, so the old reader returned False on a page where deep research
        was *on*; the run then either tapped it off, or shadowed the failure and produced a shallow
        answer under a deep-research label. Neither is visible in the output.

        The signals the backend actually uses (``selfheal_intents.json`` outcome predicates
        ``cgpt_state:active``, ``gemini_dr_state:placeholderResearch||pressed``,
        ``claude_research_tool:on``):

        * **the composer placeholder** — the most reliable of the three, because it is the platform
          telling you which mode it is in. Gemini swaps "Ask Gemini" for "What do you want to
          research", and that flip is both an on-signal and, in the other direction, a *positive*
          off-signal.
        * **a visible pill whose text is exactly the control's name** — scoped to the form, because an
          unscoped ``innerText.includes('deep research')`` false-positives on tooltips and help copy
          (a bug the backend also records fixing).
        * **pressed-ish attributes and classes** — ``aria-pressed``/``aria-selected``/``data-active``
          plus ``--selected``/``selected``/``active``/``--filled`` in the class list. Kept last and
          treated as corroboration, never as the sole signal.
        """
        if self.page is None:
            return {"on": False, "off": False, "reason": "no page"}
        # The CONTROL's own state, read from the manifest's selector rather than from a text scan.
        #
        # The third signal, and it cannot come from the pill: the pill scan deliberately skips anything
        # carrying `aria-pressed`/`aria-checked` (an indicator has no state, a control does), so a
        # `pressed` derived from the pill is structurally always false. Omitting the control's own
        # attribute therefore left a page whose ONLY signal is the toggle's `aria-pressed` with no signal
        # at all — measured on the mock platform, where the tap correctly flipped false -> true and the
        # predicate still said off. Copying `_cgpt_state_js` verbatim is what caused it: the backend's
        # `pressed` is about the pill, and its platforms happen to supply other evidence.
        control_on = control_off = False
        entry = self.deps.manifest.entry(self.platform, key)
        if entry.resolvable:
            handle = await resolve(self.page, entry)
            if handle is not None:
                state = await handle.get_attribute("aria-pressed")
                if state is None:
                    state = await handle.get_attribute("aria-checked")
                control_on = state == "true"
                control_off = state == "false"

        # Interpolated rather than passed as an argument: `PageShim.evaluate` takes a single
        # expression, so a two-arg call type-errors against the real page and only shows up at runtime.
        name = "research" if self.platform == "claude" else "deep research"
        raw = await self.page.evaluate(_TOGGLE_STATE_JS % json.dumps(name))
        if not isinstance(raw, dict):
            return {"on": control_on, "off": control_off, "reason": "state probe returned nothing"}
        placeholder_research = bool(raw.get("placeholderResearch"))
        placeholder_chat = bool(raw.get("placeholderChat"))
        pill_visible = bool(raw.get("pillVisible"))
        # Three independent ways a platform says "on", and each is the ONLY one somewhere:
        # the control's own attribute (the mock, and any well-behaved toggle), a visible indicator pill
        # (real ChatGPT, whose menu item is gone once the menu closes), the composer placeholder (Gemini).
        on = control_on or pill_visible or placeholder_research
        return {
            "on": on,
            # A positive off-signal, never `not on`. The control reporting itself unpressed, or the
            # composer saying "ask gemini", are both the platform asserting chat mode. "Cannot tell"
            # stays false, so escalation is refused rather than guessed.
            "off": (control_off or placeholder_chat) and not on,
            "placeholder": raw.get("placeholder"),
            "pillVisible": pill_visible,
            "pressed": control_on,
        }

    def _toggle_on_predicate(self, key: str):
        async def _p() -> bool:
            # The manifest entry still has to resolve — a key with no captured selector must not
            # report "on" off the back of a placeholder alone, or an uncaptured platform would look
            # configured.
            entry = self.deps.manifest.entry(self.platform, key)
            if not entry.resolvable:
                return False
            return bool((await self._toggle_state(key)).get("on"))

        return _p

    def _toggle_off_predicate(self, key: str):
        async def _p() -> bool:
            """A POSITIVE off-signal: the control exists and reports itself off.

            Not `not on`. If the control cannot be found at all we return False, so an unfindable
            toggle is never treated as confirmed-off — which is what stops a rotted selector from
            authorising a click that would turn a live control off.
            """
            if self.page is None:
                return False
            entry = self.deps.manifest.entry(self.platform, key)
            handle = await resolve(self.page, entry) if entry.resolvable else None
            if handle is None:
                return False
            return bool((await self._toggle_state(key)).get("off"))

        return _p

    # -- actions -----------------------------------------------------------------

    async def _open_then_find(self, entry: SelectorEntry, timeout: float = 8.0):
        """Tap the target's ``opener`` and then POLL for the target.

        ⚠ Polled, not read once, and the reason is measured rather than defensive: ChatGPT's plus menu
        renders in **two passes** — a first paint with 3 items, then the tools/connectors section
        arriving asynchronously to make 19, with ``Deep research`` at index 7. A single read after the
        opener tap sees the 3-item menu and concludes the control does not exist on mobile. I drew that
        exact wrong conclusion twice from script-driven samples before a real HID tap showed all 19.
        """
        if not entry.opener:
            return None
        opener = await self.page.query_selector(entry.opener)
        if opener is None:
            raise ManifestError(
                f"{self.platform}: the opener {entry.opener!r} did not match anything, so the "
                f"control it guards can never be reached. An opener that has gone missing is a "
                f"read-drift signal about the opener, not about the target."
            )
        await opener.click()
        deadline = time.monotonic() + timeout
        while True:
            handle = await resolve(self.page, entry)
            if handle is not None:
                return handle
            if time.monotonic() >= deadline:
                return None
            await asyncio.sleep(0.3)

    async def _popup_open(self, opener_css: str) -> dict:
        """Ask the OPENER whether its popup is open."""
        return await self.page.evaluate(_POPUP_STATE_JS % json.dumps(opener_css)) or {}

    async def _dismiss_opener(self, entry: SelectorEntry, timeout: float = 6.0) -> bool:
        """Close the opener's popup and VERIFY it closed.

        Needed because an open menu is not merely untidy — it **covers the send button**, so the very
        next phase taps the overlay instead and fails for a reason that points at send. Measured: the
        first time the opener mechanism landed it regressed the run twice this way.

        ⚠ The question is asked of the **opener**, not of the target, and the first version got that
        wrong in a way real ChatGPT exposed immediately. It tested "is the target still findable" as a
        proxy for "is the menu still open" — but enabling deep research CREATES a "Deep research" pill
        in the composer, and the manifest entry for that control is a text match with no css. So the
        proxy stayed true forever: the run's own **success signal** was being read as evidence of
        failure, and P2 aborted after correctly doing everything it was asked to do.

        The opener has a real answer. Measured on chatgpt.com: ``composer-plus-btn`` carries
        ``aria-expanded`` (``false`` -> ``true``) and ``data-state`` (``closed`` -> ``open``), plus
        ``aria-controls`` naming the popup. Those describe the popup itself rather than standing in for
        it.
        """
        if not entry.opener:
            return True
        deadline = time.monotonic() + timeout
        while True:
            state = await self._popup_open(entry.opener)
            if not state.get("open"):
                return True
            if time.monotonic() >= deadline:
                return False
            await self.page.keyboard.press("Escape")
            await asyncio.sleep(0.4)

    async def await_composer_ready(
        self, timeout: float = 20.0, settle: float = 1.0
    ) -> bool:
        """Wait until the composer is present, interactable, and STILL THERE a moment later.

        ⚠ **Readiness is not a one-time fact.** Enabling deep research on ChatGPT changes the URL, and
        the composer re-mounts — so a run that established readiness once, at the top, then types into
        a handle from before the navigation, types into nothing.

        The predicate names the composer specifically and nothing else. An earlier version asked a
        *chain* (marker or composer or …), which is right for resolution and wrong for readiness: any
        weak member satisfies it, so a splash shell with a logged-in marker and no composer reported
        ready.

        ⚠ ``settle`` is the third time this codebase has learned that presence is not enough —
        ``ensure_runtime_stable`` and ``await_response`` are the other two. Measured: on the run where
        deep research went off -> on, readiness passed, and ``type_brief`` then died with
        ``StaleHandleError: the node was removed or the page navigated``. The composer was there when
        asked and gone a moment later, because the activation's re-mount had not finished churning. A
        composer that survives a settle window is one the next step can actually use.
        """
        entry = self.deps.manifest.entry(self.platform, "composer")
        if not entry.resolvable or self.page is None:
            return False
        deadline = time.monotonic() + timeout
        present_since: float | None = None
        while True:
            ready = False
            handle = await resolve(self.page, entry)
            if handle is not None:
                try:
                    ready = bool(await handle.is_visible())
                # ⚠ RuntimeError, not Exception. A handle going stale between resolve and read is an
                # ordinary race during a re-mount — that is what this tolerates (StaleHandleError is a
                # RuntimeError). A bare `except Exception` also swallowed AttributeError, which turned
                # "this page object is missing is_visible" into "the composer never became ready" —
                # a wiring bug reported as a platform symptom, and it cost four test failures to see.
                except RuntimeError:
                    ready = False
            if not ready:
                present_since = None
            elif present_since is None:
                present_since = time.monotonic()
            elif time.monotonic() - present_since >= settle:
                return True
            if time.monotonic() >= deadline:
                return False
            await asyncio.sleep(0.4)

    async def _tap(self, key: str) -> None:
        entry = self.deps.manifest.require(self.platform, key)
        handle = await resolve(self.page, entry)
        opened = False
        if handle is None and entry.opener:
            # The manifest declares a two-step path for a reason: the control is inside a CLOSED menu,
            # so "did not match anything" is the expected first reading, not a failure.
            handle = await self._open_then_find(entry)
            opened = handle is not None
        if handle is None:
            raise ManifestError(
                f"{self.platform}.{key} did not match anything on the page. Selectors tried: "
                f"{list(entry.css)}"
                + (f", text~={entry.text_contains!r}" if entry.text_contains else "")
                + (
                    f" — including after tapping its opener {entry.opener!r}"
                    if entry.opener
                    else ""
                )
            )
        await handle.click()
        if opened and not await self._dismiss_opener(entry):
            raise ManifestError(
                f"{self.platform}.{key}: tapped it, but its opener's popup would not close. Leaving "
                f"it open breaks the NEXT phase — an open menu covers the send button, so send taps "
                f"the overlay and the failure reads as a send problem."
            )

    async def focus_composer(self) -> intents.IntentOutcome:
        return await intents.guarded_intent(
            self.deps.registry, f"{self.platform}.focus_composer", lambda: self._tap("composer")
        )

    async def type_brief(self, text: str, attempts: int = 3) -> None:
        """Fill the composer, re-querying it if it is replaced mid-fill.

        ⚠ The retry is the error message's own instruction, not a shrug. ``fill`` is three round trips
        (tap to focus, select-all, insert), and a composer re-mounting between any two of them fails
        with ``StaleHandleError: the node was removed or the page navigated and the runtime was
        re-injected; re-query the selector``. Measured on real ChatGPT immediately after deep research
        went off -> on. Re-querying is exactly the prescribed response, and doing it here is what makes
        the churn a non-event instead of a failed run.

        Bounded, because an unbounded retry against a composer that keeps vanishing is an infinite loop
        wearing a fix. Three attempts, then the stale error propagates with its own diagnosis intact.
        """
        entry = self.deps.manifest.require(self.platform, "composer")
        for attempt in range(attempts):
            handle = await resolve(self.page, entry)
            if handle is None:
                raise ManifestError(f"{self.platform}.composer vanished before typing")
            try:
                # fill() focuses by a real trusted tap and then uses the editor-aware path, which is
                # what ProseMirror-style composers require — a plain value assignment leaves their
                # model empty and the send control disabled.
                await handle.fill(text)
                return
            except RuntimeError:
                # StaleHandleError is a RuntimeError; ManifestError is a ValueError, so this cannot
                # swallow a manifest problem.
                if attempt == attempts - 1:
                    raise
                await self.await_composer_ready()

    async def send(self) -> intents.IntentOutcome:
        return await intents.guarded_intent(
            self.deps.registry, f"{self.platform}.send", lambda: self._tap("send")
        )

    async def enable_deep_research(self) -> intents.IntentOutcome | None:
        """Ensure deep research is ON. **Idempotent** — this is not "tap the toggle".

        ⚠ The distinction is the whole correctness of this step, and getting it wrong is silent.
        Deep-research state **persists across sessions** on the real platforms, and persistent login is
        the entire premise of this initiative — so the second run of any device finds the toggle already
        on. An unconditional tap then switches it **OFF**; the on-predicate correctly fails; escalation
        is correctly not permitted (shadow-only), so nothing recovers it; and the run proceeds to do a
        full P0–P3 with deep research disabled while reporting success. The output is a shallow answer
        that looks like a normal one.

        Found by running the e2e a second time — the first run left the mock's toggle on, exactly as a
        real platform would. It is invisible to a single run against fresh state, which is what every
        earlier run of this gate was.
        """
        for key in ("deep_research_toggle", "research_toggle"):
            if key not in self.deps.manifest.platforms.get(self.platform, {}):
                continue
            # Checked before acting, with the same predicate that would judge the action. Reusing it
            # means the "already on" test cannot drift from the "is it on now" test.
            if await self._toggle_on_predicate(key)():
                return intents.IntentOutcome(
                    intent_id=f"{self.platform}.{key}",
                    predicate_passed=True,
                    reason="already enabled — not tapped, because tapping would disable it",
                )
            return await intents.guarded_intent(
                self.deps.registry,
                f"{self.platform}.{key}",
                lambda k=key: self._tap(k),
            )
        return None

    async def start_research_if_offered(self, timeout: float = 90.0, poll: float = 2.0) -> bool:
        """Press the plan-confirmation control, if this platform has one.

        ⛔ **Measured on a live Gemini deep-research run.** Sending does not start the research: the
        platform replies with a ~1,200-character research PLAN and stops. Generation ends, the text
        is stable and entirely plausible, so the wait completes and the extractor harvests the plan
        as the report — a document about what it was going to research, shipped as research.

        ⚠ **Polled, not read once.** The plan takes tens of seconds to arrive, so a single look right
        after send finds nothing and concludes the platform has no such step — which is precisely
        how this went unnoticed until a run was watched end to end.

        ⚠ **Absence is not a failure.** ChatGPT and Claude have no plan stage, so a platform with no
        captured entry returns False immediately. Returning False also covers "the control never
        appeared", and the caller treats both as "carry on" — the wait and the report judge are what
        catch a genuinely stalled run.
        """
        # ⚠ Membership first. `entry()` RAISES for an unknown key, and `start_research` is not even
        # an allowed key on the platforms that have no plan stage — so asking directly turns "this
        # platform starts on send" into a manifest error mid-run.
        if "start_research" not in self.deps.manifest.platforms.get(self.platform, {}):
            return False
        entry = self.deps.manifest.entry(self.platform, "start_research")
        if not entry.resolvable:
            return False
        deadline = time.monotonic() + timeout
        while True:
            handle = await resolve(self.page, entry)
            if handle is not None:
                # ⚠ This NAVIGATES — the URL gains a conversation id and the inspector connection
                # drops. That is the success path, not an error, so the click is not treated as
                # fatal if the transport dies underneath it.
                try:
                    await handle.click()
                except Exception:
                    pass
                return True
            if time.monotonic() >= deadline:
                return False
            await asyncio.sleep(poll)

    async def extract_response(self) -> str:
        """The assistant's answer as text — P1's brief.

        ⚠ **This is the P1 path only, and it is a different mechanism from P2's.** With deep
        research OFF the answer is an ordinary chat turn in the main document, so reading the
        response container is right. With it ON the answer is not in the main document at all
        (gate zero: 499 chars of chrome, the report in a cross-origin frame) and P2 uses the
        conversation fetch instead. One `extract` for both would work in testing — where the
        composer is driven with DR off — and return a speaker prefix in production.
        """
        entry = self.deps.manifest.entry(self.platform, "response_container")
        if entry is None:
            raise ManifestError(
                f"{self.platform}: no response_container captured, so there is nothing to read "
                f"the brief out of."
            )
        for css in entry.css:
            handles = await self.page.query_selector_all(css)
            if not handles:
                continue
            # The LAST turn: the container matches every assistant turn in the conversation, and on
            # a re-run the earlier ones are still there.
            text = await handles[-1].inner_text()
            if text and text.strip():
                return text.strip()
        return ""

    async def extract_report(self, poll: float = 1.0, timeout: float = 45.0) -> str:
        """P2's product: the full markdown report.

        ⭐ **ChatGPT takes a different route from the other two, and that is measured, not
        stylistic.** Gate zero established that with Deep Research ON the report is not in the main
        document at all — 499 characters of chrome, the report inside a cross-origin frame whose
        targets accept no script. It IS reachable as markdown over a same-origin fetch, so ChatGPT
        goes that way and needs no HTML conversion.

        ⚠ **Claude and Gemini have NOT been measured**, so they keep the DOM read. That is an
        assumption, and it is written down as one rather than hidden: if their reports also live
        somewhere the response container cannot see, this returns something short and the floor
        rejects it — which is a visible failure rather than a plausible wrong report.
        """
        if self.platform == "chatgpt":
            await self.page.evaluate(report_extract.START_JS)
            waited = 0.0
            state: dict = {}
            while waited < timeout:
                await asyncio.sleep(poll)
                waited += poll
                raw = await self.page.evaluate(report_extract.POLL_JS)
                # ⚠ Defensive on purpose: a page that answers with something other than the stash
                # object — an older injection, a navigation mid-poll — must not crash the run with
                # an AttributeError three frames down. Anything unreadable is "keep waiting", never
                # "done".
                state = raw if isinstance(raw, dict) else {}
                if state.get("state") not in ("pending", "missing", None):
                    break
            if state.get("state") != "ok":
                self.deps.log.append(
                    f"p2:{self.platform}:fetch_failed:"
                    f"{state.get('state')}:{state.get('error') or state.get('reason')}"
                )
                return ""
            chars = int(state.get("chars") or 0)
            out = []
            offset = 0
            while offset < chars:
                chunk = await self.page.evaluate(report_extract.slice_js(offset, 40_000))
                if not chunk:
                    break
                out.append(chunk)
                offset += len(chunk)
            text = "".join(out)
            # A truncated report is still markdown and still clears the floor — it would ship as
            # research with its conclusions missing.
            if len(text) != chars:
                self.deps.log.append(
                    f"p2:{self.platform}:short_read:{len(text)}/{chars}"
                )
                return ""
            return text
        return await self.extract_response()

    async def disable_deep_research(self) -> intents.IntentOutcome | None:
        """Ensure deep research is OFF, for P1. **Idempotent, and NOT a second tap.**

        ⛔ **Tapping the toggle again ADDS A SECOND TOOL.** The backend's own hotspot hint
        (`1a-disable-dr`, `BE research.py:11396-11399`) says it in as many words: *"REMOVE it by
        pressing Backspace in the empty message box; do NOT click the 'Deep research' tool (clicking
        adds a second one)"*. A mirror-of-enable implementation leaves P1 in a worse state than it
        started, and every symptom of that is downstream and confusing.

        ⚠ **This is a live bug, not a gap.** Deep-research state persists across sessions — that is
        the premise of persistent login — so run 2's P1 begins with DR still on from run 1's P2, and
        a P1 that runs in deep-research mode returns a 30-minute report where a brief was wanted.
        The run does not fail; it produces the wrong artefact and continues.

        Checked before acting with the same predicate that judges the result, so "already off"
        cannot drift from "off now".
        """
        for key in ("deep_research_toggle", "research_toggle"):
            if key not in self.deps.manifest.platforms.get(self.platform, {}):
                continue
            # ⚠ Reuses the SHARED state reader — the one that already knows a research control
            # carries no reliable `aria-pressed`, and that a positive off-signal is not `not on`.
            # A second, simpler reader written here would be a fourth opinion on a question three
            # platforms already answer differently, and it shadowed the real one when I tried.
            state = await self._toggle_state(key)
            if state.get("off"):
                return intents.IntentOutcome(
                    intent_id=f"{self.platform}.{key}.disable",
                    predicate_passed=True,
                    reason="already off — not touched, because tapping would add a second tool",
                )
            if not state.get("on"):
                # Neither a positive on nor a positive off. **Refuse.** Proceeding on "cannot tell"
                # is how P1 runs in deep-research mode and returns a 30-minute report where a brief
                # was wanted — the run does not fail, it produces the wrong artefact.
                return intents.IntentOutcome(
                    intent_id=f"{self.platform}.{key}.disable",
                    predicate_passed=False,
                    reason=(
                        "the platform reports neither deep-research ON nor a positive OFF, so this "
                        "cannot tell whether P1 would run in the wrong mode "
                        f"(placeholder={state.get('placeholder')!r})"
                    ),
                )
            # Backspace into the EMPTY composer. Empty matters: with text present the keystroke
            # deletes a character of the prompt instead of the pill, which looks like nothing
            # happening and quietly corrupts what gets sent.
            await self.focus_composer()
            for _ in range(3):
                await self.page.key("Backspace")
                state = await self._toggle_state(key)
                if state.get("off"):
                    return intents.IntentOutcome(
                        intent_id=f"{self.platform}.{key}.disable",
                        predicate_passed=True,
                        reason="pill removed with Backspace",
                    )
            return intents.IntentOutcome(
                intent_id=f"{self.platform}.{key}.disable",
                predicate_passed=False,
                reason=(
                    "the Deep research pill survived three Backspaces. NOT falling back to a tap: "
                    "a tap adds a second tool rather than removing this one."
                ),
            )
        return None

    async def is_generating(self) -> bool:
        """Is the platform still producing the answer? Its own controls decide, not our text reading.

        ⛔ **VISIBILITY, not mere presence — measured on a COMPLETED Gemini deep-research run.** The
        page said "I've completed your research" and the finished report was in the DOM, while a
        `Stop response` button was *still present* at **height 0**. A selector-only check therefore
        reported "still generating" forever: the wait can never complete, the run burns its entire
        timeout on a report that is already sitting there, and it then reports a timeout — which
        invites someone to raise the budget for a condition no amount of waiting fixes.

        ⚠ This is the in-flight probe, so its failure direction matters: a false POSITIVE stalls a
        healthy run. A retired control left in the DOM is common enough that presence alone cannot
        mean in-flight.
        """
        if self.page is None:
            return False
        css = _GENERATING_SELECTORS.get(self.platform, _GENERATING_FALLBACK)
        # Rendered-size test rather than `offsetParent`: a `position: fixed` control has a null
        # offsetParent while being perfectly visible, and stop buttons are routinely fixed.
        js = (
            "(() => [...document.querySelectorAll(%s)].some(e => {"
            "  const r = e.getBoundingClientRect();"
            "  const s = getComputedStyle(e);"
            "  return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';"
            "}))()" % json.dumps(css)
        )
        return bool(await self.page.evaluate(js))

    async def await_response(
        self,
        timeout: float = 240.0,
        stable_for: float = 6.0,
        poll: float = 1.0,
    ) -> dict:
        """Wait for the response to be **complete**, and say why the wait ended.

        ⚠ This did not exist, and its absence was invisible for exactly as long as the only platform was
        the mock. ``p3_harvest`` ran immediately after ``p2``'s send; the mock answers in under a second,
        so sources were always there. A real deep-research run takes minutes — the same code harvests an
        empty container, and ``harvest.judge`` then reports read drift, sending the agent to repair
        selectors that were never wrong.

        Two accept signals and one veto, and every one of the three was earned by a measured failure:

        * ``[data-state=complete]`` — decisive where it exists, but **mock-only** among the platforms
          measured here. Trusting it exclusively means waiting the full timeout on every real run.
        * **content stability** — the text stops changing. Which is why the empty guard below is not
          belt-and-braces: an empty container is *perfectly stable*, and live ChatGPT produced a turn
          that stayed empty for six minutes after a Retry click that "succeeded". Stability without
          content is the signature of that failure, not evidence of completion.
        * ⚠ **the platform's own in-flight control vetoes both** (:meth:`is_generating`). Stability is a
          necessary condition for completion and never a sufficient one. Measured on live ChatGPT with
          deep research on: the assistant turn read ``Pro thinking`` — 27 characters — and held it for
          more than six seconds while ``Stop answering`` was on screen. Both guards above were satisfied
          by a page that had not started answering: non-empty, and stable. The harvest then found
          nothing and the run reported read drift about selectors that were correct. The text can lie
          about being finished; the stop button cannot.

        Errors are raised early rather than waited out: the platform saying "Failed to fetch template"
        will not become an answer in another four minutes, and burning the timeout hides the reason.
        """
        entry = self.deps.manifest.entry(self.platform, "response_container")
        if not entry.resolvable or self.page is None:
            return {"done": False, "reason": "response_container not captured"}
        deadline = time.monotonic() + timeout
        last_text: str | None = None
        stable_since: float | None = None
        polls = 0
        while True:
            polls += 1
            # ⚠ Asked BEFORE any accept signal is considered, because it overrides all of them. A
            # platform that says it is still working is still working, whatever the DOM text looks like.
            generating = await self.is_generating()
            if generating:
                # The clock restarts: time spent generating is not time spent stable.
                stable_since = None
            handle = await resolve(self.page, entry)
            if handle is not None and not generating:
                state = await handle.get_attribute("data-state")
                if state == "complete":
                    return {"done": True, "reason": "data-state=complete", "polls": polls}
                text = (await handle.inner_text()) or ""
                # Asked periodically rather than every poll: it is a whole-container text read, and a
                # 240s wait at 1s polls would run it 240 times to catch a condition that does not
                # arrive mid-second.
                if polls % 10 == 0:
                    health = classify_response(text)
                    if health["state"] == "error":
                        raise PlatformStateError(
                            f"{self.platform}: the platform reported an error while we waited "
                            f"(matched {health['matched']!r}"
                            + (
                                f", recovery offered: {health['recovery_offered']}"
                                if health.get("recovery_offered")
                                else ", no recovery control offered"
                            )
                            + f"). Waiting out the remaining timeout would hide the reason."
                        )
                # ⚠ `or stable_since is None` is load-bearing, not defensive. The clock is reset every
                # time generation resumes — and it used to be settable ONLY by a text CHANGE, so after a
                # reset on an unchanging placeholder there was nothing left to restart it and the wait
                # could never complete. Found by the test that asserts WHEN completion happens: whenever
                # there is no clock, start one.
                if text != last_text or stable_since is None:
                    last_text, stable_since = text, time.monotonic()
                elif (
                    stable_since is not None
                    # ⛔ The empty guard, and it asks the CLASSIFIER rather than `text.strip()`.
                    # A bare strip only catches whitespace, but the shape measured on the live page
                    # was a speaker prefix — "ChatGPT said:" — which is non-empty text that stays
                    # perfectly stable forever. It sailed through stability, was accepted as the
                    # answer, and became the brief three deep-research agents were given.
                    #
                    # ⚠ ONLY `empty` is refused here. `question` and `error` are deliberately allowed
                    # to complete the wait, because each has a caller downstream that raises a
                    # SPECIFIC, actionable diagnosis — a clarifying question waiting for an answer,
                    # or a platform error with its recovery control. Refusing them here would replace
                    # both with a generic timeout and lose the reason.
                    and classify_response(text)["state"] != "empty"
                    and time.monotonic() - stable_since >= stable_for
                ):
                    return {
                        "done": True,
                        "reason": f"content stable for {stable_for}s",
                        "polls": polls,
                        "chars": len(text),
                    }
            if time.monotonic() >= deadline:
                return {
                    "done": False,
                    "reason": (
                        f"still not complete after {timeout}s"
                        + (
                            " — the platform is STILL GENERATING, so this is a timeout that wants a"
                            " longer budget, not a broken page"
                            if generating
                            else " — the container is present but EMPTY, which is the shape of a"
                            " platform-side stall rather than a slow answer"
                            # ⚠ Classified, not stripped, for the same reason the completion gate
                            # is: the measured stall is a SPEAKER PREFIX, which is non-empty text.
                            # A strip-based test here blames the clock ("still not complete after
                            # Ns"), which invites a longer timeout for a condition that no amount of
                            # waiting resolves.
                            if last_text is not None
                            and classify_response(last_text)["state"] == "empty"
                            else ""
                        )
                    ),
                    "polls": polls,
                    "generating": generating,
                }
            await asyncio.sleep(poll)

    async def harvest_sources(self) -> harvest.HarvestVerdict:
        # Check the response's HEALTH before extracting anything from it.
        #
        # Wired here rather than left as a library function, because the failure it prevents happens at
        # exactly this call. Measured on live ChatGPT: the deep-research sub-app failed with "Error
        # loading app / Failed to fetch template / Retry", and the assistant turn containing that banner
        # resolves perfectly. Extracting from it harvests the error text AS RESEARCH — a run that reports
        # success with a plausible-looking body, which is worse than a crash because nothing surfaces it.
        #
        # Raised, not returned as an empty harvest. An empty harvest is a *read drift* signal and would
        # send the agent to repair selectors that are working correctly; the page is the problem, and the
        # verdict has to say so. `recovery_offered` travels with it because the platform gave a Retry
        # control, and "it failed, and there was a Retry" is actionable where "it failed" is not.
        health = await self.response_health()
        # ⭐ A clarifying question is not a harvest failure, and saying so is the whole point.
        #
        # It passes the wait — it is content, it is stable, generation has stopped — and then finds
        # no report. Reported as read drift, that sends the next session to repair selectors which
        # are working perfectly, while the platform sits waiting for an answer nobody gave it.
        if health["state"] == "question":
            raise PlatformStateError(
                f"{self.platform}: the platform asked a CLARIFYING QUESTION and is waiting for an "
                f"answer — it did not fail (matched {health.get('matched')!r}). Text: "
                f"{health.get('text')!r}"
            )
        if health["state"] == "error":
            raise PlatformStateError(
                f"{self.platform}: the platform reported an error instead of a response "
                f"(matched {health['matched']!r}"
                + (
                    f", recovery offered: {health['recovery_offered']}"
                    if health.get("recovery_offered")
                    else ", no recovery control offered"
                )
                + f"). Text: {health['text']!r}"
            )
        # ⛔ An EMPTY turn is not something to harvest sources out of, and it is not read drift.
        #
        # The measured shape is a container holding only a speaker prefix. Harvesting it finds zero
        # sources, which reports as a selector problem and sends the next session to repair selectors
        # that are working perfectly — the same misdiagnosis the question and error branches above
        # exist to prevent. The page produced nothing; say that.
        if health["state"] == "empty":
            raise PlatformStateError(
                f"{self.platform}: the response container is EMPTY — there is nothing to harvest. "
                f"This is a platform-side stall, not a selector failure. Text: {health.get('text')!r}"
            )
        entry = self.deps.manifest.require(self.platform, "sources")

        async def _extract() -> list[str]:
            handles = []
            for css in entry.css:
                handles = await self.page.query_selector_all(css)
                if handles:
                    break
            out = []
            for handle in handles:
                try:
                    out.append(await handle.inner_text())
                except Exception:
                    continue
            return out

        items = await _extract()
        return harvest.judge(f"{self.platform}.sources", items, self.deps.history)


# --------------------------------------------------------------------------------------
# the phase bodies
# --------------------------------------------------------------------------------------


def build_phase_bodies(
    deps: PhaseDeps,
    platforms: tuple[str, ...],
    *,
    response_timeout: float = _DEFAULT_RESPONSE_TIMEOUT,
):
    """Return P0–P3 bodies bound to *deps*, suitable for :func:`emubackend.pipeline.run_pipeline`.

    ``response_timeout`` is a parameter rather than a constant because the two platforms these bodies
    run against differ by an order of magnitude — the mock answers in under a second, a real
    deep-research run takes minutes. Hardcoding the real value makes every mock gate wait minutes to
    fail; hardcoding the mock value makes every real run fail at 20 seconds.
    """

    drivers = {p: PlatformDriver(p, deps) for p in platforms}

    def _phase_timeout(phase: int) -> float:
        """The wait for *phase*, honouring an explicit override.

        ⚠ Hardcoding `prompts.response_timeout(phase)` here — which the first version of the
        phase-keyed timeouts did — silently disables the injected value that exists so a mock gate
        does not wait forty minutes to fail. It does not break a run; it makes every failing test
        hang, which is worse than a wrong number because nobody reads it as a defect.
        """
        if response_timeout != _DEFAULT_RESPONSE_TIMEOUT:
            return response_timeout
        return prompts.response_timeout(phase)

    async def p0_verify(_ctx) -> None:
        """P0 — confirm every platform is logged in before committing to a run.

        Checked up front because discovering it in P2 wastes the whole brief phase, and because a
        logged-out page usually *renders* — so without an explicit marker check the run proceeds and
        fails much later for a reason that looks unrelated.
        """
        for name, driver in drivers.items():
            if not await driver.logged_in():
                raise ManifestError(
                    f"{name} is not logged in (or its logged_in_marker has not been captured "
                    f"from real mobile DOM yet). ⚠ Do NOT reuse the desktop sidebar markers — "
                    f"they collapse on mobile and would report a logged-out page as logged in."
                )
            deps.log.append(f"p0:{name}:logged_in")

    async def p1_brief(_ctx) -> None:
        """P1 — produce the BRIEF. Deep Research must be OFF.

        ⚠ Three things this used to get wrong, each of which produced a plausible wrong artefact
        rather than a failure:

        1. It typed the bare topic. The backend sends a **wrapper** asking for a research brief; the
           bare topic gets a chat answer, and P2 is then fed a conversation instead of a brief.
        2. It never disabled deep research, which persists across runs — so run 2's P1 produced a
           30-minute deep-research report where a brief was wanted.
        3. It captured nothing. The docstring said "capture the brief"; the body had no read and no
           return value, so P1's product did not exist.
        """
        driver = drivers[platforms[0]]
        # OFF before anything is typed: the disable path needs an EMPTY composer.
        outcome = await driver.disable_deep_research()
        if outcome is not None and not outcome.predicate_passed:
            raise ManifestError(
                f"{driver.platform}: deep research could not be turned off for P1 "
                f"({outcome.reason}). Continuing would spend a deep-research unit producing a "
                f"report where a brief was wanted."
            )
        if not await driver.await_composer_ready():
            raise ManifestError(
                f"{driver.platform}: the composer never became ready, so there is nothing to type "
                f"into. A page that renders is not a page that is interactable."
            )
        await driver.focus_composer()
        await driver.type_brief(prompts.brief_prompt(deps.topic, deps.feedback))
        await driver.send()
        deps.log.append(f"p1:{driver.platform}:brief_sent")

        # ⭐ And CAPTURE it — this is P1's product and P2's only input.
        await driver.await_response(timeout=_phase_timeout(1))
        brief = await driver.extract_response()
        if not brief or len(brief) < _BRIEF_FLOOR_CHARS:
            raise ManifestError(
                f"{driver.platform}: P1 returned {len(brief or '')} chars, under the "
                f"{_BRIEF_FLOOR_CHARS}-char floor. Feeding that to three deep-research agents "
                f"would spend three units of a monthly cap on a stub."
            )
        deps.brief = brief
        deps.log.append(f"p1:{driver.platform}:brief_captured:{len(brief)}")

    async def p2_deep_research(_ctx) -> None:
        """P2 — enable deep research per platform and dispatch.

        ⚠ Composer readiness is re-established **after** enabling deep research, not once at the top.
        On ChatGPT that step navigates and the composer re-mounts, so the pre-navigation composer is a
        dead handle — typing into it succeeds silently and sends nothing.
        """
        # ⛔ P2's input is the BRIEF, not the topic. Re-typing the topic makes P2 three independent
        # answers to the same question rather than three deep-research runs against one brief — the
        # product changes completely and nothing fails.
        if not deps.brief:
            raise ManifestError(
                "P2 has no brief to send. P1's product is P2's input; without it this would "
                "re-ask the topic and spend three deep-research units on the wrong prompt."
            )
        # ⚠ **SEQUENTIAL, one platform carried to completion before the next is started** (B1).
        #
        # Not a simplification: MobileSafari has one foreground tab and HID taps reach only it, so
        # `open_isolated_tab` / `switch_to` raise `BackendUnsupported` by design. Dispatching all
        # three and then collecting — which is what this used to do — leaves two runs generating on
        # pages nothing is watching, and on a platform whose report is only reachable from the page
        # that holds the conversation.
        #
        # The cost is real and is the accepted trade: wall-clock is the SUM of three deep-research
        # runs rather than the slowest of the three.
        for name in prompts.P2_PLATFORMS:
            driver = drivers.get(name)
            if driver is None:
                continue
            if prompts.deep_research_available(name):
                await driver.enable_deep_research()
            else:
                # Measured absent on this surface. Attempting it anyway would tap whatever the
                # opener's menu happens to contain — files, connectors, plugins — and the outcome
                # predicate would fail for a reason that reads as a broken selector.
                deps.log.append(f"p2:{name}:standard-mode:no-deep-research-on-this-surface")
            if not await driver.await_composer_ready():
                raise ManifestError(
                    f"{name}: the composer did not come back after enabling deep research. That step "
                    f"navigates, so readiness has to be re-established rather than assumed."
                )
            await driver.focus_composer()
            await driver.type_brief(deps.brief)
            await driver.send()
            deps.log.append(f"p2:{name}:dispatched")

            # ⛔ THE STEP NOBODY KNEW WAS THERE, measured on a live run 2026-08-09.
            #
            # Gemini's Deep Research does not start on send. It answers with a research PLAN of
            # roughly 1,200 characters and STOPS — generation ends, the text is stable, and it reads
            # like a perfectly good response. The wait therefore completes, the extractor harvests
            # the plan, and the run ships a document describing what it was *going to* research.
            # Nothing fails, nothing is empty, and the report is plausible: the exact silent shape
            # this pipeline keeps being bitten by.
            started = await driver.start_research_if_offered()
            if started:
                deps.log.append(f"p2:{name}:plan_confirmed")

            # Carried to completion HERE, before the next platform is touched.
            #
            # ⚠ The wait is LOGGED, and that is not decoration. Without a record of it the only
            # evidence of sequencing is "dispatch, report, dispatch, report" — which a run that
            # skipped the wait entirely also produces whenever extraction happens to succeed
            # immediately. A mutation deleting this wait went uncaught for exactly that reason.
            waited = await driver.await_response(timeout=_phase_timeout(2))
            deps.log.append(f"p2:{name}:waited:{(waited or {}).get('reason', 'done')}")
            report = await driver.extract_report()
            verdict = report_extract.judge_report(report)
            if not verdict.ok:
                # Recorded and skipped rather than raised: two good reports and one failure is a
                # degraded run worth finishing, and the backend's own consolidated builder simply
                # omits an agent with no text. Raising would throw away the units already spent.
                deps.log.append(f"p2:{name}:rejected:{verdict.reason}")
                continue
            # ⚠ Labelled at the point it is STORED, so every downstream consumer — the document
            # writer, the consolidated report, the NotebookLM upload — carries the caveat. Applying
            # it only at render time would leave the uploaded .md unlabelled, and that file outlives
            # this process.
            deps.reports[name] = prompts.annotate_report(name, report)
            deps.log.append(
                f"p2:{name}:report:{verdict.chars}"
                + ("" if prompts.deep_research_available(name) else ":standard-mode")
            )

        if not deps.reports:
            raise ManifestError(
                "P2 produced no usable report on any platform. Continuing would hand P3 an empty "
                "consolidated document and produce a podcast about nothing."
            )
        deps.consolidated = prompts.consolidated_report(deps.topic, deps.reports)
        deps.log.append(f"p2:consolidated:{len(deps.consolidated)}")

    async def p3_harvest(_ctx) -> None:
        """P3 — wait for the answer, then harvest, and judge the harvest rather than collect it.

        A harvest that fails its predicate raises, so a run cannot report success having collected
        nothing — the exact P1 outcome this exists to prevent.

        ⚠ The wait belongs here, before extraction. Without it this body ran the instant P2's send
        returned, which the mock survives (it answers in under a second) and a real deep-research run
        does not. The resulting empty harvest is reported by ``harvest.judge`` as read drift — pointing
        the agent at selectors that were never wrong.
        """
        for name, driver in drivers.items():
            waited = await driver.await_response(timeout=response_timeout)
            deps.log.append(f"p3:{name}:wait:{'done' if waited['done'] else 'TIMEOUT'}")
            if not waited["done"]:
                raise ManifestError(f"{name}: no complete response to harvest — {waited['reason']}")
            verdict = await driver.harvest_sources()
            deps.log.append(f"p3:{name}:{'ok' if verdict.ok else 'SUSPECT'}:{verdict.count}")
            if not verdict.ok:
                raise ManifestError(f"{name} harvest failed its predicate: {verdict.reason}")

    return [p0_verify, p1_brief, p2_deep_research, p3_harvest]
