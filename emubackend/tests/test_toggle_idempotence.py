"""`enable_deep_research` must be idempotent, because toggle state outlives the session.

This is a regression suite for a bug that a single run against fresh state cannot see. The e2e gate had
passed repeatedly while the defect was live: the first run of the day starts with the toggle off, taps
it on, and everything is correct. The *second* run starts with it on — as every real device does, since
persistent login is the point — taps it off, and completes a full P0–P3 with deep research disabled
while reporting success.

So the tests below are written from both starting states. A test that only covers "off, then enable" is
precisely the test that shipped the bug.
"""

from __future__ import annotations

import asyncio

from emubackend import harvest, intents, phases
from emubackend.selectors import SelectorEntry, SelectorManifest


class FakeHandle:
    """A toggle that reports and flips its own `aria-pressed`, like the real control."""

    def __init__(self, pressed: bool):
        self.pressed = pressed
        self.clicks = 0

    async def get_attribute(self, name: str) -> str | None:
        if name == "aria-pressed":
            return "true" if self.pressed else "false"
        return None

    async def click(self) -> None:
        self.clicks += 1
        self.pressed = not self.pressed   # a real toggle toggles; it does not "enable"


class FakePage:
    def __init__(self, handle: FakeHandle):
        self.handle = handle

    async def query_selector(self, css: str):
        return self.handle

    async def query_selector_all(self, css: str):
        return [self.handle]

    async def evaluate(self, script: str, *args):
        """Answer the deep-research state probe from the fake's own pressed flag.

        The probe replaced a bare `aria-pressed` read, so a fake returning None made every toggle
        look OFF — including the already-on case these tests exist to pin.
        """
        if "placeholderResearch" in script:
            return {
                # The pill tracks the state rather than being always-present: on ChatGPT a VISIBLE
                # "deep research" pill in the composer IS the active signal (the backend's
                # `_cgpt_state_js` treats it as sufficient), so a fake that shows it while off would
                # report every toggle as already-on and this suite would never click anything.
                "pillVisible": self.handle.pressed,
                "pressed": self.handle.pressed,
                "placeholderResearch": self.handle.pressed,
                "placeholderChat": not self.handle.pressed,
                "placeholder": "what do you want to research" if self.handle.pressed else "ask chatgpt",
            }
        return None


def _driver(pressed: bool) -> tuple[phases.PlatformDriver, FakeHandle]:
    handle = FakeHandle(pressed)
    manifest = SelectorManifest(
        platforms={
            "chatgpt": {
                key: SelectorEntry(css=(css,), provenance="test")
                for key, css in {
                    "logged_in_marker": "#marker",
                    "composer": "#composer",
                    "send": "#send",
                    "deep_research_toggle": "#toggle",
                    "sources": "#src",
                    "response_container": "#resp",
                }.items()
            }
        },
        source="test fixture",
    )
    driver = phases.PlatformDriver(
        "chatgpt",
        phases.PhaseDeps(
            manifest=manifest,
            registry=intents.IntentRegistry(),
            history=harvest.HarvestHistory(),
            pages={"chatgpt": FakePage(handle)},
            topic="anything",
        ),
    )
    return driver, handle


def test_an_already_enabled_toggle_is_left_alone():
    async def body():
        """The bug. One unconditional tap here disables deep research for the whole run."""
        driver, handle = _driver(pressed=True)
        outcome = await driver.enable_deep_research()

        assert handle.clicks == 0, "tapping an already-on toggle turns deep research OFF"
        assert handle.pressed is True, "deep research must still be enabled afterwards"
        assert outcome is not None and outcome.predicate_passed

    asyncio.run(body())


def test_a_disabled_toggle_is_enabled():
    async def body():
        """The other half — the case that was always covered, kept so the fix cannot overshoot."""
        driver, handle = _driver(pressed=False)
        outcome = await driver.enable_deep_research()

        assert handle.clicks == 1
        assert handle.pressed is True
        assert outcome is not None and outcome.predicate_passed

    asyncio.run(body())


def test_calling_it_repeatedly_converges_rather_than_oscillating():
    async def body():
        """Three calls in a row must leave it on, not flip-flop.

        The property that actually matters operationally: a resumed run may re-enter the phase, and an
        oscillating step means the outcome depends on how many times it happened to run.
        """
        driver, handle = _driver(pressed=False)
        for _ in range(3):
            await driver.enable_deep_research()

        assert handle.pressed is True
        assert handle.clicks == 1, "only the first call should have needed to act"

    asyncio.run(body())


def test_the_no_op_is_not_counted_as_an_execution():
    async def body():
        """The bake ledger counts real executions, and a skipped tap is not one.

        Inflating it would let an intent reach its bake threshold without ever having acted — and the bake
        threshold is what gates live escalation.
        """
        driver, _ = _driver(pressed=True)
        await driver.enable_deep_research()

        intent = driver.deps.registry.get("chatgpt.deep_research_toggle")
        assert getattr(intent, "executions", 0) == 0

    asyncio.run(body())


def test_a_platform_without_a_toggle_reports_nothing_to_do():
    async def body():
        """NotebookLM has no research toggle. Absence must be `None`, not a manufactured failure."""
        driver, _ = _driver(pressed=False)
        driver.deps.manifest.platforms["chatgpt"].pop("deep_research_toggle", None)
        assert await driver.enable_deep_research() is None

    asyncio.run(body())


# ======================================================================================
# the predicate port — signals aria-pressed could never see
# ======================================================================================


class StatePage:
    """A page whose deep-research state is whatever the probe is told to report.

    Exists to pin the cases that motivated porting the backend's predicates: a control that is
    genuinely ON while carrying no ARIA state at all. The old reader returned False on exactly this
    page, and the backend records what that cost — from ``research.py::_GEMINI_DR_STATE_JS``:

        the DR pill's class (mat-tonal-button…) carries NO reliable pressed marker, so a
        pressed-class-only check false-negatived an ACTIVE pill last E2E and the CUA fallback then
        toggled the working DR OFF
    """

    def __init__(self, state: dict):
        self.state = state
        self.clicks = 0

    async def query_selector(self, css: str):
        return self

    async def query_selector_all(self, css: str):
        return [self]

    async def inner_text(self):
        return "Deep research"

    async def get_attribute(self, name: str):
        return None

    async def click(self):
        self.clicks += 1

    async def evaluate(self, script: str, *args):
        if "placeholderResearch" in script:
            return self.state
        return None


def _driver_with(state: dict, platform: str = "gemini"):
    keys = {
        "logged_in_marker": "#marker",
        "composer": "#composer",
        "send": "#send",
        "deep_research_toggle": "#dr",
        "sources": ".src",
        "response_container": "#resp",
    }
    if platform == "claude":
        keys["research_toggle"] = keys.pop("deep_research_toggle")
        keys["artifact_panel"] = "#art"
    if platform == "gemini":
        keys["start_research"] = "#start"
    page = StatePage(state)
    manifest = SelectorManifest(
        platforms={
            platform: {
                key: SelectorEntry(css=(css,), provenance="test") for key, css in keys.items()
            }
        }
    )
    deps = phases.PhaseDeps(
        manifest=manifest,
        registry=intents.IntentRegistry(),
        history=harvest.HarvestHistory(),
        pages={platform: page},
        topic="t",
    )
    return phases.PlatformDriver(platform, deps), page


OFF_STATE = {
    "pillVisible": True, "pressed": False, "placeholderResearch": False,
    "placeholderChat": True, "placeholder": "ask gemini",
}
#: The state that broke the old reader: on, with no ARIA anywhere.
PLACEHOLDER_ONLY_ON = {
    "pillVisible": True, "pressed": False, "placeholderResearch": True,
    "placeholderChat": False, "placeholder": "what do you want to research",
}


def test_a_research_placeholder_reads_as_ON_without_any_aria_state():
    driver, _ = _driver_with(PLACEHOLDER_ONLY_ON)
    assert asyncio.run(driver._toggle_on_predicate("deep_research_toggle")()) is True


def test_that_state_is_NOT_also_confirmed_off():
    """The two predicates must not both fire — `off` authorises a click on a live control."""
    driver, _ = _driver_with(PLACEHOLDER_ONLY_ON)
    assert asyncio.run(driver._toggle_off_predicate("deep_research_toggle")()) is False


def test_an_already_on_toggle_is_left_alone_on_the_placeholder_signal_alone():
    """The whole point. Before the port this tapped the control and switched deep research OFF."""
    driver, page = _driver_with(PLACEHOLDER_ONLY_ON)
    outcome = asyncio.run(driver.enable_deep_research())
    assert page.clicks == 0, "an ON control must not be tapped"
    assert outcome.predicate_passed
    assert "already enabled" in (outcome.reason or "")


def test_a_chat_placeholder_is_a_positive_off_signal():
    driver, _ = _driver_with(OFF_STATE)
    assert asyncio.run(driver._toggle_off_predicate("deep_research_toggle")()) is True
    assert asyncio.run(driver._toggle_on_predicate("deep_research_toggle")()) is False


def test_an_ambiguous_state_is_neither_on_nor_confirmed_off():
    """Neither placeholder recognised and no pressed marker: the honest answer is "I cannot tell".

    Reporting confirmed-off here is the dangerous direction — it authorises a click on a control whose
    state is unknown, which is how a working toggle gets switched off.
    """
    driver, _ = _driver_with(
        {"pillVisible": False, "pressed": False, "placeholderResearch": False,
         "placeholderChat": False, "placeholder": "something new"}
    )
    assert asyncio.run(driver._toggle_on_predicate("deep_research_toggle")()) is False
    assert asyncio.run(driver._toggle_off_predicate("deep_research_toggle")()) is False


def test_chatgpts_visible_pill_alone_reads_as_on():
    """ChatGPT's signal differs from Gemini's: the pill being VISIBLE in the composer is active.

    Per the backend's `_cgpt_state_js`, `active = pillVisible || placeholder.includes('research')`.
    """
    driver, _ = _driver_with(
        {"pillVisible": True, "pressed": False, "placeholderResearch": False,
         "placeholderChat": False, "placeholder": ""},
        platform="chatgpt",
    )
    assert asyncio.run(driver._toggle_on_predicate("deep_research_toggle")()) is True


def test_an_uncaptured_toggle_never_reads_as_on_however_good_the_placeholder():
    """A platform with no captured selector must not look configured off a page-level signal."""
    page = StatePage(PLACEHOLDER_ONLY_ON)
    manifest = SelectorManifest(
        platforms={"gemini": {"deep_research_toggle": SelectorEntry(provenance="uncaptured")}}
    )
    deps = phases.PhaseDeps(
        manifest=manifest, registry=intents.IntentRegistry(),
        history=harvest.HarvestHistory(), pages={"gemini": page}, topic="t",
    )
    driver = phases.PlatformDriver("gemini", deps)
    assert asyncio.run(driver._toggle_on_predicate("deep_research_toggle")()) is False


def test_the_control_name_differs_per_platform():
    """Claude's control is "research"; ChatGPT's and Gemini's are "deep research".

    Searching Claude for "deep research" finds nothing at all — not a near miss. The backend's
    selfheal_intents.json records the accessible names, which is where this came from.
    """
    captured = {}

    class Recorder(StatePage):
        async def evaluate(self, script: str, *args):
            if "placeholderResearch" in script:
                captured["script"] = script
            return self.state

    for platform, key, expected in (
        ("claude", "research_toggle", '"research"'),
        ("gemini", "deep_research_toggle", '"deep research"'),
    ):
        driver, _ = _driver_with(OFF_STATE, platform=platform)
        driver.page = Recorder(OFF_STATE)
        asyncio.run(driver._toggle_on_predicate(key)())
        assert captured["script"].rstrip().endswith(expected + ")"), (
            f"{platform} must probe for {expected}, got …{captured['script'][-40:]!r}"
        )
