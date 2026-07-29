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


def test_coverage_counts_against_every_baseline_key_not_just_the_supplied_ones(tmp_path):
    """A partial manifest must not shrink the denominator.

    It used to: the loaded file *replaced* the baseline structure, so a file holding two keys reported
    ``(2, 2)`` — complete — and ``missing()`` returned nothing. Measured on the first real capture,
    where seven of twenty-five keys read as 7/7 done. The two functions whose only job is to report how
    far along the capture is were the two that lied about it.
    """
    path = tmp_path / "m.json"
    path.write_text(
        json.dumps({"platforms": {"chatgpt": {"composer": "#c", "send": "#s"}}})
    )
    manifest = selectors.load_manifest(path)
    assert manifest.coverage() == (2, 25)
    assert len(manifest.missing()) == 23


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
    def __init__(self, page, css, text="", attrs=None):
        self.page = page
        self.css = css
        self.text = text
        self.attrs = attrs or {}

    async def inner_text(self):
        return self.text

    async def get_attribute(self, name):
        return self.attrs.get(name)

    async def click(self):
        self.page.clicks.append(self.css)
        self.page.focused = self.css
        if self.css in self.page.toggles:
            self.page.toggles[self.css] = "true"
        if self.css in self.page.sends_produce_response:
            self.page.dom.setdefault(self.page.response_css, [FakeHandle(self.page, self.page.response_css, "answer")])

    async def fill(self, text):
        await self.click()
        self.page.typed.append(text)
        return {"ok": True, "path": "execCommand"}


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

    async def query_selector(self, css):
        if css in self.toggles:
            return FakeHandle(self, css, attrs={"aria-pressed": self.toggles[css]})
        found = self.dom.get(css)
        return found[0] if found else None

    async def query_selector_all(self, css):
        if css in self.dom:
            return list(self.dom[css])
        return []

    async def evaluate(self, _js):
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


def _deps(tmp_path, *, sources=3, toggle="false"):
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
    bodies = phases.build_phase_bodies(deps, ("chatgpt",))
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
    bodies = phases.build_phase_bodies(deps, ("chatgpt",))
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
    bodies = phases.build_phase_bodies(deps, ("chatgpt",))
    for body in bodies:
        with pytest.raises(ManifestError):
            asyncio.run(body(None))


def test_a_selector_that_matches_nothing_names_what_was_tried(tmp_path):
    deps, page = _deps(tmp_path)
    page.dom["#send"] = []
    bodies = phases.build_phase_bodies(deps, ("chatgpt",))
    asyncio.run(bodies[0](None))
    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[1](None))
    assert "did not match anything" in str(exc.value)
    assert "#send" in str(exc.value), "the message must name the selectors tried"


def test_p3_raises_when_the_harvest_fails_its_predicate(tmp_path):
    """A run must not report success having collected nothing — the P1 outcome exactly."""
    deps, _page = _deps(tmp_path, sources=0)
    bodies = phases.build_phase_bodies(deps, ("chatgpt",))
    asyncio.run(bodies[0](None))
    with pytest.raises(ManifestError) as exc:
        asyncio.run(bodies[3](None))
    assert "harvest failed its predicate" in str(exc.value)


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

    assert asyncio.run(intent.confirmed_off()) is True, "aria-pressed=false is a positive off"
    page.toggles = {}  # the control can no longer be found at all
    assert asyncio.run(intent.confirmed_off()) is False, (
        "not-found must never be treated as confirmed-off"
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
    page = FakePage(dom={"button, a, [role=button]": []})
    page.dom["button, a, [role=button]"] = [FakeHandle(page, "#x", "Start research")]
    entry = selectors.SelectorEntry(css=("#missing",), text_contains="start research")
    assert asyncio.run(phases.resolve(page, entry)) is not None


def test_resolve_returns_none_rather_than_guessing():
    page = FakePage()
    assert asyncio.run(phases.resolve(page, selectors.SelectorEntry(css=("#nope",)))) is None


def test_typing_uses_the_editor_aware_fill_path(tmp_path):
    """ProseMirror-style composers need it; a value assignment leaves the send control disabled."""
    deps, page = _deps(tmp_path)
    bodies = phases.build_phase_bodies(deps, ("chatgpt",))
    asyncio.run(bodies[1](None))
    assert page.typed == [deps.topic]
    assert page.clicks.count("#prompt-textarea") >= 1, "fill focuses by a real tap first"
