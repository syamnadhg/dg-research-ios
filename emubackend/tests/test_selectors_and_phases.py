"""Tests for the data-driven browser layer.

The point these prove: the phase bodies are complete and correct *now*, with only the selector
values outstanding. A synthetic manifest plus a fake page exercises every step, so when real
logged-in DOM arrives the only thing that changes is a JSON file.

The other half is just as important — with the empty baseline, every step **raises**. It does not
skip. A silent skip would report success on a page nothing touched.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from emubackend import harvest, intents, phases, selectors
from emubackend.selectors import ManifestError

# ======================================================================================
# the manifest
# ======================================================================================


def test_the_baseline_ships_no_invented_selectors():
    """A wrong selector produces the P1 failure (clicks land, extraction returns nothing, run

    reports success). A MISSING one fails loudly at first use. So the baseline is deliberately empty.
    """
    m = selectors.load_manifest(path=None)
    if m.source != "baseline":
        pytest.skip("an external manifest is present in this environment")
    done, total = m.coverage()
    assert done == 0
    assert total > 0, "the shape is defined even though the values are not"
    assert "chatgpt.composer" in m.missing()


def test_an_external_manifest_is_preferred_over_the_baseline(tmp_path):
    """Mirrors selfheal.load_intents: a fix ships as DATA, not as a release."""
    path = tmp_path / "selectors_mobile.json"
    path.write_text(
        json.dumps(
            {"version": 1, "platforms": {"chatgpt": {"composer": "#prompt-textarea"}}}
        )
    )
    m = selectors.load_manifest(path)
    assert m.source == str(path)
    assert m.require("chatgpt", "composer").css == ("#prompt-textarea",)


def test_a_corrupt_manifest_degrades_to_the_baseline_rather_than_failing_the_run(tmp_path):
    """A broken manifest should fall back to known-good behaviour, not take the pipeline down."""
    path = tmp_path / "bad.json"
    path.write_text("{not json")
    m = selectors.load_manifest(path)
    assert m.source.startswith("baseline (")
    assert "unusable" in m.source, "and the fallback must be visible, not mysterious"


def test_an_unknown_platform_is_rejected(tmp_path):
    path = tmp_path / "m.json"
    path.write_text(json.dumps({"platforms": {"perplexity": {"composer": "x"}}}))
    assert selectors.load_manifest(path).source.startswith("baseline (")


def test_a_typod_key_is_rejected_rather_than_ignored(tmp_path):
    """An ignored typo sits in the file doing nothing, and the symptom is a step that never finds

    its element with nothing to explain why.
    """
    path = tmp_path / "m.json"
    path.write_text(json.dumps({"platforms": {"chatgpt": {"composr": "#x"}}}))
    m = selectors.load_manifest(path)
    assert m.source.startswith("baseline (")
    assert "unknown key" in m.source


def test_a_selector_entry_accepts_a_string_a_list_or_an_object():
    assert selectors.SelectorEntry.from_json("#a").css == ("#a",)
    assert selectors.SelectorEntry.from_json(["#a", "#b"]).css == ("#a", "#b")
    rich = selectors.SelectorEntry.from_json(
        {"css": ["#a"], "text_contains": "Send", "network_hint": "/backend-api/", "provenance": "agent"}
    )
    assert rich.text_contains == "Send"
    assert rich.network_hint == "/backend-api/"
    assert rich.provenance == "agent"


def test_a_network_hint_can_be_carried_because_it_is_the_durable_signal():
    """DOM predicates rot on copy changes; an observed request to the DR backend does not."""
    entry = selectors.SelectorEntry.from_json({"css": ["#x"], "network_hint": "/deep_research"})
    assert entry.network_hint == "/deep_research"


def _baseline(tmp_path):
    """The baseline, forced.

    ``load_manifest(path=None)`` consults ``$DG_IOS_SELECTORS`` and then the repo's own
    ``selectors_mobile.json`` — so once real selectors were captured, these two tests started reading
    them and one of them stopped failing. They were asserting a property of the baseline while asking
    for whatever the repo happened to hold, which is a test that quietly changes subject.
    """
    return selectors.load_manifest(path=tmp_path / "does-not-exist.json")


def test_require_fails_loudly_on_an_uncaptured_selector(tmp_path):
    m = _baseline(tmp_path)
    with pytest.raises(ManifestError) as exc:
        m.require("chatgpt", "composer")
    assert "has not been captured" in str(exc.value)
    assert "silent skip" in str(exc.value)


def test_an_unknown_key_names_what_is_available(tmp_path):
    m = _baseline(tmp_path)
    with pytest.raises(ManifestError, match="Known keys"):
        m.entry("chatgpt", "nope")


def test_coverage_counts_every_key_of_a_named_platform_not_just_the_supplied_ones(tmp_path):
    """A partial manifest must not shrink the denominator *within* a platform.

    It used to: the loaded file *replaced* the baseline structure, so a file holding two keys reported
    ``(2, 2)`` — complete — and ``missing()`` returned nothing. Measured on the first real capture,
    where seven of twenty-five keys read as 7/7 done. The two functions whose only job is to report how
    far along the capture is were the two that lied about it.

    The denominator is that platform's full key set (7 for ChatGPT), not the whole baseline — see
    ``test_a_single_platform_manifest_is_measured_against_that_platform`` for why scoping to named
    platforms matters, and the multi-platform test for the 25 case.
    """
    path = tmp_path / "m.json"
    path.write_text(
        json.dumps({"platforms": {"chatgpt": {"composer": "#c", "send": "#s"}}})
    )
    manifest = selectors.load_manifest(path)
    assert manifest.coverage() == (2, 7)
    assert "chatgpt.sources" in manifest.missing()


def test_a_supplied_value_still_wins_over_the_baseline(tmp_path):
    """Merging must not resurrect the baseline's empty entry over a captured one."""
    path = tmp_path / "m.json"
    path.write_text(json.dumps({"platforms": {"claude": {"composer": "#real"}}}))
    manifest = selectors.load_manifest(path)
    assert manifest.entry("claude", "composer").css == ("#real",)
    assert not manifest.entry("claude", "send").resolvable


# ======================================================================================
# a fake page, so the phase bodies can be exercised now
# ======================================================================================


class FakeHandle:
    def __init__(self, page, css, text="", attrs=None, visible=True):
        self.page = page
        self.css = css
        self.text = text
        self.attrs = attrs or {}
        self.visible = visible

    async def inner_text(self):
        return self.text

    async def is_visible(self):
        """Part of the handle contract, and load-bearing for composer readiness.

        Present because a fake that omits a contract method does not fail as "method missing" — it
        failed as "the composer never became ready", four tests deep, once ``await_composer_ready``
        started asking. A fake shaped like the contract is the thing that keeps that honest.
        """
        return self.visible

    async def get_attribute(self, name):
        return self.attrs.get(name)

    async def click(self):
        self.page.clicks.append(self.css)
        self.page.focused = self.css
        hook = self.page.on_click.get(self.css)
        if hook is not None:
            hook()
        if self.css in self.page.toggles:
            self.page.toggles[self.css] = "true"
        if self.css in self.page.sends_produce_response:
            # ``data-state=complete`` on purpose: it mirrors the mock platform, whose container carries
            # it, so ``await_response`` takes its decisive branch and these body-level tests do not each
            # sit through the content-stability window. The stability path gets its own focused tests —
            # covering it here too would only make the suite slower at proving the same thing twice.
            self.page.dom.setdefault(
                self.page.response_css,
                [
                    FakeHandle(
                        self.page,
                        self.page.response_css,
                        "answer",
                        attrs={"data-state": "complete"},
                    )
                ],
            )

    async def fill(self, text):
        await self.click()
        self.page.typed.append(text)
        return {"ok": True, "path": "execCommand"}


class _FakeKeyboard:
    def __init__(self, page):
        self._page = page

    async def press(self, combo):
        self._page.keys.append(combo)
        hook = self._page.on_key.get(combo)
        if hook is not None:
            hook()


class FakePage:
    """A PageShim-shaped fake. Only what the phase bodies actually call."""

    def __init__(self, dom=None, toggles=None, response_css="#resp"):
        self.dom = dom or {}
        self.toggles = toggles or {}
        self.response_css = response_css
        self.sends_produce_response = {"#send"}
        self.clicks: list[str] = []
        self.typed: list[str] = []
        self.focused: str | None = None
        #: What the text-fallback query returns, independent of its exact selector string.
        self.text_candidates: list = []
        #: Override the deep-research state probe *independently* of ``toggles``.
        #:
        #: Needed to test the not-found invariant at all. While the probe's answer was derived from
        #: ``toggles``, emptying ``toggles`` also made the state say "cannot tell" — so a mutation
        #: deleting the not-found guard still passed, because the second signal had gone quiet for the
        #: same reason. bin/mutate.py caught it: the test was passing, for the wrong reason.
        self.dr_state = None
        #: css -> callable, run when that element is clicked. Lets a test model a page that CHANGES in
        #: response to a tap — a menu opening, a navigation tearing the composer down — which is the
        #: whole subject of the four-mechanism tests.
        self.on_click: dict = {}
        #: Called with each queried css. Lets a test make an element arrive on the Nth look, which is
        #: how "polled, not read once" is distinguished from "read once and got lucky".
        self.on_query = None
        #: key combo -> callable, and the log of what was pressed.
        self.on_key: dict = {}
        self.keys: list[str] = []
        self.keyboard = _FakeKeyboard(self)
        #: What the opener reports about its popup. Independent of `dom` on purpose: the whole defect
        #: this models is that the popup's state and the target's presence are DIFFERENT facts.
        self.popup_open = False
        #: Does the platform's own stop/in-flight control exist? The veto on completion.
        self.generating = False

    def _tick(self, css):
        if self.on_query is not None:
            self.on_query(css)

    async def query_selector(self, css):
        self._tick(css)
        if css in self.toggles:
            return FakeHandle(self, css, attrs={"aria-pressed": self.toggles[css]})
        found = self.dom.get(css)
        return found[0] if found else None

    async def query_selector_all(self, css):
        self._tick(css)
        if css in self.dom:
            return list(self.dom[css])
        # The text-fallback query is a comma list of roles, and a fake keyed on its exact string is a
        # fake that breaks whenever the list is extended — which is what happened when `[role=menuitem]`
        # was added for ChatGPT's deep-research item. Match the *shape* instead.
        if "," in css and self.text_candidates:
            return list(self.text_candidates)
        return []

    async def evaluate(self, _js):
        if "document.querySelector" in _js and "aria-label*=" in _js:
            # The in-flight probe. Independent of everything else on purpose: the defect it models is a
            # page whose TEXT looks finished while the platform is still working.
            return self.generating
        if "the opener itself is gone" in _js:
            # The popup-state probe. Answered from `popup_open`, so a test can model a menu that closes
            # itself, one that ignores Escape, and — the case real ChatGPT exposed — one that closes
            # while the TARGET remains findable.
            return {"open": self.popup_open, "why": "fake"}
        if "placeholderResearch" in _js:
            if self.dr_state is not None:
                return self.dr_state
            # Mirrors whatever aria-pressed the fake toggles carry, so these tests keep asserting the
            # same behaviour through the richer probe.
            on = any(v == "true" for v in self.toggles.values())
            return {
                # Tracks the state, not mere presence — see the note in test_toggle_idempotence.
                "pillVisible": on,
                "pressed": on,
                "placeholderResearch": on,
                "placeholderChat": bool(self.toggles) and not on,
                "placeholder": "what do you want to research" if on else "ask chatgpt",
            }
        return "DIV" if self.focused else None


MANIFEST = {
    "version": 1,
    "platforms": {
        "chatgpt": {
            "logged_in_marker": "#prompt-textarea",
            "composer": "#prompt-textarea",
            "send": "#send",
            "deep_research_toggle": "#dr",
            "sources": [".src"],
            "response_container": "#resp",
        }
    },
}


#: Every phase-body test passes this instead of the 240s production default.
#:
#: ⚠ Not a tidiness preference. `test_p3_raises_when_the_harvest_fails_its_predicate` called P3 directly
#: with no response on the page, so the new wait ran its FULL production timeout before the assertion it
#: was actually testing — one test, four minutes. A unit test that waits out a real-platform timeout is
#: a unit test nobody will run.
FAST_RESPONSE_TIMEOUT = 1.0


def _deps(tmp_path, *, sources=3, toggle="false", response=False):
    path = tmp_path / "m.json"
    path.write_text(json.dumps(MANIFEST))
    manifest = selectors.load_manifest(path)
    page = FakePage(
        dom={
            "#prompt-textarea": [FakeHandle(None, "#prompt-textarea")],
            ".src": [],
        },
        toggles={"#dr": toggle},
    )
    for h in page.dom["#prompt-textarea"]:
        h.page = page
    page.dom["#send"] = [FakeHandle(page, "#send")]
    page.dom[".src"] = [FakeHandle(page, ".src", f"source {i}") for i in range(sources)]
    if response:
        # A completed response already on the page, for tests that exercise P3 WITHOUT running P1/P2 to
        # produce one. Without it the wait is what fails, and an assertion about the harvest silently
        # becomes an assertion about the wait.
        page.dom["#resp"] = [
            FakeHandle(page, "#resp", "answer", attrs={"data-state": "complete"})
        ]
    return phases.PhaseDeps(
        manifest=manifest,
        registry=intents.IntentRegistry(),
        history=harvest.HarvestHistory(),
        pages={"chatgpt": page},
        topic="quantum error correction",
    ), page


# ======================================================================================
# the phase bodies, exercised end to end against the fake
# ======================================================================================


def test_all_four_phases_run_against_a_synthetic_manifest(tmp_path):
    """The proof that the browser layer is written: only the selector VALUES are outstanding."""
    deps, page = _deps(tmp_path)
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    for body in bodies:
        asyncio.run(body(None))

    assert "p0:chatgpt:logged_in" in deps.log
    assert "p1:chatgpt:brief_sent" in deps.log
    assert "p2:chatgpt:dispatched" in deps.log
    assert any(entry.startswith("p3:chatgpt:ok:") for entry in deps.log)
    assert deps.topic in page.typed
    assert "#send" in page.clicks


def test_p0_fails_loudly_when_a_platform_is_not_logged_in(tmp_path):
    deps, page = _deps(tmp_path)
    page.dom["#prompt-textarea"] = []
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[0](None))
    assert "not logged in" in str(exc.value)
    assert "desktop sidebar markers" in str(exc.value), (
        "the message must warn against reusing desktop markers — they collapse on mobile"
    )


def test_every_phase_raises_against_the_empty_baseline(tmp_path):
    """With no captured DOM, the layer refuses to run. It does NOT skip.

    A silent skip reports success on a page nothing touched — the failure this whole layer exists
    to make impossible.
    """
    deps = phases.PhaseDeps(
        manifest=selectors.load_manifest(path=None),
        registry=intents.IntentRegistry(),
        history=harvest.HarvestHistory(),
        pages={"chatgpt": FakePage()},
        topic="t",
    )
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    for body in bodies:
        with pytest.raises(ManifestError):
            asyncio.run(body(None))


def test_a_selector_that_matches_nothing_names_what_was_tried(tmp_path):
    deps, page = _deps(tmp_path)
    page.dom["#send"] = []
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    asyncio.run(bodies[0](None))
    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[1](None))
    assert "did not match anything" in str(exc.value)
    assert "#send" in str(exc.value), "the message must name the selectors tried"


def test_p3_raises_when_the_harvest_fails_its_predicate(tmp_path):
    """A run must not report success having collected nothing — the P1 outcome exactly."""
    deps, _page = _deps(tmp_path, sources=0, response=True)
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    asyncio.run(bodies[0](None))
    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[3](None))
    assert "harvest failed its predicate" in str(exc.value), (
        "the response is present and complete here, so the only thing left to fail is the harvest. "
        "If this reads as a wait timeout, the fixture stopped supplying a response and the test is "
        "no longer about the harvest at all."
    )


# ======================================================================================
# the four mechanisms a real platform needs and the mock never did
#
# Each of these was earned by a measured failure while driving real ChatGPT through the Swift in-app
# path. They were then absent from THIS path, and invisible for as long as the only platform here was
# the mock — a mock has no closed menus, does not navigate, and answers in under a second.
# ======================================================================================


def _driver(tmp_path, manifest_overrides=None, **page_kwargs):
    """A PlatformDriver over a fake page, with the manifest patchable per test."""
    manifest_json = json.loads(json.dumps(MANIFEST))
    if manifest_overrides:
        manifest_json["platforms"]["chatgpt"].update(manifest_overrides)
    path = tmp_path / "m.json"
    path.write_text(json.dumps(manifest_json))
    page = FakePage(**page_kwargs)
    deps = phases.PhaseDeps(
        manifest=selectors.load_manifest(path),
        registry=intents.IntentRegistry(),
        history=harvest.HarvestHistory(),
        pages={"chatgpt": page},
        topic="t",
    )
    return phases.PlatformDriver("chatgpt", deps), page


# -- mechanism 1: opener ----------------------------------------------------------------


def test_a_control_behind_an_opener_is_reached_by_tapping_the_opener_first(tmp_path):
    """The manifest declared ``opener`` and ``_tap`` ignored it.

    Not a missing feature — a DROPPED one: ``selectors.py`` parsed the field and carried it onto the
    entry, so the file said "this control is behind a closed menu" and the driver still looked for it
    in the closed state and raised. On real ChatGPT that is the whole of P2.
    """
    driver, page = _driver(
        tmp_path,
        {"deep_research_toggle": {"css": ["#dr-item"], "opener": "#plus"}},
    )
    page.dom["#plus"] = [FakeHandle(page, "#plus")]
    # The item does not exist until the opener is tapped — a closed menu, as on the real page.
    page.dom["#dr-item"] = []

    def _open():
        page.popup_open = True
        page.dom["#dr-item"] = [FakeHandle(page, "#dr-item")]

    page.on_click["#plus"] = _open
    # Choosing an item closes the menu, as most menus do. The stays-open case — ChatGPT's Deep research
    # is a `menuitem` carrying `aria-checked`, and a toggle item can keep its menu up — is covered by
    # the dismissal tests below.
    page.on_click["#dr-item"] = lambda: setattr(page, "popup_open", False)

    asyncio.run(driver._tap("deep_research_toggle"))
    assert page.clicks[0] == "#plus", "the opener must be tapped before the target is looked for"
    assert "#dr-item" in page.clicks, "and then the target itself"
    assert page.keys == [], (
        "a menu that closed itself needs no Escape — dismissal must check before it acts, not press "
        "Escape unconditionally at a page that has already moved on"
    )


def test_the_opener_is_POLLED_because_the_menu_renders_in_two_passes(tmp_path):
    """⚠ Measured, not defensive: ChatGPT's plus menu paints 3 items, then 19 asynchronously, with
    ``Deep research`` at index 7.

    A single read after the opener tap sees the 3-item menu — and I concluded twice, from exactly that
    sample, that the control does not exist on mobile web. It does. A fixed read is what made a present
    control look absent.
    """
    driver, page = _driver(
        tmp_path,
        {"deep_research_toggle": {"css": ["#dr-item"], "opener": "#plus"}},
    )
    page.dom["#plus"] = [FakeHandle(page, "#plus")]
    page.dom["#dr-item"] = []
    state = {"reads": 0}

    def _late(css):
        # Arrives on the THIRD look, which a read-once implementation never takes. Materialises ONCE:
        # a hook that re-added the item on every later query also re-opened the menu behind the
        # dismissal check, so the tap could never be seen to close it.
        if css == "#dr-item" and not state.get("arrived"):
            state["reads"] += 1
            if state["reads"] >= 3:
                page.dom["#dr-item"] = [FakeHandle(page, "#dr-item")]
                state["arrived"] = True

    page.on_query = _late
    page.on_click["#plus"] = lambda: None
    page.on_click["#dr-item"] = lambda: setattr(page, "popup_open", False)

    asyncio.run(driver._tap("deep_research_toggle"))
    assert state["reads"] >= 3, "a read-once implementation would have given up on the first look"
    assert "#dr-item" in page.clicks


def test_a_missing_opener_is_reported_as_being_about_the_opener(tmp_path):
    """When the opener itself has rotted, the target is unreachable *by construction*.

    Saying "the target did not match" sends the agent to repair a selector that is fine.
    """
    driver, page = _driver(
        tmp_path,
        {"deep_research_toggle": {"css": ["#dr-item"], "opener": "#plus"}},
    )
    page.dom["#plus"] = []
    page.dom["#dr-item"] = []
    with pytest.raises(ManifestError) as exc:
        asyncio.run(driver._tap("deep_research_toggle"))
    assert "#plus" in str(exc.value) and "opener" in str(exc.value)


# -- mechanism 2: verified dismissal ----------------------------------------------------


def _menu_driver(tmp_path):
    """A driver whose deep-research control lives behind an opener that reports popup state."""
    driver, page = _driver(
        tmp_path,
        {"deep_research_toggle": {"css": ["#dr-item"], "opener": "#plus"}},
    )
    page.dom["#plus"] = [FakeHandle(page, "#plus")]
    page.dom["#dr-item"] = []

    def _open():
        page.popup_open = True
        page.dom["#dr-item"] = [FakeHandle(page, "#dr-item")]

    page.on_click["#plus"] = _open
    return driver, page


def test_an_opened_menu_is_closed_and_the_close_is_VERIFIED(tmp_path):
    """An open menu covers the send button, so the NEXT phase taps the overlay.

    That regressed the run twice when the opener first landed, and it fails as a send problem — which
    is why dismissal is verified here rather than assumed from an Escape keypress.
    """
    driver, page = _menu_driver(tmp_path)
    # Escape closes it, as a real menu does.
    page.on_key["Escape"] = lambda: setattr(page, "popup_open", False)

    asyncio.run(driver._tap("deep_research_toggle"))
    assert "Escape" in page.keys
    assert page.popup_open is False, "the menu must actually be closed, not merely Escaped at"


def test_dismissal_asks_the_OPENER_not_whether_the_TARGET_is_still_findable(tmp_path):
    """⚠ The defect real ChatGPT exposed on the very first run, and the reason it was silent.

    Activating "Deep research" leaves a **"Deep research" pill** in the composer, and that control's
    manifest entry is a text match with no css — so the target stays findable forever. A dismissal check
    that used target-presence as a proxy for menu-open therefore read the run's own SUCCESS SIGNAL as
    evidence of failure, and P2 aborted having correctly done everything asked of it.

    Here the menu closes itself on the item click while the target REMAINS. Dismissal must be satisfied.
    """
    driver, page = _menu_driver(tmp_path)

    def _choose():
        page.popup_open = False          # the menu closed…
        # …and the target is still there, standing in for the pill the activation created.
        page.dom["#dr-item"] = [FakeHandle(page, "#dr-item")]

    page.on_click["#dr-item"] = _choose

    asyncio.run(driver._tap("deep_research_toggle"))  # must not raise
    assert page.dom["#dr-item"] != [], "the target deliberately outlives the popup here"
    assert page.keys == [], "and a closed popup needs no Escape"


def test_a_menu_that_refuses_to_close_FAILS_rather_than_being_assumed_shut(tmp_path):
    """The failure has to surface here, where it is explicable, instead of as a send that missed."""
    driver, page = _menu_driver(tmp_path)
    # Escape does nothing — the menu stays open.
    with pytest.raises(ManifestError) as exc:
        asyncio.run(driver._tap("deep_research_toggle"))
    assert "would not close" in str(exc.value)
    assert "covers the send button" in str(exc.value), (
        "the message must name the consequence, because the symptom appears in the NEXT phase"
    )


def test_a_control_reached_WITHOUT_an_opener_is_not_dismissed(tmp_path):
    """Escape after an ordinary tap is not harmless — on a real composer it can clear a draft."""
    driver, page = _driver(tmp_path)
    page.dom["#send"] = [FakeHandle(page, "#send")]
    asyncio.run(driver._tap("send"))
    assert page.keys == [], "nothing was opened, so there is nothing to dismiss"


# -- mechanism 3: composer readiness ---------------------------------------------------


def test_composer_readiness_names_the_composer_and_nothing_else(tmp_path):
    """⚠ A readiness predicate must name the thing that depends on it.

    An earlier version asked a CHAIN (marker or composer or …), which is right for *resolution* and
    wrong for *readiness*: any weak member satisfies it, so a splash shell carrying a logged-in marker
    and no composer reported ready — and the run typed into nothing.
    """
    driver, page = _driver(tmp_path)
    # The logged-in marker is present (same selector as the composer in this manifest would hide the
    # bug, so give the marker its own element and empty the composer).
    # ⚠ timeout MUST exceed settle, or the assertion is vacuous. With the default settle=1.0 and a
    # 0.5s timeout this returned False whatever the predicate said — bin/mutate.py caught the sibling
    # test passing against `ready = True`.
    page.dom["#prompt-textarea"] = []
    assert asyncio.run(driver.await_composer_ready(timeout=1.5, settle=0.3)) is False


def test_an_invisible_composer_is_not_ready(tmp_path):
    """Present in the DOM is not interactable. A hidden composer is a mounting one."""
    driver, page = _driver(tmp_path)
    page.dom["#prompt-textarea"] = [
        FakeHandle(page, "#prompt-textarea", visible=False)
    ]
    # timeout > settle, so a "visible" verdict really would return True here — see the note above.
    assert asyncio.run(driver.await_composer_ready(timeout=1.5, settle=0.3)) is False


def test_composer_readiness_WAITS_rather_than_reading_once(tmp_path):
    """Enabling deep research navigates and the composer re-mounts — readiness is not a one-time fact."""
    driver, page = _driver(tmp_path)
    page.dom["#prompt-textarea"] = []
    state = {"reads": 0}

    def _remount(css):
        if css == "#prompt-textarea":
            state["reads"] += 1
            if state["reads"] >= 3:
                page.dom["#prompt-textarea"] = [FakeHandle(page, "#prompt-textarea")]

    page.on_query = _remount
    assert asyncio.run(driver.await_composer_ready(timeout=5.0)) is True
    assert state["reads"] >= 3


def test_a_missing_is_visible_is_a_wiring_bug_not_an_unready_composer(tmp_path):
    """⚠ The catch is RuntimeError, deliberately narrower than Exception.

    A bare ``except Exception`` swallowed AttributeError, so a page object missing a contract method
    reported "the composer never became ready" — a wiring bug wearing a platform symptom. It cost four
    test failures to diagnose, and this pins the narrowing.
    """

    class HandleWithoutContract:
        async def is_visible(self):
            raise AttributeError("no such thing")

    driver, page = _driver(tmp_path)
    page.dom["#prompt-textarea"] = [HandleWithoutContract()]
    with pytest.raises(AttributeError):
        asyncio.run(driver.await_composer_ready(timeout=0.5))


# -- mechanism 4: the response wait ----------------------------------------------------


def test_the_response_wait_accepts_the_decisive_state_attribute(tmp_path):
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [
        FakeHandle(page, "#resp", "answer", attrs={"data-state": "complete"})
    ]
    got = asyncio.run(driver.await_response(timeout=2.0))
    assert got["done"] and got["reason"] == "data-state=complete"


def test_the_response_wait_also_accepts_CONTENT_STABILITY(tmp_path):
    """``data-state=complete`` is mock-only among the platforms measured here.

    Trusting it exclusively means waiting the full timeout on every real run.
    """
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [FakeHandle(page, "#resp", "a real answer with no state attribute")]
    got = asyncio.run(driver.await_response(timeout=5.0, stable_for=0.5, poll=0.1))
    assert got["done"] and "stable" in got["reason"]
    assert got["chars"] > 0


def test_an_EMPTY_container_is_never_accepted_however_stable_it_is(tmp_path):
    """⚠ The guard that makes stability safe, and it is not belt-and-braces.

    Live ChatGPT produced a turn that stayed empty for SIX MINUTES after a Retry click that succeeded
    as a click. An empty container is perfectly stable — stability without content is the signature of
    that stall, not evidence of completion. Without this guard the run harvests nothing and reports it
    as read drift.
    """
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [FakeHandle(page, "#resp", "   \n  ")]
    got = asyncio.run(driver.await_response(timeout=1.5, stable_for=0.3, poll=0.1))
    assert got["done"] is False
    assert "EMPTY" in got["reason"], (
        "and the reason must distinguish a platform-side stall from a merely slow answer"
    )


def test_the_wait_raises_on_a_platform_error_instead_of_waiting_it_out(tmp_path):
    """"Failed to fetch template" will not become an answer in another four minutes."""
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [
        FakeHandle(page, "#resp", "Error loading app Failed to fetch template Retry")
    ]
    with pytest.raises(phases.PlatformStateError) as exc:
        asyncio.run(driver.await_response(timeout=5.0, stable_for=9.0, poll=0.05))
    assert "while we waited" in str(exc.value)
    assert "hide the reason" in str(exc.value)


def test_an_uncaptured_response_container_is_reported_not_waited_on(tmp_path):
    driver, _page = _driver(tmp_path, {"response_container": None})
    got = asyncio.run(driver.await_response(timeout=0.2))
    assert got["done"] is False and "not captured" in got["reason"]


def test_p3_waits_before_harvesting(tmp_path):
    """Without the wait, P3 ran the instant P2's send returned.

    The mock survives that (it answers in under a second); a real deep-research run takes minutes, and
    the empty harvest is then reported as read drift — sending the agent to repair selectors that were
    never wrong.

    ⚠ This test used to assert the LOG LINE ``p3:…:wait:done`` and nothing more, and bin/mutate.py
    caught it: replacing the whole wait with ``{"done": True}`` still wrote that line, so the test
    passed against a P3 that did not wait at all. The subject is behaviour, so the arrangement has to
    make behaviour the only thing that can satisfy it — the answer AND its sources arrive late, exactly
    as on a real platform, and a P3 that skips the wait harvests an empty page and raises.
    """
    deps, page = _deps(tmp_path, sources=0)
    state = {"looks": 0}

    def _late(css):
        if css != "#resp":
            return
        state["looks"] += 1
        if state["looks"] >= 3:
            page.dom["#resp"] = [
                FakeHandle(page, "#resp", "answer", attrs={"data-state": "complete"})
            ]
            page.dom[".src"] = [FakeHandle(page, ".src", f"source {i}") for i in range(3)]

    page.on_query = _late
    bodies = phases.build_phase_bodies(deps, ("chatgpt",), response_timeout=10.0)
    asyncio.run(bodies[0](None))
    asyncio.run(bodies[3](None))

    assert state["looks"] >= 3, "P3 must have polled the page, not assumed the answer was there"
    assert "p3:chatgpt:ok:3" in deps.log, (
        "the harvest must succeed BECAUSE the wait let the sources arrive — skip the wait and this "
        "page has zero sources, so P3 raises"
    )
    assert deps.log.index("p3:chatgpt:wait:done") < deps.log.index("p3:chatgpt:ok:3")


def test_p3_refuses_to_harvest_when_the_response_never_completes(tmp_path):
    deps, _page = _deps(tmp_path)  # no response container on the page at all
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    asyncio.run(bodies[0](None))
    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[3](None))
    assert "no complete response to harvest" in str(exc.value)


def test_p2_re_establishes_composer_readiness_after_enabling_deep_research(tmp_path):
    """That step NAVIGATES on ChatGPT and the composer re-mounts.

    Typing into the pre-navigation handle succeeds silently and sends nothing.
    """
    deps, page = _deps(tmp_path, toggle="false")
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    # The toggle tap tears the composer down; it comes back a moment later, as after a navigation.
    state = {"reads": 0}

    def _navigate():
        page.dom["#prompt-textarea"] = []

    def _remount(css):
        if css == "#prompt-textarea" and not page.dom.get("#prompt-textarea"):
            state["reads"] += 1
            if state["reads"] >= 2:
                page.dom["#prompt-textarea"] = [FakeHandle(page, "#prompt-textarea")]

    page.on_click["#dr"] = _navigate
    page.on_query = _remount

    asyncio.run(bodies[2](None))
    assert "p2:chatgpt:dispatched" in deps.log
    assert state["reads"] >= 2, "P2 must WAIT for the re-mounted composer, not read once"
    assert deps.topic in page.typed, "and then actually type into it"


def test_mutating_steps_go_through_the_guarded_wrapper(tmp_path):
    """Phase A1 under A8: wrapping is a design property, so the intents must be registered."""
    deps, _page = _deps(tmp_path)
    phases.build_phase_bodies(deps, ("chatgpt",))
    for intent_id in ("chatgpt.focus_composer", "chatgpt.send", "chatgpt.deep_research_toggle"):
        assert deps.registry.get(intent_id) is not None


def test_a_toggle_is_the_only_escalation_eligible_intent(tmp_path):
    """Reversible AND verifiable AND carrying a positive off-signal — a toggle is the one shape

    that qualifies, and everything else is structurally shadow-only by construction.
    """
    deps, _page = _deps(tmp_path)
    phases.build_phase_bodies(deps, ("chatgpt",))
    assert deps.registry.get("chatgpt.deep_research_toggle").escalation_eligible is True
    assert deps.registry.get("chatgpt.send").escalation_eligible is False
    assert deps.registry.get("chatgpt.focus_composer").escalation_eligible is False


def test_the_off_signal_is_positive_not_the_inverse_of_the_predicate(tmp_path):
    """An unfindable toggle must NOT read as confirmed-off, or a rotted selector authorises a

    click that switches a live control off (#709).
    """
    deps, page = _deps(tmp_path, toggle="false")
    phases.build_phase_bodies(deps, ("chatgpt",))
    intent = deps.registry.get("chatgpt.deep_research_toggle")

    assert asyncio.run(intent.confirmed_off()) is True, "a chat placeholder is a positive off"

    # The control can no longer be found, WHILE the page still reports a confidently-off state. That
    # pairing is the whole test: the two signals are read independently and resolution failing has to
    # win. Clearing `toggles` alone silenced the state too, so the mutation that deletes the not-found
    # guard passed anyway.
    #
    # No pill and a chat placeholder — coherent for ChatGPT, whose on-signal is the pill being visible
    # at all. A first attempt set pillVisible=True, which reads as ON, so `off` was False for that
    # reason instead. A fixture has to be coherent with the platform it stands in for.
    page.toggles = {}
    page.dr_state = {
        "pillVisible": False, "pressed": False, "placeholderResearch": False,
        "placeholderChat": True, "placeholder": "ask chatgpt",
    }
    assert asyncio.run(intent.confirmed_off()) is False, (
        "not-found must never be treated as confirmed-off, however off the page looks"
    )
    assert asyncio.run(intent.outcome_predicate()) is False


def test_resolve_tries_the_css_chain_in_order():
    """Platforms A/B-test their DOM, so a single selector is a single point of failure.

    Order is significant and must be tested with BOTH selectors present: the first match wins, so a
    manifest lists its most specific selector first. With only one match the order is unobservable
    and a reversed chain passes — found by bin/mutate.py.
    """
    page = FakePage(
        dom={
            "#first": [FakeHandle(None, "#first")],
            "#second": [FakeHandle(None, "#second")],
        }
    )
    for handles in page.dom.values():
        for h in handles:
            h.page = page

    entry = selectors.SelectorEntry(css=("#first", "#second"))
    found = asyncio.run(phases.resolve(page, entry))
    assert found is not None and found.css == "#first", (
        "the most specific selector is listed first and must win"
    )

    # And the chain genuinely falls through when the first is absent.
    page.dom["#first"] = []
    fallback = asyncio.run(phases.resolve(page, entry))
    assert fallback is not None and fallback.css == "#second"


def test_resolve_falls_back_to_text_last():
    """Text is the fallback for structure that moves but labels that do not — and it is LAST,

    because matching on copy is fragile in the opposite direction (an i18n change breaks it).
    """
    page = FakePage()
    page.text_candidates = [FakeHandle(page, "#x", "Start research")]
    entry = selectors.SelectorEntry(css=("#missing",), text_contains="start research")
    assert asyncio.run(phases.resolve(page, entry)) is not None


def test_the_text_fallback_reaches_menu_items_not_just_buttons():
    """ChatGPT's deep-research control is a `[role=menuitem]` with no testid and no id.

    Text is its only handle, and the fallback query used to cover `button, a, [role=button]` only — so
    the one control that had just been located by hand would still have been unreachable. Measured on
    the real page: 19 items in the composer's plus menu, "Deep research" at index 7, each
    `role=menuitem` carrying `aria-checked`.
    """
    page = FakePage()
    seen: list[str] = []

    class Recorder(FakePage):
        async def query_selector_all(self, css):
            seen.append(css)
            return [FakeHandle(self, "#dr", "Deep research")]

    entry = selectors.SelectorEntry(css=(), text_contains="Deep research")
    found = asyncio.run(phases.resolve(Recorder(), entry))
    assert found is not None
    assert "[role=menuitem]" in seen[0], f"menu roles must be queried; got {seen[0]!r}"


def test_a_text_only_entry_is_resolvable_without_any_css():
    """ChatGPT's entry deliberately carries NO css: a broad `[role=menuitem]` would match "Camera",

    the first of 19 items, because resolve() tries css before text.
    """
    entry = selectors.SelectorEntry(css=(), text_contains="Deep research")
    assert entry.resolvable


def test_resolve_returns_none_rather_than_guessing():
    page = FakePage()
    assert asyncio.run(phases.resolve(page, selectors.SelectorEntry(css=("#nope",)))) is None


def test_typing_uses_the_editor_aware_fill_path(tmp_path):
    """ProseMirror-style composers need it; a value assignment leaves the send control disabled."""
    deps, page = _deps(tmp_path)
    bodies = phases.build_phase_bodies(
        deps, ("chatgpt",), response_timeout=FAST_RESPONSE_TIMEOUT
    )
    asyncio.run(bodies[1](None))
    assert page.typed == [deps.topic]
    assert page.clicks.count("#prompt-textarea") >= 1, "fill focuses by a real tap first"


def test_a_single_platform_manifest_is_measured_against_that_platform(tmp_path):
    """The correction to the correction, and a real gate failure.

    Merging onto EVERY baseline platform fixed the honesty bug (a 7-key file reporting 7/7 complete) and
    created a new one: the mock e2e's manifest deliberately covers one platform, so judging it against
    all twenty-five made `done == total` false and the gate failed on a manifest that was entirely
    correct. Caught by re-running bin/all_gates.sh rather than by reasoning.
    """
    path = tmp_path / "mock.json"
    path.write_text(
        json.dumps({"platforms": {"chatgpt": {
            key: "#x" for key in sorted(selectors.ALLOWED_KEYS["chatgpt"])
        }}})
    )
    manifest = selectors.load_manifest(path)
    assert manifest.coverage() == (7, 7), "one platform named -> one platform's denominator"
    assert manifest.missing() == []


def test_a_multi_platform_manifest_still_counts_every_platform_it_names(tmp_path):
    """The honesty fix must survive: naming four platforms means being judged on four."""
    path = tmp_path / "m.json"
    path.write_text(
        json.dumps({"platforms": {
            "chatgpt": {"composer": "#c"}, "gemini": {"composer": "#c"},
            "claude": {"composer": "#c"}, "notebooklm": {"logged_in_marker": "#m"},
        }})
    )
    done, total = selectors.load_manifest(path).coverage()
    assert (done, total) == (4, 25)


def test_the_baseline_alone_still_covers_every_platform(tmp_path):
    assert selectors.load_manifest(path=tmp_path / "nope.json").coverage() == (0, 25)


def test_the_platforms_own_in_flight_control_VETOES_completion(tmp_path):
    """⚠ The failure that got past both existing guards, measured on live ChatGPT.

    With deep research on, the assistant turn read ``Pro thinking`` — 27 characters — and held it for
    more than six seconds while ``Stop answering`` was on screen. Non-empty, and stable: both accept
    signals satisfied by a page that had not started answering. The harvest then found nothing and the
    run reported read drift about selectors that were correct.

    Stability is a NECESSARY condition for completion and never a sufficient one. The text can lie about
    being finished; the stop button cannot.
    """
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [FakeHandle(page, "#resp", "Pro thinking")]  # non-empty AND stable
    page.generating = True
    got = asyncio.run(driver.await_response(timeout=1.5, stable_for=0.3, poll=0.1))
    assert got["done"] is False
    assert got["generating"] is True
    assert "STILL GENERATING" in got["reason"], (
        "and the reason must distinguish 'needs a longer budget' from 'the page is broken' — the two "
        "call for opposite responses"
    )


def test_the_veto_also_overrides_the_decisive_state_attribute(tmp_path):
    """A page asserting complete while its stop control is up is contradicting itself.

    Believing the attribute would make the veto bypassable by exactly the platform most likely to get
    its own bookkeeping wrong.
    """
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [
        FakeHandle(page, "#resp", "answer", attrs={"data-state": "complete"})
    ]
    page.generating = True
    got = asyncio.run(driver.await_response(timeout=0.8, stable_for=0.2, poll=0.1))
    assert got["done"] is False


def test_completion_is_accepted_once_the_in_flight_control_GOES_AWAY(tmp_path):
    """The veto must lift, or nothing ever completes."""
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [FakeHandle(page, "#resp", "a full answer with real content")]
    page.generating = True
    state = {"polls": 0}

    def _finish(css):
        if css != "#resp":
            return
        state["polls"] += 1
        if state["polls"] >= 3:
            page.generating = False

    page.on_query = _finish
    got = asyncio.run(driver.await_response(timeout=8.0, stable_for=0.3, poll=0.1))
    assert got["done"] is True and "stable" in got["reason"]


def test_the_stability_clock_RESTARTS_when_generation_resumes(tmp_path):
    """Time spent generating is not time spent stable.

    Otherwise a long generation whose placeholder happens not to change accumulates a stable window
    while the platform is visibly working — which is the original defect wearing a different hat.

    ⚠ Asserted on WHEN it completed, not merely that it did, and bin/mutate.py is why. The first version
    only checked ``done is False``, which the accept condition's own veto already guarantees — so
    deleting the clock reset changed nothing the test could see. The reset is only observable in the
    timing: banked pre-generation stability must not count toward the window that follows.
    """
    driver, page = _driver(tmp_path)
    page.dom["#resp"] = [FakeHandle(page, "#resp", "unchanging placeholder")]
    state = {"polls": 0}

    # Quiet for 5 polls (0.5s banked), generating for 3, then quiet again. With stable_for=0.6 the
    # window can only be satisfied from poll 9 onward — unless the banked 0.5s is wrongly credited, in
    # which case poll 9 completes immediately.
    def _phases(css):
        if css != "#resp":
            return
        state["polls"] += 1
        page.generating = 6 <= state["polls"] <= 8

    page.on_query = _phases
    got = asyncio.run(driver.await_response(timeout=6.0, stable_for=0.6, poll=0.1))
    assert got["done"] is True, "generation stopped, so it must eventually complete"
    assert got["polls"] >= 14, (
        f"completed at poll {got['polls']} — too early. The 0.6s window has to be measured from the "
        f"moment generation STOPPED (poll 9), not from the quiet polls before it."
    )


def test_the_in_flight_selectors_are_the_backends_own_per_platform_sets(tmp_path):
    """⚠ Ported, not invented — and Gemini's breadth carries a specific paid-for lesson.

    The backend's comment (#897b): Gemini's collapsed composer often shows NO stop button mid-run, so a
    stop-button-only check reads a live deep-research run as finished and drops the user's mid-run chat.
    A per-platform map that quietly collapsed to the generic fallback would reintroduce that.
    """
    assert 'data-testid="stop-button"' in phases._GENERATING_SELECTORS["chatgpt"]
    gemini = phases._GENERATING_SELECTORS["gemini"]
    assert "progressbar" in gemini and "data-is-streaming" in gemini, (
        "Gemini needs signals BEYOND the stop button — see #897b"
    )
    assert phases._GENERATING_SELECTORS["gemini"] != phases._GENERATING_FALLBACK


def test_readiness_requires_the_composer_to_SURVIVE_a_settle_window(tmp_path):
    """⚠ Presence is not enough — the third time this codebase has learned that.

    Measured on the run where deep research went off -> on: readiness passed, and ``type_brief`` then
    died with ``StaleHandleError: the node was removed or the page navigated``. The composer was there
    when asked and gone a moment later, because the activation's re-mount had not finished churning.
    """
    driver, page = _driver(tmp_path)
    state = {"looks": 0}

    # Present for two consecutive looks, then gone for two, repeating — a composer mid-re-mount.
    #
    # ⚠ Two, not one, and bin/mutate.py is why. Alternating single looks meant `present_since` was set
    # and reset on every iteration, so the settle comparison was never REACHED — and a mutation that
    # replaced it with `True` changed nothing the test could observe. The fixture has to get far enough
    # in for the guard to matter.
    def _flicker(css):
        if css != "#prompt-textarea":
            return
        state["looks"] += 1
        present = (state["looks"] - 1) % 4 < 2
        page.dom["#prompt-textarea"] = (
            [FakeHandle(page, "#prompt-textarea")] if present else []
        )

    page.on_query = _flicker
    assert asyncio.run(driver.await_composer_ready(timeout=2.0, settle=1.0)) is False, (
        "a composer that keeps vanishing must not be reported ready just because two looks found it"
    )


def test_a_stale_composer_is_RE_QUERIED_rather_than_failing_the_run(tmp_path):
    """``fill`` is three round trips, and a re-mount between any two of them raises StaleHandleError.

    Its message says "re-query the selector" — so that is what happens. Measured on real ChatGPT right
    after deep research turned on.
    """
    driver, page = _driver(tmp_path)
    state = {"fills": 0}

    class Flaky(FakeHandle):
        async def fill(self, text):
            state["fills"] += 1
            if state["fills"] == 1:
                raise RuntimeError(
                    "fill: handle is no-such-handle. The node was removed or the page navigated"
                )
            return await super().fill(text)

    page.dom["#prompt-textarea"] = [Flaky(page, "#prompt-textarea")]
    asyncio.run(driver.type_brief("the brief"))
    assert state["fills"] == 2, "it must have re-queried and tried again"
    assert "the brief" in page.typed


def test_the_re_query_is_BOUNDED_not_an_infinite_loop(tmp_path):
    """A composer that keeps vanishing must surface, with the stale error's own diagnosis intact."""
    driver, page = _driver(tmp_path)
    state = {"fills": 0}

    class AlwaysStale(FakeHandle):
        async def fill(self, text):
            state["fills"] += 1
            raise RuntimeError("fill: handle is no-such-handle. The node was removed")

    page.dom["#prompt-textarea"] = [AlwaysStale(page, "#prompt-textarea")]
    with pytest.raises(RuntimeError, match="no-such-handle"):
        asyncio.run(driver.type_brief("x", attempts=2))
    assert state["fills"] == 2, "bounded at the attempt count, and the original error propagates"


def test_a_manifest_problem_is_not_swallowed_by_the_stale_retry(tmp_path):
    """The retry catches RuntimeError; ManifestError is a ValueError, and must still fail loudly."""
    driver, page = _driver(tmp_path)
    page.dom["#prompt-textarea"] = []
    with pytest.raises(ManifestError, match="vanished before typing"):
        asyncio.run(driver.type_brief("x"))
