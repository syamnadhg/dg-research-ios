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


#: Coherent off: no indicator pill AND a chat placeholder.
#:
#: This carried `pillVisible: True` at first, which is self-contradictory once the pill is defined as a
#: stateless INDICATOR — an element reading "Deep research" cannot be visible while the composer says
#: "Ask Gemini". Third time a fixture in this suite has been incoherent with the model it stands for, and
#: each time the symptom was a test failing for a reason that had nothing to do with the code.
OFF_STATE = {
    "pillVisible": False, "pressed": False, "placeholderResearch": False,
    "placeholderChat": True, "placeholder": "ask gemini",
}
#: The state that broke the old reader: on, with no ARIA anywhere — and no pill either.
#:
#: `pillVisible` was True here, which meant the test named "placeholder only" was actually passing on the
#: pill and would have kept passing with the placeholder signal deleted. bin/mutate.py caught it. A
#: fixture that names one signal has to carry only that signal, or it proves nothing about it.
PLACEHOLDER_ONLY_ON = {
    "pillVisible": False, "pressed": False, "placeholderResearch": True,
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


def test_chatgpts_real_placeholder_is_recognised_as_chat_mode():
    """"Chat with ChatGPT" — the actual string, measured while driving the toggle.

    The first version of the chat-placeholder list guessed "ask chatgpt", which matches nothing on
    ChatGPT. The effect was one-sided and easy to miss: the on-signal still worked, so runs looked fine,
    but `confirmed_off` could never fire for that platform and escalation was therefore refused forever.
    A guard that can never say "off" is half a guard.

    Asserted against the CALL, not the bare phrase: the first version checked `"chat with" in js` and
    passed even with the check deleted, because the comment explaining the fix contains `chat with` too.
    bin/mutate.py caught that — the same grep-cannot-tell-code-from-commentary trap `_code_only` exists
    for elsewhere in this repo.
    """
    js = phases._TOGGLE_STATE_JS
    assert "includes('chat with')" in js
    for other in ("ask gemini", "write a message"):
        assert f"includes('{other}')" in js, f"{other} must still be recognised"


def test_the_measured_chatgpt_on_state_reads_as_ON_though_pressed_is_false():
    """Verbatim from driving the real control: the pill appears, `pressed` never becomes true.

    BEFORE {pillVisible: false, pressed: false, placeholder: "chat with chatgpt"}
    AFTER  {pillVisible: true,  pressed: false, placeholder: "chat with chatgpt"}

    An aria-pressed reader sees no change across an activation that plainly happened. This is the whole
    reason the predicate was ported, pinned to the numbers the real page produced.
    """
    driver, _ = _driver_with(
        {"pillVisible": False, "pressed": False, "placeholderResearch": False,
         "placeholderChat": True, "placeholder": "chat with chatgpt"},
        platform="chatgpt",
    )
    assert asyncio.run(driver._toggle_on_predicate("deep_research_toggle")()) is False
    assert asyncio.run(driver._toggle_off_predicate("deep_research_toggle")()) is True

    driver, _ = _driver_with(
        {"pillVisible": True, "pressed": False, "placeholderResearch": False,
         "placeholderChat": True, "placeholder": "chat with chatgpt"},
        platform="chatgpt",
    )
    assert asyncio.run(driver._toggle_on_predicate("deep_research_toggle")()) is True, (
        "the pill appearing IS ChatGPT's on-signal"
    )
    assert asyncio.run(driver._toggle_off_predicate("deep_research_toggle")()) is False, (
        "and the two predicates must never both fire"
    )


def test_a_control_carrying_state_is_not_mistaken_for_the_indicator():
    """The toggle must not be its own on-signal.

    Measured on the mock platform, whose toggle sits in the form with `aria-pressed`: the predicate
    returned True while aria-pressed went false -> false, so `enable_deep_research` reported "already
    enabled", never tapped, and the run continued with deep research OFF. The P1 shape, produced by the
    check meant to prevent it.

    A control carries aria-pressed/aria-checked/aria-selected; an indicator carries none. Verified both
    ways against real ChatGPT: its menu item has aria-checked (excluded), its active composer pill has
    no state attribute (kept).
    """
    js = phases._TOGGLE_STATE_JS
    for attr in ("aria-pressed", "aria-checked", "aria-selected"):
        assert f"p.hasAttribute('{attr}')" in js, (
            f"an element carrying {attr} is a control, not the indicator"
        )
    assert js.index("hasAttribute('aria-pressed')") < js.index("=== target"), (
        "the exclusion must run BEFORE the text match, or the control is still selected"
    )


def test_the_controls_own_state_is_enough_on_its_own():
    """A well-behaved toggle reports its own aria-pressed, and that must be sufficient.

    Measured on the mock platform: the tap flipped aria-pressed false -> true and the predicate still
    said off, because the ChatGPT branch read only pill + placeholder. Copying `_cgpt_state_js` verbatim
    caused it — the backend's `pressed` is about the pill, and its platforms supply other evidence. The
    pill cannot supply it here either, since the pill scan skips state-carrying elements by design.
    """

    class ControlStatePage(StatePage):
        def __init__(self, state, pressed):
            super().__init__(state)
            self._pressed = pressed

        async def get_attribute(self, name):
            if name == "aria-pressed":
                return "true" if self._pressed else "false"
            return None

    silent = {"pillVisible": False, "pressed": False, "placeholderResearch": False,
              "placeholderChat": False, "placeholder": "type here"}
    for platform in ("chatgpt", "gemini", "claude"):
        key = "research_toggle" if platform == "claude" else "deep_research_toggle"
        driver, _ = _driver_with(silent, platform=platform)
        driver.page = ControlStatePage(silent, pressed=True)
        assert asyncio.run(driver._toggle_on_predicate(key)()) is True, (
            f"{platform}: the control's own aria-pressed=true must read as ON"
        )
        driver.page = ControlStatePage(silent, pressed=False)
        assert asyncio.run(driver._toggle_on_predicate(key)()) is False
        assert asyncio.run(driver._toggle_off_predicate(key)()) is True, (
            f"{platform}: aria-pressed=false is a positive off-signal"
        )
